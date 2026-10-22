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
}
