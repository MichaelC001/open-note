// test/services/media/gpu_capability_test.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_note/services/media/gpu_capability.dart';
import 'package:open_note/services/media/process_runner.dart';

void main() {
  group('parseNvidiaSmi', () {
    test('parseNvidiaSmi 解析驱动与 CUDA 版本', () {
      final cap = parseNvidiaSmi(
          'Mon Sep 00 ...\n| Driver Version: 566.36 | CUDA Version: 12.7 |');
      expect(cap.kind, GpuKind.cuda);
      expect(cap.driverVersion, '566.36');
      expect(cap.cudaVersion, '12.7');
    });
    test('无 Driver Version 输出 → none', () {
      expect(parseNvidiaSmi('no gpu here').kind, GpuKind.none);
    });
    test('缺 CUDA Version 行时 cudaVersion 为 null 仍判定 cuda', () {
      final cap = parseNvidiaSmi('| Driver Version: 566.36 |');
      expect(cap.kind, GpuKind.cuda);
      expect(cap.driverVersion, '566.36');
      expect(cap.cudaVersion, isNull);
    });
    test('CUDA Version 为 N/A 时归一为 null', () {
      final cap = parseNvidiaSmi(
          '| Driver Version: 566.36 | CUDA Version: N/A |');
      expect(cap.kind, GpuKind.cuda);
      expect(cap.driverVersion, '566.36');
      expect(cap.cudaVersion, isNull);
    });
  });

  group('黑名单键构造', () {
    test('黑名单键构造', () {
      expect(gpuUnavailableKeyMac('1.9.5'), 'mac:1.9.5');
      expect(gpuUnavailableKeyWin('b5454'), 'win:b5454');
    });
  });

  group('GpuCapabilityDetector', () {
    test('detect 返回当前平台能力并写缓存（含 atMs）', () async {
      Map<String, dynamic>? cached;
      var probeCalls = 0;
      final detector = GpuCapabilityDetector(
        readCache: () async => cached,
        writeCache: (c) async => cached = c,
        runProbe: (exe, args) async {
          probeCalls++;
          return const ProcessRunResult(0, '', '');
        },
      );
      final cap = await detector.detect();
      final expectedKind = Platform.isMacOS ? GpuKind.metal : GpuKind.none;
      expect(cap.kind, expectedKind);
      expect(probeCalls, Platform.isMacOS ? 0 : 1,
          reason: 'Mac 直接返回 metal 不 spawn 进程，其余平台走探测');
      expect(cached, isNotNull);
      final entry = cached!;
      expect(entry['atMs'], isA<int>());
      expect(entry['kind'], expectedKind.name);
    });

    test('24h 内命中缓存直接返回且不重复写缓存', () async {
      Map<String, dynamic>? cached = <String, dynamic>{
        'atMs': DateTime.now().millisecondsSinceEpoch,
        'kind': 'cuda',
        'driverVersion': '566.36',
        'cudaVersion': '12.7',
      };
      var writes = 0;
      var probeCalls = 0;
      final detector = GpuCapabilityDetector(
        readCache: () async => cached,
        writeCache: (c) async {
          cached = c;
          writes++;
        },
        runProbe: (exe, args) async {
          probeCalls++;
          return const ProcessRunResult(0, '', '');
        },
      );
      final cap = await detector.detect();
      expect(cap.kind, GpuKind.cuda);
      expect(cap.driverVersion, '566.36');
      expect(cap.cudaVersion, '12.7');
      expect(writes, 0, reason: '缓存新鲜时不重写');
      expect(probeCalls, 0, reason: '缓存新鲜时不探测');
    });

    test('缓存超过 24h 重新探测并更新时间戳', () async {
      final staleAt = DateTime.now()
          .subtract(const Duration(hours: 25))
          .millisecondsSinceEpoch;
      Map<String, dynamic>? cached = <String, dynamic>{'atMs': staleAt};
      var writes = 0;
      final detector = GpuCapabilityDetector(
        readCache: () async => cached,
        writeCache: (c) async {
          cached = c;
          writes++;
        },
        runProbe: (exe, args) async => const ProcessRunResult(0, '', ''),
      );
      final cap = await detector.detect();
      expect(cap.kind, Platform.isMacOS ? GpuKind.metal : GpuKind.none);
      expect(writes, 1);
      expect(cached!['atMs'] as int, greaterThan(staleAt));
    });

    test('force: true 绕过新鲜缓存强制复测', () async {
      Map<String, dynamic>? cached = <String, dynamic>{
        'atMs': DateTime.now().millisecondsSinceEpoch,
        'kind': 'metal',
      };
      var writes = 0;
      final detector = GpuCapabilityDetector(
        readCache: () async => cached,
        writeCache: (c) async {
          cached = c;
          writes++;
        },
        runProbe: (exe, args) async => const ProcessRunResult(0, '', ''),
      );
      await detector.detect(force: true);
      expect(writes, 1, reason: 'force 复测后重写缓存');
    });

    test('缓存损坏（缺 atMs）视为无缓存重新探测', () async {
      Map<String, dynamic>? cached = <String, dynamic>{'kind': 'cuda'};
      final detector = GpuCapabilityDetector(
        readCache: () async => cached,
        writeCache: (c) async => cached = c,
        runProbe: (exe, args) async => const ProcessRunResult(0, '', ''),
      );
      final cap = await detector.detect();
      expect(cap.kind, Platform.isMacOS ? GpuKind.metal : GpuKind.none);
      expect(cached!['atMs'], isA<int>());
    });

    test('探测抛错（如 nvidia-smi 不存在）→ none 且不向上抛', () async {
      if (!Platform.isWindows) return;
      final detector = GpuCapabilityDetector(
        readCache: () async => null,
        writeCache: (c) async {},
        runProbe: (exe, args) async => throw const ProcessException('nvidia-smi', []),
      );
      final cap = await detector.detect();
      expect(cap.kind, GpuKind.none);
    });

    test('writeCache 抛错不影响探测结果返回', () async {
      final detector = GpuCapabilityDetector(
        readCache: () async => null,
        writeCache: (c) async => throw Exception('disk full'),
        runProbe: (exe, args) async => const ProcessRunResult(0, '', ''),
      );
      final cap = await detector.detect();
      expect(cap.kind, Platform.isMacOS ? GpuKind.metal : GpuKind.none);
    });
  });

  test('metalProbeWavBytes：标准 WAV 头 + 1 秒 16kHz 单声道 16bit', () {
    final b = metalProbeWavBytes();
    expect(b.length, 44 + 16000 * 2);
    expect(String.fromCharCodes(b.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(b.sublist(8, 12)), 'WAVE');
    final bd = ByteData.sublistView(b);
    expect(bd.getUint32(24, Endian.little), 16000, reason: '采样率');
    expect(bd.getUint16(22, Endian.little), 1, reason: '单声道');
    expect(bd.getUint16(34, Endian.little), 16, reason: '16-bit');
    expect(bd.getUint32(40, Endian.little), 32000, reason: 'data 长度');
    expect(bd.getUint16(20, Endian.little), 1, reason: 'PCM 格式');
  });
}
