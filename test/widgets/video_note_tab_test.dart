// test/widgets/video_note_tab_test.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_note/l10n/strings.g.dart';
import 'package:open_note/providers/language_provider.dart';
import 'package:open_note/providers/media_import_provider.dart';
import 'package:open_note/providers/update_provider.dart';
import 'package:open_note/services/media/media_tool_service.dart';
import 'package:open_note/services/media/whisper_model_service.dart';
import 'package:open_note/utils/app_info.dart';
import 'package:open_note/widgets/settings/video_note_tab.dart';
import 'package:open_note/widgets/settings_dialog.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _CountingToolService extends MediaToolService {
  int checkCount = 0;
  final bool allReady;

  _CountingToolService(Directory dir, {this.allReady = false})
      : super(resolveBaseDir: () async => dir.path);

  @override
  Future<MediaToolStatus> check(MediaToolKind kind) async {
    checkCount++;
    if (allReady) {
      return MediaToolStatus(kind: kind, ready: true, version: '1.0');
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

class _FastModelService extends WhisperModelService {
  final Directory dir;

  _FastModelService(this.dir) : super(resolveBaseDir: () async => dir.path);

  @override
  Future<WhisperModelTier> recommendTierForDevice() async =>
      WhisperModelTier.base;

  @override
  Future<File?> localModelFile(WhisperModelTier tier) async => null;

  // 基类实现含真实文件 IO（exists/create），FakeAsync 下无法完成，改纯计算
  @override
  Future<String> modelsDir() async => '${dir.path}/whisper_models';
}

class _AllDownloadedFastService extends _FastModelService {
  _AllDownloadedFastService(super.dir);

  @override
  Future<File?> localModelFile(WhisperModelTier tier) async => File('m.bin');
}

void main() {
  late Directory tmpTools;
  late Directory tmpModels;
  late _CountingToolService toolsFake;
  late _FastModelService modelsFake;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    tmpTools = Directory.systemTemp.createTempSync('vnt_tools');
    tmpModels = Directory.systemTemp.createTempSync('vnt_models');
  });

  tearDown(() {
    try {
      tmpTools.deleteSync(recursive: true);
      tmpModels.deleteSync(recursive: true);
    } catch (_) {}
  });

  MediaImportProvider makeProvider({bool toolsReady = false}) {
    toolsFake = _CountingToolService(tmpTools, allReady: toolsReady);
    modelsFake = toolsReady
        ? _AllDownloadedFastService(tmpModels)
        : _FastModelService(tmpModels);
    return MediaImportProvider(toolService: toolsFake, modelService: modelsFake);
  }

  Future<void> pumpTab(WidgetTester tester, MediaImportProvider provider) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: ChangeNotifierProvider<MediaImportProvider>.value(
          value: provider,
          child: MaterialApp(home: Scaffold(body: VideoNoteTab(modelService: modelsFake))),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('设置页新增独立「视频转笔记」Tab 且偏好设置页不再包含该分区',
      (tester) async {
    // 应用强制最小窗口 1080×720（main.dart），默认 800×600 测试面会令
    // 设置对话框（0.65 倍宽）内工具行按钮溢出，与真实运行环境不符
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    PackageInfo.setMockInitialValues(
      appName: 'OpenNote',
      packageName: 'net.zsdn.opennote',
      version: '1.2.0',
      buildNumber: '1',
      buildSignature: 'test',
    );
    await AppInfo.init();
    await tester.pumpWidget(
      TranslationProvider(
        child: MultiProvider(
          providers: [
            ChangeNotifierProvider<MediaImportProvider>.value(
              value: makeProvider(),
            ),
            ChangeNotifierProvider(create: (_) => UpdateProvider()),
            ChangeNotifierProvider(create: (_) => LanguageProvider()),
          ],
          child: const MaterialApp(home: Scaffold(body: SettingsDialog())),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('视频转笔记'), findsOneWidget);
    expect(find.text('下载源'), findsNothing);

    await tester.tap(find.text('视频转笔记'));
    await tester.pumpAndSettle();

    expect(find.text('下载源'), findsOneWidget);
    expect(find.text('默认识别模型'), findsOneWidget);
    expect(find.text('完成后删除下载的源媒体'), findsOneWidget);

    // 回到首选项，确认分区已移出
    await tester.tap(find.text('首选项'));
    await tester.pumpAndSettle();
    expect(find.text('下载源'), findsNothing);
  });

  testWidgets('工具与模型区：就绪工具显示版本，模型三行全显', (tester) async {
    // provider: 工具全就绪(appManaged)、模型全下载
    final provider = makeProvider(toolsReady: true);
    await pumpTab(tester, provider);
    await provider.checkEnvironment();
    await tester.pumpAndSettle();
    expect(find.text('ffmpeg'), findsOneWidget);
    expect(find.text('yt-dlp'), findsOneWidget);
    expect(find.text('whisper.cpp'), findsOneWidget);
    expect(find.text('base'), findsOneWidget);
    expect(find.text('large-v3-turbo'), findsOneWidget);
    expect(find.textContaining('v1'), findsWidgets); // 就绪版本号
  });

  testWidgets('显示模型下载目录并可复制', (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform, (call) async => null);
    final provider = makeProvider(toolsReady: true);
    await pumpTab(tester, provider);
    await provider.checkEnvironment();
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.folder_open), findsOneWidget);
    expect(find.textContaining('whisper_models'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.copy));
    await tester.pump();
    expect(find.byType(SnackBar), findsOneWidget);
    // 冲洗 SnackBar 自动消失 Timer（4s）及其退场动画，避免 pending timer
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('点击重新检测触发 checkEnvironment', (tester) async {
    final provider = makeProvider();
    await pumpTab(tester, provider);
    await tester.pumpAndSettle();
    final before = toolsFake.checkCount;
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();
    expect(toolsFake.checkCount, greaterThan(before));
  });
}
