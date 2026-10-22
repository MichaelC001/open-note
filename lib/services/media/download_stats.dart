// lib/services/media/download_stats.dart

/// 一次下载的实时状态快照。
class DownloadStatus {
  final double progress;
  final double speedBps;
  final int? etaSeconds;

  const DownloadStatus({
    this.progress = 0,
    this.speedBps = 0,
    this.etaSeconds,
  });
}

/// 基于指数移动平均的下载速度/剩余时间跟踪器。
class DownloadSpeedTracker {
  static const int _minSampleIntervalMs = 200;
  static const double _emaWeight = 0.7;

  int? _lastReceived;
  DateTime? _lastTime;
  double _ema = 0;

  DownloadStatus tick(int received, int total, {DateTime? now}) {
    final time = now ?? DateTime.now();
    if (_lastReceived != null && received < _lastReceived!) {
      _lastReceived = received;
      _lastTime = time;
    }
    if (_lastReceived != null && _lastTime != null) {
      final dtMs = time.difference(_lastTime!).inMilliseconds;
      if (dtMs >= _minSampleIntervalMs && received > _lastReceived!) {
        final instant = (received - _lastReceived!) * 1000 / dtMs;
        _ema = _ema <= 0 ? instant : _emaWeight * _ema + (1 - _emaWeight) * instant;
        _lastReceived = received;
        _lastTime = time;
      }
    } else {
      _lastReceived = received;
      _lastTime = time;
    }
    final progress = total > 0 ? (received / total).clamp(0.0, 1.0) : 0.0;
    final etaSeconds =
        _ema > 0 && total > received ? ((total - received) / _ema).round() : null;
    return DownloadStatus(
      progress: progress,
      speedBps: _ema,
      etaSeconds: etaSeconds,
    );
  }

  void reset() {
    _lastReceived = null;
    _lastTime = null;
    _ema = 0;
  }
}

String formatBytesRate(double bytesPerSecond) {
  if (bytesPerSecond <= 0) return '--';
  if (bytesPerSecond < 1024) {
    return '${bytesPerSecond.toStringAsFixed(0)} B/s';
  }
  if (bytesPerSecond < 1024 * 1024) {
    return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
  }
  return '${(bytesPerSecond / 1024 / 1024).toStringAsFixed(1)} MB/s';
}

String formatEtaClock(int? seconds) {
  if (seconds == null || seconds < 0) return '--:--';
  String two(int v) => v.toString().padLeft(2, '0');
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}
