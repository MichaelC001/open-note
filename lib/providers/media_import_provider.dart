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
import '../services/media/tool_update_service.dart';
import '../services/media/process_runner.dart';
import '../services/media/transcript_formatter.dart';
import '../services/media/whisper_model_service.dart';

enum MediaImportStep { source, envCheck, confirm, processing, done }

enum ImportSourceKind { url, file }

/// ffmpeg 新下载资产无法运行（装前可执行验证失败）。
class ToolBinaryInvalidException implements Exception {
  const ToolBinaryInvalidException();
  @override
  String toString() => '下载的引擎文件无法运行，已保留当前版本';
}

class MediaImportProvider extends ChangeNotifier {
  final MediaToolService toolService;
  final WhisperModelService modelService;
  final MediaDownloader downloader;
  final MediaImportSettings settings = MediaImportSettings();
  final Future<String> Function(String prompt)? callAI;
  final Future<ProcessRunResult> Function(String, List<String>) installerRunner;
  final Future<String?> Function() brewPathResolver;
  final Future<String?> Function() wingetPathResolver;
  final ToolUpdateService updateService;
  final DateTime Function() clock;

  MediaImportProvider({
    MediaToolService? toolService,
    WhisperModelService? modelService,
    MediaDownloader? downloader,
    this.callAI,
    Future<ProcessRunResult> Function(String, List<String>)? installerRunner,
    Future<String?> Function()? brewPathResolver,
    Future<String?> Function()? wingetPathResolver,
    ToolUpdateService? updateService,
    DateTime Function()? clock,
  }) : toolService = toolService ?? _defaultToolService(),
       modelService = modelService ?? WhisperModelService(),
       downloader = downloader ?? MediaDownloader(),
       installerRunner = installerRunner ?? _defaultInstallerRunner,
       brewPathResolver = brewPathResolver ?? _defaultBrewPathResolver,
       wingetPathResolver = wingetPathResolver ?? _defaultWingetPathResolver,
        updateService = updateService ?? ToolUpdateService(),
        clock = clock ?? DateTime.now {
    // fire-and-forget：从持久化恢复「可更新」徽标（跨重启不丢，见 checkToolUpdates）
    unawaited(_restoreUpdateAvailable());
  }

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
  final Map<MediaToolKind, String?> updateAvailableVersion = {};
  final Map<MediaToolKind, bool> updateChecking = {};
  // 非阻断系统提示（经 ToolStatusRow.systemHint 渲染），如「更新未生效」
  final Map<MediaToolKind, String> toolHints = {};
  Timer? _updateCheckTimer;
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

  /// 当次转换实际使用的内容优化档（confirmAndStart 时捕获）。
  /// raw 档不调用 AI，完成页不应显示「AI 格式化未完成」。
  ContentPolishLevel donePolishLevel = ContentPolishLevel.structured;

  CancelToken? _downloadCancel;
  Process? _activeInstaller;
  MediaImportService? _activeService;
  bool _busy = false;

  bool get busy => _busy;

  bool get operationInProgress =>
      _busy ||
      toolDownloading.values.any((v) => v) ||
      toolInstalling.values.any((v) => v) ||
      toolUninstalling.values.any((v) => v) ||
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

  /// 构造后恢复持久化的更新标记（kindName 反序列化，非法 kind/值跳过）。
  Future<void> _restoreUpdateAvailable() async {
    try {
      final table = await settings.readUpdateAvailable();
      if (table.isEmpty) return;
      for (final entry in table.entries) {
        try {
          final kind = MediaToolKind.values.byName(entry.key);
          updateAvailableVersion.putIfAbsent(kind, () => entry.value);
        } catch (_) {
          // 未知 kind（枚举演进/脏数据）：跳过
        }
      }
      _notify();
    } catch (_) {
      // 恢复失败静默：下次检查会重建
    }
  }

  /// 将内存徽标整表落盘（与已存内容一致时跳过写入）。
  Future<void> _persistUpdateAvailable() async {
    try {
      final table = <String, String>{
        for (final e in updateAvailableVersion.entries)
          if (e.value != null) e.key.name: e.value!,
      };
      final stored = await settings.readUpdateAvailable();
      if (stored.length == table.length &&
          stored.entries.every((e) => table[e.key] == e.value)) {
        return;
      }
      await settings.writeUpdateAvailable(table);
    } catch (_) {
      // 持久化失败静默
    }
  }

  Future<void> startForUrl(String url) async {
    sourceKind = ImportSourceKind.url;
    urlInput = url;
    pickedFile = null;
    if (_enterConfirmIfReady()) return;
    step = MediaImportStep.envCheck;
    _notify();
    await checkEnvironment();
  }

  Future<void> startForFile(File f) async {
    sourceKind = ImportSourceKind.file;
    pickedFile = f;
    if (_enterConfirmIfReady()) return;
    step = MediaImportStep.envCheck;
    _notify();
    await checkEnvironment();
  }

  /// 环境已就绪（工具全 ready && 所选模型已下载）时跳过检测步骤直达确认页，
  /// 检测转为后台静默刷新（验证缓存使其近乎零成本）。
  bool _enterConfirmIfReady() {
    if (!environmentReady) return false;
    step = MediaImportStep.confirm;
    _notify();
    unawaited(checkEnvironment());
    return true;
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
      selectedTier = recommendedTier;
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

  /// 静默定时检查工具新版本（默认延迟 15s；到点时若操作进行中或环境尚未检测
  /// （toolStatuses 为空，如 splash 只调度未进入媒体 UI）则顺延 60s 重试，
  /// 避免会话内永不检查——24h 节流由 checkToolUpdates 内部兜底，重试零成本）。
  void scheduleUpdateCheck({Duration delay = const Duration(seconds: 15)}) {
    _updateCheckTimer?.cancel();
    _updateCheckTimer = Timer(delay, () {
      if (operationInProgress || toolStatuses.isEmpty) {
        scheduleUpdateCheck(delay: const Duration(seconds: 60));
        return;
      }
      checkToolUpdates();
    });
  }

  /// 静默检查 appManaged 工具的新版本（24h 节流，全程不抛错）。
  Future<void> checkToolUpdates() async {
    try {
      final last = await settings.lastUpdateCheckAt();
      if (last != null &&
          clock().difference(last) < const Duration(hours: 24)) {
        return;
      }
      // 本轮至少实际 fetch 过一个 kind 才写 24h 节流时间戳：
      // 全部被跳过（无状态/非 appManaged/操作占用）时空转不烧节流预算
      var fetchedKinds = 0;
      var updateTableChanged = false;
      for (final kind in MediaToolKind.values) {
        if ((toolDownloading[kind] ?? false) ||
            (toolInstalling[kind] ?? false) ||
            (toolUninstalling[kind] ?? false)) {
          continue;
        }
        final st = toolStatuses[kind];
        if (st == null ||
            !st.ready ||
            st.source != MediaToolSource.appManaged) {
          continue;
        }
        try {
          updateChecking[kind] = true;
          _notify();
          final latest = await updateService.fetchLatestVersion(kind);
          fetchedKinds++; // 网络已探测（返回 null 也算），才允许写节流时间戳
          if (latest != null) {
            final stored = kind == MediaToolKind.whisperCli
                ? await settings.whisperCliSourceTag()
                : null;
            if (ToolUpdateService.hasUpdate(
              localVersion: st.version,
              remoteTag: latest,
              kind: kind,
              storedSourceTag: stored,
            )) {
              if (updateAvailableVersion[kind] != latest) {
                updateAvailableVersion[kind] = latest;
                updateTableChanged = true;
              }
            } else if (updateAvailableVersion.remove(kind) != null) {
              // 拉到最新且无更新：清掉过期徽标
              updateTableChanged = true;
            }
          }
        } catch (_) {
          // 单个工具检查失败不影响后续工具
        } finally {
          updateChecking[kind] = false;
          _notify();
        }
      }
      if (fetchedKinds > 0) {
        await settings.setLastUpdateCheckAt(clock());
      }
      if (updateTableChanged) {
        await _persistUpdateAvailable();
      }
    } catch (_) {
      // 更新检查绝不影响主流程
    }
  }

  void _markFinishing(MediaToolKind kind) {
    toolDownloading[kind] = false;
    toolFinishing[kind] = true;
    _notify();
  }

  Future<void> downloadTool(MediaToolKind kind) async {
    // 操作占用守卫：下载/安装/finishing 收尾/卸载期间重复触发直接忽略
    //（防 finishing 窗口内重复点击「更新」造成二次下载/状态互踩）
    if ((toolDownloading[kind] ?? false) ||
        (toolInstalling[kind] ?? false) ||
        (toolFinishing[kind] ?? false) ||
        (toolUninstalling[kind] ?? false)) {
      return;
    }
    // 先取检测到的更新 tag 再清徽标：ffmpeg「更新」按该具体 tag 下载
    final updateTag = updateAvailableVersion.remove(kind);
    final isUpdate = updateTag != null;
    // 1b 装后版本比对基线：更新前的本地版本
    final prevVersion = toolStatuses[kind]?.version;
    toolHints.remove(kind);
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
        final isFfmpeg = kind == MediaToolKind.ffmpeg;
        // 1a 装前可执行验证：ffmpeg 先下到 staging，验证通过才替换旧文件
        final target = isFfmpeg ? File('${dest.path}.staging') : dest;
        await downloader.download(
          kind == MediaToolKind.ytDlp
              ? MediaDownloader.ytDlpDirectUrl()
              : MediaDownloader.ffmpegDirectUrl(tag: updateTag),
          destFile: target,
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
        if (isFfmpeg) {
          final runnable = await verifyDownloadedBinary(target);
          if (!runnable) {
            // 坏资产：不替换旧版本，清理临时文件，走下载失败错误路径
            try {
              if (await target.exists()) await target.delete();
            } catch (_) {}
            throw const ToolBinaryInvalidException();
          }
          if (await dest.exists()) {
            try {
              await dest.delete();
            } catch (_) {}
          }
          await target.rename(dest.path);
        } else if (!Platform.isWindows) {
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
        final sourceTag = ToolUpdateService.whisperTagFromUrl(directUrl);
        if (sourceTag != null) {
          try {
            await settings.setWhisperCliSourceTag(sourceTag);
          } catch (_) {}
        }
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
      } else {
        // 1b 装后版本比对：更新场景下版本未变化（下载源内容未变化）
        // → 徽标已清（内存开始时移除），落盘同步 + 非阻断提示
        final newVersion = toolStatuses[kind]?.version;
        if (isUpdate &&
            newVersion != null &&
            prevVersion != null &&
            newVersion == prevVersion) {
          toolHints[kind] = '更新未生效（下载源内容未变化），已保留当前版本';
        }
        // 更新/下载安装成功：徽标已清，同步落盘（下次启动不再误报）
        await _persistUpdateAvailable();
      }
    } on ToolBinaryInvalidException {
      errorMessage = '下载的引擎文件无法运行，已保留当前版本';
      errorDetail = null;
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

  /// 1a 装前可执行验证：mac/linux `chmod +x` 后执行 `-version`（超时 5s），
  /// windows 复制到同目录临时 `.exe` 再探测（PE 必须以 .exe 结尾才能启动）。
  /// 退出码非 0 / 超时 / 被系统杀死 / 无法执行 → false（视为坏资产）。
  Future<bool> verifyDownloadedBinary(File f) async {
    File probe = f;
    if (!Platform.isWindows) {
      try {
        await Process.run('chmod', ['+x', f.path]);
      } catch (_) {}
    } else {
      probe = File('${f.path}.verify.exe');
      try {
        await f.copy(probe.path);
      } catch (_) {
        return false;
      }
    }
    try {
      final r = await installerRunner(probe.path, const ['-version'])
          .timeout(const Duration(seconds: 5));
      return r.exitCode == 0;
    } catch (_) {
      return false;
    } finally {
      if (probe.path != f.path) {
        try {
          await probe.delete();
        } catch (_) {}
      }
    }
  }

  /// 一键自动安装（macOS=brew / Windows=winget，仅 whisperCli 支持）。
  Future<void> autoInstallTool(MediaToolKind kind) async {
    final pkgPath = await _resolvePkgManagerPath();
    final plan = MediaToolService.autoInstallPlan(
      kind,
      brewPath: pkgPath,
      wingetPath: pkgPath,
      isMac: Platform.isMacOS,
      isWin: Platform.isWindows,
    );
    if (plan == null) {
      errorMessage = '无法自动安装';
      errorDetail = Platform.isMacOS
          ? '未检测到 Homebrew，请按指引手动安装（终端执行 brew install whisper-cpp）'
          : Platform.isWindows
              ? '未检测到 winget（应用安装程序），请按指引手动安装；'
                  '可从 Microsoft Store 安装“应用安装程序 (App Installer)”后重试'
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
    String? wingetPath,
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
      if (wingetPath == null || wingetPath.isEmpty) return null;
      return InstallerPlan(wingetPath, [
        'uninstall', '--id', 'ggml.whisper-cpp', '-e', '--disable-interactivity',
      ]);
    }
    return null;
  }

  /// 当前平台包管理器绝对路径（mac=brew / win=winget，其余 null）。
  Future<String?> _resolvePkgManagerPath() async {
    if (Platform.isMacOS) return brewPathResolver();
    if (Platform.isWindows) return wingetPathResolver();
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
        final pkgPath = await _resolvePkgManagerPath();
        final plan = uninstallPlan(
          kind,
          brewPath: pkgPath,
          wingetPath: pkgPath,
          isMac: Platform.isMacOS,
          isWin: Platform.isWindows,
        );
        if (plan == null) {
          errorMessage = '无法自动卸载';
          errorDetail = Platform.isWindows
              ? '未检测到 winget（应用安装程序），请使用对应包管理器卸载；'
                  '可从 Microsoft Store 安装“应用安装程序 (App Installer)”后重试'
              : '请使用对应包管理器卸载';
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
      // 卸载成功：清徽标并落盘（旧版本已不存在，更新提示失效）
      updateAvailableVersion.remove(kind);
      await _persistUpdateAvailable();
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

  static Future<String?> _defaultWingetPathResolver() async {
    for (final path in MediaToolService.wingetCandidatePaths()) {
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
    final includeTs = await settings.includeTimestamps();
    final polish = await settings.polishLevel();
    donePolishLevel = polish;
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
                includeTimestamps: includeTs,
                polishLevel: polish,
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

  @override
  void dispose() {
    _updateCheckTimer?.cancel();
    super.dispose();
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
