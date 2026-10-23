// test/services/media/media_import_settings_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:open_note/services/media/media_import_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('media_tool_update_available 持久化', () {
    test('空表往返：未写入时读取返回空 Map', () async {
      final s = MediaImportSettings();
      expect(await s.readUpdateAvailable(), isEmpty);
    });

    test('写入后读取往返一致', () async {
      final s = MediaImportSettings();
      await s.writeUpdateAvailable({'ffmpeg': 'b7.0.1', 'ytDlp': '2026.10.05'});
      expect(await s.readUpdateAvailable(), {
        'ffmpeg': 'b7.0.1',
        'ytDlp': '2026.10.05',
      });
    });

    test('空表写入清除持久化键', () async {
      final s = MediaImportSettings();
      await s.writeUpdateAvailable({'ffmpeg': 'b7.0.1'});
      await s.writeUpdateAvailable({});
      expect(await s.readUpdateAvailable(), isEmpty);
    });

    test('存储内容非法 JSON 时读取返回空 Map 不抛错', () async {
      SharedPreferences.setMockInitialValues(
          <String, Object>{'media_tool_update_available': '{not-json'});
      final s = MediaImportSettings();
      expect(await s.readUpdateAvailable(), isEmpty);
    });
  });
}
