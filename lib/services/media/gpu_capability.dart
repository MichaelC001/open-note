// lib/services/media/gpu_capability.dart
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'process_runner.dart';

/// GPU 加速能力类型。
enum GpuKind { none, cuda, metal }

/// GPU 能力探测结果（kind + 可选驱动 / CUDA 版本）。
class GpuCapability {
  final GpuKind kind;
  final String? driverVersion;
  final String? cudaVersion;

  const GpuCapability({
    required this.kind,
    this.driverVersion,
    this.cudaVersion,
  });

  Map<String, dynamic> toCache() => {
        'kind': kind.name,
        if (driverVersion != null) 'driverVersion': driverVersion,
        if (cudaVersion != null) 'cudaVersion': cudaVersion,
      };

  static GpuCapability fromCache(Map<String, dynamic> c) {
    final kind = GpuKind.values.firstWhere(
      (k) => k.name == c['kind'],
      orElse: () => GpuKind.none,
    );
    return GpuCapability(
      kind: kind,
      driverVersion: c['driverVersion'] as String?,
      cudaVersion: c['cudaVersion'] as String?,
    );
  }
}

/// 解析 `nvidia-smi` 标准输出：含 `Driver Version` 行判定 cuda，
/// 否则 none；驱动 / CUDA 版本解析失败为 null 不影响判定。
GpuCapability parseNvidiaSmi(String stdout) {
  if (!stdout.contains('Driver Version')) {
    return const GpuCapability(kind: GpuKind.none);
  }
  final driver =
      RegExp(r'Driver Version:\s*(\S+)').firstMatch(stdout)?.group(1);
  final cudaRaw = RegExp(r'CUDA Version:\s*(\S+)').firstMatch(stdout)?.group(1);
  return GpuCapability(
    kind: GpuKind.cuda,
    driverVersion: driver,
    // 部分驱动输出 CUDA Version: N/A，归一为 null 语义更准（无有效 CUDA 版本）
    cudaVersion: (cudaRaw == null || cudaRaw == 'N/A') ? null : cudaRaw,
  );
}

/// GPU 不可用黑名单键（值存原因摘要），版本升级后自然不命中。
String gpuUnavailableKeyMac(String version) => 'mac:$version';
String gpuUnavailableKeyWin(String tag) => 'win:$tag';

/// GPU 能力探测器：Windows 跑 `nvidia-smi`（5s 超时），Mac 直接 metal；
/// 结果经注入的缓存读写持久化，24h 内不重复探测。
class GpuCapabilityDetector {
  static const _throttle = Duration(hours: 24);

  final Future<Map<String, dynamic>?> Function() readCache;
  final Future<void> Function(Map<String, dynamic>) writeCache;
  final Future<ProcessRunResult> Function(String exe, List<String> args)
      runProbe;
  final DateTime Function()? now;

  GpuCapabilityDetector({
    required this.readCache,
    required this.writeCache,
    required this.runProbe,
    this.now,
  });

  DateTime _now() => (now ?? DateTime.now)();

  Future<GpuCapability> detect({bool force = false}) async {
    if (!force) {
      final cached = await readCache();
      final atMs = cached?['atMs'];
      if (cached != null && atMs is int) {
        final age = _now().difference(DateTime.fromMillisecondsSinceEpoch(atMs));
        if (age >= Duration.zero && age < _throttle) {
          return GpuCapability.fromCache(cached);
        }
      }
    }
    final cap = await _probe();
    try {
      final entry = cap.toCache()..['atMs'] = _now().millisecondsSinceEpoch;
      await writeCache(entry);
    } catch (_) {
      // 缓存写失败不影响探测结论：仅损失 24h 节流（下次会重复探测）
    }
    return cap;
  }

  Future<GpuCapability> _probe() async {
    if (Platform.isMacOS) {
      return const GpuCapability(kind: GpuKind.metal);
    }
    if (!Platform.isWindows) {
      return const GpuCapability(kind: GpuKind.none);
    }
    try {
      final r = await runProbe('nvidia-smi', const [])
          .timeout(const Duration(seconds: 5));
      if (r.exitCode == 0 && r.stdout.contains('Driver Version')) {
        return parseNvidiaSmi(r.stdout);
      }
      return const GpuCapability(kind: GpuKind.none);
    } catch (_) {
      // nvidia-smi 不存在 / 超时 / 非零退出：一律按无能力处理
      return const GpuCapability(kind: GpuKind.none);
    }
  }
}

/// 1 秒 440Hz 正弦 WAV（16kHz / 单声道 / 16-bit PCM），
/// Metal 实测探测的输入音频。纯 Dart 生成，不依赖 ffmpeg。
Uint8List metalProbeWavBytes() {
  const sampleRate = 16000;
  const numSamples = sampleRate; // 1 秒
  const dataSize = numSamples * 2;
  const total = 44 + dataSize;
  final b = ByteData(total);
  void str(int off, String s) {
    for (var i = 0; i < s.length; i++) {
      b.setUint8(off + i, s.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  b.setUint32(4, total - 8, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  b.setUint32(16, 16, Endian.little); // fmt 块长
  b.setUint16(20, 1, Endian.little); // PCM
  b.setUint16(22, 1, Endian.little); // 单声道
  b.setUint32(24, sampleRate, Endian.little);
  b.setUint32(28, sampleRate * 2, Endian.little); // 字节率
  b.setUint16(32, 2, Endian.little); // 块对齐
  b.setUint16(34, 16, Endian.little); // 位深
  str(36, 'data');
  b.setUint32(40, dataSize, Endian.little);
  for (var i = 0; i < numSamples; i++) {
    final v = (32767 * 0.6 * sin(2 * pi * 440 * i / sampleRate)).round();
    b.setInt16(44 + i * 2, v, Endian.little);
  }
  return b.buffer.asUint8List();
}
