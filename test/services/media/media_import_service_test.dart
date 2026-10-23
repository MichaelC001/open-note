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
  }) async =>
      const Transcript(segments: [
        TranscriptSegment(startMs: 0, endMs: 1000, text: '你好'),
        TranscriptSegment(startMs: 1000, endMs: 2000, text: '世界'),
      ]);
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

  test('deriveTitleFromMedia 去扩展名', () {
    expect(MediaImportService.deriveTitleFromMedia('/x/我的视频 [abc].mp4'),
        '我的视频 [abc]');
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
            MediaImportRequest(localFile: src, tier: WhisperModelTier.base)),
        throwsA(isA<MediaImportException>()));
  });
}
