import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_note/providers/media_import_provider.dart';
import 'package:open_note/services/media/media_downloader.dart';
import 'package:open_note/services/media/media_import_service.dart';
import 'package:open_note/services/media/media_import_settings.dart';
import 'package:open_note/services/media/media_tool_service.dart';
import 'package:open_note/services/media/tool_update_service.dart';
import 'package:open_note/services/media/whisper_model_service.dart';
import 'package:open_note/services/media/process_runner.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ReadyToolService extends MediaToolService {
  int checkCount = 0;
  _ReadyToolService(Future<String> Function() base)
    : super(resolveBaseDir: base);
  @override
  Future<MediaToolStatus> check(MediaToolKind kind,
      {bool forceVerify = false}) async {
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
  Future<MediaToolStatus> check(MediaToolKind kind,
      {bool forceVerify = false}) async {
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

class _SystemToolService extends _ReadyToolService {
  _SystemToolService(super.base);
  @override
  Future<MediaToolStatus> check(MediaToolKind kind,
      {bool forceVerify = false}) async {
    checkCount++;
    return MediaToolStatus(
      kind: kind, ready: true, path: '/usr/bin/${kind.name}',
      version: '1', source: MediaToolSource.systemPath);
  }
}

class _RealAllModelsService extends WhisperModelService {
  _RealAllModelsService(Future<String> Function() base) : super(resolveBaseDir: base);
  @override
  Future<WhisperModelTier> recommendTierForDevice() async => WhisperModelTier.base;
  // localModelFile 用真实实现（基于 modelsDir 文件存在性）
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

  test('checkEnvironment 后 selectedTier==recommendedTier（不再读默认模型档设置）',
      () async {
    // 预置历史默认模型档偏好：实现不再读取该设置时，选中档恒等于推荐档
    SharedPreferences.setMockInitialValues(
        <String, Object>{'media_import_default_model': 'base'});
    final p = makeProvider();
    await p.checkEnvironment();
    expect(p.selectedTier, p.recommendedTier);
    expect(p.selectedTier, WhisperModelTier.largeV3Turbo);
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

      // finishing 窗口内重复点击「更新」：守卫直接 return，不二次下载
      unawaited(p.downloadTool(MediaToolKind.ytDlp));
      await Future<void>.delayed(Duration.zero);
      expect(fake.downloadCount, 1);
      expect(p.toolDownloading[MediaToolKind.ytDlp] ?? false, isFalse);
      expect(p.toolFinishing[MediaToolKind.ytDlp] ?? false, isTrue);

      tools.checkGate!.complete();
      await run;
      expect(p.toolFinishing[MediaToolKind.ytDlp] ?? false, isFalse);
      expect(p.toolStatuses[MediaToolKind.ytDlp]!.ready, isTrue);
    });
  });

  group('operationInProgress 统一判定', () {
    test('覆盖 _busy/finishing 窗口，空闲时为 false', () async {
      final tools = _GatedCheckToolService(() async => tmp.path);
      final fake = _HangingDownloader();
      final p = MediaImportProvider(
        toolService: tools,
        modelService: _AllModelsService(() async => tmp.path),
        downloader: fake,
      );
      // _busy 窗口：挂起 checkEnvironment 期间判定为进行中
      tools.checkGate = Completer<void>();
      final start = p.startForFile(File('${tmp.path}/a.mp4'));
      await Future.delayed(const Duration(milliseconds: 20));
      expect(p.operationInProgress, isTrue); // checkEnvironment 进行中(_busy)
      tools.checkGate!.complete();
      await start;
      expect(p.operationInProgress, isFalse);

      // finishing 窗口：下载收尾（gated check 挂起）判定为进行中
      tools.checkGate = Completer<void>();
      final run = p.downloadTool(MediaToolKind.ytDlp);
      await fake.started.future;
      fake.release.complete();
      await Future.delayed(const Duration(milliseconds: 20));
      expect(p.toolFinishing[MediaToolKind.ytDlp] ?? false, isTrue);
      expect(p.operationInProgress, isTrue); // finishing 窗口
      tools.checkGate!.complete();
      await run;
      expect(p.operationInProgress, isFalse);
    });
  });

  group('uninstallPlan 纯函数', () {
    test('mac 有 brew：三种工具都有 brew uninstall 计划', () {
      final ffmpegPlan = MediaImportProvider.uninstallPlan(MediaToolKind.ffmpeg,
          brewPath: '/opt/homebrew/bin/brew', isMac: true, isWin: false);
      expect(ffmpegPlan!.executable, '/opt/homebrew/bin/brew');
      expect(ffmpegPlan.args, ['uninstall', '-q', 'ffmpeg']);
      expect(
          MediaImportProvider.uninstallPlan(MediaToolKind.whisperCli,
              brewPath: '/brew', isMac: true, isWin: false)!.args
              .last, 'whisper-cpp');
    });
    test('mac 无 brew / linux：返回 null', () {
      expect(
          MediaImportProvider.uninstallPlan(MediaToolKind.ffmpeg,
              brewPath: null, isMac: true, isWin: false), isNull);
      expect(
          MediaImportProvider.uninstallPlan(MediaToolKind.ffmpeg,
              brewPath: '/brew', isMac: false, isWin: false), isNull);
    });
    test('windows：仅 whisper-cli 有 winget 计划（需绝对路径）', () {
      const winget = r'C:\Users\a\AppData\Local\Microsoft\WindowsApps\winget.exe';
      final plan = MediaImportProvider.uninstallPlan(MediaToolKind.whisperCli,
          wingetPath: winget, isMac: false, isWin: true);
      expect(plan!.executable, winget);
      expect(plan.args.first, 'uninstall');
      expect(plan.args.join(' '), contains('ggml.whisper-cpp'));
      expect(
          MediaImportProvider.uninstallPlan(MediaToolKind.ffmpeg,
              wingetPath: winget, isMac: false, isWin: true), isNull);
    });
    test('windows：wingetPath 为空 -> null（回退指引）', () {
      expect(
          MediaImportProvider.uninstallPlan(MediaToolKind.whisperCli,
              wingetPath: null, isMac: false, isWin: true), isNull);
      expect(
          MediaImportProvider.uninstallPlan(MediaToolKind.whisperCli,
              wingetPath: '', isMac: false, isWin: true), isNull);
    });
  });

  group('uninstallTool / deleteModel', () {
    test('appManaged：删除 toolDir 内容并重查', () async {
      final tools = _ReadyToolService(() async => tmp.path);
      final p = MediaImportProvider(
          toolService: tools, modelService: _AllModelsService(() async => tmp.path));
      await p.startForFile(File('${tmp.path}/a.mp4'));
      final bin = File(
          '${await tools.toolDir(MediaToolKind.whisperCli)}/${tools.binaryName(MediaToolKind.whisperCli)}');
      await bin.create(recursive: true);
      await p.uninstallTool(MediaToolKind.whisperCli);
      expect(bin.existsSync(), isFalse);
      expect(p.errorMessage, isNull);
      expect(p.toolUninstalling[MediaToolKind.whisperCli] ?? false, isFalse);
    });

    test('uninstallTool 进行中 operationInProgress 为 true', () async {
      final tools = _GatedCheckToolService(() async => tmp.path);
      final p = MediaImportProvider(
        toolService: tools,
        modelService: _AllModelsService(() async => tmp.path),
      );
      await p.startForFile(File('${tmp.path}/a.mp4'));
      tools.checkGate = Completer<void>();

      final run = p.uninstallTool(MediaToolKind.ffmpeg);
      for (var i = 0;
          i < 100 && !(p.toolUninstalling[MediaToolKind.ffmpeg] ?? false);
          i++) {
        await Future.delayed(const Duration(milliseconds: 5));
      }
      expect(p.toolUninstalling[MediaToolKind.ffmpeg] ?? false, isTrue);
      expect(p.operationInProgress, isTrue);

      tools.checkGate!.complete();
      await run;
      expect(p.toolUninstalling[MediaToolKind.ffmpeg] ?? false, isFalse);
      expect(p.operationInProgress, isFalse);
    });

    test('systemPath：mac 调 brew uninstall，失败写 errorMessage', () async {
      String? capturedExe; List<String>? capturedArgs;
      final sysTool = _SystemToolService(() async => tmp.path);
      final p = MediaImportProvider(
        toolService: sysTool,
        modelService: _AllModelsService(() async => tmp.path),
        installerRunner: (exe, args) async {
          capturedExe = exe; capturedArgs = args;
          return const ProcessRunResult(1, '', 'No such keg');
        },
        brewPathResolver: () async => '/fake/brew',
      );
      await p.startForFile(File('${tmp.path}/a.mp4'));
      await p.uninstallTool(MediaToolKind.ffmpeg);
      expect(capturedExe, '/fake/brew');
      expect(capturedArgs, containsAll(['uninstall', '-q', 'ffmpeg']));
      expect(p.errorMessage, '自动卸载失败');
      expect(p.errorDetail, contains('No such keg'));
    });

    test('deleteModel：删除文件并移出 downloadedTiers；转录中阻止', () async {
      final models = _RealAllModelsService(() async => tmp.path);
      final p = MediaImportProvider(
          toolService: _ReadyToolService(() async => tmp.path),
          modelService: models);
      await p.startForFile(File('${tmp.path}/a.mp4'));
      final f = File(
          '${await models.modelsDir()}/${WhisperModelService.infoFor(WhisperModelTier.base).fileName}');
      await f.create(recursive: true);
      p.downloadedTiers.add(WhisperModelTier.base);
      expect(p.downloadedTiers.contains(WhisperModelTier.base), isTrue);
      await p.deleteModel(WhisperModelTier.base);
      expect(f.existsSync(), isFalse);
      expect(p.downloadedTiers.contains(WhisperModelTier.base), isFalse);

      // 转录中守卫
      await f.create(recursive: true);
      p.downloadedTiers.add(WhisperModelTier.base);
      await p.confirmAndStart(
        runOverride: (_, _) async {
          await Future.delayed(const Duration(seconds: 5));
          throw StateError('unreachable');
        },
        saveNote: (r) async => null,
        waitCompletion: false,
      );
      await p.deleteModel(WhisperModelTier.base);
      expect(p.errorMessage, '转录进行中，无法删除模型');
      expect(f.existsSync(), isTrue);
      p.cancel();
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

    test('downloadTool(ffmpeg) 更新时用检测到的具体 tag 下载并清除徽标', () async {
      final fake = _CapturingDownloader();
      final p = MediaImportProvider(
        toolService: _ReadyToolService(() async => tmp.path),
        modelService: _AllModelsService(() async => tmp.path),
        downloader: fake,
      );
      await p.startForFile(File('${tmp.path}/a.mp4'));
      p.toolStatuses[MediaToolKind.ffmpeg] = const MediaToolStatus.missing(
          MediaToolKind.ffmpeg);
      p.updateAvailableVersion[MediaToolKind.ffmpeg] = 'b6.1.1';

      await p.downloadTool(MediaToolKind.ffmpeg);

      expect(fake.lastUrl, contains('/releases/download/b6.1.1/'));
      expect(fake.lastUrl, isNot(contains('/releases/latest/')));
      expect(p.updateAvailableVersion[MediaToolKind.ffmpeg], isNull);
    });
  });
  group('ffmpeg 装前可执行验证（坏资产防护）', () {
    List<String> ranExe = [];
    List<List<String>> ranArgs = [];

    MediaImportProvider makeVerifyProvider({
      required int exitCode,
      _ReadyToolService? tools,
    }) {
      ranExe = [];
      ranArgs = [];
      return MediaImportProvider(
        toolService: tools ?? _ReadyToolService(() async => tmp.path),
        modelService: _AllModelsService(() async => tmp.path),
        downloader: _WritingDownloader(),
        installerRunner: (exe, args) async {
          ranExe.add(exe);
          ranArgs.add(args);
          return ProcessRunResult(exitCode, 'ffmpeg version n6.0', '');
        },
      );
    }

    Future<File> destPath(MediaToolService tools, MediaToolKind kind) async =>
        File('${await tools.toolDir(kind)}/${tools.binaryName(kind)}');

    test('坏资产（exitCode 1）：旧文件不被替换，走错误路径并清理临时文件', () async {
      final tools = _ReadyToolService(() async => tmp.path);
      final dest = await destPath(tools, MediaToolKind.ffmpeg);
      await dest.create(recursive: true);
      await dest.writeAsString('OLD');
      final p = makeVerifyProvider(exitCode: 1, tools: tools);
      await p.startForFile(File('${tmp.path}/a.mp4'));

      await p.downloadTool(MediaToolKind.ffmpeg);

      expect(ranExe, hasLength(1));
      expect(ranExe.single, isNot(dest.path)); // 验证发生在替换前的临时文件上
      expect(ranArgs.single, ['-version']);
      expect(dest.readAsStringSync(), 'OLD'); // 旧文件未被替换
      expect(p.errorMessage, '下载的引擎文件无法运行，已保留当前版本');
      expect(File('${dest.path}.staging').existsSync(), isFalse); // 临时文件已清理
      expect(p.toolDownloading[MediaToolKind.ffmpeg] ?? false, isFalse);
      expect(p.toolFinishing[MediaToolKind.ffmpeg] ?? false, isFalse);
    });

    test('好资产（exitCode 0）：替换旧文件且无错误', () async {
      final tools = _ReadyToolService(() async => tmp.path);
      final dest = await destPath(tools, MediaToolKind.ffmpeg);
      await dest.create(recursive: true);
      await dest.writeAsString('OLD');
      final p = makeVerifyProvider(exitCode: 0, tools: tools);
      await p.startForFile(File('${tmp.path}/a.mp4'));

      await p.downloadTool(MediaToolKind.ffmpeg);

      expect(dest.readAsStringSync(), 'NEW-BINARY');
      expect(p.errorMessage, isNull);
      expect(File('${dest.path}.staging').existsSync(), isFalse);
    });

    test('yt-dlp 不做装前可执行验证', () async {
      final tools = _ReadyToolService(() async => tmp.path);
      final dest = await destPath(tools, MediaToolKind.ytDlp);
      final p = makeVerifyProvider(exitCode: 1, tools: tools);
      await p.startForFile(File('${tmp.path}/a.mp4'));

      await p.downloadTool(MediaToolKind.ytDlp);

      expect(ranExe, isEmpty); // 未执行 -version 探测
      expect(dest.readAsStringSync(), 'NEW-BINARY'); // 直接落位
      expect(File('${dest.path}.staging').existsSync(), isFalse);
      expect(p.errorMessage, isNull);
    });
  });

  group('装后版本比对（更新未生效检测）', () {
    test('更新后版本未变化：清除更新标记并给出非阻断提示', () async {
      // _ReadyToolService 恒返回 version '1' → 模拟镜像内容未变化
      final p = MediaImportProvider(
        toolService: _ReadyToolService(() async => tmp.path),
        modelService: _AllModelsService(() async => tmp.path),
        downloader: _WritingDownloader(),
        installerRunner: (exe, args) async => const ProcessRunResult(0, '', ''),
      );
      await p.startForFile(File('${tmp.path}/a.mp4'));
      p.updateAvailableVersion[MediaToolKind.ffmpeg] = 'b6.1.1';

      await p.downloadTool(MediaToolKind.ffmpeg);

      expect(p.updateAvailableVersion[MediaToolKind.ffmpeg], isNull);
      expect(await MediaImportSettings().readUpdateAvailable(), isEmpty);
      expect(p.toolHints[MediaToolKind.ffmpeg], contains('更新未生效'));
      expect(p.errorMessage, isNull); // 非阻断：无 ErrorBanner 错误
    });

    test('更新后版本变化：无提示，标记保持清除', () async {
      final p = MediaImportProvider(
        toolService: _VersionShiftToolService(() async => tmp.path),
        modelService: _AllModelsService(() async => tmp.path),
        downloader: _WritingDownloader(),
        installerRunner: (exe, args) async => const ProcessRunResult(0, '', ''),
      );
      await p.startForFile(File('${tmp.path}/a.mp4'));
      p.updateAvailableVersion[MediaToolKind.ffmpeg] = 'b6.1';

      await p.downloadTool(MediaToolKind.ffmpeg);

      expect(p.updateAvailableVersion[MediaToolKind.ffmpeg], isNull);
      expect(p.toolHints[MediaToolKind.ffmpeg], isNull);
      expect(p.errorMessage, isNull);
    });

    test('非更新场景（首次安装）：不产生更新未生效提示', () async {
      final p = MediaImportProvider(
        toolService: _ReadyToolService(() async => tmp.path),
        modelService: _AllModelsService(() async => tmp.path),
        downloader: _WritingDownloader(),
        installerRunner: (exe, args) async => const ProcessRunResult(0, '', ''),
      );
      await p.startForFile(File('${tmp.path}/a.mp4'));
      p.toolStatuses[MediaToolKind.ffmpeg] =
          const MediaToolStatus.missing(MediaToolKind.ffmpeg);

      await p.downloadTool(MediaToolKind.ffmpeg);

      expect(p.toolHints[MediaToolKind.ffmpeg], isNull);
      expect(p.errorMessage, isNull);
    });
  });

  group('工具静默新版本检查（checkToolUpdates）', () {
    MediaImportProvider makeUpdateProvider(_CountingFetcher fetcher) =>
        MediaImportProvider(
          toolService: _MixedSourceToolService(() async => tmp.path),
          modelService: _AllModelsService(() async => tmp.path),
          updateService: ToolUpdateService(fetcher: fetcher.call),
          clock: () => DateTime(2026, 1, 1, 12),
        );

    test('只检查 ready+appManaged 工具，systemPath/无状态跳过', () async {
      final fetcher = _CountingFetcher('b7.0');
      final p = makeUpdateProvider(fetcher);
      await p.startForFile(File('${tmp.path}/a.mp4'));

      await p.checkToolUpdates();

      expect(fetcher.calls, 1);
      expect(fetcher.urls.single,
          contains('repos/eugeneware/ffmpeg-static/releases/latest'));
    });

    test('发现新版本写入 updateAvailableVersion 并复位 checking', () async {
      final fetcher = _CountingFetcher('b7.0');
      final p = makeUpdateProvider(fetcher);
      await p.startForFile(File('${tmp.path}/a.mp4'));

      await p.checkToolUpdates();

      expect(p.updateAvailableVersion[MediaToolKind.ffmpeg], 'b7.0');
      expect(p.updateChecking[MediaToolKind.ffmpeg] ?? false, isFalse);
    });

    test('24h 内二次调用被节流跳过（fetch 次数不变）', () async {
      final fetcher = _CountingFetcher('b7.0');
      final p = makeUpdateProvider(fetcher);
      await p.startForFile(File('${tmp.path}/a.mp4'));

      await p.checkToolUpdates();
      expect(fetcher.calls, 1);
      await p.checkToolUpdates();
      expect(fetcher.calls, 1);
    });

    test('本地版本等于远端时不写入更新', () async {
      final fetcher = _CountingFetcher('b6.0'); // normalize 后 == 本地 6.0
      final p = makeUpdateProvider(fetcher);
      await p.startForFile(File('${tmp.path}/a.mp4'));

      await p.checkToolUpdates();

      expect(p.updateAvailableVersion[MediaToolKind.ffmpeg], isNull);
    });

    test('下载进行中时检查跳过该 kind：fetch 返回也不写回更新徽标', () async {
      final fetcher = _GatedFetcher();
      final fake = _HangingDownloader();
      final p = MediaImportProvider(
        toolService: _MixedSourceToolService(() async => tmp.path),
        modelService: _AllModelsService(() async => tmp.path),
        downloader: fake,
        updateService: ToolUpdateService(fetcher: fetcher.call),
        clock: () => DateTime(2026, 1, 1, 12),
      );
      await p.startForFile(File('${tmp.path}/a.mp4'));

      final run = p.downloadTool(MediaToolKind.ffmpeg);
      await fake.started.future;
      expect(p.toolDownloading[MediaToolKind.ffmpeg] ?? false, isTrue);

      final check = p.checkToolUpdates();
      fetcher.gate.complete();
      await check;

      fake.release.complete();
      await run;

      expect(p.updateAvailableVersion[MediaToolKind.ffmpeg], isNull);
    });

    test('全部被跳过（systemPath）时：不 fetch 也不写 24h 节流时间戳', () async {
      final fetcher = _CountingFetcher('b7.0');
      final p = MediaImportProvider(
        toolService: _SystemToolService(() async => tmp.path),
        modelService: _AllModelsService(() async => tmp.path),
        updateService: ToolUpdateService(fetcher: fetcher.call),
        clock: () => DateTime(2026, 1, 1, 12),
      );
      await p.startForFile(File('${tmp.path}/a.mp4'));

      await p.checkToolUpdates();

      expect(fetcher.calls, 0);
      expect(await MediaImportSettings().lastUpdateCheckAt(), isNull);
    });

    test('环境未检测（toolStatuses 空）时定时器顺延且不空转，填充后下一轮才检查',
        () async {
      final fetcher = _CountingFetcher('b7.0');
      final p = makeUpdateProvider(fetcher);
      await SharedPreferences.getInstance(); // 预热 mock 存储（纯微任务，FakeAsync 内可完成）

      FakeAsync().run((async) {
        // 1) toolStatuses 为空（splash 只调度未检测）：到点不 fetch；
        //    顺延 60s 到点仍空 → 再顺延，fetch 恒为 0，也不写节流时间戳
        p.scheduleUpdateCheck(delay: const Duration(milliseconds: 50));
        async.elapse(const Duration(seconds: 1));
        expect(fetcher.calls, 0);
        async.elapse(const Duration(seconds: 61));
        expect(fetcher.calls, 0);

        // 2) 用户打开媒体 UI：startForFile 填充状态（fake 服务纯微任务可完成）
        //    （不再 await 其 future——FakeAsync 区内创建的 future 出区后 await 会悬死）
        unawaited(p.startForFile(File('${tmp.path}/a.mp4')));
        async.elapse(const Duration(seconds: 1));
        expect(p.toolStatuses[MediaToolKind.ffmpeg], isNotNull);

        // 3) 重新调度：到点才真正执行检查
        p.scheduleUpdateCheck(delay: const Duration(milliseconds: 50));
        async.elapse(const Duration(seconds: 1));
        expect(fetcher.calls, 1);
        expect(p.updateAvailableVersion[MediaToolKind.ffmpeg], 'b7.0');
      });
    });

    test('定时器到点时操作进行中：顺延重试而非永久跳过，空闲后执行检查', () async {
      final fetcher = _CountingFetcher('b7.0');
      final p = makeUpdateProvider(fetcher);
      await p.startForFile(File('${tmp.path}/a.mp4'));
      await SharedPreferences.getInstance(); // 预热 mock 存储（纯微任务，FakeAsync 内可完成）

      FakeAsync().run((async) {
        p.modelDownloading = true; // 模拟启动 15 秒内开始的长操作（如模型下载）
        p.scheduleUpdateCheck(delay: const Duration(milliseconds: 50));

        async.elapse(const Duration(seconds: 1));
        expect(fetcher.calls, 0); // 忙：本轮跳过

        p.modelDownloading = false; // 操作结束
        async.elapse(const Duration(seconds: 61)); // 顺延的 60s 重试到点
        expect(fetcher.calls, greaterThanOrEqualTo(1)); // 重试确实执行了检查
        expect(p.updateAvailableVersion[MediaToolKind.ffmpeg], 'b7.0');
      });
    });
  });

  group('环境就绪跳过检测步骤', () {
    void seedAllReady(MediaImportProvider p, {bool withModel = true}) {
      for (final k in MediaToolKind.values) {
        p.toolStatuses[k] = MediaToolStatus(
          kind: k,
          ready: true,
          path: 'fake',
          version: '1',
          source: MediaToolSource.appManaged,
        );
      }
      if (withModel) p.downloadedTiers.add(p.selectedTier);
    }

    test('工具与模型全就绪：startForUrl 直达 confirm 并后台刷新检测', () async {
      final tools = _ReadyToolService(() async => tmp.path);
      final p = MediaImportProvider(
        toolService: tools,
        modelService: _AllModelsService(() async => tmp.path),
      );
      seedAllReady(p);
      final before = tools.checkCount;

      await p.startForUrl('https://example.com/v');

      expect(p.step, MediaImportStep.confirm);
      // 后台静默刷新确实执行了检测（验证缓存使其廉价）
      expect(tools.checkCount, greaterThan(before));
    });

    test('工具就绪：startForFile 直达 confirm', () async {
      final p = makeProvider();
      seedAllReady(p);

      await p.startForFile(File('${tmp.path}/a.mp4'));

      expect(p.step, MediaImportStep.confirm);
    });

    test('缺模型：仍走 envCheck 完整检测', () async {
      final p = makeProvider();
      seedAllReady(p, withModel: false);

      await p.startForFile(File('${tmp.path}/a.mp4'));

      expect(p.step, MediaImportStep.envCheck);
      expect(p.environmentReady, isTrue); // 检测完成后模型就绪
    });
  });

  group('更新标记持久化（跨重启恢复 + 落盘）', () {
    MediaImportProvider makeUpdateProvider(_CountingFetcher fetcher) =>
        MediaImportProvider(
          toolService: _MixedSourceToolService(() async => tmp.path),
          modelService: _AllModelsService(() async => tmp.path),
          updateService: ToolUpdateService(fetcher: fetcher.call),
          clock: () => DateTime(2026, 1, 1, 12),
        );

    Future<void> flushRestore() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }

    test('构造后从持久化恢复更新标记，非法 kind 跳过', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'media_tool_update_available': '{"ffmpeg":"b7.0","bogus":"x"}',
      });
      final p = makeUpdateProvider(_CountingFetcher('b7.0'));
      await flushRestore();
      expect(p.updateAvailableVersion[MediaToolKind.ffmpeg], 'b7.0');
      expect(p.updateAvailableVersion.length, 1);
    });

    test('checkToolUpdates 发现更新：内存与持久化表都写入', () async {
      final fetcher = _CountingFetcher('b7.0');
      final p = makeUpdateProvider(fetcher);
      await p.startForFile(File('${tmp.path}/a.mp4'));

      await p.checkToolUpdates();

      expect(p.updateAvailableVersion[MediaToolKind.ffmpeg], 'b7.0');
      expect(await MediaImportSettings().readUpdateAvailable(),
          {'ffmpeg': 'b7.0'});
    });

    test('checkToolUpdates 无更新：清除该 kind 的持久化标记', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'media_tool_update_available': '{"ffmpeg":"b7.0"}',
      });
      final fetcher = _CountingFetcher('b6.0'); // == 本地版本 → 无更新
      final p = makeUpdateProvider(fetcher);
      await flushRestore();
      await p.startForFile(File('${tmp.path}/a.mp4'));

      await p.checkToolUpdates();

      expect(p.updateAvailableVersion[MediaToolKind.ffmpeg], isNull);
      expect(await MediaImportSettings().readUpdateAvailable(), isEmpty);
    });

    test('downloadTool 成功后从持久化表移除该 kind', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'media_tool_update_available': '{"ffmpeg":"b6.1.1"}',
      });
      final p = MediaImportProvider(
        toolService: _ReadyToolService(() async => tmp.path),
        modelService: _AllModelsService(() async => tmp.path),
        downloader: _CapturingDownloader(),
        // 装前可执行验证需通过：fake runner 模拟可运行资产
        installerRunner: (exe, args) async => const ProcessRunResult(0, '', ''),
      );
      await p.startForFile(File('${tmp.path}/a.mp4'));
      await flushRestore();
      expect(p.updateAvailableVersion[MediaToolKind.ffmpeg], 'b6.1.1');

      await p.downloadTool(MediaToolKind.ffmpeg);

      expect(p.errorMessage, isNull);
      expect(p.updateAvailableVersion[MediaToolKind.ffmpeg], isNull);
      expect(await MediaImportSettings().readUpdateAvailable(), isEmpty);
    });

    test('uninstallTool 成功后从持久化表移除该 kind', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'media_tool_update_available': '{"whisperCli":"b1.2.3"}',
      });
      final tools = _ReadyToolService(() async => tmp.path);
      final p = MediaImportProvider(
        toolService: tools,
        modelService: _AllModelsService(() async => tmp.path),
      );
      await p.startForFile(File('${tmp.path}/a.mp4'));
      await flushRestore();
      final bin = File(
          '${await tools.toolDir(MediaToolKind.whisperCli)}/${tools.binaryName(MediaToolKind.whisperCli)}');
      await bin.create(recursive: true);

      await p.uninstallTool(MediaToolKind.whisperCli);

      expect(p.errorMessage, isNull);
      expect(p.updateAvailableVersion[MediaToolKind.whisperCli], isNull);
      expect(await MediaImportSettings().readUpdateAvailable(), isEmpty);
    });
  });
}

class _CountingFetcher {
  int calls = 0;
  final List<String> urls = [];
  final String tag;
  _CountingFetcher(this.tag);
  Future<Response<dynamic>> call(String url, Options options) async {
    calls++;
    urls.add(url);
    return Response<dynamic>(
      data: {'tag_name': tag},
      requestOptions: RequestOptions(path: url),
    );
  }
}

class _GatedFetcher {
  final Completer<void> gate = Completer<void>();
  int calls = 0;
  Future<Response<dynamic>> call(String url, Options options) async {
    calls++;
    await gate.future;
    return Response<dynamic>(
      data: const {'tag_name': 'b7.0'},
      requestOptions: RequestOptions(path: url),
    );
  }
}

class _MixedSourceToolService extends MediaToolService {
  _MixedSourceToolService(Future<String> Function() base)
      : super(resolveBaseDir: base);
  @override
  Future<MediaToolStatus> check(MediaToolKind kind,
      {bool forceVerify = false}) async {
    if (kind == MediaToolKind.whisperCli) {
      return const MediaToolStatus(
        kind: MediaToolKind.whisperCli,
        ready: true,
        path: '/usr/bin/whisper-cli',
        version: 'ready',
        source: MediaToolSource.systemPath,
      );
    }
    return MediaToolStatus(
      kind: kind,
      ready: true,
      path: 'fake',
      version: '6.0',
      source: MediaToolSource.appManaged,
    );
  }
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
    await destFile.parent.create(recursive: true);
    await destFile.writeAsString('NEW-BINARY');
    return destFile;
  }
}

/// 真实写入目标文件（模拟下载产物落盘），供装前验证链路测试。
class _WritingDownloader extends MediaDownloader {
  @override
  Future<File> download(
    String directUrl, {
    required File destFile,
    MediaDownloadSourceMode mode = MediaDownloadSourceMode.auto,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
    String? expectedSha256,
  }) async {
    await destFile.parent.create(recursive: true);
    await destFile.writeAsString('NEW-BINARY');
    return destFile;
  }
}

/// 装前检测返回 6.0、forceVerify（装后重检）返回 6.1。
class _VersionShiftToolService extends _ReadyToolService {
  _VersionShiftToolService(super.base);
  @override
  Future<MediaToolStatus> check(MediaToolKind kind,
      {bool forceVerify = false}) async {
    checkCount++;
    return MediaToolStatus(
      kind: kind,
      ready: true,
      path: 'fake',
      version: forceVerify ? '6.1' : '6.0',
      source: MediaToolSource.appManaged,
    );
  }
}

class _HangingDownloader extends MediaDownloader {
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();
  int downloadCount = 0;

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
    downloadCount++;
    onProgress?.call(0, 1000);
    onProgress?.call(500, 1000);
    started.complete();
    await release.future;
    return destFile;
  }
}
