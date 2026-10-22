// test/services/media/download_stats_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:open_note/services/media/download_stats.dart';

DateTime t(int ms) => DateTime.fromMillisecondsSinceEpoch(ms);

void main() {
  group('DownloadSpeedTracker', () {
    test('首样本无速度，进度正确', () {
      final tr = DownloadSpeedTracker();
      final st = tr.tick(0, 1000, now: t(0));
      expect(st.progress, 0.0);
      expect(st.speedBps, 0.0);
      expect(st.etaSeconds, isNull);
    });

    test('间隔 1 秒收 500 字节 -> 速度 500B/s，ETA 正确', () {
      final tr = DownloadSpeedTracker();
      tr.tick(0, 1000, now: t(0));
      final st = tr.tick(500, 1000, now: t(1000));
      expect(st.speedBps, closeTo(500, 0.1));
      expect(st.progress, closeTo(0.5, 1e-9));
      expect(st.etaSeconds, 1); // (1000-500)/500
    });

    test('EMA 平滑：速度突变时取加权而非瞬时跳变', () {
      final tr = DownloadSpeedTracker();
      tr.tick(0, 10000, now: t(0));
      tr.tick(1000, 10000, now: t(1000)); // inst=1000, ema=1000
      final st = tr.tick(2000, 10000, now: t(2000)); // inst=1000
      expect(st.speedBps, closeTo(1000, 0.1));
      tr.tick(4000, 10000, now: t(3000)); // inst=2000 -> ema=0.7*1000+0.3*2000=1300
      // inst=2000 -> ema=0.7*1300+0.3*2000=1510
      expect(tr.tick(6000, 10000, now: t(4000)).speedBps, closeTo(1510, 0.1));
    });

    test('小于 200ms 的样本不更新速度但推进进度', () {
      final tr = DownloadSpeedTracker();
      tr.tick(0, 1000, now: t(0));
      tr.tick(500, 1000, now: t(1000)); // ema=500
      final st = tr.tick(600, 1000, now: t(1100)); // dt=100ms 忽略
      expect(st.speedBps, 500);
      expect(st.progress, closeTo(0.6, 1e-9));
    });

    test('resume 场景 received 回退时重置基线不产生负速度', () {
      final tr = DownloadSpeedTracker();
      tr.tick(800, 1000, now: t(0));
      tr.tick(800, 1000, now: t(1000));
      final st = tr.tick(0, 1000, now: t(2000));
      expect(st.speedBps, isNonNegative);
      expect(st.progress, 0.0);
    });

    test('reset 清空基线', () {
      final tr = DownloadSpeedTracker();
      tr.tick(0, 1000, now: t(0));
      tr.tick(500, 1000, now: t(1000));
      tr.reset();
      final st = tr.tick(900, 1000, now: t(2000));
      expect(st.speedBps, 0.0);
      expect(st.etaSeconds, isNull);
    });
  });

  group('格式化', () {
    test('formatBytesRate 分档', () {
      expect(formatBytesRate(0), '--');
      expect(formatBytesRate(-1), '--');
      expect(formatBytesRate(500), '500 B/s');
      expect(formatBytesRate(1024), '1.0 KB/s');
      expect(formatBytesRate(1536), '1.5 KB/s');
      expect(formatBytesRate(1024 * 1024), '1.0 MB/s');
      expect(formatBytesRate(2.5 * 1024 * 1024), '2.5 MB/s');
    });

    test('formatEtaClock', () {
      expect(formatEtaClock(null), '--:--');
      expect(formatEtaClock(0), '00:00');
      expect(formatEtaClock(45), '00:45');
      expect(formatEtaClock(205), '03:25');
      expect(formatEtaClock(3661), '1:01:01');
    });
  });
}
