// test/services/media/whisper_runner_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:open_note/services/media/wav_duration.dart';
import 'package:open_note/services/media/whisper_runner.dart';

void main() {
  test('estimateWavDurationMs', () {
    expect(estimateWavDurationMs(0), 0);
    expect(estimateWavDurationMs(44), 0);
    expect(estimateWavDurationMs(44 + 32000), 1000);
  });

  test('buildArgs 基础参数与语言参数', () {
    expect(
        WhisperRunner.buildArgs(
            modelPath: 'm.bin', wavPath: 'a.wav', outPrefix: 'a'),
        ['-m', 'm.bin', '-f', 'a.wav', '-oj', '-of', 'a', '-np']);
    expect(
        WhisperRunner.buildArgs(
            modelPath: 'm.bin',
            wavPath: 'a.wav',
            outPrefix: 'a',
            language: 'zh')
            .sublist(8),
        ['-l', 'zh']);
  });

  test('parseProgressSeconds 取最后一个时间戳', () {
    const chunk = '[00:00:00 --> 00:00:02] hi\n[00:01:05 --> 00:01:10] yo\n';
    expect(WhisperRunner.parseProgressSeconds(chunk), 65);
    expect(WhisperRunner.parseProgressSeconds('nothing'), isNull);
  });
}
