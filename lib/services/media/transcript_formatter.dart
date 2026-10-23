// lib/services/media/transcript_formatter.dart
import 'transcript_parser.dart';

/// 内容优化强度：raw 逐字稿（不调 AI）、structured 仅段落排版、organized 完整整理。
enum ContentPolishLevel { raw, structured, organized }

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
      {bool withTitle = false,
      required bool includeTimestamps,
      required ContentPolishLevel level}) {
    final buffer = StringBuffer();
    for (final s in segments) {
      buffer.writeln('[${s.timestampLabel}] ${s.text}');
    }
    final transcriptBody = '''

转录文本：
$buffer''';
    if (level == ContentPolishLevel.structured) {
      return '你是专业的视频笔记排版助手。以下是同一段视频转录文本的一部分，'
          '每行格式为 [时间戳] 文本。请只做段落拆分与排版：'
          '1. 按语义把文本重新分段，每段一行或数行；'
          '2. 严禁改写任何文字、严禁调整内容顺序、严禁增删任何内容、'
          '不要划分章节、不要添加要点符号以外的结构；'
          '3. ${includeTimestamps ? '保留每行开头的时间戳标记。' : '删除每行开头的时间戳标记。'} '
          '4. 只输出处理后的文本，不要任何解释。'
          '${withTitle ? '\n5. 若能推断视频主题，请在最开头用一行 "# 总标题" 给出总标题。' : ''}'
          '$transcriptBody';
    }
    final sectionRule = includeTimestamps
        ? '1. 按内容主题划分章节，章节标题格式为 "## HH:MM:SS 章节标题"，'
            '时间戳取该章节第一句话的时间戳。'
        : '1. 按内容主题划分章节，章节标题格式为 "## 章节标题"（不要包含时间戳），'
            '并按章节顺序组织内容。';
    return '''你是专业的视频笔记整理助手。以下是同一段视频转录文本的一部分，每行格式为 [时间戳] 文本。
请整理为 Markdown 结构化笔记，要求：
$sectionRule
2. 章节内用要点或段落组织，保留关键技术细节、数据与结论，修正口语冗余与错别字，不得遗漏实质内容。
3. 只输出 Markdown 正文，不要任何解释或额外说明。
4. 高保真约束：不得改写原意，保留关键技术细节、数据与结论原貌，不增写转录文本之外的内容。${withTitle ? '\n5. 若能推断视频主题，请在最开头用一行 "# 总标题" 给出总标题。' : ''}${includeTimestamps ? '' : '\n${withTitle ? '6' : '5'}. 不要在输出中出现任何 [HH:MM:SS] 或时间戳标记。'}$transcriptBody''';
  }

  String buildTitlePrompt(String markdown) =>
      '请为以下视频笔记起一个简洁标题（不超过 20 字），只输出标题本身：\n\n$markdown';

  String fallbackMarkdown(Transcript t, {required bool includeTimestamps}) =>
      '# 转录笔记\n\n'
      '${t.segments.map((s) => includeTimestamps ? '[${s.timestampLabel}] ${s.text}' : s.text).join('\n\n')}\n';

  Future<String> format(
    Transcript t, {
    required bool includeTimestamps,
    required ContentPolishLevel level,
  }) async {
    if (level == ContentPolishLevel.raw) {
      return fallbackMarkdown(t, includeTimestamps: includeTimestamps);
    }
    final chunks = splitSegments(t);
    if (chunks.isEmpty) {
      throw const FormatException('转录内容为空');
    }
    final parts = <String>[];
    for (var i = 0; i < chunks.length; i++) {
      final res = await callAI(buildSegmentPrompt(
        chunks[i],
        withTitle: i == 0,
        includeTimestamps: includeTimestamps,
        level: level,
      ));
      parts.add(_stripFence(res.trim()));
    }
    var out = parts.join('\n\n');
    if (!includeTimestamps) {
      out = _stripTimestamps(out);
    }
    return out;
  }

  /// 关闭时间戳时清洗 AI 输出：剥章节标题时间戳与行内 [HH:MM:SS] 标记。
  static String _stripTimestamps(String md) => md
      .replaceAll(
          RegExp(r'^##\s*\d{2}:\d{2}:\d{2}\s*', multiLine: true), '## ')
      .replaceAll(RegExp(r'\[\d{2}:\d{2}:\d{2}\]\s*'), '');

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
