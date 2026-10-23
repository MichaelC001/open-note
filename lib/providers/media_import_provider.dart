// lib/providers/media_import_provider.dart
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../services/media/download_stats.dart';
import '../services/media/media_downloader.dart';
import '../services/media/media_import_service.dart';
import '../services/media/media_import_settings.dart';
import '../services/media/media_tool_service.dart';
import '../services/media/process_runner.dart';
import '../services/media/transcript_formatter.dart';
import '../services/media/whisper_model_service.dart';

enum MediaImportStep { source, envCheck, confirm, processing, done }

enum ImportSourceKind { url, file }

class MediaImportProvider extends ChangeNotifier {
  final MediaToolService toolService;
  final WhisperModelService modelService;
  final MediaDownloader downloader;
  final MediaImportSettings settings = MediaImportSettings();
  final Future<String> Function(String prompt)? callAI;
  final Future<ProcessRunResult> Function(String, List<String>) installerRunner;
  final Future<String?> Function() brewPathResolver;

  MediaImportProvider({
    MediaToolService? toolService,
    WhisperModelService? modelService,
    MediaDownloader? downloader,
    this.callAI,
    Future<ProcessRunResult> Function(String, List<String>)? installerRunner,
    Future<String?> Function()? brewPathResolver,
  }) : toolService = toolService ?? _defaultToolService(),
       modelService = modelService ?? WhisperModelService(),
       downloader = downloader ?? MediaDownloader(),
       installerRunner = installerRunner ?? _defaultInstallerRunner,
       brewPathResolver = brewPathResolver ?? _defaultBrewPathResolver;

  /// 默认工具服务：接 SharedPreferences 验证缓存（yt-dlp 等 spawn 慢的二进制免重复验证）。
  static MediaToolService _defaultToolService() {
    final s = MediaImportSettings();
    return MediaToolService(
      cacheReader: s.readVerifyCache,
      cacheWriter: s.writeVerifyCache,
    );
  }

  MediaImportStep step = MediaImportStep.source;
  ImportSourceKind sourceKind = ImportSourceKind.url;
  String urlInput = '';
  File? pickedFile;

  final Map<MediaToolKind, MediaToolStatus> toolStatuses = {};
  final Map<MediaToolKind, bool> toolDownloading = {};
  final Map<MediaToolKind, bool> toolFinishing = {};
  final Map<MediaToolKind, bool> toolInstalling = {};
  final Map<MediaToolKind, bool> toolUninstalling = {};
  bool modelDeleting = false;
  final Map<MediaToolKind, DownloadStatus> toolDownloadStatus = {};
  final Map<String, DownloadSpeedTracker> _downloadTrackers = {};

  WhisperModelTier recommendedTier = WhisperModelTier.medium;
  WhisperModelTier selectedTier = WhisperModelTier.medium;
  final Set<WhisperModelTier> downloadedTiers = {};
  bool modelDownloading = false;
  DownloadStatus modelDownloadStatus = const DownloadStatus();
  DownloadSpeedTracker? _modelTracker;

  MediaImportPhase? phase;
  double? phaseProgress;
  String? errorMessage;
  String? errorDetail;
  bool aiUnavailable = false;

  MediaImportResult? result;
  String? resultNoteId;

  CancelToken? _downloadCancel;
  Process? _activeInstaller;
  MediaImportService? _activeService;
  bool _busy = false;

  bool get busy => _busy;

  bool get operationInProgress =>
      _busy ||
      toolDownloading.values.any((v) => v) ||
      toolInstalling.values.any((v) => v) ||
      toolFinishing.values.any((v) => v) ||
      modelDownloading ||
      modelDeleting;

  bool get transcriptionActive => _activeService != null;

  String pendingLanguage = 'auto';

  bool isToolRequired(MediaToolKind kind) =>
      kind != MediaToolKind.ytDlp || sourceKind == ImportSourceKind.url;

  bool get environmentReady =>
      MediaToolKind.values
          .where(isToolRequired)
          .every((k) => toolStatuses[k]?.ready ?? false) &&
      downloadedTiers.contains(selectedTier);

  void _notify() => notifyListeners();

  Future<void> startForUrl(String url) async {
    sourceKind = ImportSourceKind.url;
    urlInput = url;
    pickedFile = null;
    step = MediaImportStep.envCheck;
    _notify();
    await checkEnvironment();
  }

  Future<void> startForFile(File f) async {
    sourceKind = ImportSourceKind.file;
    pickedFile = f;
    step = MediaImportStep.envCheck;
    _notify();
    await checkEnvironment();
  }

  Future<void> checkEnvironment({bool forceVerify = false}) async {
    _busy = true;
    errorMessage = null;
    errorDetail = null;
    _notify();
    try {
      for (final kind in MediaToolKind.values.where(isToolRequired)) {
        toolStatuses[kind] =
            await toolService.check(kind, forceVerify: forceVerify);
        _notify();
      }
      recommendedTier = await modelService.recommendTierForDevice();
      final fixed = await settings.defaultTier();
      selectedTier = fixed ?? recommendedTier;
      downloadedTiers.clear();
      for (final t in WhisperModelTier.values) {
        if (await modelService.localModelFile(t) != null) {
          downloadedTiers.add(t);
        }
      }
      aiUnavailable = callAI == null;
    } catch (e) {
      errorMessage = '环境检查失败';
      errorDetail = e.toString();
    } finally {
      _busy = false;
      _notify();
    }
  }

  void _markFinishing(MediaToolKind kind) {
    toolDownloading[kind] = false;
    toolFinishing[kind] = true;
    _notify();
  }

  Future<void> downloadTool(MediaToolKind kind) async {
    toolDownloading[kind] = true;
    toolDownloadStatus[kind] = const DownloadStatus();
    _downloadTrackers['tool:${kind.name}'] = DownloadSpeedTracker();
    errorMessage = null;
    _notify();
    try {
      final dir = await toolService.toolDir(kind);
      // 磁盘空间预检：不足约 200MB 直接阻止下载
      final free = await downloader.freeDiskBytes(dir);
      const needBytes = 200 * 1024 * 1024;
      if (free != null && free < needBytes) {
        errorMessage = '磁盘空间不足';
        errorDetail =
            '需要约 ${needBytes ~/ 1024 / 1024} MB，可用 '
            '${free ~/ 1024 / 1024} MB';
        return;
      }
      _downloadCancel = CancelToken();
      final binName = toolService.binaryName(kind);
      final dest = File('$dir/$binName');
      final isSingleFile = kind != MediaToolKind.whisperCli;
      if (isSingleFile) {
        await downloader.download(
          kind == MediaToolKind.ytDlp
              ? MediaDownloader.ytDlpDirectUrl()
              : MediaDownloader.ffmpegDirectUrl(),
          destFile: dest,
          mode: await settings.downloadSource(),
          cancelToken: _downloadCancel,
          onProgress: (r, t) {
            if (t > 0) {
              toolDownloadStatus[kind] = _downloadTrackers['tool:${kind.name}']!
                  .tick(r, t);
              _notify();
            }
          },
        );
        _markFinishing(kind);
        if (!Platform.isWindows) {
          await Process.run('chmod', ['+x', dest.path]);
        }
      } else {
        final directUrl = await _resolveWhisperAssetUrl();
        final archiveName = destNameOf(directUrl);
        final archive = File('$dir/$archiveName');
        await downloader.download(
          directUrl,
          destFile: archive,
          mode: await settings.downloadSource(),
          cancelToken: _downloadCancel,
          onProgress: (r, t) {
            if (t > 0) {
              toolDownloadStatus[kind] = _downloadTrackers['tool:${kind.name}']!
                  .tick(r, t);
              _notify();
            }
          },
        );
        _markFinishing(kind);
        final extractDir =
            '$dir/_extract_${DateTime.now().millisecondsSinceEpoch}';
        await downloader.extract(archive, extractDir);
        final installed = await toolService.installExtractedBinary(
          extractDir,
          kind,
        );
        _deleteDirQuiet(Directory(extractDir));
        if (archive.path != dest.path && await archive.exists()) {
          try {
            await archive.delete();
          } catch (_) {}
        }
        if (installed == null) {
          throw Exception('安装包中未找到 $binName，请改用手动安装指引');
        }
      }
      toolStatuses[kind] =
          await toolService.check(kind, forceVerify: true);
      if (!(toolStatuses[kind]?.ready ?? false)) {
        errorMessage = '工具安装后校验未通过';
        errorDetail = null;
      }
    } catch (e) {
      errorMessage = '工具下载/安装失败';
      errorDetail = e.toString();
    } finally {
      toolDownloading[kind] = false;
      toolFinishing[kind] = false;
      _downloadCancel = null;
      _downloadTrackers.remove('tool:${kind.name}');
      _notify();
    }
  }

  /// 一键自动安装（macOS=brew / Windows=winget，仅 whisperCli 支持）。
  Future<void> autoInstallTool(MediaToolKind kind) async {
    final brewPath = Platform.isMacOS ? await brewPathResolver() : null;
    final plan = MediaToolService.autoInstallPlan(
      kind,
      brewPath: brewPath,
      isMac: Platform.isMacOS,
      isWin: Platform.isWindows,
    );
    if (plan == null) {
      errorMessage = '无法自动安装';
      errorDetail = Platform.isMacOS
          ? '未检测到 Homebrew，请按指引手动安装（终端执行 brew install whisper-cpp）'
          : '当前平台不支持自动安装，请按指引手动安装';
      _notify();
      return;
    }
    toolInstalling[kind] = true;
    errorMessage = null;
    errorDetail = null;
    _notify();
    try {
      final r = await installerRunner(plan.executable, plan.args);
      if (r.exitCode != 0) {
        errorMessage = '自动安装失败';
        errorDetail = (r.stderr.trim().isNotEmpty ? r.stderr : r.stdout).trim();
        return;
      }
      toolStatuses[kind] =
          await toolService.check(kind, forceVerify: true);
    } catch (e) {
      errorMessage = '自动安装失败';
      errorDetail = e.toString();
    } finally {
      toolInstalling[kind] = false;
      _activeInstaller = null;
      _notify();
    }
  }

  /// 卸载计划：mac 走 brew（ffmpeg/yt-dlp/whisper-cpp），windows 仅 whisper-cli 走 winget。
  static InstallerPlan? uninstallPlan(
    MediaToolKind kind, {
    String? brewPath,
    required bool isMac,
    required bool isWin,
  }) {
    if (isMac) {
      if (brewPath == null || brewPath.isEmpty) return null;
      final name = switch (kind) {
        MediaToolKind.ffmpeg => 'ffmpeg',
        MediaToolKind.ytDlp => 'yt-dlp',
        MediaToolKind.whisperCli => 'whisper-cpp',
      };
      return InstallerPlan(brewPath, ['uninstall', '-q', name]);
    }
    if (isWin && kind == MediaToolKind.whisperCli) {
      return const InstallerPlan('winget', [
        'uninstall', '--id', 'ggml.whisper-cpp', '-e', '--disable-interactivity',
      ]);
    }
    return null;
  }

  Future<void> uninstallTool(MediaToolKind kind) async {
    final status = toolStatuses[kind];
    if (status == null || !status.ready) return;
    if ((toolDownloading[kind] ?? false) ||
        (toolInstalling[kind] ?? false) ||
        (toolFinishing[kind] ?? false)) {
      return;
    }
    toolUninstalling[kind] = true;
    errorMessage = null;
    errorDetail = null;
    _notify();
    try {
      if (status.source == MediaToolSource.appManaged) {
        // 同步删除：FakeAsync（widget 测试）下 dart:io 异步方法无法完成
        final dir = Directory(await toolService.toolDir(kind));
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      } else {
        final brewPath = Platform.isMacOS ? await brewPathResolver() : null;
        final plan = uninstallPlan(
          kind,
          brewPath: brewPath,
          isMac: Platform.isMacOS,
          isWin: Platform.isWindows,
        );
        if (plan == null) {
          errorMessage = '无法自动卸载';
          errorDetail = '请使用对应包管理器卸载';
          return;
        }
        final r = await installerRunner(plan.executable, plan.args);
        if (r.exitCode != 0) {
          errorMessage = '自动卸载失败';
          errorDetail =
              (r.stderr.trim().isNotEmpty ? r.stderr : r.stdout).trim();
          return;
        }
      }
      toolStatuses[kind] =
          await toolService.check(kind, forceVerify: true);
    } catch (e) {
      errorMessage = '卸载失败';
      errorDetail = e.toString();
    } finally {
      toolUninstalling[kind] = false;
      _activeInstaller = null;
      _notify();
    }
  }

  Future<void> deleteModel(WhisperModelTier tier) async {
    if (_activeService != null) {
      errorMessage = '转录进行中，无法删除模型';
      _notify();
      return;
    }
    if (modelDeleting || !downloadedTiers.contains(tier)) return;
    modelDeleting = true;
    _notify();
    try {
      final info = WhisperModelService.infoFor(tier);
      final f = File('${await modelService.modelsDir()}/${info.fileName}');
      if (f.existsSync()) f.deleteSync();
      downloadedTiers.remove(tier);
    } catch (e) {
      errorMessage = '删除模型失败';
      errorDetail = e.toString();
    } finally {
      modelDeleting = false;
      _notify();
    }
  }

  static Future<ProcessRunResult> _defaultInstallerRunner(
    String executable,
    List<String> args,
  ) async {
    final process = await Process.start(executable, args);
    final sbOut = StringBuffer();
    final sbErr = StringBuffer();
    process.stdout.transform(utf8.decoder).listen(sbOut.write);
    process.stderr.transform(utf8.decoder).listen(sbErr.write);
    final code = await process.exitCode;
    return ProcessRunResult(code, _tailOf(sbOut), _tailOf(sbErr));
  }

  static String _tailOf(StringBuffer sb) {
    final s = sb.toString();
    return s.length > 2000 ? s.substring(s.length - 2000) : s;
  }

  static Future<String?> _defaultBrewPathResolver() async {
    for (final path in MediaToolService.brewCandidatePaths()) {
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  Future<void> downloadSelectedModel() async {
    modelDownloading = true;
    modelDownloadStatus = const DownloadStatus();
    _modelTracker = DownloadSpeedTracker();
    errorMessage = null;
    _notify();
    try {
      final info = WhisperModelService.infoFor(selectedTier);
      final modelsDir = await modelService.modelsDir();
      // 磁盘空间预检：按所选模型标称大小估算
      final free = await downloader.freeDiskBytes(modelsDir);
      final needBytes = info.downloadSizeBytes;
      if (free != null && free < needBytes) {
        errorMessage = '磁盘空间不足';
        errorDetail =
            '需要约 ${needBytes ~/ 1024 / 1024} MB，可用 '
            '${free ~/ 1024 / 1024} MB';
        return;
      }
      _downloadCancel = CancelToken();
      await downloader.download(
        WhisperModelService.modelUrl(info, mirror: false).toString(),
        destFile: File('$modelsDir/${info.fileName}'),
        mode: await settings.downloadSource(),
        cancelToken: _downloadCancel,
        onProgress: (r, t) {
          if (t > 0) {
            modelDownloadStatus = _modelTracker!.tick(r, t);
            _notify();
          }
        },
      );
      downloadedTiers.add(selectedTier);
    } catch (e) {
      errorMessage = '模型下载失败';
      errorDetail = e.toString();
    } finally {
      modelDownloading = false;
      _downloadCancel = null;
      _modelTracker = null;
      _notify();
    }
  }

  Future<String> _resolveWhisperAssetUrl() async {
    final dio = Dio();
    final resp = await dio.get<dynamic>(
      MediaDownloader.whisperReleasesApiUrl(),
      options: Options(headers: {'Accept': 'application/vnd.github+json'}),
    );
    final releases = (resp.data as List?) ?? const [];
    for (final release in releases) {
      final map = release as Map;
      final assets = ((map['assets'] as List?) ?? const [])
          .map((a) => (a as Map)['name'].toString())
          .toList();
      final asset = MediaDownloader.pickWhisperAsset(
        assets,
        isWindows: Platform.isWindows,
        isMac: Platform.isMacOS,
        isArm: _isArmHost,
      );
      if (asset != null) {
        return 'https://github.com/ggml-org/whisper.cpp/releases/download/'
            '${map['tag_name']}/$asset';
      }
    }
    throw Exception('当前平台暂无 whisper.cpp 预编译包，请查看安装指引手动安装');
  }

  /// Dart 进程真实架构（Rosetta 下 x64 进程选 x64 包恰好正确）。
  static bool get _isArmHost {
    if (Platform.isMacOS || Platform.isLinux) {
      return switch (Abi.current()) {
        Abi.macosArm64 || Abi.linuxArm64 => true,
        _ => false,
      };
    }
    return false;
  }

  static String destNameOf(String url) {
    final clean = url.split('?').first;
    return clean.substring(clean.lastIndexOf('/') + 1);
  }

  void _deleteDirQuiet(Directory dir) {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  }

  void gotoConfirm() {
    step = MediaImportStep.confirm;
    notifyListeners();
  }

  void selectTier(WhisperModelTier tier) {
    selectedTier = tier;
    notifyListeners();
  }

  Future<void> startProcessing({
    String language = 'auto',
    required Future<String?> Function(MediaImportResult result) saveNote,
  }) async {
    pendingLanguage = language;
    step = MediaImportStep.processing;
    notifyListeners();
    await confirmAndStart(saveNote: saveNote);
  }

  Future<void> confirmAndStart({
    required Future<String?> Function(MediaImportResult result) saveNote,
    Future<MediaImportResult> Function(MediaImportService, MediaImportRequest)?
    runOverride,
    bool waitCompletion = true,
  }) async {
    step = MediaImportStep.processing;
    phase = null;
    phaseProgress = null;
    errorMessage = null;
    errorDetail = null;
    result = null;
    resultNoteId = null;
    _notify();

    final hasAI = callAI != null;
    final formatter = hasAI ? TranscriptFormatter(callAI!) : null;
    final service = MediaImportService(
      toolService: toolService,
      modelService: modelService,
      formatter: formatter,
    );
    _activeService = service;

    final request = MediaImportRequest(
      url: sourceKind == ImportSourceKind.url ? urlInput : null,
      localFile: sourceKind == ImportSourceKind.file ? pickedFile : null,
      tier: selectedTier,
      language: pendingLanguage,
      deleteSourceAfter: await settings.deleteSourceAfter(),
    );

    Future<void> doRun() async {
      try {
        final r = runOverride != null
            ? await runOverride(service, request)
            : await service.run(
                request,
                onProgress: (p, v) {
                  phase = p;
                  phaseProgress = v;
                  _notify();
                },
              );
        result = r;
        resultNoteId = await saveNote(r);
        step = MediaImportStep.done;
      } on MediaImportException catch (e) {
        if (e.message == MediaImportException.cancelledMessage) {
          reset();
        } else {
          errorMessage = e.message;
          errorDetail = e.detail;
        }
      } catch (e) {
        errorMessage = '转换失败';
        errorDetail = e.toString();
      } finally {
        _activeService = null;
        _notify();
      }
    }

    if (waitCompletion) {
      await doRun();
    } else {
      unawaited(doRun());
    }
  }

  void cancel() {
    _downloadCancel?.cancel();
    _activeService?.cancel();
    _activeInstaller?.kill();
  }

  void reset() {
    step = MediaImportStep.source;
    urlInput = '';
    pickedFile = null;
    phase = null;
    phaseProgress = null;
    errorMessage = null;
    errorDetail = null;
    result = null;
    resultNoteId = null;
    _notify();
  }
}
