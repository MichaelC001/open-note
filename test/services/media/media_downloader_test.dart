// test/services/media/media_downloader_test.dart
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_note/services/media/media_downloader.dart';

void main() {
  const ffmpegUrl =
      'https://github.com/eugeneware/ffmpeg-static/releases/latest/download/ffmpeg-darwin-arm64';
  const ffmpegTaggedUrl =
      'https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/ffmpeg-darwin-arm64';
  group('candidateUrls', () {
    test('ffmpeg-static: latest URL auto 顺序 [直连, gh-proxy, ghfast]（latest 不映射 npmmirror）', () {
      final urls = MediaDownloader.candidateUrls(
          ffmpegUrl, MediaDownloadSourceMode.auto);
      expect(urls, [
        ffmpegUrl,
        'https://gh-proxy.com/$ffmpegUrl',
        'https://ghfast.top/$ffmpegUrl'
      ]);
    });
    test('ffmpeg-static: latest URL mirror 顺序 [gh-proxy, ghfast, 直连]', () {
      final urls = MediaDownloader.candidateUrls(
          ffmpegUrl, MediaDownloadSourceMode.mirror);
      expect(urls, [
        'https://gh-proxy.com/$ffmpegUrl',
        'https://ghfast.top/$ffmpegUrl',
        ffmpegUrl
      ]);
    });
    test('ffmpeg-static: tagged URL auto 顺序 npmmirror(同 tag) 置首', () {
      final urls = MediaDownloader.candidateUrls(
          ffmpegTaggedUrl, MediaDownloadSourceMode.auto);
      expect(urls, [
        'https://registry.npmmirror.com/-/binary/ffmpeg-static/b6.1.1/ffmpeg-darwin-arm64',
        ffmpegTaggedUrl,
        'https://gh-proxy.com/$ffmpegTaggedUrl',
        'https://ghfast.top/$ffmpegTaggedUrl'
      ]);
    });
    test('ffmpeg-static: tagged URL mirrorUrls 含 npmmirror 同 tag 同名资产', () {
      final mirrors = MediaDownloader.mirrorUrls(ffmpegTaggedUrl);
      expect(
          mirrors.first,
          'https://registry.npmmirror.com/-/binary/ffmpeg-static/b6.1.1/'
          'ffmpeg-darwin-arm64');
      expect(mirrors, contains('https://gh-proxy.com/$ffmpegTaggedUrl'));
    });
    test('huggingface 模型: direct 直连优先、失败回退 hf-mirror', () {
      const hf =
          'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin';
      final urls = MediaDownloader.candidateUrls(hf, MediaDownloadSourceMode.direct);
      expect(urls, [
        hf,
        'https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-base.bin'
      ]);
    });
    test('huggingface 模型: mirror 镜像优先、直连兜底', () {
      const hf =
          'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin';
      final urls = MediaDownloader.candidateUrls(hf, MediaDownloadSourceMode.mirror);
      expect(urls, [
        'https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-base.bin',
        hf
      ]);
    });
    test('github ffmpeg: direct 直连优先、npmmirror/github 镜像顺序不变', () {
      final urls = MediaDownloader.candidateUrls(
          ffmpegTaggedUrl, MediaDownloadSourceMode.direct);
      expect(urls, [
        ffmpegTaggedUrl,
        'https://registry.npmmirror.com/-/binary/ffmpeg-static/b6.1.1/ffmpeg-darwin-arm64',
        'https://gh-proxy.com/$ffmpegTaggedUrl',
        'https://ghfast.top/$ffmpegTaggedUrl'
      ]);
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
    test('direct：直连优先、镜像兜底', () {
      final urls = MediaDownloader.candidateUrls(
          'https://github.com/a/b', MediaDownloadSourceMode.direct);
      expect(urls.first, 'https://github.com/a/b');
      expect(
          urls,
          containsAllInOrder([
            'https://gh-proxy.com/https://github.com/a/b',
            'https://ghfast.top/https://github.com/a/b',
          ]));
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
    test('npmmirrorUrls：latest 不映射，tagged 映射同 tag 同名资产', () {
      expect(MediaDownloader.npmmirrorUrls(ffmpegUrl), isEmpty);
      expect(
          MediaDownloader.npmmirrorUrls(ffmpegTaggedUrl),
          [
            'https://registry.npmmirror.com/-/binary/ffmpeg-static/b6.1.1/ffmpeg-darwin-arm64'
          ]);
      expect(MediaDownloader.npmmirrorUrls('https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos'), isEmpty);
    });
    test('ffmpegDirectUrl 带 tag 使用具体 tag 而非 latest', () {
      final url = MediaDownloader.ffmpegDirectUrl(tag: 'b6.1.1');
      expect(url, contains('/releases/download/b6.1.1/ffmpeg-'));
      expect(url, isNot(contains('/releases/latest/')));
      final latest = MediaDownloader.ffmpegDirectUrl();
      expect(latest, contains('/releases/latest/download/ffmpeg-'));
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
        'whisper-cublas-11.8.0-bin-x64.zip',
        'whisper-cublas-12.4.0-bin-x64.zip',
      ];
      // 纯 CPU x64 包（whisper-bin-x64.zip，无 'win' 子串）为第一优先：
      // CUDA 包 ggml-cuda.dll 依赖 NVIDIA 驱动，无 N 卡进程无法启动（校验失败，
      // 用户 Windows 实测）；blas/cublas/win32/adreno/opencl 排除
      expect(
          MediaDownloader.pickWhisperAsset(b5454Assets,
              isWindows: true, isMac: false, isArm: false),
          'whisper-bin-x64.zip');
      expect(
          MediaToolCandidates.whisper(b5454Assets,
              isWindows: true, isMac: false, isArm: false),
          [
            'whisper-bin-x64.zip',
            'whisper-bin-win-cuda-11.8.0-x64.zip',
            'whisper-bin-win-cuda-12.4.0-x64.zip',
          ],
          reason: '纯 CPU x64 优先、cuda x64 兜底，blas/cublas/Win32 排除');
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

    test('candidates Windows x64：纯 CPU x64（无 win 子串）优先于 cuda x64', () {
      const names = [
        'whisper-bin-win-cuda-12.4.0-x64.zip',
        'whisper-bin-x64.zip',
      ];
      expect(
          MediaToolCandidates.whisper(names,
              isWindows: true, isMac: false, isArm: false),
          ['whisper-bin-x64.zip', 'whisper-bin-win-cuda-12.4.0-x64.zip']);
    });

    test('candidates Windows x64：仅 cuda 包时兜底命中，blas/cublas 排除', () {
      expect(
          MediaToolCandidates.whisper(
              const ['whisper-bin-win-cuda-12.4.0-x64.zip'],
              isWindows: true, isMac: false, isArm: false),
          ['whisper-bin-win-cuda-12.4.0-x64.zip'],
          reason: '无纯 CPU x64 包时 cuda x64 兜底');
      expect(
          MediaToolCandidates.whisper(
              const [
                'whisper-blas-bin-x64.zip',
                'whisper-cublas-12.4.0-bin-x64.zip',
                'whisper-bin-Win32.zip',
              ],
              isWindows: true, isMac: false, isArm: false),
          isEmpty,
          reason: 'cublas 含 blas 子串被 bad 正则覆盖；Win32 无 x64 不命中');
    });

    test('candidates Windows ARM：cpu arm64 优先、cuda arm64 兜底、adreno/opencl 排除', () {
      const names = [
        'whisper-bin-win-cuda-13.4-arm64.zip',
        'whisper-bin-win-opencl-adreno-arm64.zip',
        'whisper-bin-win-cpu-arm64.zip',
      ];
      expect(
          MediaToolCandidates.whisper(names,
              isWindows: true, isMac: false, isArm: true),
          ['whisper-bin-win-cpu-arm64.zip', 'whisper-bin-win-cuda-13.4-arm64.zip']);
      expect(
          MediaToolCandidates.whisper(const ['whisper-bin-win-cuda-13.4-arm64.zip'],
              isWindows: true, isMac: false, isArm: true),
          ['whisper-bin-win-cuda-13.4-arm64.zip'],
          reason: '仅 cuda arm64 时兜底命中');
    });

    test('preferCuda=true 时 cuda x64 层优先于纯 CPU 层', () {
      final names = ['whisper-bin-x64.zip', 'whisper-bin-win-cuda-12.4.0-x64.zip', 'whisper-blas-bin-x64.zip'];
      expect(MediaToolCandidates.whisper(names, isWindows: true, isMac: false, isArm: false, preferCuda: true).first,
          'whisper-bin-win-cuda-12.4.0-x64.zip');
      expect(MediaToolCandidates.whisper(names, isWindows: true, isMac: false, isArm: false).first,
          'whisper-bin-x64.zip');
    });

    test('pickWhisperAsset preferCuda 透传', () {
      const names = ['whisper-bin-x64.zip', 'whisper-bin-win-cuda-12.4.0-x64.zip'];
      expect(
          MediaDownloader.pickWhisperAsset(names,
              isWindows: true, isMac: false, isArm: false, preferCuda: true),
          'whisper-bin-win-cuda-12.4.0-x64.zip');
      expect(
          MediaDownloader.pickWhisperAsset(names,
              isWindows: true, isMac: false, isArm: false),
          'whisper-bin-x64.zip');
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
        ..writeAsBytesSync(ZipEncoder().encode(archive));
      final out = '${tmp.path}/out';
      await MediaDownloader().extract(zip, out);
      expect(File('$out/inner.txt').readAsStringSync(), 'hi');
    });
    test('非压缩包直接成功', () async {
      final f = File('${tmp.path}/bin')..writeAsStringSync('x');
      await MediaDownloader().extract(f, '${tmp.path}/out2');
    });
  });

  group('whisperApiCandidates', () {
    const apiUrl =
        'https://api.github.com/repos/ggml-org/whisper.cpp/releases?per_page=30';
    test('auto: 直连优先、gh-proxy 镜像兜底', () {
      expect(
          MediaDownloader.whisperApiCandidates(
              apiUrl, mode: MediaDownloadSourceMode.auto),
          [apiUrl, 'https://gh-proxy.com/$apiUrl']);
    });
    test('direct: 直连优先、gh-proxy 镜像兜底', () {
      expect(
          MediaDownloader.whisperApiCandidates(
              apiUrl, mode: MediaDownloadSourceMode.direct),
          [apiUrl, 'https://gh-proxy.com/$apiUrl']);
    });
    test('mirror: gh-proxy 镜像优先（ghfast 不支持 api.github.com）', () {
      expect(
          MediaDownloader.whisperApiCandidates(
              apiUrl, mode: MediaDownloadSourceMode.mirror),
          ['https://gh-proxy.com/$apiUrl', apiUrl]);
    });
  });

  group('download 失败逐源诊断', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('vtn_diag'));
    tearDown(() => tmp.deleteSync(recursive: true));
    const hf =
        'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin';

    ResponseBody notFound(RequestOptions options) =>
        throw DioException.badResponse(
          statusCode: 404,
          requestOptions: options,
          response: Response<dynamic>(
              requestOptions: options, statusCode: 404, data: 'not found'),
        );

    test('两候选均失败：消息含两个 url 片段与「已尝试 2 个源」', () async {
      final dio = Dio()
        ..httpClientAdapter = _StubAdapter((options) => notFound(options));
      final dl = MediaDownloader(dio: dio);
      Object? err;
      try {
        await dl.download(hf, destFile: File('${tmp.path}/m.bin'));
      } catch (e) {
        err = e;
      }
      expect(err, isNotNull);
      final msg = err.toString();
      expect(msg, contains('已尝试 2 个源'));
      expect(msg, contains(hf));
      expect(msg, contains('https://hf-mirror.com/ggerganov/whisper.cpp'));
    });

    test('SHA256 失败候选也计入逐源诊断', () async {
      final dio = Dio()
        ..httpClientAdapter = _StubAdapter((options) {
          if (options.uri.host == 'huggingface.co') {
            return ResponseBody.fromString('hello', 200);
          }
          return notFound(options);
        });
      final dl = MediaDownloader(dio: dio);
      Object? err;
      try {
        await dl.download(hf,
            destFile: File('${tmp.path}/m2.bin'), expectedSha256: 'deadbeef');
      } catch (e) {
        err = e;
      }
      expect(err, isNotNull);
      final msg = err.toString();
      expect(msg, contains('已尝试 2 个源'));
      expect(msg, contains('SHA256'));
      expect(msg, contains(hf));
      expect(msg, contains('https://hf-mirror.com/ggerganov/whisper.cpp'));
    });
  });
}

class _StubAdapter implements HttpClientAdapter {
  final ResponseBody Function(RequestOptions options) handler;
  _StubAdapter(this.handler);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async =>
      handler(options);

  @override
  void close({bool force = false}) {}
}
