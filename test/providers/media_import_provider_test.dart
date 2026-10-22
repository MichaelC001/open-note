import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_note/providers/media_import_provider.dart';
import 'package:open_note/services/media/media_downloader.dart';
import 'package:open_note/services/media/media_import_service.dart';
import 'package:open_note/services/media/media_tool_service.dart';
import 'package:open_note/services/media/whisper_model_service.dart';
import 'package:open_note/services/media/process_runner.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ReadyToolService extends MediaToolService {
  int checkCount = 0;
  _ReadyToolService(Future<String> Function() base)
    : super(resolveBaseDir: base);
  @override
  Future<MediaToolStatus> check(MediaToolKind kind) async {
    checkCount++;
    return MediaToolStatus(
      kind: kind,
      ready: true,
      path: 'fake',
      version: '1',
      source: MediaToolSource.appManaged,
    );
  }
}

class _GatedCheckToolService extends _ReadyToolService {
  Completer<void>? checkGate;
  _GatedCheckToolService(super.base);

  @override
  Future<MediaToolStatus> check(MediaToolKind kind) async {
    if (checkGate != null) await checkGate!.future;
    return super.check(kind);
  }
}

class _AllModelsService extends WhisperModelService {
  _AllModelsService(Future<String> Function() base)
    : super(resolveBaseDir: base);
  @override
  Future<WhisperModelTier> recommendTierForDevice() async =>
      WhisperModelTier.largeV3Turbo;
  @override
  Future<File?> localModelFile(WhisperModelTier tier) async => File('m.bin');
}

void main() {
  late Directory tmp;
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmp = Directory.systemTemp.createTempSync('vtn_prov');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  MediaImportProvider makeProvider() => MediaImportProvider(
    toolService: _ReadyToolService(() async => tmp.path),
    modelService: _AllModelsService(() async => tmp.path),
  );

  test('startForFile -> envCheck 且环境就绪', () async {
    final p = makeProvider();
    await p.startForFile(File('${tmp.path}/a.mp4'));
    expect(p.step, MediaImportStep.envCheck);
    expect(p.toolStatuses[MediaToolKind.ffmpeg]!.ready, isTrue);
    expect(p.toolStatuses[MediaToolKind.ytDlp], isNull);
    expect(p.recommendedTier, WhisperModelTier.largeV3Turbo);
    expect(p.selectedTier, WhisperModelTier.largeV3Turbo);
    expect(p.environmentReady, isTrue);
  });

  test('URL 来源时 yt-dlp 必检', () async {
    final p = makeProvider();
    await p.startForUrl('https://example.com/v');
    expect(p.toolStatuses[MediaToolKind.ytDlp], isNotNull);
  });

  test('confirmAndStart 成功后 done 且回调拿到结果', () async {
    final p = makeProvider();
    await p.startForFile(File('${tmp.path}/a.mp4'));
    MediaImportResult? captured;
    await p.confirmAndStart(
      runOverride: (_, _) async {
        await Future.delayed(const Duration(milliseconds: 10));
        return const MediaImportResult(
          markdown: '# ok',
          title: 'T',
          formattedByAI: true,
        );
      },
      saveNote: (r) async {
        captured = r;
        return 'note-1';
      },
    );
    expect(p.step, MediaImportStep.done);
    expect(p.resultNoteId, 'note-1');
    expect(captured!.markdown, '# ok');
  });

  test('confirmAndStart 失败写入 errorMessage', () async {
    final p = makeProvider();
    await p.startForFile(File('${tmp.path}/a.mp4'));
    await p.confirmAndStart(
      runOverride: (_, _) async =>
          throw const MediaImportException('boom', 'detail'),
      saveNote: (r) async => null,
    );
    expect(p.errorMessage, 'boom');
    expect(p.errorDetail, 'detail');
    expect(p.step, isNot(MediaImportStep.done));
  });

  test('cancel 终止处理', () async {
    final p = makeProvider();
    await p.startForFile(File('${tmp.path}/a.mp4'));
    await p.confirmAndStart(
      runOverride: (_, _) async {
        await Future.delayed(const Duration(seconds: 5));
        throw StateError('should not reach');
      },
      saveNote: (r) async => null,
      waitCompletion: false,
    );
    p.cancel();
    await Future.delayed(const Duration(milliseconds: 50));
    expect(p.step, isNot(MediaImportStep.done));
  });

  group('autoInstallTool（一键自动安装）', () {
    test('成功后重新检测、清除安装中状态、无错误', () async {
      final tools = _ReadyToolService(() async => tmp.path);
      final p = MediaImportProvider(
        toolService: tools,
        modelService: _AllModelsService(() async => tmp.path),
        installerRunner: (exe, args) async =>
            const ProcessRunResult(0, 'Pouring whisper-cpp', ''),
        brewPathResolver: () async => '/fake/brew',
      );
      await p.startForFile(File('${tmp.path}/a.mp4'));
      final before = tools.checkCount;

      await p.autoInstallTool(MediaToolKind.whisperCli);

      expect(tools.checkCount, greaterThan(before));
      expect(p.toolInstalling[MediaToolKind.whisperCli] ?? false, isFalse);
      expect(p.errorMessage, isNull);
      expect(p.toolStatuses[MediaToolKind.whisperCli]!.ready, isTrue);
    });

    test('安装进程非零退出时写入 errorMessage/errorDetail', () async {
      final p = MediaImportProvider(
        toolService: _ReadyToolService(() async => tmp.path),
        modelService: _AllModelsService(() async => tmp.path),
        installerRunner: (exe, args) async =>
            const ProcessRunResult(1, '', 'Error: formula unavailable'),
        brewPathResolver: () async => '/fake/brew',
      );
      await p.startForFile(File('${tmp.path}/a.mp4'));

      await p.autoInstallTool(MediaToolKind.whisperCli);

      expect(p.errorMessage, '自动安装失败');
      expect(p.errorDetail, contains('formula unavailable'));
      expect(p.toolInstalling[MediaToolKind.whisperCli] ?? false, isFalse);
    });

    test('brew 缺失（plan 为 null）时提示并回退指引', () async {
      final p = MediaImportProvider(
        toolService: _ReadyToolService(() async => tmp.path),
        modelService: _AllModelsService(() async => tmp.path),
        installerRunner: (exe, args) async => const ProcessRunResult(0, '', ''),
        brewPathResolver: () async => null,
      );
      await p.startForFile(File('${tmp.path}/a.mp4'));

      await p.autoInstallTool(MediaToolKind.whisperCli);

      expect(p.errorMessage, '无法自动安装');
      expect(p.errorDetail, contains('Homebrew'));
    });
  });

  group('下载进度状态（速度/百分比/ETA）', () {
    test('downloadTool 进度回调更新 toolDownloadStatus', () async {
      final fake = _HangingDownloader();
      final p = MediaImportProvider(
        toolService: _ReadyToolService(() async => tmp.path),
        modelService: _AllModelsService(() async => tmp.path),
        downloader: fake,
      );
      await p.startForFile(File('${tmp.path}/a.mp4'));

      final run = p.downloadTool(MediaToolKind.ytDlp);
      await fake.started.future;
      await Future.delayed(Duration.zero);

      expect(p.toolDownloading[MediaToolKind.ytDlp] ?? false, isTrue);
      final st = p.toolDownloadStatus[MediaToolKind.ytDlp];
      expect(st, isNotNull);
      expect(st!.progress, closeTo(0.5, 1e-9));
      expect(st.speedBps, 0);
      expect(st.etaSeconds, isNull);

      fake.release.complete();
      await run;
      expect(p.toolDownloading[MediaToolKind.ytDlp] ?? false, isFalse);
    });

    test('downloadSelectedModel 进度回调更新 modelDownloadStatus', () async {
      final fake = _HangingDownloader();
      final p = MediaImportProvider(
        toolService: _ReadyToolService(() async => tmp.path),
        modelService: _AllModelsService(() async => tmp.path),
        downloader: fake,
      );
      await p.startForFile(File('${tmp.path}/a.mp4'));
      p.downloadedTiers.clear();

      final run = p.downloadSelectedModel();
      await fake.started.future;
      await Future.delayed(Duration.zero);

      expect(p.modelDownloadStatus.progress, closeTo(0.5, 1e-9));

      fake.release.complete();
      await run;
    });

    test('工具下载完成后进入 安装中 状态，检测完成后退出', () async {
      final tools = _GatedCheckToolService(() async => tmp.path);
      final fake = _HangingDownloader();
      final p = MediaImportProvider(
        toolService: tools,
        modelService: _AllModelsService(() async => tmp.path),
        downloader: fake,
      );
      await p.startForFile(File('${tmp.path}/a.mp4'));
      tools.checkGate = Completer<void>();

      final run = p.downloadTool(MediaToolKind.ytDlp);
      await fake.started.future;
      expect(p.toolFinishing[MediaToolKind.ytDlp] ?? false, isFalse);

      fake.release.complete();
      await Future.delayed(const Duration(milliseconds: 20));
      expect(p.toolDownloading[MediaToolKind.ytDlp] ?? false, isFalse);
      expect(p.toolFinishing[MediaToolKind.ytDlp] ?? false, isTrue);

      tools.checkGate!.complete();
      await run;
      expect(p.toolFinishing[MediaToolKind.ytDlp] ?? false, isFalse);
      expect(p.toolStatuses[MediaToolKind.ytDlp]!.ready, isTrue);
    });
  });

  group('ffmpeg 单文件下载 URL 回归', () {
    test('downloadTool(ffmpeg) 使用 ffmpeg-static 而非 yt-dlp URL', () async {
      final fake = _CapturingDownloader();
      final p = MediaImportProvider(
        toolService: _ReadyToolService(() async => tmp.path),
        modelService: _AllModelsService(() async => tmp.path),
        downloader: fake,
      );
      await p.startForFile(File('${tmp.path}/a.mp4'));
      p.toolStatuses[MediaToolKind.ffmpeg] = const MediaToolStatus.missing(
          MediaToolKind.ffmpeg);
      await p.downloadTool(MediaToolKind.ffmpeg);
      expect(fake.lastUrl, contains('/ffmpeg-static/releases/'));
      expect(fake.lastUrl, isNot(contains('/yt-dlp/')));
    });
  });
}

class _CapturingDownloader extends MediaDownloader {
  String? lastUrl;
  @override
  Future<File> download(
    String directUrl, {
    required File destFile,
    MediaDownloadSourceMode mode = MediaDownloadSourceMode.auto,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
    String? expectedSha256,
  }) async {
    lastUrl = directUrl;
    return destFile;
  }
}

class _HangingDownloader extends MediaDownloader {
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();

  _HangingDownloader();

  @override
  Future<File> download(
    String directUrl, {
    required File destFile,
    MediaDownloadSourceMode mode = MediaDownloadSourceMode.auto,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
    String? expectedSha256,
  }) async {
    onProgress?.call(0, 1000);
    onProgress?.call(500, 1000);
    started.complete();
    await release.future;
    return destFile;
  }
}
