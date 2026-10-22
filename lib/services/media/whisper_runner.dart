// lib/services/media/whisper_runner.dart
import 'dart:convert';
import 'dart:io';

import 'transcript_parser.dart';

class WhisperException implements Exception {
  final String message;
  final String? stderr;

  const WhisperException(this.message, [this.stderr]);

  @override
  String toString() => stderr == null ? message : '$message\n$stderr';
}

class WhisperRunner {
  static List<String> buildArgs({
    required String modelPath,
    required String wavPath,
    required String outPrefix,
    String language = 'auto',
  }) {
    final args = [
      '-m', modelPath,
      '-f', wavPath,
      '-oj',
      '-of', outPrefix,
      '-np',
      '-pp',
    ];
    if (language != 'auto') {
      args.addAll(['-l', language]);
    }
    return args;
  }

  /// 从输出解析已转录到的秒数（行如 "[00:01:23 --> 00:01:30]"）。
  static int? parseProgressSeconds(String chunk) {
    int? latest;
    final re = RegExp(r'\[(\d+):(\d+):(\d+)\s*-->');
    for (final m in re.allMatches(chunk)) {
      latest = int.parse(m.group(1)!) * 3600 +
          int.parse(m.group(2)!) * 60 +
          int.parse(m.group(3)!);
    }
    return latest;
  }

  /// 从 `-pp` 进度行解析百分比（行如 "progress = 35%"），返回最后匹配的小数。
  static double? parseProgressPercent(String chunk) {
    double? latest;
    final re = RegExp(r'progress\s*=\s*(\d+)%');
    for (final m in re.allMatches(chunk)) {
      latest = int.parse(m.group(1)!) / 100;
    }
    return latest;
  }

  Future<Transcript> transcribe({
    required String whisperCliPath,
    required File model,
    required File wav,
    String language = 'auto',
    int? totalDurationMs,
    void Function(double progress)? onProgress,
    void Function(Process process)? onStarted,
  }) async {
    final prefix = wav.path.toLowerCase().endsWith('.wav')
        ? wav.path.substring(0, wav.path.length - 4)
        : '${wav.path}_out';
    final process = await Process.start(
      whisperCliPath,
      buildArgs(
          modelPath: model.path,
          wavPath: wav.path,
          outPrefix: prefix,
          language: language),
    );
    onStarted?.call(process);
    // 段落文本行走 stdout，不排水会填满 64KB 管道导致 whisper 写阻塞死锁
    process.stdout.listen((_) {}, onError: (_) {});
    final sbErr = StringBuffer();
    process.stderr.transform(utf8.decoder).listen((chunk) {
      sbErr.write(chunk);
      if (totalDurationMs == null || totalDurationMs <= 0) return;
      final sec = parseProgressSeconds(chunk);
      final pct = parseProgressPercent(chunk);
      if (pct != null) {
        onProgress?.call(pct.clamp(0.0, 1.0));
      } else if (sec != null) {
        onProgress?.call((sec * 1000 / totalDurationMs).clamp(0.0, 1.0));
      }
    });
    final code = await process.exitCode;
    if (code != 0) {
      throw WhisperException('whisper.cpp 退出码 $code', _tail(sbErr));
    }
    final jsonFile = File('$prefix.json');
    if (!await jsonFile.exists()) {
      throw WhisperException('whisper.cpp 未生成转录输出', _tail(sbErr));
    }
    return parseWhisperJson(await jsonFile.readAsString());
  }

  static String _tail(StringBuffer sb) {
    final s = sb.toString();
    return s.length > 2000 ? s.substring(s.length - 2000) : s;
  }
}
