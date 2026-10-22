// test/services/media/transcript_formatter_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:open_note/services/media/transcript_formatter.dart';
import 'package:open_note/services/media/transcript_parser.dart';

Transcript makeTranscript(int n, {int charsPerSeg = 10}) => Transcript(
      segments: List.generate(
          n,
          (i) => TranscriptSegment(
              startMs: i * 1000,
              endMs: i * 1000 + 900,
              text: 's$i' * charsPerSeg)),
    );

void main() {
  group('splitSegments', () {
    test('超过上限切分且不丢段', () {
      final chunks =
          TranscriptFormatter.splitSegments(makeTranscript(10), maxChars: 25);
      expect(chunks.expand((c) => c).length, 10);
      expect(chunks.length, greaterThan(1));
    });
    test('单段超限也完整保留', () {
      final chunks = TranscriptFormatter.splitSegments(
          makeTranscript(1, charsPerSeg: 100),
          maxChars: 25);
      expect(chunks.single.single.text.length, 200);
    });
    test('空转录返回空', () {
      expect(
          TranscriptFormatter.splitSegments(const Transcript(segments: [])),
          isEmpty);
    });
  });

  test('buildSegmentPrompt 含时间戳与标题指令', () {
    final f = TranscriptFormatter((p) async => '');
    final p = f.buildSegmentPrompt(
        [const TranscriptSegment(startMs: 5000, endMs: 6000, text: 'hi')],
        withTitle: true);
    expect(p.contains('[00:00:05]'), isTrue);
    expect(p.contains('## '), isTrue);
    expect(p.contains('总标题'), isTrue);
  });

  test('fallbackMarkdown 带时间戳', () {
    final f = TranscriptFormatter((p) async => '');
    final md = f.fallbackMarkdown(makeTranscript(2));
    expect(md.contains('# 转录笔记'), isTrue);
    expect(md.contains('[00:00:01]'), isTrue);
  });

  group('format', () {
    test('剥代码围栏', () async {
      final f = TranscriptFormatter(
          (p) async => '```\n# 标题\n\n## 00:00:00 章节\n- 要点\n```');
      final md = await f.format(makeTranscript(2));
      expect(md.startsWith('# 标题'), isTrue);
      expect(md.contains('```'), isFalse);
    });
    test('多块拼接', () async {
      var call = 0;
      final f = TranscriptFormatter((p) async => 'part${call++}');
      final md = await f.format(makeTranscript(100, charsPerSeg: 50));
      expect(md.contains('part0'), isTrue);
      expect(md.contains('part1'), isTrue);
    });
    test('callAI 抛错则 format 抛出', () async {
      final f = TranscriptFormatter((p) async => throw Exception('x'));
      await expectLater(f.format(makeTranscript(2)), throwsException);
    });
  });

  test('suggestTitle 失败返回 null、成功去除井号', () async {
    expect(
        await TranscriptFormatter((p) async => throw Exception('x'))
            .suggestTitle('md'),
        isNull);
    expect(
        await TranscriptFormatter((p) async => '## 我的标题').suggestTitle('md'),
        '我的标题');
  });
}
