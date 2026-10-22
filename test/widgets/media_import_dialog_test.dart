// test/widgets/media_import_dialog_test.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_note/l10n/strings.g.dart';
import 'package:open_note/providers/media_import_provider.dart';
import 'package:open_note/services/media/media_tool_service.dart';
import 'package:open_note/services/media/whisper_model_service.dart';
import 'package:open_note/widgets/media_import/media_import_dialog.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _CountingToolService extends MediaToolService {
  int checkCount = 0;

  _CountingToolService(Directory dir)
      : super(resolveBaseDir: () async => dir.path);

  @override
  Future<MediaToolStatus> check(MediaToolKind kind) async {
    checkCount++;
    return MediaToolStatus.missing(kind);
  }
}

class _AllDownloadedFastService extends _FastModelService {
  _AllDownloadedFastService(super.dir);

  @override
  Future<File?> localModelFile(WhisperModelTier tier) async => File('m.bin');
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
  });
}
