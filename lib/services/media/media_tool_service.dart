// lib/services/media/media_tool_service.dart
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'process_runner.dart';

enum MediaToolKind { ffmpeg, ytDlp, whisperCli }

/// 一键自动安装的可执行计划。
class InstallerPlan {
  final String executable;
  final List<String> args;

  const InstallerPlan(this.executable, this.args);
}

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
  final Future<Map<String, String>?> Function()? cacheReader;
  final Future<void> Function(Map<String, String> map)? cacheWriter;

  final Map<String, String> _memoryCache = {};
  bool _cacheLoaded = false;

  MediaToolService({
    Future<ProcessRunResult> Function(String, List<String>)? run,
    Future<String> Function()? resolveBaseDir,
    this.cacheReader,
    this.cacheWriter,
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

  Future<MediaToolStatus> check(
    MediaToolKind kind, {
    bool forceVerify = false,
  }) async {
    final appPath = await appManagedPath(kind);
    if (!forceVerify) {
      final cached = await _cachedStatus(kind);
      if (cached != null &&
          (appPath == cached.path ||
              (appPath == null && await _whichPath(kind) == cached.path))) {
        return cached;
      }
    }
    if (appPath != null) {
      final st = await _verify(kind, appPath, MediaToolSource.appManaged);
      if (st != null) {
        await _storeCache(kind, st);
        return st;
      }
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
      if (st != null) {
        await _storeCache(kind, st);
        return st;
      }
    }
    return MediaToolStatus.missing(kind);
  }

  /// 验证结果缓存：key=kind，value=JSON(path/size/mtime/version/source)。
  /// yt-dlp 等二进制单次 spawn 验证可达数秒，同一文件（大小+mtime 未变）直接复用结果。
  Future<void> _ensureCacheLoaded() async {
    if (_cacheLoaded) return;
    _cacheLoaded = true;
    if (cacheReader == null) return;
    try {
      final persisted = await cacheReader!();
      if (persisted != null) _memoryCache.addAll(persisted);
    } catch (_) {}
  }

  Future<MediaToolStatus?> _cachedStatus(MediaToolKind kind) async {
    await _ensureCacheLoaded();
    final raw = _memoryCache[kind.name];
    if (raw == null) return null;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final path = m['p'] as String;
      final f = File(path);
      if (!await f.exists()) return null;
      if (await f.length() != (m['s'] as int)) return null;
      if ((await f.lastModified()).millisecondsSinceEpoch !=
          (m['m'] as int)) {
        return null;
      }
      final source = (m['src'] as String?)?.isEmpty ?? true
          ? null
          : MediaToolSource.values.firstWhere((s) => s.name == m['src']);
      return MediaToolStatus(
        kind: kind,
        ready: true,
        path: path,
        version: m['v'] as String?,
        source: source,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _storeCache(MediaToolKind kind, MediaToolStatus st) async {
    try {
      final f = File(st.path!);
      final entry = jsonEncode({
        'p': st.path,
        's': await f.length(),
        'm': (await f.lastModified()).millisecondsSinceEpoch,
        'v': st.version,
        'src': st.source?.name ?? '',
      });
      _memoryCache[kind.name] = entry;
      if (cacheWriter != null) await cacheWriter!(_memoryCache);
    } catch (_) {}
  }

  Future<String?> _whichPath(MediaToolKind kind) async {
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
      if (path.isNotEmpty) return path;
    }
    return null;
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

  /// 一键自动安装计划：whisperCli 在 macOS 用 brew、Windows 用 winget；
  /// Linux 因 apt 需要交互提权不支持，返回 null 时 UI 回退为安装指引。
  static InstallerPlan? autoInstallPlan(
    MediaToolKind kind, {
    String? brewPath,
    String? wingetPath,
    required bool isMac,
    required bool isWin,
  }) {
    if (kind != MediaToolKind.whisperCli) return null;
    if (isMac) {
      if (brewPath == null || brewPath.isEmpty) return null;
      return InstallerPlan(brewPath, ['install', '-q', 'whisper-cpp']);
    }
    if (isWin) {
      if (wingetPath == null || wingetPath.isEmpty) return null;
      return InstallerPlan(wingetPath, [
        'install',
        '--id',
        'ggml.whisper-cpp',
        '-e',
        '--accept-source-agreements',
        '--accept-package-agreements',
        '--disable-interactivity',
      ]);
    }
    return null;
  }

  /// 常见 brew 安装路径（GUI 应用无 shell PATH，需按绝对路径探测）。
  static List<String> brewCandidatePaths() => Platform.isMacOS
      ? ['/opt/homebrew/bin/brew', '/usr/local/bin/brew']
      : const [];

  /// Windows winget 绝对路径（GUI 应用无 shell PATH，CreateProcess 解析不了
  /// App Execution Alias，需按绝对路径探测；LOCALAPPDATA 缺失返回空）。
  static List<String> wingetCandidatePaths() {
    if (!Platform.isWindows) return const [];
    final local = Platform.environment['LOCALAPPDATA'];
    if (local == null || local.isEmpty) return const [];
    return ['$local\\Microsoft\\WindowsApps\\winget.exe'];
  }

  static String? parseFfmpegVersion(String stdout) =>
      RegExp(r'ffmpeg version (\S+)').firstMatch(stdout)?.group(1);

  static String? parseYtDlpVersion(String stdout) {
    final t = stdout.trim();
    return RegExp(r'^\d{4}\.\d{2}\.\d{2}').hasMatch(t) ? t : null;
  }

  /// 从解压目录递归查找工具二进制，移动到统一 toolDir 并赋执行权限；找不到返回 null。
  /// whisperCli 额外把二进制所在目录内的 *.dll/*.so*/*.dylib 平铺复制到 toolDir
  /// （Windows 包与 ubuntu 包的动态库均与 whisper-cli 同目录，缺库则无法启动）。
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
    final dirPath = await toolDir(kind);
    if (kind == MediaToolKind.whisperCli) {
      await for (final e in found.parent.list(followLinks: false)) {
        if (e is! File) continue;
        final name = e.uri.pathSegments.last;
        final lower = name.toLowerCase();
        final isLib = lower.endsWith('.dll') ||
            lower.endsWith('.dylib') ||
            lower.contains('.so');
        if (!isLib) continue;
        final libDest = File('$dirPath/$name');
        if (await libDest.exists()) await libDest.delete();
        try {
          await e.rename(libDest.path);
        } catch (_) {
          await e.copy(libDest.path);
        }
      }
    }
    final dest = File('$dirPath/${binaryName(kind)}');
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
