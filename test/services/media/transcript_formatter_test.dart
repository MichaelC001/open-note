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

  test('buildSegmentPrompt organized 含时间戳与标题指令', () {
    final f = TranscriptFormatter((p) async => '');
    final p = f.buildSegmentPrompt(
        [const TranscriptSegment(startMs: 5000, endMs: 6000, text: 'hi')],
        withTitle: true,
        includeTimestamps: true,
        level: ContentPolishLevel.organized);
    expect(p.contains('[00:00:05]'), isTrue);
    expect(p.contains('## '), isTrue);
    expect(p.contains('总标题'), isTrue);
  });

  test('fallbackMarkdown includeTimestamps=true 带时间戳', () {
    final f = TranscriptFormatter((p) async => '');
    final md = f.fallbackMarkdown(makeTranscript(2), includeTimestamps: true);
    expect(md.contains('# 转录笔记'), isTrue);
    expect(md.contains('[00:00:01]'), isTrue);
  });

  test('fallbackMarkdown includeTimestamps=false 无时间戳前缀', () {
    final f = TranscriptFormatter((p) async => '');
    final md = f.fallbackMarkdown(makeTranscript(2), includeTimestamps: false);
    expect(md.contains('[00:0'), isFalse);
    expect(md.contains('s0s0'), isTrue);
  });

  group('format 三档强度', () {
    test('raw：不调 callAI 且输出含原文', () async {
      var calls = 0;
      final f = TranscriptFormatter((p) async {
        calls++;
        return 'X';
      });
      final md = await f.format(makeTranscript(2),
          includeTimestamps: true, level: ContentPolishLevel.raw);
      expect(calls, 0);
      expect(md.contains('s0s0'), isTrue);
      expect(md.contains('s1s1'), isTrue);
    });

    test('structured：prompt 含禁改写与不划分章节', () async {
      final prompts = <String>[];
      final f = TranscriptFormatter((p) async {
        prompts.add(p);
        return 'ok';
      });
      await f.format(makeTranscript(2),
          includeTimestamps: true, level: ContentPolishLevel.structured);
      expect(prompts.single.contains('严禁改写'), isTrue);
      expect(prompts.single.contains('不要划分章节'), isTrue);
      expect(prompts.single.contains('要点符号（-）'), isTrue);
      expect(prompts.single.contains('不得添加标题'), isTrue);
      expect(prompts.single.contains('## '), isFalse);
    });

    test('structured：includeTimestamps=false prompt 含删除时间戳指令', () async {
      final prompts = <String>[];
      final f = TranscriptFormatter((p) async {
        prompts.add(p);
        return 'ok';
      });
      await f.format(makeTranscript(2),
          includeTimestamps: false, level: ContentPolishLevel.structured);
      expect(prompts.single.contains('删除每行开头的时间戳'), isTrue);
    });

    test('structured：includeTimestamps=true prompt 含保留时间戳指令与总标题', () async {
      final prompts = <String>[];
      final f = TranscriptFormatter((p) async {
        prompts.add(p);
        return 'ok';
      });
      await f.format(makeTranscript(2),
          includeTimestamps: true, level: ContentPolishLevel.structured);
      expect(prompts.single.contains('保留每行开头的时间戳标记'), isTrue);
      expect(prompts.single.contains('总标题'), isTrue);
    });

    test('organized：prompt 含高保真约束', () async {
      final prompts = <String>[];
      final f = TranscriptFormatter((p) async {
        prompts.add(p);
        return 'ok';
      });
      await f.format(makeTranscript(2),
          includeTimestamps: true, level: ContentPolishLevel.organized);
      expect(prompts.single.contains('高保真'), isTrue);
    });

    test('organized：includeTimestamps=false prompt 含禁输出时间戳', () async {
      final prompts = <String>[];
      final f = TranscriptFormatter((p) async {
        prompts.add(p);
        return 'ok';
      });
      await f.format(makeTranscript(2),
          includeTimestamps: false, level: ContentPolishLevel.organized);
      expect(prompts.single.contains('不要在输出中出现任何'), isTrue);
      expect(prompts.single.contains('"## 章节标题"'), isTrue);
    });
  });

  group('format 输出清洗', () {
    test('剥代码围栏', () async {
      final f = TranscriptFormatter(
          (p) async => '```\n# 标题\n\n## 00:00:00 章节\n- 要点\n```');
      final md = await f.format(makeTranscript(2),
          includeTimestamps: true, level: ContentPolishLevel.organized);
      expect(md.startsWith('# 标题'), isTrue);
      expect(md.contains('```'), isFalse);
    });
    test('includeTimestamps=false 剥章节与行内时间戳', () async {
      final f = TranscriptFormatter(
          (p) async => '## 00:01:00 章节\n内容\n[00:00:01] 文本');
      final md = await f.format(makeTranscript(2),
          includeTimestamps: false, level: ContentPolishLevel.organized);
      expect(md.contains('00:01:00'), isFalse);
      expect(md.contains('[00:00:01]'), isFalse);
      expect(md.contains('## 章节'), isTrue);
      expect(md.contains('内容'), isTrue);
    });
    test('includeTimestamps=true 保留时间戳', () async {
      final f = TranscriptFormatter((p) async => '## 00:01:00 章节\n内容');
      final md = await f.format(makeTranscript(2),
          includeTimestamps: true, level: ContentPolishLevel.organized);
      expect(md.contains('00:01:00'), isTrue);
    });
    test('多块拼接', () async {
      var call = 0;
      final f = TranscriptFormatter((p) async => 'part${call++}');
      final md = await f.format(makeTranscript(100, charsPerSeg: 50),
          includeTimestamps: true, level: ContentPolishLevel.organized);
      expect(md.contains('part0'), isTrue);
      expect(md.contains('part1'), isTrue);
    });
    test('callAI 抛错则 format 抛出', () async {
      final f = TranscriptFormatter((p) async => throw Exception('x'));
      await expectLater(
          f.format(makeTranscript(2),
              includeTimestamps: true, level: ContentPolishLevel.organized),
          throwsException);
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
