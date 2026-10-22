// lib/services/media/transcript_formatter.dart
import 'transcript_parser.dart';

class TranscriptFormatter {
  final Future<String> Function(String prompt) callAI;

  TranscriptFormatter(this.callAI);

  static const int maxCharsPerChunk = 6000;

  static List<List<TranscriptSegment>> splitSegments(Transcript t,
      {int maxChars = maxCharsPerChunk}) {
    final chunks = <List<TranscriptSegment>>[];
    var current = <TranscriptSegment>[];
    var currentChars = 0;
    for (final seg in t.segments) {
      final len = seg.text.length;
      if (current.isNotEmpty && currentChars + len > maxChars) {
        chunks.add(current);
        current = <TranscriptSegment>[];
        currentChars = 0;
      }
      current.add(seg);
      currentChars += len;
    }
    if (current.isNotEmpty) chunks.add(current);
    return chunks;
  }

  String buildSegmentPrompt(List<TranscriptSegment> segments,
      {bool withTitle = false}) {
    final buffer = StringBuffer();
    for (final s in segments) {
      buffer.writeln('[${s.timestampLabel}] ${s.text}');
    }
    return '''
你是专业的视频笔记整理助手。以下是同一段视频转录文本的一部分，每行格式为 [时间戳] 文本。
请整理为 Markdown 结构化笔记，要求：
1. 按内容主题划分章节，章节标题格式为 "## HH:MM:SS 章节标题"，时间戳取该章节第一句话的时间戳。
2. 章节内用要点或段落组织，保留关键技术细节、数据与结论，修正口语冗余与错别字，不得遗漏实质内容。
3. 只输出 Markdown 正文，不要任何解释或额外说明。${withTitle ? '\n4. 若能推断视频主题，请在最开头用一行 "# 总标题" 给出总标题。' : ''}

转录文本：
$buffer''';
  }

  String buildTitlePrompt(String markdown) =>
      '请为以下视频笔记起一个简洁标题（不超过 20 字），只输出标题本身：\n\n$markdown';

  String fallbackMarkdown(Transcript t) => '# 转录笔记\n\n'
      '${t.segments.map((s) => '[${s.timestampLabel}] ${s.text}').join('\n\n')}\n';

  Future<String> format(Transcript t) async {
    final chunks = splitSegments(t);
    if (chunks.isEmpty) {
      throw const FormatException('转录内容为空');
    }
    final parts = <String>[];
    for (var i = 0; i < chunks.length; i++) {
      final raw = await callAI(buildSegmentPrompt(chunks[i], withTitle: i == 0));
      parts.add(_stripFence(raw.trim()));
    }
    return parts.join('\n\n');
  }

  Future<String?> suggestTitle(String markdown) async {
    try {
      final title = (await callAI(buildTitlePrompt(markdown))).trim();
      if (title.isEmpty) return null;
      return title.replaceAll(RegExp(r'^#+\s*'), '').split('\n').first.trim();
    } catch (_) {
      return null;
    }
  }

  static String _stripFence(String md) {
    if (md.startsWith('```')) {
      final firstNewline = md.indexOf('\n');
      if (firstNewline > 0 && md.endsWith('```')) {
        return md.substring(firstNewline + 1, md.length - 3).trim();
      }
    }
    return md;
  }
}
