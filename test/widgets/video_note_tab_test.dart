// test/widgets/video_note_tab_test.dart
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_note/l10n/strings.g.dart';
import 'package:open_note/providers/language_provider.dart';
import 'package:open_note/providers/media_import_provider.dart';
import 'package:open_note/providers/update_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:open_note/services/media/gpu_capability.dart';
import 'package:open_note/services/media/media_downloader.dart';
import 'package:open_note/services/media/media_import_settings.dart';
import 'package:open_note/services/media/media_tool_service.dart';
import 'package:open_note/services/media/process_runner.dart';
import 'package:open_note/services/media/transcript_formatter.dart';
import 'package:open_note/services/media/tool_update_service.dart';
import 'package:open_note/services/media/whisper_model_service.dart';
import 'package:open_note/theme/design_tokens.dart';
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
  Future<MediaToolStatus> check(MediaToolKind kind,
      {bool forceVerify = false}) async {
    checkCount++;
    if (allReady) {
      return MediaToolStatus(
        kind: kind,
        ready: true,
        version: '1.0',
        source: MediaToolSource.appManaged,
      );
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

class _StubFetcher {
  final String tag;
  _StubFetcher(this.tag);
  Future<Response<dynamic>> call(String url, Options options) async =>
      Response<dynamic>(
        data: {'tag_name': tag},
        requestOptions: RequestOptions(path: url),
      );
}

class _CapturingDownloader extends MediaDownloader {
  String? lastUrl;

  // 基类实现走真实 df 子进程，FakeAsync（widget 测试）下无法完成
  @override
  Future<int?> freeDiskBytes(String path) async => null;

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

/// 固定能力结论的假探测器：UI 测试与宿主机真探测解耦。
class _FakeGpuDetector extends GpuCapabilityDetector {
  final GpuCapability cap;

  _FakeGpuDetector(this.cap)
      : super(
          readCache: () async => null,
          writeCache: (_) async {},
          runProbe: (_, _) async => ProcessRunResult(1, '', ''),
        );

  @override
  Future<GpuCapability> detect({bool force = false}) async => cap;
}

/// 记录 setWhisperGpuEnabled 调用的 spy provider（不触发真实重装联动）。
class _SpyGpuProvider extends MediaImportProvider {
  int gpuToggleCalls = 0;
  bool? lastGpuToggleValue;
  int probeCalls = 0;

  _SpyGpuProvider({
    required super.toolService,
    required super.modelService,
    super.gpuDetector,
  });

  @override
  Future<void> setWhisperGpuEnabled(bool v) async {
    gpuToggleCalls++;
    lastGpuToggleValue = v;
    await settings.setWhisperGpu(v);
  }

  @override
  Future<void> ensureWhisperMetalProbe() async {
    probeCalls++;
    return super.ensureWhisperMetalProbe();
  }

  // checkEnvironment 完成后的真实重算（refreshWhisperMetalState）会按
  // 设置表清空手工置入的黑名单缓存，故在 pump 稳定后经此注入命中值，
  // 等价真实「命中→notify」链路
  void setMetalUnavailableVersionForTest(String version) {
    whisperMetalUnavailableVersion = version;
    notifyListeners();
  }
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

  MediaImportProvider makeProvider({
    bool toolsReady = false,
    ToolUpdateService? updateService,
    MediaDownloader? downloader,
    GpuCapabilityDetector? gpuDetector,
  }) {
    toolsFake = _CountingToolService(tmpTools, allReady: toolsReady);
    modelsFake = toolsReady
        ? _AllDownloadedFastService(tmpModels)
        : _FastModelService(tmpModels);
    return MediaImportProvider(
      toolService: toolsFake,
      modelService: modelsFake,
      updateService: updateService,
      downloader: downloader,
      gpuDetector: gpuDetector,
    );
  }

  _SpyGpuProvider makeSpyProvider({GpuCapabilityDetector? gpuDetector}) {
    toolsFake = _CountingToolService(tmpTools, allReady: true);
    modelsFake = _AllDownloadedFastService(tmpModels);
    return _SpyGpuProvider(
      toolService: toolsFake,
      modelService: modelsFake,
      gpuDetector: gpuDetector,
    );
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
    expect(find.text('引擎源'), findsNothing);

    await tester.tap(find.text('视频转笔记'));
    await tester.pumpAndSettle();

    expect(find.text('引擎源'), findsOneWidget);
    expect(find.text('默认识别模型'), findsNothing);
    expect(find.text('完成后删除下载的源媒体'), findsOneWidget);

    // 侧边栏导航项 hover 高亮与激活态同为 8 圆角
    final navInk = tester.widget<InkWell>(find.ancestor(
        of: find.text('视频转笔记'), matching: find.byType(InkWell)));
    expect(navInk.borderRadius, BorderRadius.circular(8));

    // 回到首选项，确认分区已移出
    await tester.tap(find.text('首选项'));
    await tester.pumpAndSettle();
    expect(find.text('下载源'), findsNothing);
    expect(find.text('引擎源'), findsNothing);
  });

  testWidgets('工具与模型区：就绪工具显示版本，模型三行全显', (tester) async {
    // provider: 工具全就绪(appManaged)、模型全下载
    final provider = makeProvider(toolsReady: true);
    await pumpTab(tester, provider);
    await provider.checkEnvironment();
    await tester.pumpAndSettle();
    expect(find.text('媒体处理引擎（ffmpeg）'), findsOneWidget);
    expect(find.text('媒体嗅探引擎（yt-dlp）'), findsOneWidget);
    expect(find.text('语音识别引擎（whisper.cpp）'), findsOneWidget);
    expect(find.text('引擎'), findsOneWidget);
    expect(find.textContaining('约 2GB 内存'), findsOneWidget);
    expect(find.text('base'), findsOneWidget);
    expect(find.text('large-v3-turbo'), findsOneWidget);
    expect(find.textContaining('v1'), findsWidgets); // 就绪版本号
  });

  testWidgets('引擎卡片左上角显示主题 ribbon 背景图', (tester) async {
    final provider = makeProvider(toolsReady: true);
    await pumpTab(tester, provider);
    await tester.pumpAndSettle();
    expect(find.byType(SvgPicture), findsOneWidget);
    // ribbon 顶满卡片宽度（1280 视口减页边距 16×2），而非固定 180
    expect(tester.getSize(find.byType(SvgPicture)).width, greaterThan(600));
  });

  testWidgets('临时目录行位于删除源开关之后、关键时间戳之前', (tester) async {
    tester.view.physicalSize = const Size(1280, 1100);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final provider = makeProvider(toolsReady: true);
    await pumpTab(tester, provider);
    await tester.pumpAndSettle();

    expect(find.textContaining('media_import_tmp'), findsOneWidget);
    final delSourceDy =
        tester.getTopLeft(find.text('完成后删除下载的源媒体')).dy;
    final tmpDirDy =
        tester.getTopLeft(find.textContaining('media_import_tmp')).dy;
    final tsDy = tester.getTopLeft(find.text('关键时间戳')).dy;
    expect(delSourceDy, lessThan(tmpDirDy));
    expect(tmpDirDy, lessThan(tsDy));
  });

  testWidgets('显示模型下载目录并可复制', (tester) async {
    // 卡片新增引擎标题与模型描述行后变高，800x600 默认面会令目录行溢出视口
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    String? clipboardText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboardText = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    final provider = makeProvider(toolsReady: true);
    await pumpTab(tester, provider);
    await provider.checkEnvironment();
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.folder_open), findsNWidgets(2));
    expect(find.textContaining('whisper_models'), findsOneWidget);
    expect(find.textContaining('media_import_tmp'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.copy).first);
    await tester.pump();
    expect(find.byType(SnackBar), findsOneWidget);
    expect(clipboardText, '${tmpModels.path}/whisper_models');
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

  testWidgets('appManaged 就绪工具显示卸载按钮，确认后调用卸载', (tester) async {
    final provider = makeProvider(toolsReady: true);
    await pumpTab(tester, provider);
    await provider.checkEnvironment();
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pumpAndSettle();
    expect(find.text('确定卸载 ffmpeg？'), findsOneWidget);
    await tester.tap(find.text('卸载').last);
    await tester.pumpAndSettle();
    // fake 工具目录被删 → check 后 fake 恒 ready，仅验证无错误弹出
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('已就绪模型行显示删除按钮，确认后移出列表', (tester) async {
    final provider = makeProvider(toolsReady: true);
    await pumpTab(tester, provider);
    await provider.checkEnvironment();
    await tester.pumpAndSettle();
    // 模型行删除按钮（tooltip=删除）共 3 个，first 为 base 行
    await tester.tap(find.byTooltip('删除').first);
    await tester.pumpAndSettle();
    expect(find.text('确定删除模型 base？'), findsOneWidget);
    await tester.tap(find.text('删除').last);
    await tester.pumpAndSettle();
    expect(provider.downloadedTiers.contains(WhisperModelTier.base), isFalse);
  });

  testWidgets('下载源缺省镜像优先且排首位；隐藏默认模型行；引擎标题与模型硬件说明',
      (tester) async {
    final provider = makeProvider(toolsReady: true);
    await pumpTab(tester, provider);
    await tester.pumpAndSettle();

    expect(find.text('引擎'), findsOneWidget);
    expect(find.text('默认识别模型'), findsNothing);
    expect(find.text('推荐（镜像优先）'), findsOneWidget);
    expect(find.textContaining('约 2GB 内存'), findsOneWidget);
    final dd = tester.widget<DropdownButton<MediaDownloadSourceMode>>(
        find.byType(DropdownButton<MediaDownloadSourceMode>));
    expect(dd.value, MediaDownloadSourceMode.mirror);
    expect(dd.items!.map((i) => i.value).toList(), [
      MediaDownloadSourceMode.mirror,
      MediaDownloadSourceMode.auto,
      MediaDownloadSourceMode.direct,
    ]);
  });

  testWidgets('源媒体路径随删除源开关动态切换（tmp/media 目录）', (tester) async {
    tester.view.physicalSize = const Size(1280, 1100);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final provider = makeProvider(toolsReady: true);
    await pumpTab(tester, provider);
    await tester.pumpAndSettle();

    // 默认删除源=开 → 源媒体随任务删除，展示临时目录
    expect(find.textContaining('media_import_tmp'), findsOneWidget);
    expect(find.textContaining('media_import_media'), findsNothing);

    // 关 → 保留副本目录
    await tester.tap(find.text('完成后删除下载的源媒体'));
    await tester.pumpAndSettle();
    expect(find.textContaining('media_import_media'), findsOneWidget);
    expect(find.textContaining('media_import_tmp'), findsNothing);

    // 重新开 → 切回临时目录
    await tester.tap(find.text('完成后删除下载的源媒体'));
    await tester.pumpAndSettle();
    expect(find.textContaining('media_import_tmp'), findsOneWidget);
    expect(find.textContaining('media_import_media'), findsNothing);
  });

  testWidgets('源媒体路径行显示并可复制', (tester) async {
    // 卡片新增时间戳开关与优化强度滑块后变高，900 视口令路径行落出视口不可点
    tester.view.physicalSize = const Size(1280, 1100);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    String? clipboardText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboardText = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    final provider = makeProvider(toolsReady: true);
    await pumpTab(tester, provider);
    await tester.pumpAndSettle();

    expect(find.textContaining('media_import_tmp'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.copy).last);
    await tester.pump();
    expect(find.byType(SnackBar), findsOneWidget);
    expect(clipboardText, '${tmpModels.path}/media_import_tmp');
    // 冲洗 SnackBar 自动消失 Timer（4s）及其退场动画，避免 pending timer
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('关键时间戳开关与内容优化强度滑块渲染、默认值与持久化', (tester) async {
    // GPU 开关行加入引擎卡片后整体下移，1000 视口令滑块落出不可拖
    tester.view.physicalSize = const Size(1280, 1100);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final provider = makeProvider(toolsReady: true);
    await pumpTab(tester, provider);
    await tester.pumpAndSettle();

    // 两新项渲染
    expect(find.text('关键时间戳'), findsOneWidget);
    expect(find.text('内容优化强度'), findsOneWidget);

    // 开关默认关；默认档位为结构格式化
    final tsSwitch = tester.widget<SwitchListTile>(find.ancestor(
        of: find.text('关键时间戳'), matching: find.byType(SwitchListTile)));
    expect(tsSwitch.value, isFalse);
    expect(find.text('结构格式化'), findsOneWidget);
    // 默认档位描述行（structured）
    expect(find.text('仅拆分段落，不改写内容'), findsOneWidget);

    // 开关切到开 → 持久化
    await tester.tap(find.text('关键时间戳'));
    await tester.pumpAndSettle();
    expect(await MediaImportSettings().includeTimestamps(), isTrue);

    // 滑块切到最右档 organized → 持久化（重进读取验证）
    await tester.drag(find.byType(Slider), const Offset(300, 0));
    await tester.pumpAndSettle();
    expect(await MediaImportSettings().polishLevel(),
        ContentPolishLevel.organized);
    expect(find.text('内容整理'), findsOneWidget);
    expect(find.text('结构格式化'), findsNothing);
    // 描述行随档位切换
    expect(find.text('整理章节并重排，不改写原意'), findsOneWidget);
    expect(find.text('仅拆分段落，不改写内容'), findsNothing);
  });

  testWidgets('发现新版本显示可更新标记，点更新触发重新下载并清除标记',
      (tester) async {
    // 卡片含引擎/模型/路径行，默认 800x600 视口会溢出，与真实窗口不符
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fetcher = _StubFetcher('b7.0'); // 远端 b7.0，本地 fake 版本 1.0 → 有更新
    final fakeDl = _CapturingDownloader();
    final provider = makeProvider(
      toolsReady: true,
      updateService: ToolUpdateService(fetcher: fetcher.call),
      downloader: fakeDl,
    );
    await pumpTab(tester, provider);
    await provider.checkEnvironment();
    await provider.checkToolUpdates();
    await tester.pumpAndSettle();

    // appManaged ready 行尾出现橙色「可更新 v7.0」与「更新」按钮
    expect(find.text('可更新 v7.0'), findsWidgets);
    expect(find.text('更新'), findsWidgets);

    // 点第一行（ffmpeg）的「更新」→ 走 onDownload 同链路重新下载覆盖
    await tester.tap(find.text('更新').first);
    // downloadTool 后续经真实 chmod 子进程（FakeAsync 下不完成，行尾停在
    // finishing 转圈），只能用显式 pump 排空微任务，不能 pumpAndSettle
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(provider.updateAvailableVersion[MediaToolKind.ffmpeg], isNull);
    expect(fakeDl.lastUrl, contains('/ffmpeg-static/releases/'));
  });

  testWidgets('Windows 无 N 卡 → GPU 开关禁灰且副标题提示未检测到',
      (tester) async {
    // 基线不变量在 tearDown 前校验，平台覆写须在测试体内复位
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final provider = makeProvider(
        toolsReady: true,
        gpuDetector:
            _FakeGpuDetector(const GpuCapability(kind: GpuKind.none)),
      );
      await pumpTab(tester, provider);

      final tile = tester.widget<SwitchListTile>(find.ancestor(
          of: find.text('GPU 加速'), matching: find.byType(SwitchListTile)));
      expect(tile.onChanged, isNull, reason: '无 CUDA 能力应禁灰');
      expect(find.text('未检测到 NVIDIA GPU'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Windows 有 N 卡 → CUDA 副标题且开关可用', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final provider = makeProvider(
        toolsReady: true,
        gpuDetector: _FakeGpuDetector(const GpuCapability(kind: GpuKind.cuda)),
      );
      await pumpTab(tester, provider);

      final tile = tester.widget<SwitchListTile>(find.ancestor(
          of: find.text('GPU 加速'), matching: find.byType(SwitchListTile)));
      expect(tile.onChanged, isNotNull);
      expect(find.text('使用 NVIDIA CUDA 加速语音识别'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Mac：版本黑名单命中 → 开关 OFF+置灰+副标题含版本', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final provider = makeSpyProvider(
          gpuDetector:
              _FakeGpuDetector(const GpuCapability(kind: GpuKind.metal)));
      await pumpTab(tester, provider);

      provider.setMetalUnavailableVersionForTest('1.9.5');
      await tester.pump();

      final tile = tester.widget<SwitchListTile>(find.ancestor(
          of: find.text('GPU 加速'), matching: find.byType(SwitchListTile)));
      expect(tile.value, isFalse);
      expect(tile.onChanged, isNull);
      expect(find.text('当前版本（1.9.5）的 Metal 加速不可用，已自动使用 CPU'),
          findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Mac：探测进行中 → 置灰+探测文案副标题', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final provider = makeSpyProvider(
          gpuDetector:
              _FakeGpuDetector(const GpuCapability(kind: GpuKind.metal)));
      provider.metalProbeRunning = true;
      await pumpTab(tester, provider);

      final tile = tester.widget<SwitchListTile>(find.ancestor(
          of: find.text('GPU 加速'), matching: find.byType(SwitchListTile)));
      expect(tile.onChanged, isNull);
      expect(find.text('正在检测 Metal 加速可用性…'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Mac：打开 GPU 开关触发一次 Metal 探测', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final provider = makeSpyProvider(
          gpuDetector:
              _FakeGpuDetector(const GpuCapability(kind: GpuKind.metal)));
      await pumpTab(tester, provider);

      await tester.tap(find.text('GPU 加速'));
      await tester.pump();

      expect(provider.probeCalls, 1);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('支持时 toggle → provider.setWhisperGpuEnabled 联动',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final provider = makeSpyProvider(
        gpuDetector:
            _FakeGpuDetector(const GpuCapability(kind: GpuKind.metal)),
      );
      await pumpTab(tester, provider);

      expect(find.text('使用 Metal GPU 加速语音识别'), findsOneWidget);
      await tester.tap(find.text('GPU 加速'));
      await tester.pumpAndSettle();

      expect(provider.gpuToggleCalls, 1);
      expect(provider.lastGpuToggleValue, isFalse, reason: '默认开 → 点击后关');
      expect(await MediaImportSettings().whisperGpu(), isFalse);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Linux 不渲染 GPU 加速行', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      final provider = makeProvider(
        toolsReady: true,
        gpuDetector:
            _FakeGpuDetector(const GpuCapability(kind: GpuKind.none)),
      );
      await pumpTab(tester, provider);

      expect(find.text('GPU 加速'), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('暗色模式两个开关拨杆白色可见（thumbColor 生效）', (tester) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final provider = makeProvider(
      toolsReady: true,
      gpuDetector: _FakeGpuDetector(const GpuCapability(kind: GpuKind.metal)),
    );
    await tester.pumpWidget(
      TranslationProvider(
        child: ChangeNotifierProvider<MediaImportProvider>.value(
          value: provider,
          child: MaterialApp(
            theme: ThemeData(brightness: Brightness.dark),
            home: Scaffold(body: VideoNoteTab(modelService: modelsFake)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 范围为删除源/关键时间戳/GPU 加速三个开关
    final switches =
        tester.widgetList<SwitchListTile>(find.byType(SwitchListTile)).toList();
    expect(switches.length, 3);
    for (final s in switches) {
      expect(s.thumbColor?.resolve(const <WidgetState>{}), Colors.white);
      // 既有 activeThumbColor 保留
      expect(s.activeThumbColor, DesignTokens.primary500);
    }
  });
}
