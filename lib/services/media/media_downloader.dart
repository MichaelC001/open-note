// lib/services/media/media_downloader.dart
import 'dart:ffi';
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

  static const ghProxyPrefix = 'https://gh-proxy.com/';

  static const List<String> githubMirrors = [
    ghProxyPrefix,
    'https://ghfast.top/',
  ];

  static const npmmirrorBase =
      'https://registry.npmmirror.com/-/binary/ffmpeg-static/';

  /// ffmpeg-static 资产在 npmmirror 的同名镜像（资产名与 GitHub release 一致）。
  /// 仅映射具体 tag 的 release 下载链；latest 链不映射（npmmirror 目录按 tag 组织，
  /// 钉死版本段会导致「更新」总命中旧版）。
  static List<String> npmmirrorUrls(String directUrl) {
    final m = RegExp(
      r'ffmpeg-static/releases/download/([^/]+)/(ffmpeg-[a-z0-9-]+)$',
    ).firstMatch(directUrl);
    final tag = m?.group(1);
    if (m == null || tag == null || tag == 'latest') return const [];
    return ['$npmmirrorBase$tag/${m.group(2)}'];
  }

  static List<String> mirrorUrls(String directUrl) {
    if (directUrl.startsWith('https://huggingface.co/')) {
      return [
        directUrl.replaceFirst(
            'https://huggingface.co/', 'https://hf-mirror.com/')
      ];
    }
    if (directUrl.startsWith('https://github.com/') ||
        directUrl.startsWith('https://objects.githubusercontent.com/')) {
      return [...npmmirrorUrls(directUrl),
        ...githubMirrors.map((m) => '$m$directUrl')];
    }
    return const [];
  }

  static List<String> candidateUrls(
      String directUrl, MediaDownloadSourceMode mode) {
    final mirrors = mirrorUrls(directUrl);
    switch (mode) {
      case MediaDownloadSourceMode.direct:
        // direct/mirror 为「优先级」而非「排他」：直连优先，连接失败自动回退镜像
        return [directUrl, ...mirrors];
      case MediaDownloadSourceMode.mirror:
        return [...mirrors, directUrl];
      case MediaDownloadSourceMode.auto:
        // npmmirror 为全球 CDN，ffmpeg 候选置首（直连 GitHub 在国内极慢）
        final npmFirst = mirrors.isNotEmpty &&
            mirrors.first.startsWith(npmmirrorBase);
        return npmFirst
            ? [mirrors.first, directUrl, ...mirrors.skip(1)]
            : [directUrl, ...mirrors];
    }
  }

  static String ytDlpAssetName() {
    if (Platform.isWindows) return 'yt-dlp.exe';
    if (Platform.isMacOS) return 'yt-dlp_macos';
    return 'yt-dlp_linux';
  }

  static String ytDlpDirectUrl() =>
      'https://github.com/yt-dlp/yt-dlp/releases/latest/download/${ytDlpAssetName()}';

  /// ffmpeg-static 资产的「平台-位数」后缀。
  static String _ffmpegAssetSuffix() {
    final arch = Platform.isMacOS
        ? 'darwin'
        : Platform.isWindows
            ? 'win32'
            : 'linux';
    final isArm = switch (Abi.current()) {
      Abi.macosArm64 || Abi.linuxArm64 => true,
      _ => false,
    };
    final bits = Platform.isWindows
        ? 'x64'
        : isArm
            ? 'arm64'
            : 'x64';
    return '$arch-$bits';
  }

  /// 三平台统一 ffmpeg-static 单文件静态二进制。
  /// [tag] 为 null 时取 latest；否则下载该具体 tag（用于「更新到检测到的版本」）。
  static String ffmpegDirectUrl({String? tag}) {
    final asset = 'ffmpeg-${_ffmpegAssetSuffix()}';
    if (tag == null || tag.isEmpty) {
      return 'https://github.com/eugeneware/ffmpeg-static/releases/latest/download/$asset';
    }
    return 'https://github.com/eugeneware/ffmpeg-static/releases/download/$tag/$asset';
  }

  static String whisperReleasesApiUrl() =>
      'https://api.github.com/repos/ggml-org/whisper.cpp/releases?per_page=30';

  /// whisper.cpp releases API 候选链：gh-proxy 支持代理 api.github.com，
  /// ghfast.top 不支持（Invalid input），故仅 gh-proxy 入链。
  static List<String> whisperApiCandidates(
      String apiUrl, {required MediaDownloadSourceMode mode}) {
    final mirrored = '$ghProxyPrefix$apiUrl';
    switch (mode) {
      case MediaDownloadSourceMode.mirror:
        return [mirrored, apiUrl];
      case MediaDownloadSourceMode.direct:
      case MediaDownloadSourceMode.auto:
        return [apiUrl, mirrored];
    }
  }

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
    final attempts = <String>[];
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
            attempts.add('$url → SHA256 校验失败');
            if (await partial.exists()) await partial.delete();
            continue;
          }
        }
        if (await destFile.exists()) await destFile.delete();
        await partial.rename(destFile.path);
        return destFile;
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel) rethrow;
        attempts.add('$url → ${_briefError(e)}');
      } catch (e) {
        attempts.add('$url → ${_briefError(e)}');
      }
    }
    throw Exception(
        '下载失败（已尝试 ${attempts.length} 个源）：${attempts.join('；')}');
  }

  /// 逐源诊断用的错误摘要：toString 首行并截断，避免堆栈刷屏。
  static String _briefError(Object e) {
    var s = e.toString().split('\n').first.trim();
    if (s.length > 120) s = s.substring(0, 120);
    return s;
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
    // cuda 进主排除（CUDA 包 ggml-cuda.dll 依赖 NVIDIA 驱动，无 N 卡进程
    // 无法启动 → 校验失败），单独作兜底层：无纯 CPU 包可用时仍可下载尝试。
    // x64 主层不要求 'win' 子串——纯 CPU 包名为 whisper-bin-x64.zip。
    final bad =
        RegExp(r'cuda|blas|win32|xcframework|adreno|cublas|vulkan|clblast|opencl|wasm|addon');
    if (isWindows) {
      bool zipOk(String n) =>
          n.endsWith('.zip') &&
          (isArm ? n.contains('arm64') : n.contains('x64'));
      // 主优先级：非 bad 包（x64 即纯 CPU；arm64 需含 'cpu'）；兜底层仅 cuda 包，
      // 两者皆非（blas/cublas/win32/adreno/opencl 等）不命中（cublas 含 blas 子串
      // 已被 bad 覆盖）
      bool isMain(String n) =>
          !bad.hasMatch(n) && (isArm ? n.contains('cpu') : true);
      final main = <String>[];
      final cuda = <String>[];
      for (final n in names) {
        if (!zipOk(n)) continue;
        if (isMain(n)) {
          main.add(n);
        } else if (n.contains('cuda')) {
          cuda.add(n);
        }
      }
      return [...main, ...cuda];
    }
    return names.where((n) {
      if (bad.hasMatch(n)) return false;
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
