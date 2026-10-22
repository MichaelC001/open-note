// test/services/media/media_tool_service_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_note/services/media/media_tool_service.dart';
import 'package:open_note/services/media/process_runner.dart';

ProcessRunResult ok(String out) => ProcessRunResult(0, out, '');
const ProcessRunResult fail = ProcessRunResult(1, '', '');

void main() {
  group('版本解析', () {
    test('parseFfmpegVersion', () {
      expect(
        MediaToolService.parseFfmpegVersion('ffmpeg version 7.1-x\n...'),
        '7.1-x',
      );
      expect(MediaToolService.parseFfmpegVersion('nonsense'), isNull);
    });
    test('parseYtDlpVersion', () {
      expect(MediaToolService.parseYtDlpVersion('2025.10.22'), isNotNull);
      expect(MediaToolService.parseYtDlpVersion('garbage'), isNull);
    });
  });

  group('check（注入假命令执行）', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('vtn_tools'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('应用自管目录存在且版本可用 -> appManaged', () async {
      final ffmpegDir = Directory('${tmp.path}/tools/ffmpeg');
      ffmpegDir.createSync(recursive: true);
      final bin = File(
        '${ffmpegDir.path}/ffmpeg${Platform.isWindows ? '.exe' : ''}',
      );
      bin.writeAsStringSync('');
      if (!Platform.isWindows) {
        await Process.run('chmod', ['+x', bin.path]);
      }

      final svc = MediaToolService(
        resolveBaseDir: () async => tmp.path,
        run: (exe, args) async {
          if (args.contains('-version')) return ok('ffmpeg version 7.1');
          return fail;
        },
      );
      final st = await svc.check(MediaToolKind.ffmpeg);
      expect(st.ready, isTrue);
      expect(st.source, MediaToolSource.appManaged);
      expect(st.version, '7.1');
    });

    test('自管缺失且 which 成功 -> systemPath', () async {
      final svc = MediaToolService(
        resolveBaseDir: () async => tmp.path,
        run: (exe, args) async {
          if (exe == 'which') return ok('/usr/local/bin/ffmpeg\n');
          if (args.contains('-version')) return ok('ffmpeg version 6.0');
          return fail;
        },
      );
      final st = await svc.check(MediaToolKind.ffmpeg);
      expect(st.ready, isTrue);
      expect(st.source, MediaToolSource.systemPath);
      expect(st.path, '/usr/local/bin/ffmpeg');
    });

    test('全部缺失 -> ready=false', () async {
      final svc = MediaToolService(
        resolveBaseDir: () async => tmp.path,
        run: (exe, args) async => fail,
      );
      expect((await svc.check(MediaToolKind.ytDlp)).ready, isFalse);
    });
  });

  group('installExtractedBinary', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('vtn_install'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('递归找到二进制并安装到 toolDir', () async {
      final nested = Directory('${tmp.path}/extract/ffmpeg-7.1/bin');
      nested.createSync(recursive: true);
      final found = File(
        '${nested.path}/ffmpeg${Platform.isWindows ? '.exe' : ''}',
      );
      found.writeAsStringSync('#!/bin/sh\n');
      final svc = MediaToolService(resolveBaseDir: () async => tmp.path);
      final installed = await svc.installExtractedBinary(
        '${tmp.path}/extract',
        MediaToolKind.ffmpeg,
      );
      expect(installed, isNotNull);
      expect(
        File(installed!).path.endsWith(
          'tools/ffmpeg/ffmpeg${Platform.isWindows ? '.exe' : ''}',
        ),
        isTrue,
      );
    });

    test('找不到二进制返回 null', () async {
      Directory('${tmp.path}/extract').createSync(recursive: true);
      final svc = MediaToolService(resolveBaseDir: () async => tmp.path);
      expect(
        await svc.installExtractedBinary(
          '${tmp.path}/extract',
          MediaToolKind.whisperCli,
        ),
        isNull,
      );
    });

    test('whisper 安装时把同目录动态库一并平铺搬到 toolDir', () async {
      final nested = Directory('${tmp.path}/extract2/build/bin');
      nested.createSync(recursive: true);
      final exeName = Platform.isWindows ? 'whisper-cli.exe' : 'whisper-cli';
      final libExt = Platform.isWindows ? '.dll' : '.so';
      File('${nested.path}/$exeName').writeAsStringSync('x');
      final lib = File('${nested.path}/whisper$libExt')
        ..writeAsStringSync('lib');
      File('${nested.path}/readme.txt').writeAsStringSync('doc');
      final svc = MediaToolService(resolveBaseDir: () async => tmp.path);
      final installed = await svc.installExtractedBinary(
          '${tmp.path}/extract2', MediaToolKind.whisperCli);
      expect(installed, isNotNull);
      final toolDirPath = await svc.toolDir(MediaToolKind.whisperCli);
      expect(File('$toolDirPath/$exeName').existsSync(), isTrue);
      final libName = lib.uri.pathSegments.last;
      expect(File('$toolDirPath/$libName').existsSync(), isTrue);
      expect(File('$toolDirPath/readme.txt').existsSync(), isFalse);
    });
  });

  group('autoInstallPlan（一键安装命令构建）', () {
    test('macOS + brew 路径 -> brew install whisper-cpp', () {
      final plan = MediaToolService.autoInstallPlan(
        MediaToolKind.whisperCli,
        brewPath: '/opt/homebrew/bin/brew',
        isMac: true,
        isWin: false,
      );
      expect(plan, isNotNull);
      expect(plan!.executable, '/opt/homebrew/bin/brew');
      expect(plan.args, ['install', '-q', 'whisper-cpp']);
    });

    test('macOS 但未找到 brew -> null（回退指引）', () {
      expect(
        MediaToolService.autoInstallPlan(
          MediaToolKind.whisperCli,
          brewPath: null,
          isMac: true,
          isWin: false,
        ),
        isNull,
      );
    });

    test('Windows -> winget 静默安装 ggml.whisper-cpp', () {
      final plan = MediaToolService.autoInstallPlan(
        MediaToolKind.whisperCli,
        brewPath: null,
        isMac: false,
        isWin: true,
      );
      expect(plan, isNotNull);
      expect(plan!.executable, 'winget');
      expect(plan.args.join(' '), contains('ggml.whisper-cpp'));
      expect(plan.args.join(' '), contains('--disable-interactivity'));
    });

    test('Linux 不支持自动安装 -> null（保留指引）', () {
      expect(
        MediaToolService.autoInstallPlan(
          MediaToolKind.whisperCli,
          brewPath: null,
          isMac: false,
          isWin: false,
        ),
        isNull,
      );
    });

    test('非 whisperCli 工具不提供自动安装 -> null', () {
      expect(
        MediaToolService.autoInstallPlan(
          MediaToolKind.ffmpeg,
          brewPath: '/opt/homebrew/bin/brew',
          isMac: true,
          isWin: false,
        ),
        isNull,
      );
    });
  });
}
