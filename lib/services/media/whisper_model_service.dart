// lib/services/media/whisper_model_service.dart
import 'dart:io';

import 'package:path_provider/path_provider.dart';

enum WhisperModelTier { base, medium, largeV3Turbo }

class WhisperModelInfo {
  final WhisperModelTier tier;
  final String fileName;
  final int downloadSizeBytes;
  final String hfRepoPath;

  const WhisperModelInfo({
    required this.tier,
    required this.fileName,
    required this.downloadSizeBytes,
    required this.hfRepoPath,
  });

  String get displayLabel => switch (tier) {
        WhisperModelTier.base => 'base',
        WhisperModelTier.medium => 'medium',
        WhisperModelTier.largeV3Turbo => 'large-v3-turbo',
      };
}

class WhisperModelService {
  static const String _hfBase = 'https://huggingface.co';
  static const String _hfMirror = 'https://hf-mirror.com';

  static const List<WhisperModelInfo> catalog = [
    WhisperModelInfo(
      tier: WhisperModelTier.base,
      fileName: 'ggml-base.bin',
      downloadSizeBytes: 150 * 1024 * 1024,
      hfRepoPath: 'ggerganov/whisper.cpp/resolve/main/ggml-base.bin',
    ),
    WhisperModelInfo(
      tier: WhisperModelTier.medium,
      fileName: 'ggml-medium.bin',
      downloadSizeBytes: 1600 * 1024 * 1024,
      hfRepoPath: 'ggerganov/whisper.cpp/resolve/main/ggml-medium.bin',
    ),
    WhisperModelInfo(
      tier: WhisperModelTier.largeV3Turbo,
      fileName: 'ggml-large-v3-turbo.bin',
      downloadSizeBytes: 1700 * 1024 * 1024,
      hfRepoPath: 'ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin',
    ),
  ];

  final Future<String> Function() resolveBaseDir;

  WhisperModelService({Future<String> Function()? resolveBaseDir})
      : resolveBaseDir = resolveBaseDir ?? _defaultBaseDir;

  static Future<String> _defaultBaseDir() async =>
      (await getApplicationSupportDirectory()).path;

  static WhisperModelInfo infoFor(WhisperModelTier tier) =>
      catalog.firstWhere((m) => m.tier == tier);

  static Uri modelUrl(WhisperModelInfo model, {required bool mirror}) =>
      Uri.parse('${mirror ? _hfMirror : _hfBase}/${model.hfRepoPath}');

  /// RAM ≥ 16GB -> largeV3Turbo；≥ 8GB -> medium；其余 base。
  static WhisperModelTier recommendTier(int totalRamBytes) {
    const gb = 1024 * 1024 * 1024;
    if (totalRamBytes >= 16 * gb) return WhisperModelTier.largeV3Turbo;
    if (totalRamBytes >= 8 * gb) return WhisperModelTier.medium;
    return WhisperModelTier.base;
  }

  Future<int> detectTotalRamBytes() async {
    try {
      if (Platform.isMacOS) {
        final r = await Process.run('sysctl', ['-n', 'hw.memsize']);
        return int.tryParse(r.stdout.toString().trim()) ?? 0;
      }
      if (Platform.isLinux) {
        final file = File('/proc/meminfo');
        if (!await file.exists()) return 0;
        final m = RegExp(r'MemTotal:\s+(\d+)\s+kB')
            .firstMatch(await file.readAsString());
        return m == null ? 0 : int.parse(m.group(1)!) * 1024;
      }
      if (Platform.isWindows) {
        var r = await Process.run(
            'wmic', ['ComputerSystem', 'get', 'TotalPhysicalMemory']);
        var m = RegExp(r'(\d{10,})').firstMatch(r.stdout.toString());
        if (m != null) return int.parse(m.group(1)!);
        r = await Process.run('powershell', [
          '-Command',
          '(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory',
        ]);
        m = RegExp(r'(\d{10,})').firstMatch(r.stdout.toString());
        return m == null ? 0 : int.parse(m.group(1)!);
      }
    } catch (_) {
      return 0;
    }
    return 0;
  }

  Future<WhisperModelTier> recommendTierForDevice() async {
    final ram = await detectTotalRamBytes();
    if (ram <= 0) return WhisperModelTier.medium;
    return recommendTier(ram);
  }

  Future<String> modelsDir() async {
    final dir = Directory('${await resolveBaseDir()}/whisper_models');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  /// 已完整下载（大小 ≥ 预期一半）返回文件，否则 null。
  Future<File?> localModelFile(WhisperModelTier tier) async {
    final info = infoFor(tier);
    final file = File('${await modelsDir()}/${info.fileName}');
    if (!await file.exists()) return null;
    return await file.length() >= info.downloadSizeBytes ~/ 2 ? file : null;
  }

  Future<void> deleteModel(WhisperModelTier tier) async {
    final file = await localModelFile(tier);
    if (file != null) await file.delete();
  }
}
