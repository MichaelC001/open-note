// lib/services/media/media_tool_service.dart
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'process_runner.dart';

enum MediaToolKind { ffmpeg, ytDlp, whisperCli }

enum MediaToolSource { appManaged, systemPath }

class MediaToolStatus {
  final MediaToolKind kind;
  final bool ready;
  final String? path;
  final String? version;
  final MediaToolSource? source;

  const MediaToolStatus({
    required this.kind,
    required this.ready,
    this.path,
    this.version,
    this.source,
  });

  const MediaToolStatus.missing(this.kind)
      : ready = false,
        path = null,
        version = null,
        source = null;
}

class MediaToolService {
  final Future<ProcessRunResult> Function(String, List<String>) run;
  final Future<String> Function() resolveBaseDir;

  MediaToolService({
    Future<ProcessRunResult> Function(String, List<String>)? run,
    Future<String> Function()? resolveBaseDir,
  })  : run = run ?? runCommand,
        resolveBaseDir = resolveBaseDir ?? _defaultBaseDir;

  static Future<String> _defaultBaseDir() async =>
      (await getApplicationSupportDirectory()).path;

  Future<String> toolDir(MediaToolKind kind) async {
    final sub = switch (kind) {
      MediaToolKind.ffmpeg => 'ffmpeg',
      MediaToolKind.ytDlp => 'yt-dlp',
      MediaToolKind.whisperCli => 'whisper',
    };
    final dir = Directory('${await resolveBaseDir()}/tools/$sub');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  String binaryName(MediaToolKind kind) {
    final exe = Platform.isWindows ? '.exe' : '';
    return switch (kind) {
      MediaToolKind.ffmpeg => 'ffmpeg$exe',
      MediaToolKind.ytDlp => 'yt-dlp$exe',
      MediaToolKind.whisperCli => 'whisper-cli$exe',
    };
  }

  Future<String?> appManagedPath(MediaToolKind kind) async {
    final file = File('${await toolDir(kind)}/${binaryName(kind)}');
    return await file.exists() ? file.path : null;
  }

  Future<MediaToolStatus> check(MediaToolKind kind) async {
    final appPath = await appManagedPath(kind);
    if (appPath != null) {
      final st = await _verify(kind, appPath, MediaToolSource.appManaged);
      if (st != null) return st;
    }
    final lookup = Platform.isWindows ? 'where' : 'which';
    final names = switch (kind) {
      MediaToolKind.ffmpeg => ['ffmpeg'],
      MediaToolKind.ytDlp => ['yt-dlp'],
      MediaToolKind.whisperCli => ['whisper-cli', 'whispercpp', 'whisper.cpp'],
    };
    for (final name in names) {
      final r = await run(lookup, [name]);
      if (r.exitCode != 0) continue;
      final path = r.stdout
          .trim()
          .split(RegExp(r'\r?\n'))
          .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '')
          .trim();
      if (path.isEmpty) continue;
      final st = await _verify(kind, path, MediaToolSource.systemPath);
      if (st != null) return st;
    }
    return MediaToolStatus.missing(kind);
  }

  Future<MediaToolStatus?> _verify(
      MediaToolKind kind, String path, MediaToolSource source) async {
    try {
      final r = await run(path, switch (kind) {
        MediaToolKind.ffmpeg => ['-version'],
        MediaToolKind.ytDlp => ['--version'],
        MediaToolKind.whisperCli => ['--help'],
      });
      if (r.exitCode != 0) return null;
      final version = switch (kind) {
        MediaToolKind.ffmpeg => parseFfmpegVersion(r.stdout),
        MediaToolKind.ytDlp => parseYtDlpVersion(r.stdout),
        MediaToolKind.whisperCli => 'ready',
      };
      if (version == null) return null;
      return MediaToolStatus(
          kind: kind,
          ready: true,
          path: path,
          version: version,
          source: source);
    } catch (_) {
      return null;
    }
  }

  static String? parseFfmpegVersion(String stdout) =>
      RegExp(r'ffmpeg version (\S+)').firstMatch(stdout)?.group(1);

  static String? parseYtDlpVersion(String stdout) {
    final t = stdout.trim();
    return RegExp(r'^\d{4}\.\d{2}\.\d{2}').hasMatch(t) ? t : null;
  }

  /// whisper.cpp Release 资产候选名（按平台），排除 CUDA/Vulkan 等重型构建。
  static List<String> whisperAssetCandidates(
      {required bool isWindows, required bool isMac, required bool isArm}) {
    final bad = RegExp(r'cublas|vulkan|clblast|opencl|wasm|addon');
    final all = [
      'whisper-bin-x64.zip',
      'whisper-bin-arm64.zip',
      'whisper-macos-arm64.zip',
      'whisper-macos-x64.zip',
      'whisper-arm64-macos.zip',
      'whisper-x64-macos.zip',
      'whisper-macos-arm64.tar.gz',
      'whisper-macos-x64.tar.gz',
      'whisper-linux-x64.tar.gz',
      'whisper-bin-linux-x64.tar.gz',
    ].where((n) => !bad.hasMatch(n)).toList();
    return all.where((n) {
      if (isWindows) return n.contains('x64') && n.endsWith('.zip');
      if (isMac) {
        if (!(n.contains('macos') || n.contains('darwin'))) return false;
        return isArm
            ? n.contains('arm64')
            : n.contains('x64') && !n.contains('arm64');
      }
      return n.contains('linux') && n.endsWith('.tar.gz');
    }).toList();
  }

  /// 从解压目录递归查找工具二进制，移动到统一 toolDir 并赋执行权限；找不到返回 null。
  Future<String?> installExtractedBinary(
      String extractedDir, MediaToolKind kind) async {
    final candidates = switch (kind) {
      MediaToolKind.ffmpeg => ['ffmpeg', 'ffmpeg.exe'],
      MediaToolKind.ytDlp =>
        ['yt-dlp', 'yt-dlp.exe', 'yt-dlp_macos', 'yt-dlp_linux'],
      MediaToolKind.whisperCli =>
        ['whisper-cli', 'whisper-cli.exe', 'main', 'main.exe'],
    };
    File? found;
    await for (final e in Directory(extractedDir)
        .list(recursive: true, followLinks: false)) {
      if (e is File && candidates.contains(e.uri.pathSegments.last)) {
        found = e;
        break;
      }
    }
    if (found == null) return null;
    final dest = File('${await toolDir(kind)}/${binaryName(kind)}');
    if (await dest.exists()) await dest.delete();
    try {
      await found.rename(dest.path);
    } catch (_) {
      await found.copy(dest.path);
    }
    if (!Platform.isWindows) {
      await Process.run('chmod', ['+x', dest.path]);
    }
    return dest.path;
  }
}
