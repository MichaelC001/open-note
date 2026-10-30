// lib/services/media/gpu_capability.dart
import 'dart:io';

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
  final cuda = RegExp(r'CUDA Version:\s*(\S+)').firstMatch(stdout)?.group(1);
  return GpuCapability(
    kind: GpuKind.cuda,
    driverVersion: driver,
    cudaVersion: cuda,
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
    final entry = cap.toCache()..['atMs'] = _now().millisecondsSinceEpoch;
    await writeCache(entry);
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
