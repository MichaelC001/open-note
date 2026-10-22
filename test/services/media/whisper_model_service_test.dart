// test/services/media/whisper_model_service_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_note/services/media/whisper_model_service.dart';

void main() {
  group('recommendTier', () {
    const gb = 1024 * 1024 * 1024;
    test('>=16GB -> largeV3Turbo', () {
      expect(WhisperModelService.recommendTier(16 * gb),
          WhisperModelTier.largeV3Turbo);
      expect(WhisperModelService.recommendTier(32 * gb),
          WhisperModelTier.largeV3Turbo);
    });
    test('8-16GB -> medium（含 8GB 边界）', () {
      expect(WhisperModelService.recommendTier(8 * gb),
          WhisperModelTier.medium);
      expect(WhisperModelService.recommendTier(16 * gb - 1),
          WhisperModelTier.medium);
    });
    test('<8GB -> base（含 0）', () {
      expect(WhisperModelService.recommendTier(0), WhisperModelTier.base);
      expect(WhisperModelService.recommendTier(8 * gb - 1),
          WhisperModelTier.base);
    });
  });

  group('catalog', () {
    test('包含三档且文件名正确', () {
      expect(WhisperModelService.catalog.length, 3);
      expect(WhisperModelService.infoFor(WhisperModelTier.base).fileName,
          'ggml-base.bin');
      expect(WhisperModelService.infoFor(WhisperModelTier.medium).fileName,
          'ggml-medium.bin');
      expect(
          WhisperModelService.infoFor(WhisperModelTier.largeV3Turbo).fileName,
          'ggml-large-v3-turbo.bin');
    });
    test('modelUrl 直连与镜像 host 正确', () {
      final m = WhisperModelService.infoFor(WhisperModelTier.base);
      expect(WhisperModelService.modelUrl(m, mirror: false).host,
          'huggingface.co');
      expect(WhisperModelService.modelUrl(m, mirror: true).host,
          'hf-mirror.com');
      expect(WhisperModelService.modelUrl(m, mirror: true).path,
          '/ggml-org/whisper.cpp/resolve/main/ggml-base.bin');
    });
  });

  group('localModelFile', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('vtn_models'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('文件存在且达到预期一半返回文件，否则 null；删除生效', () async {
      final svc = WhisperModelService(resolveBaseDir: () async => tmp.path);
      final model = WhisperModelService.infoFor(WhisperModelTier.base);
      final dir = Directory('${tmp.path}/whisper_models');
      dir.createSync(recursive: true);
      expect(await svc.localModelFile(WhisperModelTier.base), isNull);
      final f = File('${dir.path}/${model.fileName}');
      await f.writeAsBytes(List.filled(model.downloadSizeBytes ~/ 2, 0));
      expect(await svc.localModelFile(WhisperModelTier.base), isNotNull);
      await svc.deleteModel(WhisperModelTier.base);
      expect(await svc.localModelFile(WhisperModelTier.base), isNull);
    });
  });

  test('detectTotalRamBytes 在真机返回非负且映射到合法档位', () async {
    final svc = WhisperModelService(resolveBaseDir: () async => '');
    final ram = await svc.detectTotalRamBytes();
    expect(ram, greaterThanOrEqualTo(0));
    expect(WhisperModelService.recommendTier(ram),
        isIn(WhisperModelTier.values));
  });
}
