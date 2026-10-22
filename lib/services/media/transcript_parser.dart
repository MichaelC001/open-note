// lib/services/media/transcript_parser.dart
import 'dart:convert';

class TranscriptSegment {
  final int startMs;
  final int endMs;
  final String text;

  const TranscriptSegment({
    required this.startMs,
    required this.endMs,
    required this.text,
  });

  String get timestampLabel {
    String two(int v) => v.toString().padLeft(2, '0');
    final d = Duration(milliseconds: startMs);
    return '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
  }
}

class Transcript {
  final List<TranscriptSegment> segments;
  final String language;

  const Transcript({required this.segments, this.language = 'auto'});

  String get plainText => segments
      .map((s) => s.text.trim())
      .where((t) => t.isNotEmpty)
      .join('\n');
}

Transcript parseWhisperJson(String raw) {
  final map = jsonDecode(raw) as Map<String, dynamic>;
  final list = (map['transcription'] as List?) ?? const [];
  final segments = list
      .map((e) {
        final item = e as Map<String, dynamic>;
        final offsets =
            (item['offsets'] as Map<String, dynamic>?) ?? const {};
        return TranscriptSegment(
          startMs: (offsets['from'] as num?)?.toInt() ?? 0,
          endMs: (offsets['to'] as num?)?.toInt() ?? 0,
          text: (item['text'] as String? ?? '').trim(),
        );
      })
      .where((s) => s.text.isNotEmpty)
      .toList();
  final lang =
      ((map['result'] as Map<String, dynamic>?)?['language'] as String?) ??
          'auto';
  return Transcript(segments: segments, language: lang);
}
