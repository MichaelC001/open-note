// lib/providers/media_import_provider.dart
import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../services/media/media_downloader.dart';
import '../services/media/media_import_service.dart';
import '../services/media/media_import_settings.dart';
import '../services/media/media_tool_service.dart';
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

  MediaImportProvider({
    MediaToolService? toolService,
    WhisperModelService? modelService,
    MediaDownloader? downloader,
    this.callAI,
  })  : toolService = toolService ?? MediaToolService(),
        modelService = modelService ?? WhisperModelService(),
        downloader = downloader ?? MediaDownloader();

  MediaImportStep step = MediaImportStep.source;
  ImportSourceKind sourceKind = ImportSourceKind.url;
  String urlInput = '';
  File? pickedFile;

  final Map<MediaToolKind, MediaToolStatus> toolStatuses = {};
  final Map<MediaToolKind, bool> toolDownloading = {};
  final Map<MediaToolKind, double> toolProgress = {};

  WhisperModelTier recommendedTier = WhisperModelTier.medium;
  WhisperModelTier selectedTier = WhisperModelTier.medium;
  final Set<WhisperModelTier> downloadedTiers = {};
  bool modelDownloading = false;
  double modelProgress = 0;

  MediaImportPhase? phase;
  double? phaseProgress;
  String? errorMessage;
  String? errorDetail;
  bool aiUnavailable = false;

  MediaImportResult? result;
  String? resultNoteId;

  CancelToken? _downloadCancel;
  MediaImportService? _activeService;
  bool _busy = false;

  bool get busy => _busy;

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

  Future<void> checkEnvironment() async {
    _busy = true;
    errorMessage = null;
    errorDetail = null;
    _notify();
    try {
      for (final kind in MediaToolKind.values.where(isToolRequired)) {
        toolStatuses[kind] = await toolService.check(kind);
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

  Future<void> downloadTool(MediaToolKind kind) async {
    toolDownloading[kind] = true;
    toolProgress[kind] = 0;
    errorMessage = null;
    _notify();
    try {
      final dir = await toolService.toolDir(kind);
      // 磁盘空间预检：不足约 200MB 直接阻止下载
      final free = await downloader.freeDiskBytes(dir);
      const needBytes = 200 * 1024 * 1024;
      if (free != null && free < needBytes) {
        errorMessage = '磁盘空间不足';
        errorDetail = '需要约 ${needBytes ~/ 1024 / 1024} MB，可用 '
            '${free ~/ 1024 / 1024} MB';
        return;
      }
      _downloadCancel = CancelToken();
      final binName = toolService.binaryName(kind);
      final dest = File('$dir/$binName');
      if (kind == MediaToolKind.ytDlp) {
        await downloader.download(
          MediaDownloader.ytDlpDirectUrl(),
          destFile: dest,
          mode: await settings.downloadSource(),
          cancelToken: _downloadCancel,
          onProgress: (r, t) {
            if (t > 0) {
              toolProgress[kind] = r / t;
              _notify();
            }
          },
        );
        if (!Platform.isWindows) {
          await Process.run('chmod', ['+x', dest.path]);
        }
      } else {
        final directUrl = kind == MediaToolKind.ffmpeg
            ? MediaDownloader.ffmpegDirectUrl()
            : await _resolveWhisperAssetUrl();
        final archiveName = kind == MediaToolKind.ffmpeg
            ? 'ffmpeg.zip'
            : destNameOf(directUrl);
        final archive = File('$dir/$archiveName');
        await downloader.download(
          directUrl,
          destFile: archive,
          mode: await settings.downloadSource(),
          cancelToken: _downloadCancel,
          onProgress: (r, t) {
            if (t > 0) {
              toolProgress[kind] = r / t;
              _notify();
            }
          },
        );
        final extractDir = '$dir/_extract_${DateTime.now().millisecondsSinceEpoch}';
        await downloader.extract(archive, extractDir);
        final installed =
            await toolService.installExtractedBinary(extractDir, kind);
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
      toolStatuses[kind] = await toolService.check(kind);
    } catch (e) {
      errorMessage = '工具下载/安装失败';
      errorDetail = e.toString();
    } finally {
      toolDownloading[kind] = false;
      _downloadCancel = null;
      _notify();
    }
  }

  Future<void> downloadSelectedModel() async {
    modelDownloading = true;
    modelProgress = 0;
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
        errorDetail = '需要约 ${needBytes ~/ 1024 / 1024} MB，可用 '
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
            modelProgress = r / t;
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
      _notify();
    }
  }

  Future<String> _resolveWhisperAssetUrl() async {
    final dio = Dio();
    final resp = await dio.get<dynamic>(
      MediaDownloader.whisperLatestReleaseApiUrl(),
      options: Options(headers: {'Accept': 'application/vnd.github+json'}),
    );
    final assets = (resp.data['assets'] as List)
        .map((a) => (a as Map)['name'].toString())
        .toList();
    final asset = MediaDownloader.pickWhisperAsset(
      assets,
      isWindows: Platform.isWindows,
      isMac: Platform.isMacOS,
      isArm: _isArmHost,
    );
    if (asset == null) {
      throw Exception('当前平台暂无 whisper.cpp 预编译包，请查看安装指引手动安装');
    }
    return 'https://github.com/ggml-org/whisper.cpp/releases/download/'
        '${resp.data['tag_name']}/$asset';
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
    Future<MediaImportResult> Function(
            MediaImportService, MediaImportRequest)?
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
            : await service.run(request, onProgress: (p, v) {
                phase = p;
                phaseProgress = v;
                _notify();
              });
        result = r;
        resultNoteId = await saveNote(r);
        step = MediaImportStep.done;
      } on MediaImportException catch (e) {
        errorMessage = e.message;
        errorDetail = e.detail;
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
