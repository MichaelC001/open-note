// test/models/note_source_type_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:open_note/models/note.dart';

void main() {
  test('NoteSourceType.video 存在且 name 为 video', () {
    expect(NoteSourceType.video.name, 'video');
  });
  test('fromMap 能还原 video 类型', () {
    final note = Note.fromMap({
      'id': 'n1',
      'title': 't',
      'content': 'c',
      'created_at': 0,
      'updated_at': 0,
      'source_type': 'video',
    });
    expect(note.sourceType, NoteSourceType.video);
    expect(note.toMap()['source_type'], 'video');
  });
}
