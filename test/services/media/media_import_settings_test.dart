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

  group('whisper GPU 设置键', () {
    test('whisperGpu 默认 true，set 后读回一致', () async {
      final s = MediaImportSettings();
      expect(await s.whisperGpu(), isTrue);
      await s.setWhisperGpu(false);
      expect(await s.whisperGpu(), isFalse);
      await s.setWhisperGpu(true);
      expect(await s.whisperGpu(), isTrue);
    });

    test('markGpuUnavailable 两次写入合并为 2 键', () async {
      final s = MediaImportSettings();
      await s.markGpuUnavailable('mac:1.9.5', 'Metal 崩溃');
      await s.markGpuUnavailable('win:b5454', 'CUDA 校验失败');
      expect(await s.gpuUnavailableVersions(), {
        'mac:1.9.5': 'Metal 崩溃',
        'win:b5454': 'CUDA 校验失败',
      });
    });

    test('whisperBuild 未写入为 null，写入后读回', () async {
      final s = MediaImportSettings();
      expect(await s.whisperBuild(), isNull);
      await s.setWhisperBuild('cuda');
      expect(await s.whisperBuild(), 'cuda');
    });

    test('gpuDetectCache 未写入为 null，写入后读回', () async {
      final s = MediaImportSettings();
      expect(await s.gpuDetectCache(), isNull);
      await s.setGpuDetectCache({'atMs': 123, 'kind': 'metal'});
      expect(await s.gpuDetectCache(), {'atMs': 123, 'kind': 'metal'});
    });
  });

  group('metalOkVersions / markMetalOk', () {
    test('空表默认 + 追加 roundtrip + 同键覆盖', () async {
      final s = MediaImportSettings();
      expect(await s.metalOkVersions(), isEmpty);
      await s.markMetalOk('1.9.4');
      await s.markMetalOk('1.9.4');
      await s.markMetalOk('1.9.5');
      final t = await s.metalOkVersions();
      expect(t.keys, containsAll(['1.9.4', '1.9.5']));
      expect(t['1.9.4'], isNotEmpty);
    });
  });
}
