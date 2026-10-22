import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_note/providers/media_import_provider.dart';
import 'package:open_note/services/media/media_import_service.dart';
import 'package:open_note/services/media/media_tool_service.dart';
import 'package:open_note/services/media/whisper_model_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ReadyToolService extends MediaToolService {
  _ReadyToolService(Future<String> Function() base)
      : super(resolveBaseDir: base);
  @override
  Future<MediaToolStatus> check(MediaToolKind kind) async => MediaToolStatus(
      kind: kind,
      ready: true,
      path: 'fake',
      version: '1',
      source: MediaToolSource.appManaged);
}

class _AllModelsService extends WhisperModelService {
  _AllModelsService(Future<String> Function() base)
      : super(resolveBaseDir: base);
  @override
  Future<WhisperModelTier> recommendTierForDevice() async =>
      WhisperModelTier.largeV3Turbo;
  @override
  Future<File?> localModelFile(WhisperModelTier tier) async => File('m.bin');
}

void main() {
  late Directory tmp;
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmp = Directory.systemTemp.createTempSync('vtn_prov');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  MediaImportProvider makeProvider() => MediaImportProvider(
        toolService: _ReadyToolService(() async => tmp.path),
        modelService: _AllModelsService(() async => tmp.path),
      );

  test('startForFile -> envCheck 且环境就绪', () async {
    final p = makeProvider();
    await p.startForFile(File('${tmp.path}/a.mp4'));
    expect(p.step, MediaImportStep.envCheck);
    expect(p.toolStatuses[MediaToolKind.ffmpeg]!.ready, isTrue);
    expect(p.toolStatuses[MediaToolKind.ytDlp], isNull);
    expect(p.recommendedTier, WhisperModelTier.largeV3Turbo);
    expect(p.selectedTier, WhisperModelTier.largeV3Turbo);
    expect(p.environmentReady, isTrue);
  });

  test('URL 来源时 yt-dlp 必检', () async {
    final p = makeProvider();
    await p.startForUrl('https://example.com/v');
    expect(p.toolStatuses[MediaToolKind.ytDlp], isNotNull);
  });

  test('confirmAndStart 成功后 done 且回调拿到结果', () async {
    final p = makeProvider();
    await p.startForFile(File('${tmp.path}/a.mp4'));
    MediaImportResult? captured;
    await p.confirmAndStart(
      runOverride: (_, _) async {
        await Future.delayed(const Duration(milliseconds: 10));
        return const MediaImportResult(
            markdown: '# ok', title: 'T', formattedByAI: true);
      },
      saveNote: (r) async {
        captured = r;
        return 'note-1';
      },
    );
    expect(p.step, MediaImportStep.done);
    expect(p.resultNoteId, 'note-1');
    expect(captured!.markdown, '# ok');
  });

  test('confirmAndStart 失败写入 errorMessage', () async {
    final p = makeProvider();
    await p.startForFile(File('${tmp.path}/a.mp4'));
    await p.confirmAndStart(
      runOverride: (_, _) async =>
          throw const MediaImportException('boom', 'detail'),
      saveNote: (r) async => null,
    );
    expect(p.errorMessage, 'boom');
    expect(p.errorDetail, 'detail');
    expect(p.step, isNot(MediaImportStep.done));
  });

  test('cancel 终止处理', () async {
    final p = makeProvider();
    await p.startForFile(File('${tmp.path}/a.mp4'));
    await p.confirmAndStart(
      runOverride: (_, _) async {
        await Future.delayed(const Duration(seconds: 5));
        throw StateError('should not reach');
      },
      saveNote: (r) async => null,
      waitCompletion: false,
    );
    p.cancel();
    await Future.delayed(const Duration(milliseconds: 50));
    expect(p.step, isNot(MediaImportStep.done));
  });
}
