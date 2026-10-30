// test/services/media/media_import_service_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_note/services/media/media_import_service.dart';
import 'package:open_note/services/media/media_tool_service.dart';
import 'package:open_note/services/media/transcript_formatter.dart';
import 'package:open_note/services/media/transcript_parser.dart';
import 'package:open_note/services/media/whisper_model_service.dart';
import 'package:open_note/services/media/whisper_runner.dart';

class _FakeToolService extends MediaToolService {
  _FakeToolService(Future<String> Function() base) : super(resolveBaseDir: base);
  @override
  Future<MediaToolStatus> check(MediaToolKind kind,
      {bool forceVerify = false}) async => MediaToolStatus(
      kind: kind,
      ready: true,
      path: 'fake',
      version: '1',
      source: MediaToolSource.appManaged);
}

class _FakeModelService extends WhisperModelService {
  _FakeModelService(Future<String> Function() base)
      : super(resolveBaseDir: base);
  @override
  Future<File?> localModelFile(WhisperModelTier tier) async => File('m.bin');
}

class _FakeWhisperRunner extends WhisperRunner {
  @override
  Future<Transcript> transcribe({
    required String whisperCliPath,
    required File model,
    required File wav,
    String language = 'auto',
    int? totalDurationMs,
    void Function(double progress)? onProgress,
    void Function(Process process)? onStarted,
    bool forceNoGpu = false,
    void Function()? onGpuFallback,
  }) async =>
      const Transcript(segments: [
        TranscriptSegment(startMs: 0, endMs: 1000, text: '你好'),
        TranscriptSegment(startMs: 1000, endMs: 2000, text: '世界'),
      ]);
}

/// 记录转录入参（forceNoGpu / onGpuFallback 透传验证）。
class _CapturingRunner extends WhisperRunner {
  final List<bool> forceNoGpuCalls = [];
  final List<void Function()?> fallbackCallbacks = [];
  @override
  Future<Transcript> transcribe({
    required String whisperCliPath,
    required File model,
    required File wav,
    String language = 'auto',
    int? totalDurationMs,
    void Function(double progress)? onProgress,
    void Function(Process process)? onStarted,
    bool forceNoGpu = false,
    void Function()? onGpuFallback,
  }) async {
    forceNoGpuCalls.add(forceNoGpu);
    fallbackCallbacks.add(onGpuFallback);
    return const Transcript(segments: [
      TranscriptSegment(startMs: 0, endMs: 1000, text: 'hi'),
    ]);
  }
}

class _FakeFormatter extends TranscriptFormatter {
  _FakeFormatter() : super((p) async => '# AI 标题\n\n## 00:00:00 章节');
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('vtn_pipe'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('parseFfmpegDurationSec / parseFfmpegTimeSec', () {
    expect(
        MediaImportService.parseFfmpegDurationSec(
            '  Duration: 00:01:02.50, start: 0'),
        62);
    expect(MediaImportService.parseFfmpegTimeSec('time=00:00:30.00 '), 30);
    expect(MediaImportService.parseFfmpegTimeSec('no data'), isNull);
  });

  group('ffmpegErrorDetail 剥离启动横幅', () {
    test('横幅三行被剥掉，真实错误保留', () {
      final sb = StringBuffer('''
ffmpeg version 6.1.1-essentials_build-www.gyan.dev Copyright (c) 2000-2023
  built with gcc 12.2.0 (Rev10, Built by MSYS2 project)
  configuration: --enable-gpl --enable-version3 --enable-static
C:/Users/x/a.mp4: Invalid data found when processing input''');
      final d = MediaImportService.ffmpegErrorDetail(sb);
      expect(d, isNot(contains('ffmpeg version')));
      expect(d, isNot(contains('built with')));
      expect(d, isNot(contains('configuration:')));
      expect(d, contains('Invalid data found when processing input'));
    });

    test('无横幅时原样保留内容并去掉空行', () {
      final sb = StringBuffer('a\n\n\nb\n');
      expect(MediaImportService.ffmpegErrorDetail(sb), 'a\nb');
    });

    test('超长输出截尾保留末尾', () {
      final sb = StringBuffer('x' * 3000 + '|TAIL');
      final d = MediaImportService.ffmpegErrorDetail(sb);
      expect(d.endsWith('|TAIL'), isTrue);
      expect(d.length, lessThanOrEqualTo(1200));
    });
  });

  test('deriveTitleFromMedia 去扩展名', () {
    expect(MediaImportService.deriveTitleFromMedia('/x/我的视频 [abc].mp4'),
        '我的视频 [abc]');
  });

  group('ytDlpArgs', () {
    test('不含 ffmpegPath：不追加 --ffmpeg-location，url 收尾', () {
      final args = MediaImportService.ytDlpArgs(url: 'https://youtu.be/abc');
      expect(args, [
        '--no-playlist',
        '--newline',
        '-f',
        'ba/b',
        '-o',
        '%(title).80s [%(id)s].%(ext)s',
        '--print',
        'after_move:filepath',
        'https://youtu.be/abc',
      ]);
    });

    test('含 ffmpegPath：在 url 前追加 --ffmpeg-location', () {
      final args = MediaImportService.ytDlpArgs(
          url: 'https://youtu.be/abc', ffmpegPath: '/usr/local/bin/ffmpeg');
      expect(args.last, 'https://youtu.be/abc');
      final i = args.indexOf('--ffmpeg-location');
      expect(i, greaterThanOrEqualTo(0));
      expect(args[i + 1], '/usr/local/bin/ffmpeg');
      expect(args.getRange(0, i),
          containsAllInOrder(['--print', 'after_move:filepath']));
    });
  });

  test('本地 WAV 全流程：阶段推进/AI 格式化/临时目录清理', () async {
    final src = File('${tmp.path}/src.wav');
    src.writeAsBytesSync(List<int>.filled(44 + 32000 * 2, 0));

    final svc = MediaImportService(
      resolveBaseDir: () async => tmp.path,
      toolService: _FakeToolService(() async => tmp.path),
      modelService: _FakeModelService(() async => tmp.path),
      whisperRunner: _FakeWhisperRunner(),
      formatter: _FakeFormatter(),
    );
    final phases = <MediaImportPhase>[];
    final result = await svc.run(
      MediaImportRequest(localFile: src, tier: WhisperModelTier.base),
      includeTimestamps: true,
      polishLevel: ContentPolishLevel.organized,
      onProgress: (p, v) {
        if (phases.isEmpty || phases.last != p) phases.add(p);
      },
    );
    expect(phases,
        [MediaImportPhase.acquiring, MediaImportPhase.extractingAudio,
         MediaImportPhase.transcribing, MediaImportPhase.formatting]);
    expect(result.formattedByAI, isTrue);
    expect(result.title, isNotEmpty);
    expect(result.markdown, contains('# AI 标题'));
    expect(Directory('${tmp.path}/media_import_tmp').listSync(), isEmpty);
  });

  test('raw 档全链路不调用 AI（含标题生成），formattedByAI=false，标题来自文件名', () async {
    final src = File('${tmp.path}/rawsrc.wav');
    src.writeAsBytesSync(List<int>.filled(44 + 32000, 0));

    var aiCalls = 0;
    final svc = MediaImportService(
      resolveBaseDir: () async => tmp.path,
      toolService: _FakeToolService(() async => tmp.path),
      modelService: _FakeModelService(() async => tmp.path),
      whisperRunner: _FakeWhisperRunner(),
      formatter: TranscriptFormatter((prompt) async {
        aiCalls++;
        return '# AI 标题\n\n## 00:00:00 章节';
      }),
    );
    final result = await svc.run(
      MediaImportRequest(localFile: src, tier: WhisperModelTier.base),
      includeTimestamps: true,
      polishLevel: ContentPolishLevel.raw,
    );
    expect(aiCalls, 0);
    expect(result.formattedByAI, isFalse);
    expect(result.title, 'rawsrc');
    expect(result.markdown, contains('# 转录笔记'));
    expect(result.markdown, isNot(contains('AI 标题')));
  });

  test('organized 档 AI 调用失败降级：formattedByAI=false 且标题来自文件名', () async {
    final src = File('${tmp.path}/failing.wav');
    src.writeAsBytesSync(List<int>.filled(44 + 32000, 0));
    final svc = MediaImportService(
      resolveBaseDir: () async => tmp.path,
      toolService: _FakeToolService(() async => tmp.path),
      modelService: _FakeModelService(() async => tmp.path),
      whisperRunner: _FakeWhisperRunner(),
      formatter: TranscriptFormatter((prompt) async => throw StateError('AI 挂了')),
    );
    final result = await svc.run(
      MediaImportRequest(localFile: src, tier: WhisperModelTier.base),
      includeTimestamps: true,
      polishLevel: ContentPolishLevel.organized,
    );
    expect(result.formattedByAI, isFalse);
    expect(result.title, 'failing');
    expect(result.markdown, contains('# 转录笔记'));
  });

  test('formatter 为 null 时降级 fallbackMarkdown', () async {
    final src = File('${tmp.path}/src2.wav');
    src.writeAsBytesSync(List<int>.filled(44 + 32000, 0));
    final svc = MediaImportService(
      resolveBaseDir: () async => tmp.path,
      toolService: _FakeToolService(() async => tmp.path),
      modelService: _FakeModelService(() async => tmp.path),
      whisperRunner: _FakeWhisperRunner(),
    );
    final result = await svc.run(
      MediaImportRequest(localFile: src, tier: WhisperModelTier.base),
      includeTimestamps: true,
      polishLevel: ContentPolishLevel.organized,
    );
    expect(result.formattedByAI, isFalse);
    expect(result.markdown, contains('# 转录笔记'));
    expect(result.title, 'src2');
  });

  test('cancel 后 run 抛出 已取消', () async {
    final src = File('${tmp.path}/src3.wav');
    src.writeAsBytesSync(List<int>.filled(44 + 32000, 0));
    final svc = MediaImportService(
      resolveBaseDir: () async => tmp.path,
      toolService: _FakeToolService(() async => tmp.path),
      modelService: _FakeModelService(() async => tmp.path),
      whisperRunner: _FakeWhisperRunner(),
    );
    svc.cancel();
    await expectLater(
        svc.run(
            MediaImportRequest(localFile: src, tier: WhisperModelTier.base),
            includeTimestamps: true,
            polishLevel: ContentPolishLevel.organized),
        throwsA(isA<MediaImportException>()));
  });

  group('运行层 GPU 决策注入（resolveNoGpu / onGpuFallback 透传）', () {
    Future<(Directory, File)> makeWav() async {
      final src = File('${tmp.path}/gpu.wav')
        ..writeAsBytesSync(List<int>.filled(44 + 32000, 0));
      return (tmp, src);
    }

    test('resolveNoGpu true → runner forceNoGpu=true；未注入 → false', () async {
      var resolveCalls = 0;
      final runner = _CapturingRunner();
      final (_, src) = await makeWav();
      final svc = MediaImportService(
        resolveBaseDir: () async => tmp.path,
        toolService: _FakeToolService(() async => tmp.path),
        modelService: _FakeModelService(() async => tmp.path),
        whisperRunner: runner,
        resolveNoGpu: () async {
          resolveCalls++;
          return true;
        },
      );
      await svc.run(
        MediaImportRequest(localFile: src, tier: WhisperModelTier.base),
        includeTimestamps: false,
        polishLevel: ContentPolishLevel.raw,
      );
      expect(resolveCalls, 1, reason: '转录入口恰调用一次决策');
      expect(runner.forceNoGpuCalls, [true]);

      final runner2 = _CapturingRunner();
      final svc2 = MediaImportService(
        resolveBaseDir: () async => tmp.path,
        toolService: _FakeToolService(() async => tmp.path),
        modelService: _FakeModelService(() async => tmp.path),
        whisperRunner: runner2,
      );
      await svc2.run(
        MediaImportRequest(localFile: src, tier: WhisperModelTier.base),
        includeTimestamps: false,
        polishLevel: ContentPolishLevel.raw,
      );
      expect(runner2.forceNoGpuCalls, [false]);
    });

    test('onGpuFallback 原样透传给 runner', () async {
      final runner = _CapturingRunner();
      void cb() {}
      final (_, src) = await makeWav();
      final svc = MediaImportService(
        resolveBaseDir: () async => tmp.path,
        toolService: _FakeToolService(() async => tmp.path),
        modelService: _FakeModelService(() async => tmp.path),
        whisperRunner: runner,
        onGpuFallback: cb,
      );
      await svc.run(
        MediaImportRequest(localFile: src, tier: WhisperModelTier.base),
        includeTimestamps: false,
        polishLevel: ContentPolishLevel.raw,
      );
      expect(runner.fallbackCallbacks.single, same(cb));
    });
  });
}
