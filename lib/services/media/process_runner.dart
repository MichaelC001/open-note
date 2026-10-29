// lib/services/media/process_runner.dart
import 'dart:io';

class ProcessRunResult {
  final int exitCode;
  final String stdout;
  final String stderr;
  const ProcessRunResult(this.exitCode, this.stdout, this.stderr);
}

Future<ProcessRunResult> runCommand(
  String executable,
  List<String> args, {
  String? workingDirectory,
}) async {
  final result = await Process.run(executable, args,
      workingDirectory: workingDirectory);
  return ProcessRunResult(
    result.exitCode,
    result.stdout.toString(),
    result.stderr.toString(),
  );
}
