// lib/services/media/media_downloader.dart
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';

enum MediaDownloadSourceMode { auto, direct, mirror }

class MediaDownloader {
  final Dio _dio;
  MediaDownloader({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(minutes: 30),
            ));

  static const List<String> githubMirrors = [
    'https://gh-proxy.com/',
    'https://ghfast.top/',
  ];

  static List<String> mirrorUrls(String directUrl) {
    if (directUrl.startsWith('https://huggingface.co/')) {
      return [
        directUrl.replaceFirst(
            'https://huggingface.co/', 'https://hf-mirror.com/')
      ];
    }
    if (directUrl.startsWith('https://github.com/') ||
        directUrl.startsWith('https://objects.githubusercontent.com/')) {
      return githubMirrors.map((m) => '$m$directUrl').toList();
    }
    return const [];
  }

  static List<String> candidateUrls(
      String directUrl, MediaDownloadSourceMode mode) {
    switch (mode) {
      case MediaDownloadSourceMode.direct:
        return [directUrl];
      case MediaDownloadSourceMode.mirror:
        return [...mirrorUrls(directUrl), directUrl];
      case MediaDownloadSourceMode.auto:
        return [directUrl, ...mirrorUrls(directUrl)];
    }
  }

  static String ytDlpAssetName() {
    if (Platform.isWindows) return 'yt-dlp.exe';
    if (Platform.isMacOS) return 'yt-dlp_macos';
    return 'yt-dlp_linux';
  }

  static String ytDlpDirectUrl() =>
      'https://github.com/yt-dlp/yt-dlp/releases/latest/download/${ytDlpAssetName()}';

  static String ffmpegDirectUrl() {
    if (Platform.isWindows) {
      return 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip';
    }
    if (Platform.isMacOS) {
      return 'https://evermeet.cx/ffmpeg/getrelease/zip';
    }
    throw UnsupportedError('Linux 不提供 ffmpeg 便携版，请使用系统包管理器安装');
  }

  static String whisperReleasesApiUrl() =>
      'https://api.github.com/repos/ggml-org/whisper.cpp/releases?per_page=30';

  static String? pickWhisperAsset(List<String> names,
      {required bool isWindows, required bool isMac, required bool isArm}) {
    final candidates = MediaToolCandidates.whisper(names,
        isWindows: isWindows, isMac: isMac, isArm: isArm);
    return candidates.isEmpty ? null : candidates.first;
  }

  Future<File> download(
    String directUrl, {
    required File destFile,
    MediaDownloadSourceMode mode = MediaDownloadSourceMode.auto,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
    String? expectedSha256,
  }) async {
    await destFile.parent.create(recursive: true);
    final partial = File('${destFile.path}.part');
    Object? lastError;
    for (final url in candidateUrls(directUrl, mode)) {
      try {
        await _dio.download(
          url,
          partial.path,
          onReceiveProgress: onProgress,
          cancelToken: cancelToken,
        );
        if (expectedSha256 != null) {
          final actual = await sha256File(partial);
          if (actual != expectedSha256) {
            lastError = Exception('SHA256 校验失败: $url');
            if (await partial.exists()) await partial.delete();
            continue;
          }
        }
        if (await destFile.exists()) await destFile.delete();
        await partial.rename(destFile.path);
        return destFile;
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel) rethrow;
        lastError = e;
      } catch (e) {
        lastError = e;
      }
    }
    throw Exception('下载失败: $lastError');
  }

  /// 解压 zip / tar.gz 到 destDir；非压缩包（如 yt-dlp 单文件）直接成功。
  Future<void> extract(File archiveFile, String destDir) async {
    final name = archiveFile.path.toLowerCase();
    if (!name.endsWith('.zip') &&
        !name.endsWith('.tar.gz') &&
        !name.endsWith('.tgz')) {
      return;
    }
    await Directory(destDir).create(recursive: true);
    final bytes = await archiveFile.readAsBytes();
    final Archive archive;
    if (name.endsWith('.zip')) {
      archive = ZipDecoder().decodeBytes(bytes);
    } else {
      archive = TarDecoder().decodeBytes(GZipDecoder().decodeBytes(bytes));
    }
    await extractArchiveToDisk(archive, destDir);
  }

  /// 流式计算 SHA256（模型文件可达 1.7GB，禁止 readAsBytes）。
  static Future<String> sha256File(File f) async {
    final sink = _DigestConsumer();
    final converter = crypto.sha256.startChunkedConversion(sink);
    await for (final chunk in f.openRead()) {
      converter.add(chunk);
    }
    converter.close();
    return sink.value!.toString();
  }

  /// 解析 `df -k` 输出的 Available 列（字节）。
  static int? parseDfK(String stdout) {
    final lines = stdout.trim().split(RegExp(r'\r?\n'));
    if (lines.length < 2) return null;
    final cols = lines.last.trim().split(RegExp(r'\s+'));
    if (cols.length < 4) return null;
    final kb = int.tryParse(cols[3]);
    return kb == null ? null : kb * 1024;
  }

  Future<int?> freeDiskBytes(String path) async {
    try {
      if (Platform.isWindows) {
        final drive = path.length >= 2 && path[1] == ':' ? path[0] : 'C';
        final r = await Process.run('powershell', [
          '-Command',
          '(New-Object -ComObject Scripting.FileSystemObject)'
              '.GetDrive("$drive:").FreeSpace',
        ]);
        return int.tryParse(r.stdout.toString().trim());
      }
      final r = await Process.run('df', ['-k', path]);
      return parseDfK(r.stdout.toString());
    } catch (_) {
      return null;
    }
  }
}

class _DigestConsumer implements Sink<crypto.Digest> {
  crypto.Digest? value;
  @override
  void add(crypto.Digest data) => value = data;
  @override
  void close() {}
}

/// whisper 资产筛选纯函数（media_tool_service 与 media_downloader 共用）。
class MediaToolCandidates {
  static List<String> whisper(List<String> names,
      {required bool isWindows, required bool isMac, required bool isArm}) {
    final bad =
        RegExp(r'cuda|blas|win32|xcframework|adreno|cublas|vulkan|clblast|opencl|wasm|addon');
    return names.where((n) {
      if (bad.hasMatch(n)) return false;
      if (isWindows) return n.contains('x64') && n.endsWith('.zip');
      if (isMac) {
        if (!(n.contains('macos') || n.contains('darwin'))) return false;
        return isArm
            ? n.contains('arm64')
            : n.contains('x64') && !n.contains('arm64');
      }
      if (!(n.contains('linux') || n.contains('ubuntu'))) return false;
      if (!n.endsWith('.tar.gz') && !n.endsWith('.tgz')) return false;
      return isArm
          ? n.contains('arm64')
          : n.contains('x64') && !n.contains('arm64');
    }).toList();
  }
}
