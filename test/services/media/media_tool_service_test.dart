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
      expect(MediaToolService.parseFfmpegVersion('ffmpeg version 7.1-x\n...'),
          '7.1-x');
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
      final bin =
          File('${ffmpegDir.path}/ffmpeg${Platform.isWindows ? '.exe' : ''}');
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
      final found =
          File('${nested.path}/ffmpeg${Platform.isWindows ? '.exe' : ''}');
      found.writeAsStringSync('#!/bin/sh\n');
      final svc = MediaToolService(resolveBaseDir: () async => tmp.path);
      final installed =
          await svc.installExtractedBinary('${tmp.path}/extract', MediaToolKind.ffmpeg);
      expect(installed, isNotNull);
      expect(
          File(installed!).path.endsWith(
              'tools/ffmpeg/ffmpeg${Platform.isWindows ? '.exe' : ''}'),
          isTrue);
    });

    test('找不到二进制返回 null', () async {
      Directory('${tmp.path}/extract').createSync(recursive: true);
      final svc = MediaToolService(resolveBaseDir: () async => tmp.path);
      expect(
          await svc.installExtractedBinary(
              '${tmp.path}/extract', MediaToolKind.whisperCli),
          isNull);
    });

    test('whisper 安装时把同目录动态库一并平铺搬到 toolDir', () async {
      final binDir = Directory('${tmp.path}/extract/build/bin');
      binDir.createSync(recursive: true);
      final exe = Platform.isWindows ? '.exe' : '';
      File('${binDir.path}/whisper-cli$exe').writeAsStringSync('#!/bin/sh\n');
      final lib = Platform.isWindows
          ? File('${binDir.path}/whisper.dll')
          : File('${binDir.path}/libwhisper.so');
      lib.writeAsStringSync('libbytes');
      // 干扰项：非库文件不应被搬动
      File('${binDir.path}/readme.txt').writeAsStringSync('doc');

      final svc = MediaToolService(resolveBaseDir: () async => tmp.path);
      final installed = await svc.installExtractedBinary(
          '${tmp.path}/extract', MediaToolKind.whisperCli);
      expect(installed, isNotNull);
      final toolDirPath = await svc.toolDir(MediaToolKind.whisperCli);
      expect(
          File('$toolDirPath/whisper-cli$exe').existsSync(), isTrue);
      final libName = lib.uri.pathSegments.last;
      expect(File('$toolDirPath/$libName').existsSync(), isTrue);
      expect(File('$toolDirPath/readme.txt').existsSync(), isFalse);
    });
  });
}
