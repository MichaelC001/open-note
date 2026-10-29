// test/services/media/media_tool_service_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_note/services/media/media_import_settings.dart';
import 'package:open_note/services/media/media_tool_service.dart';
import 'package:open_note/services/media/process_runner.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
        run: (exe, args, {String? workingDirectory}) async {
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
        run: (exe, args, {String? workingDirectory}) async {
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
        run: (exe, args, {String? workingDirectory}) async => fail,
      );
      expect((await svc.check(MediaToolKind.ytDlp)).ready, isFalse);
    });

    test('whisperCli 探测以 exe 所在目录为工作目录（dll 搜索保险）', () async {
      final whisperDir = Directory('${tmp.path}/tools/whisper');
      whisperDir.createSync(recursive: true);
      final bin = File(
        '${whisperDir.path}/whisper-cli${Platform.isWindows ? '.exe' : ''}',
      );
      bin.writeAsStringSync('');
      if (!Platform.isWindows) {
        await Process.run('chmod', ['+x', bin.path]);
      }
      String? capturedWd;
      final svc = MediaToolService(
        resolveBaseDir: () async => tmp.path,
        run: (exe, args, {workingDirectory}) async {
          if (args.contains('--help')) {
            capturedWd = workingDirectory;
            return ok('usage: whisper-cli [options] file');
          }
          return fail;
        },
      );
      final st = await svc.check(MediaToolKind.whisperCli);
      expect(st.ready, isTrue);
      expect(capturedWd, whisperDir.path);
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

    test('whisper 安装时把 exe 同目录文件全部平铺搬到 toolDir（全量安装）', () async {
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
      expect(File('$toolDirPath/readme.txt').existsSync(), isTrue,
          reason: '全量安装：非库文件同样平铺复制');
    });

    test('whisper 全量安装：嵌套 Release/ 子目录 exe+dll+杂文件全部平铺且 exe 改名', () async {
      final release = Directory('${tmp.path}/extract3/whisper-bin-x64/Release');
      release.createSync(recursive: true);
      final exeName = Platform.isWindows ? 'whisper-cli.exe' : 'whisper-cli';
      final libExt = Platform.isWindows ? '.dll' : '.so';
      File('${release.path}/$exeName').writeAsStringSync('exe');
      File('${release.path}/ggml$libExt').writeAsStringSync('ggml');
      File('${release.path}/whisper$libExt').writeAsStringSync('whisper');
      File('${release.path}/BUILD-INFO.txt').writeAsStringSync('meta');
      File('${tmp.path}/extract3/LICENSE').writeAsStringSync('mit');
      final svc = MediaToolService(resolveBaseDir: () async => tmp.path);
      final installed = await svc.installExtractedBinary(
          '${tmp.path}/extract3', MediaToolKind.whisperCli);
      expect(installed, isNotNull);
      final toolDirPath = await svc.toolDir(MediaToolKind.whisperCli);
      expect(File('$toolDirPath/$exeName').readAsStringSync(), 'exe');
      for (final name in [
        'ggml$libExt',
        'whisper$libExt',
        'BUILD-INFO.txt',
        'LICENSE',
      ]) {
        expect(File('$toolDirPath/$name').existsSync(), isTrue, reason: name);
      }
      expect(Directory('$toolDirPath/Release').existsSync(), isFalse,
          reason: '子目录结构不带入 toolDir（平铺）');
      expect(Directory('$toolDirPath/whisper-bin-x64').existsSync(), isFalse);
    });
  });

  group('check 验证缓存（yt-dlp 二进制 spawn 慢，避免重复验证）', () {
    late Directory tmp;
    late Map<String, String> store;
    late Directory appDir;
    late File bin;
    late int runCount;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('vtn_cache');
      store = <String, String>{};
      runCount = 0;
      appDir = Directory('${tmp.path}/tools/ffmpeg')
        ..createSync(recursive: true);
      bin = File('${appDir.path}/ffmpeg${Platform.isWindows ? '.exe' : ''}')
        ..writeAsStringSync('x' * 10);
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    MediaToolService makeSvc() => MediaToolService(
          resolveBaseDir: () async => tmp.path,
          run: (exe, args, {String? workingDirectory}) async {
            if (!args.contains('-version')) return fail;
            runCount++;
            return ok('ffmpeg version 7.1');
          },
          cacheReader: () async => store,
          cacheWriter: (m) async => store
            ..clear()
            ..addAll(m),
        );

    test('同一二进制第二次 check 不再 spawn 验证命令', () async {
      final svc = makeSvc();
      final st1 = await svc.check(MediaToolKind.ffmpeg);
      expect(st1.ready, isTrue);
      expect(runCount, 1);

      final st2 = await svc.check(MediaToolKind.ffmpeg);
      expect(st2.ready, isTrue);
      expect(st2.version, '7.1');
      expect(st2.source, MediaToolSource.appManaged);
      expect(runCount, 1, reason: '缓存命中不应重复 spawn');
    });

    test('文件被替换（大小/mtime 变化）后缓存失效重新验证', () async {
      final svc = makeSvc();
      await svc.check(MediaToolKind.ffmpeg);
      expect(runCount, 1);

      bin.writeAsStringSync('x' * 99);
      final st = await svc.check(MediaToolKind.ffmpeg);
      expect(st.ready, isTrue);
      expect(runCount, 2, reason: '二进制变化应重新验证');
    });

    test('forceVerify: true 绕过缓存强制重验', () async {
      final svc = makeSvc();
      await svc.check(MediaToolKind.ffmpeg);
      expect(runCount, 1);

      final st = await svc.check(MediaToolKind.ffmpeg, forceVerify: true);
      expect(st.ready, isTrue);
      expect(runCount, 2);
    });

    test('缓存跨实例持久化（新实例零 spawn 命中）', () async {
      final svc1 = makeSvc();
      await svc1.check(MediaToolKind.ffmpeg);
      expect(runCount, 1);
      expect(store, isNotEmpty);

      runCount = 0;
      final st = await makeSvc().check(MediaToolKind.ffmpeg);
      expect(st.ready, isTrue);
      expect(st.version, '7.1');
      expect(runCount, 0, reason: '新实例应从持久化缓存命中');
    });

    test('二进制被删除后缓存失效回落 which 流程', () async {
      final svc = makeSvc();
      await svc.check(MediaToolKind.ffmpeg);
      expect(runCount, 1);

      bin.deleteSync();
      final st = await svc.check(MediaToolKind.ffmpeg);
      expect(st.ready, isFalse);
      expect(runCount, 1, reason: '缓存因文件缺失失效，但 which 全失败无验证 spawn');
    });

    test('MediaImportSettings 验证缓存 roundtrip', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final settings = MediaImportSettings();
      expect(await settings.readVerifyCache(), isEmpty);

      await settings.writeVerifyCache({'ffmpeg': '{"p":"/a","s":1}'});
      expect(await settings.readVerifyCache(),
          {'ffmpeg': '{"p":"/a","s":1}'});
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

    test('Windows -> winget 静默安装 ggml.whisper-cpp（绝对路径）', () {
      final plan = MediaToolService.autoInstallPlan(
        MediaToolKind.whisperCli,
        brewPath: null,
        wingetPath:
            r'C:\Users\a\AppData\Local\Microsoft\WindowsApps\winget.exe',
        isMac: false,
        isWin: true,
      );
      expect(plan, isNotNull);
      expect(
          plan!.executable, r'C:\Users\a\AppData\Local\Microsoft\WindowsApps\winget.exe');
      expect(plan.args.join(' '), contains('ggml.whisper-cpp'));
      expect(plan.args.join(' '), contains('--disable-interactivity'));
    });

    test('Windows 但未找到 winget -> null（回退指引）', () {
      expect(
        MediaToolService.autoInstallPlan(
          MediaToolKind.whisperCli,
          brewPath: null,
          wingetPath: null,
          isMac: false,
          isWin: true,
        ),
        isNull,
      );
    });

    test('wingetCandidatePaths：Windows 展开 LOCALAPPDATA，非 Windows 返回空', () {
      final paths = MediaToolService.wingetCandidatePaths();
      if (Platform.isWindows) {
        final local = Platform.environment['LOCALAPPDATA'];
        expect(paths, ['$local\\Microsoft\\WindowsApps\\winget.exe']);
      } else {
        expect(paths, isEmpty);
      }
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
