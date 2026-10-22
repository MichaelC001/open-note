// lib/services/media/wav_duration.dart
/// 估算 16kHz 单声道 16bit PCM WAV 时长（本流水线统一该格式）。
int estimateWavDurationMs(int wavFileBytes) {
  if (wavFileBytes <= 44) return 0;
  return (wavFileBytes - 44) * 1000 ~/ 32000;
}
