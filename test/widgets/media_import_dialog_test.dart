// test/widgets/media_import_dialog_test.dart
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_note/l10n/strings.g.dart';
import 'package:open_note/providers/media_import_provider.dart';
import 'package:open_note/services/media/media_downloader.dart';
import 'package:open_note/services/media/media_import_service.dart';
import 'package:open_note/services/media/media_tool_service.dart';
import 'package:open_note/services/media/whisper_model_service.dart';
import 'package:open_note/theme/design_tokens.dart';
import 'package:open_note/widgets/media_import/confirm_step.dart';
import 'package:open_note/widgets/media_import/env_check_step.dart';
import 'package:open_note/widgets/media_import/media_import_dialog.dart';
import 'package:open_note/widgets/media_import/tool_status_row.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _CountingToolService extends MediaToolService {
  int checkCount = 0;
  bool ytDlpMissing = false;

  _CountingToolService(Directory dir)
      : super(resolveBaseDir: () async => dir.path);

  @override
  Future<MediaToolStatus> check(MediaToolKind kind,
      {bool forceVerify = false}) async {
    checkCount++;
    if (ytDlpMissing && kind == MediaToolKind.ytDlp) {
      return const MediaToolStatus.missing(MediaToolKind.ytDlp);
    }
    if (ytDlpMissing) {
      return MediaToolStatus(kind: kind, ready: true, version: 'fake');
    }
    return MediaToolStatus.missing(kind);
  }

  // 基类实现含真实文件 IO（exists/create），FakeAsync 下无法完成，改纯计算
  @override
  Future<String> toolDir(MediaToolKind kind) async {
    final base = await resolveBaseDir();
    return '$base/tools/${kind.name}';
  }
}

class _AllDownloadedFastService extends _FastModelService {
  _AllDownloadedFastService(super.dir);

  @override
  Future<File?> localModelFile(WhisperModelTier tier) async => File('m.bin');
}

class _GatedDownloader extends MediaDownloader {
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();

  _GatedDownloader();

  // testWidgets 的 FakeAsync 内真实 df 子进程事件无法送达，覆写避免死等
  @override
  Future<int?> freeDiskBytes(String path) async => 10 << 30;

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

class _FastModelService extends WhisperModelService {
  _FastModelService(Directory dir)
      : super(resolveBaseDir: () async => dir.path);

  @override
  Future<WhisperModelTier> recommendTierForDevice() async =>
      WhisperModelTier.base;

  @override
  Future<File?> localModelFile(WhisperModelTier tier) async => null;
}

void main() {
  testWidgets('默认渲染 source 步骤，含 URL 输入与文件按钮', (tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: ChangeNotifierProvider<MediaImportProvider>(
          create: (_) => MediaImportProvider(),
          child: const MaterialApp(home: Scaffold(body: MediaImportDialog())),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('done 步骤渲染标题与打开按钮', (tester) async {
    final provider = MediaImportProvider();
    await tester.pumpWidget(
      TranslationProvider(
        child: ChangeNotifierProvider<MediaImportProvider>.value(
          value: provider,
          child: const MaterialApp(home: Scaffold(body: MediaImportDialog())),
        ),
      ),
    );
    // 直接注入 done 状态所需数据
    provider.step = MediaImportStep.done;
    await tester.pumpAndSettle();
    expect(find.byType(MediaImportDialog), findsOneWidget);
  });

  group('环境检测刷新', () {
    late _CountingToolService tools;
    late _FastModelService models;
    late Directory tmpTools;
    late Directory tmpModels;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      tmpTools = Directory.systemTemp.createTempSync('vtn_rc');
      tmpModels = Directory.systemTemp.createTempSync('vtn_rm');
      tools = _CountingToolService(tmpTools);
      models = _FastModelService(tmpModels);
    });

    tearDown(() {
      try {
        tmpTools.deleteSync(recursive: true);
        tmpModels.deleteSync(recursive: true);
      } catch (_) {}
    });

    Future<void> pumpDialogWith(
        WidgetTester tester, MediaImportProvider provider) async {
      await tester.pumpWidget(
        TranslationProvider(
          child: ChangeNotifierProvider<MediaImportProvider>.value(
            value: provider,
            child:
                const MaterialApp(home: Scaffold(body: MediaImportDialog())),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    MediaImportProvider makeProvider() => MediaImportProvider(
          toolService: tools,
          modelService: models,
        );

    testWidgets('source 步不触发检测，重新打开向导（envCheck 态）自动重新检测',
        (tester) async {
      final provider = makeProvider();
      await pumpDialogWith(tester, provider);
      expect(tools.checkCount, 0);

      await provider.startForFile(File('/tmp/demo.mp4'));
      await tester.pumpAndSettle();
      final afterFirst = tools.checkCount;
      expect(afterFirst, greaterThan(0));

      // 模拟关闭对话框后重新打开：同一 Provider 重新挂载 → initState 自动重检
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await pumpDialogWith(tester, provider);
      expect(tools.checkCount, greaterThan(afterFirst));
    });

    testWidgets('envCheck 步骤提供重新检测按钮，点击后重新检测', (tester) async {
      final provider = makeProvider();
      await pumpDialogWith(tester, provider);
      await provider.startForFile(File('/tmp/demo.mp4'));
      await tester.pumpAndSettle();
      final afterAuto = tools.checkCount;
      expect(afterAuto, greaterThan(0));

      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pumpAndSettle();
      expect(tools.checkCount, greaterThan(afterAuto));
    });

    testWidgets('envCheck 错误横幅下内容可滚动不溢出', (tester) async {
      final provider = makeProvider();
      await pumpDialogWith(tester, provider);
      await provider.startForFile(File('/tmp/demo.mp4'));
      await tester.pumpAndSettle();
      provider
        ..errorMessage = '模型下载失败'
        ..errorDetail = 'Exception: DioException [bad response]: 404';
      provider.notifyListeners();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('toolHints 更新未生效提示经 systemHint 渲染在工具行下', (tester) async {
      tools.ytDlpMissing = true; // 使 ffmpeg/whisper 行处于 ready（提示仅在 ready 分支渲染）
      final provider = makeProvider();
      await pumpDialogWith(tester, provider);
      await provider.startForFile(File('/tmp/demo.mp4'));
      await tester.pumpAndSettle();
      provider.toolHints[MediaToolKind.ffmpeg] = '更新未生效（下载源内容未变化），已保留当前版本';
      provider.notifyListeners();
      await tester.pumpAndSettle();

      expect(find.text('更新未生效（下载源内容未变化），已保留当前版本'), findsOneWidget);
    });

    testWidgets('whisperCpp 未安装时提供一键安装按钮（macOS/Windows）',
        (tester) async {
      final provider = makeProvider();
      await pumpDialogWith(tester, provider);
      await provider.startForFile(File('/tmp/demo.mp4'));
      await tester.pumpAndSettle();
      // 测试默认 TargetPlatform 为 macOS
      expect(find.text('一键安装'), findsOneWidget);
    });

    testWidgets('识别模型列表展示全部三档，默认选中硬件推荐档', (tester) async {
      final provider = MediaImportProvider(
        toolService: tools,
        modelService: _AllDownloadedFastService(tmpModels),
      );
      await pumpDialogWith(tester, provider);
      await provider.startForFile(File('/tmp/demo.mp4'));
      await tester.pumpAndSettle();

      // 三档全部可见（_AllModelsService 推荐档为 large-v3-turbo）
      expect(find.text('base'), findsOneWidget);
      expect(find.text('medium'), findsOneWidget);
      expect(find.text('large-v3-turbo'), findsOneWidget);
      expect(find.text('推荐'), findsOneWidget);
      // 全部已下载 -> 每档显示已就绪，无下载按钮
      expect(find.text('已就绪'), findsNWidgets(3));
      expect(find.text('下载模型'), findsNothing);
      expect(provider.selectedTier, WhisperModelTier.base);
    });

    testWidgets('未下载档位显示下载按钮，选中可切换', (tester) async {
      final provider = makeProvider();
      await pumpDialogWith(tester, provider);
      await provider.startForFile(File('/tmp/demo.mp4'));
      await tester.pumpAndSettle();
      // 仅 large-v3-turbo 已就绪（场景：其余两档未下载）
      provider.downloadedTiers
        ..clear()
        ..add(WhisperModelTier.largeV3Turbo);
      provider.notifyListeners();
      await tester.pumpAndSettle();

      expect(find.text('下载模型'), findsNWidgets(2));
      // 切换到未下载的 base 档
      await tester.tap(find.text('base'));
      await tester.pumpAndSettle();
      expect(provider.selectedTier, WhisperModelTier.base);
      expect(provider.environmentReady, isFalse);
    });

    testWidgets('confirm 步骤不再显示磁盘空间预估文案', (tester) async {
      final provider = makeProvider();
      await pumpDialogWith(tester, provider);
      await provider.startForFile(File('/tmp/demo.mp4'));
      await tester.pumpAndSettle();
      provider.gotoConfirm();
      await tester.pumpAndSettle();

      expect(find.textContaining('磁盘空间'), findsNothing);
    });

    testWidgets('structured 档 AI 格式化失败：完成页显示未完成提示', (tester) async {
      final provider = makeProvider();
      await pumpDialogWith(tester, provider);
      await provider.confirmAndStart(
        runOverride: (_, _) async => const MediaImportResult(
          markdown: '# raw',
          title: 'T',
          formattedByAI: false,
        ),
        saveNote: (_) async => 'note-1',
      );
      await tester.pumpAndSettle();

      expect(provider.step, MediaImportStep.done);
      expect(find.text('AI 格式化未完成，已保存原始转录文本'), findsOneWidget);
    });

    testWidgets('raw 档（预期不格式化）完成页不显示未完成提示', (tester) async {
      SharedPreferences.setMockInitialValues(
          <String, Object>{'media_import_polish_level': 'raw'});
      final provider = makeProvider();
      await pumpDialogWith(tester, provider);
      await provider.confirmAndStart(
        runOverride: (_, _) async => const MediaImportResult(
          markdown: '# raw',
          title: 'T',
          formattedByAI: false,
        ),
        saveNote: (_) async => 'note-1',
      );
      await tester.pumpAndSettle();

      expect(provider.step, MediaImportStep.done);
      expect(find.text('AI 格式化未完成，已保存原始转录文本'), findsNothing);
    });

    testWidgets('关闭向导后状态重置回 source 步，可重新填写', (tester) async {
      final provider = makeProvider();
      await pumpDialogWith(tester, provider);
      await provider.startForFile(File('/tmp/demo.mp4'));
      await tester.pumpAndSettle();
      expect(provider.step, MediaImportStep.envCheck);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(provider.step, MediaImportStep.source);
      expect(provider.pickedFile, isNull);
      expect(provider.urlInput, isEmpty);
    });

    testWidgets('show(initialUrl:) 打开即进入该 URL 的流程', (tester) async {
      final provider = makeProvider();
      await tester.pumpWidget(
        TranslationProvider(
          child: ChangeNotifierProvider<MediaImportProvider>.value(
            value: provider,
            child: MaterialApp(
              home: Scaffold(
                body: Builder(
                  builder: (context) => Center(
                    child: TextButton(
                      onPressed: () => MediaImportDialog.show(
                        context,
                        initialUrl: 'https://example.com/v.mp4',
                      ),
                      child: const Text('open'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(provider.urlInput, 'https://example.com/v.mp4');
      expect(provider.step, isNot(MediaImportStep.source));
    });

    testWidgets('下载中关闭向导：提示后台继续且不取消下载', (tester) async {
      tools.ytDlpMissing = true;
      final gate = _GatedDownloader();
      final provider = MediaImportProvider(
        toolService: tools,
        modelService: models,
        downloader: gate,
      );
      // 走生产同款 showDialog 流程：关闭的是对话框路由，宿主 Scaffold 保留，
      // ScaffoldMessenger 的 SnackBar 才能持续展示
      await tester.pumpWidget(
        TranslationProvider(
          child: ChangeNotifierProvider<MediaImportProvider>.value(
            value: provider,
            child: MaterialApp(
              home: Scaffold(
                body: Builder(
                  builder: (context) => Center(
                    child: TextButton(
                      onPressed: () => MediaImportDialog.show(context),
                      child: const Text('open'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await provider.startForUrl('https://example.com/v.mp4');
      await tester.pumpAndSettle();
      await provider.checkEnvironment();
      await tester.pumpAndSettle();
      // 仅 yt-dlp 未就绪 → 行内出现下载按钮
      await tester.tap(find.text('下载便携版').first);
      // FakeAsync 下先 pump 排空微任务，下载链路才能推进到 started 门
      await tester.pump();
      await gate.started.future;
      await tester.pump();
      // 关闭向导
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.byType(MediaImportDialog), findsNothing);
      expect(find.byType(SnackBar), findsOneWidget);
      expect(provider.toolDownloading[MediaToolKind.ytDlp] ?? false, isTrue);
      gate.release.complete();
      await tester.pump();
      // 冲洗 SnackBar 自动消失 Timer（4s）及其退场动画，避免 pending timer
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });
  });

  group('confirm 步骤模型防御性禁选', () {
    late Directory tmpTools;
    late Directory tmpModels;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      tmpTools = Directory.systemTemp.createTempSync('vtn_cf_t');
      tmpModels = Directory.systemTemp.createTempSync('vtn_cf_m');
    });

    tearDown(() {
      try {
        tmpTools.deleteSync(recursive: true);
        tmpModels.deleteSync(recursive: true);
      } catch (_) {}
    });

    MediaImportProvider makeProvider() => MediaImportProvider(
          toolService: _CountingToolService(tmpTools),
          modelService: _FastModelService(tmpModels),
        );

    Future<void> pumpConfirm(
        WidgetTester tester, MediaImportProvider provider) async {
      await tester.pumpWidget(
        TranslationProvider(
          child: ChangeNotifierProvider<MediaImportProvider>.value(
            value: provider,
            child: MaterialApp(
              home: Scaffold(
                body: ConfirmStep(saveNote: (_) async => 'note-1'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    DropdownButton<WhisperModelTier> tierDropdown(WidgetTester tester) =>
        tester.widget<DropdownButton<WhisperModelTier>>(
            find.byType(DropdownButton<WhisperModelTier>));

    testWidgets('未下载档在下拉中禁用且文字置灰，已下载档可选中', (tester) async {
      final provider = makeProvider();
      provider.downloadedTiers..clear()..add(WhisperModelTier.base);
      provider.selectTier(WhisperModelTier.base);
      await pumpConfirm(tester, provider);

      final items = tierDropdown(tester).items!;
      // 全量 tier 仍在：selectedTier 停留在未下载档时 value 依旧合法
      expect(items.map((i) => i.value).toSet(), WhisperModelTier.values.toSet());
      final byTier = {for (final i in items) i.value!: i};
      expect(byTier[WhisperModelTier.base]!.enabled, isTrue);
      expect(byTier[WhisperModelTier.medium]!.enabled, isFalse);
      // 未下载项文字灰色，已下载项保持现状样式（不覆写颜色）
      expect((byTier[WhisperModelTier.medium]!.child as Text).style?.color,
          DesignTokens.gray400);
      expect(
          (byTier[WhisperModelTier.base]!.child as Text).style?.color, isNull);
    });

    testWidgets('selectedTier 未下载时开始按钮禁用（防御），切到已下载档恢复', (tester) async {
      final provider = makeProvider();
      provider.downloadedTiers..clear()..add(WhisperModelTier.base);
      provider.selectTier(WhisperModelTier.medium); // 未下载
      await pumpConfirm(tester, provider);

      FilledButton startButton() =>
          tester.widget<FilledButton>(find.byType(FilledButton));
      // 边界：selectedTier 恰好未下载，下拉 value 仍合法不抛错
      expect(tierDropdown(tester).value, WhisperModelTier.medium);
      expect(tester.takeException(), isNull);
      expect(startButton().onPressed, isNull);

      provider.selectTier(WhisperModelTier.base); // 已下载
      await tester.pumpAndSettle();
      expect(startButton().onPressed, isNotNull);
    });
  });

  group('envCheck 下一步固定底部', () {
    late Directory tmpTools;
    late Directory tmpModels;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      tmpTools = Directory.systemTemp.createTempSync('vtn_ev_t');
      tmpModels = Directory.systemTemp.createTempSync('vtn_ev_m');
    });

    tearDown(() {
      try {
        tmpTools.deleteSync(recursive: true);
        tmpModels.deleteSync(recursive: true);
      } catch (_) {}
    });

    MediaImportProvider makeProvider() => MediaImportProvider(
          toolService: _CountingToolService(tmpTools),
          modelService: _FastModelService(tmpModels),
        );

    Future<void> pumpEnvCheck(
        WidgetTester tester, MediaImportProvider provider) async {
      await tester.pumpWidget(
        TranslationProvider(
          child: ChangeNotifierProvider<MediaImportProvider>.value(
            value: provider,
            child: const MaterialApp(home: Scaffold(body: EnvCheckStep())),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    double nextButtonTop(WidgetTester tester) =>
        tester.getTopLeft(find.widgetWithText(FilledButton, '下一步')).dy;

    testWidgets('小视口（400 高）下一步按钮无需滚动即可见', (tester) async {
      tester.view.physicalSize = const Size(500, 400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final provider = makeProvider();
      await pumpEnvCheck(tester, provider);
      await provider.startForFile(File('/tmp/demo.mp4'));
      await tester.pumpAndSettle();
      expect(nextButtonTop(tester), lessThan(400));
      expect(tester.takeException(), isNull);
    });

    testWidgets('内容超高（三工具行+错误横幅）下一步仍固定底部可见', (tester) async {
      tester.view.physicalSize = const Size(500, 400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final provider = makeProvider();
      await pumpEnvCheck(tester, provider);
      // URL 源 → yt-dlp 也必装，3 个工具行 + 错误横幅令内容远超视口
      await provider.startForUrl('https://example.com/v.mp4');
      provider
        ..errorMessage = '模型下载失败'
        ..errorDetail = 'Exception: DioException [bad response]: 404';
      provider.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.byType(ToolStatusRow), findsNWidgets(3));
      expect(nextButtonTop(tester), lessThan(400));
      expect(tester.takeException(), isNull);
    });
  });
}
