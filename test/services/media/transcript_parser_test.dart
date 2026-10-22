// test/services/media/transcript_parser_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:open_note/services/media/transcript_parser.dart';

const fixture = '''
{
  "transcription": [
    {"timestamps": {"from": "00:00:00,000", "to": "00:00:02,000"},
     "offsets": {"from": 0, "to": 2000}, "text": " 大家好"},
    {"timestamps": {"from": "00:00:02,000", "to": "00:01:03,500"},
     "offsets": {"from": 2000, "to": 63500}, "text": " 今天讲Flutter。"},
    {"offsets": {"from": 63500, "to": 64000}, "text": "   "}
  ],
  "result": {"language": "zh"}
}
''';

void main() {
  test('解析 offsets 与语言、过滤空段', () {
    final t = parseWhisperJson(fixture);
    expect(t.language, 'zh');
    expect(t.segments.length, 2);
    expect(t.segments[0].startMs, 0);
    expect(t.segments[0].endMs, 2000);
    expect(t.segments[0].text, '大家好');
    expect(t.segments[1].timestampLabel, '00:00:02');
    expect(t.plainText, '大家好\n今天讲Flutter。');
  });
  test('空输入安全', () {
    expect(parseWhisperJson('{"transcription": []}').segments, isEmpty);
  });
}
