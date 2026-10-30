// test/services/media/whisper_runner_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_note/services/media/wav_duration.dart';
import 'package:open_note/services/media/whisper_runner.dart';

/// 生成假 whisper-cli 脚本：无 `-ng` 时输出 Metal 崩溃特征并退出 1；
/// 带 `-ng` 时写转录 json 并退出 0。每次调用向 [logPath] 追加 `ng=0/1`。
Future<File> _writeFakeWhisperCli(Directory dir, String logPath) async {
  final script = File('${dir.path}/whisper-cli-fake.sh');
  await script.writeAsString('''
#!/bin/sh
prefix=""
has_ng=0
prev=""
for a in "\$@"; do
  [ "\$prev" = "-of" ] && prefix="\$a"
  [ "\$a" = "-ng" ] && has_ng=1
  prev="\$a"
done
echo "ng=\$has_ng" >> '$logPath'
if [ "\$has_ng" = "1" ]; then
  echo '{"transcription":[{"offsets":{"from":0,"to":1000},"text":" hi"}],"result":{"language":"en"}}' > "\$prefix.json"
  exit 0
fi
echo "ggml_metal_init: error: cannot run the operation" >&2
exit 1
''');
  await Process.run('chmod', ['+x', script.path]);
  return script;
}

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
        ['-m', 'm.bin', '-f', 'a.wav', '-oj', '-of', 'a', '-np', '-pp']);
    expect(
        WhisperRunner.buildArgs(
            modelPath: 'm.bin',
            wavPath: 'a.wav',
            outPrefix: 'a',
            language: 'zh')
            .sublist(9),
        ['-l', 'zh']);
  });

  test('parseProgressSeconds 取最后一个时间戳', () {
    const chunk = '[00:00:00 --> 00:00:02] hi\n[00:01:05 --> 00:01:10] yo\n';
    expect(WhisperRunner.parseProgressSeconds(chunk), 65);
    expect(WhisperRunner.parseProgressSeconds('nothing'), isNull);
  });

  test('buildArgs noGpu 追加 -ng', () {
    expect(
        WhisperRunner.buildArgs(
            modelPath: 'm.bin', wavPath: 'a.wav', outPrefix: 'a', noGpu: true),
        ['-m', 'm.bin', '-f', 'a.wav', '-oj', '-of', 'a', '-np', '-pp', '-ng']);
  });

  test('looksLikeGpuFailure 识别 Metal 后端失败', () {
    expect(
        WhisperRunner.looksLikeGpuFailure(
            -6,
            'ggml_metal_init: error: pre-allocated tensor (leaf_0) in a buffer '
            '(MTL0) that cannot run the operation (NONE)'),
        isTrue);
    expect(WhisperRunner.looksLikeGpuFailure(1, 'some other error'), isFalse);
    expect(WhisperRunner.looksLikeGpuFailure(0, ''), isFalse);
  });

  test('parseProgressPercent 取最后一个百分比', () {
    expect(WhisperRunner.parseProgressPercent('[progress = 35%]'), 0.35);
    expect(
        WhisperRunner.parseProgressPercent(
            'progress = 30%\nprogress = 35%\n'),
        0.35);
    expect(WhisperRunner.parseProgressPercent('nothing here'), isNull);
  });

  test('transcribe forceNoGpu：首启即带 -ng，不再先无参尝试',
      skip: Platform.isWindows ? '依赖 sh 脚本假进程' : null, () async {
    final tmp = await Directory.systemTemp.createTemp('whisper_fake');
    final log = File('${tmp.path}/invocations.log');
    final cli = await _writeFakeWhisperCli(tmp, log.path);
    final wav = File('${tmp.path}/a.wav')..writeAsBytesSync(List.filled(64, 0));
    var fallbackCalls = 0;
    final t = await WhisperRunner().transcribe(
      whisperCliPath: cli.path,
      model: File('${tmp.path}/m.bin'),
      wav: wav,
      forceNoGpu: true,
      onGpuFallback: () => fallbackCalls++,
    );
    expect(t.plainText, 'hi');
    // 恰一次调用且带 -ng：若首启漏 -ng，脚本会 Metal 失败触发重试（两次调用）
    expect(log.readAsStringSync().trim().split('\n'), ['ng=1']);
    expect(fallbackCalls, 0);
    tmp.deleteSync(recursive: true);
  });

  test('transcribe：Metal 失败→CPU 重试成功后回调 onGpuFallback',
      skip: Platform.isWindows ? '依赖 sh 脚本假进程' : null, () async {
    final tmp = await Directory.systemTemp.createTemp('whisper_fake');
    final log = File('${tmp.path}/invocations.log');
    final cli = await _writeFakeWhisperCli(tmp, log.path);
    final wav = File('${tmp.path}/a.wav')..writeAsBytesSync(List.filled(64, 0));
    var fallbackCalls = 0;
    final t = await WhisperRunner().transcribe(
      whisperCliPath: cli.path,
      model: File('${tmp.path}/m.bin'),
      wav: wav,
      onGpuFallback: () => fallbackCalls++,
    );
    expect(t.plainText, 'hi');
    expect(log.readAsStringSync().trim().split('\n'), ['ng=0', 'ng=1'],
        reason: '首次无 -ng 崩溃，重试带 -ng');
    expect(fallbackCalls, 1);
    tmp.deleteSync(recursive: true);
  });
}
