// test/services/media/media_downloader_test.dart
import 'dart:ffi' as ffi;
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_note/services/media/media_downloader.dart';

void main() {
  const ffmpegUrl =
      'https://github.com/eugeneware/ffmpeg-static/releases/latest/download/ffmpeg-darwin-arm64';
  group('candidateUrls', () {
    test('ffmpeg-static: auto 顺序 npmmirror 置首、直连居中', () {
      final urls = MediaDownloader.candidateUrls(
          ffmpegUrl, MediaDownloadSourceMode.auto);
      expect(urls.first,
          'https://registry.npmmirror.com/-/binary/ffmpeg-static/b6.0/ffmpeg-darwin-arm64');
      expect(urls[1], ffmpegUrl);
      expect(urls.any((u) => u.startsWith('https://gh-proxy.com/')), isTrue);
    });
    test('ffmpeg-static: mirror 顺序 npmmirror > gh-proxy > ghfast > 直连', () {
      final urls = MediaDownloader.candidateUrls(
          ffmpegUrl, MediaDownloadSourceMode.mirror);
      expect(urls,
          ['https://registry.npmmirror.com/-/binary/ffmpeg-static/b6.0/ffmpeg-darwin-arm64',
           'https://gh-proxy.com/$ffmpegUrl',
           'https://ghfast.top/$ffmpegUrl',
           ffmpegUrl]);
    });
    test('huggingface 模型: auto 仍为 [直连, hf-mirror]', () {
      const hf = 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin';
      final urls = MediaDownloader.candidateUrls(hf, MediaDownloadSourceMode.auto);
      expect(urls, [hf, 'https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-base.bin']);
    });
    test('github 通用（yt-dlp）: auto 仍为 [直连, gh-proxy, ghfast]', () {
      const ytdlp = 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos';
      final urls = MediaDownloader.candidateUrls(ytdlp, MediaDownloadSourceMode.auto);
      expect(urls, [ytdlp, 'https://gh-proxy.com/$ytdlp', 'https://ghfast.top/$ytdlp']);
    });
  });

  group('candidateUrls / mirrorUrls', () {
    test('auto：直连在前、镜像在后', () {
      final urls = MediaDownloader.candidateUrls(
          'https://github.com/a/b', MediaDownloadSourceMode.auto);
      expect(urls.first, 'https://github.com/a/b');
      expect(urls.length, 3);
    });
    test('direct：仅直连', () {
      expect(
          MediaDownloader.candidateUrls(
              'https://github.com/a/b', MediaDownloadSourceMode.direct),
          ['https://github.com/a/b']);
    });
    test('mirror：镜像在前、直连兜底', () {
      final urls = MediaDownloader.candidateUrls(
          'https://github.com/a/b', MediaDownloadSourceMode.mirror);
      expect(urls.last, 'https://github.com/a/b');
      expect(urls.first.contains('github.com/a/b'), isTrue);
      expect(urls.first, isNot('https://github.com/a/b'));
    });
    test('HF 链接镜像为主机替换', () {
      expect(
          MediaDownloader.mirrorUrls(
              'https://huggingface.co/repo/resolve/main/f.bin'),
          ['https://hf-mirror.com/repo/resolve/main/f.bin']);
    });
    test('未知 host 无镜像', () {
      expect(MediaDownloader.mirrorUrls('https://example.com/f'), isEmpty);
    });
  });

  group('静态资源名', () {
    test('yt-dlp 资产名按平台', () {
      final name = MediaDownloader.ytDlpAssetName();
      if (Platform.isWindows) {
        expect(name, 'yt-dlp.exe');
      } else if (Platform.isMacOS) {
        expect(name, 'yt-dlp_macos');
      } else {
        expect(name, 'yt-dlp_linux');
      }
    });
    test('ffmpeg 直链按平台（三平台统一 ffmpeg-static 单文件）', () {
      final url = MediaDownloader.ffmpegDirectUrl();
      final isArm = switch (ffi.Abi.current()) {
        ffi.Abi.macosArm64 || ffi.Abi.linuxArm64 => true,
        _ => false,
      };
      if (Platform.isWindows) {
        expect(url,
            contains('ffmpeg-static/releases/latest/download/ffmpeg-win32-x64'));
      } else if (Platform.isMacOS) {
        expect(url,
            contains('ffmpeg-static/releases/latest/download/ffmpeg-darwin-'));
        expect(url.endsWith(isArm ? 'arm64' : 'x64'), isTrue);
      } else {
        expect(url, contains('ffmpeg-linux-'));
        expect(url.endsWith(isArm ? 'arm64' : 'x64'), isTrue);
      }
    });
    test('npmmirrorUrls 从 ffmpeg-static 直链解析同名资产', () {
      expect(
          MediaDownloader.npmmirrorUrls(ffmpegUrl),
          ['https://registry.npmmirror.com/-/binary/ffmpeg-static/b6.0/ffmpeg-darwin-arm64']);
      expect(MediaDownloader.npmmirrorUrls('https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos'), isEmpty);
    });
    test('pickWhisperAsset 用 b5454 真实资产列表命中与排除', () {
      const b5454Assets = [
        'whisper-b5454-xcframework.zip',
        'whisper-bin-ubuntu-arm64.tar.gz',
        'whisper-bin-ubuntu-x64.tar.gz',
        'whisper-bin-win-cpu-arm64.zip',
        'whisper-bin-win-cuda-11.8.0-x64.zip',
        'whisper-bin-win-cuda-12.4.0-x64.zip',
        'whisper-bin-win-cuda-13.4-arm64.zip',
        'whisper-bin-win-opencl-adreno-arm64.zip',
        'whisper-bin-Win32.zip',
        'whisper-bin-x64.zip',
        'whisper-blas-bin-Win32.zip',
        'whisper-blas-bin-x64.zip',
      ];
      expect(
          MediaDownloader.pickWhisperAsset(b5454Assets,
              isWindows: true, isMac: false, isArm: false),
          'whisper-bin-x64.zip');
      expect(
          MediaDownloader.pickWhisperAsset(b5454Assets,
              isWindows: false, isMac: false, isArm: false),
          'whisper-bin-ubuntu-x64.tar.gz');
      expect(
          MediaDownloader.pickWhisperAsset(b5454Assets,
              isWindows: false, isMac: false, isArm: true),
          'whisper-bin-ubuntu-arm64.tar.gz');
      expect(
          MediaDownloader.pickWhisperAsset(b5454Assets,
              isWindows: false, isMac: true, isArm: true),
          isNull);
      expect(
          MediaDownloader.pickWhisperAsset(['unrelated.zip'],
              isWindows: true, isMac: false, isArm: false),
          isNull);
    });
  });

  group('sha256File / parseDfK', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('vtn_dl'));
    tearDown(() => tmp.deleteSync(recursive: true));
    test('sha256 已知内容', () async {
      final f = File('${tmp.path}/a.txt')..writeAsStringSync('hello');
      expect(
          await MediaDownloader.sha256File(f),
          '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824');
    });
    test('parseDfK 取 avail 列', () {
      const out = 'Filesystem 1024-blocks Used Available Capacity '
          'Mounted on\n/dev/disk1 1000000 500000 500000 50% /\n';
      expect(MediaDownloader.parseDfK(out), 500000 * 1024);
      expect(MediaDownloader.parseDfK('bad'), isNull);
    });
  });

  group('extract', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('vtn_ex'));
    tearDown(() => tmp.deleteSync(recursive: true));
    test('解压 zip', () async {
      final archive = Archive()
        ..addFile(ArchiveFile('inner.txt', 'hi'.length, 'hi'.codeUnits));
      final zip = File('${tmp.path}/t.zip')
        ..writeAsBytesSync(ZipEncoder().encode(archive)!);
      final out = '${tmp.path}/out';
      await MediaDownloader().extract(zip, out);
      expect(File('$out/inner.txt').readAsStringSync(), 'hi');
    });
    test('非压缩包直接成功', () async {
      final f = File('${tmp.path}/bin')..writeAsStringSync('x');
      await MediaDownloader().extract(f, '${tmp.path}/out2');
    });
  });
}
