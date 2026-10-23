// test/services/media/tool_update_service_test.dart
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_note/services/media/media_tool_service.dart';
import 'package:open_note/services/media/tool_update_service.dart';

void main() {
  group('normalizeTag', () {
    test('b 前缀去除：b6.0 -> 6.0', () {
      expect(ToolUpdateService.normalizeTag('b6.0'), '6.0');
    });
    test('v 前缀去除：v1.7.2 -> 1.7.2', () {
      expect(ToolUpdateService.normalizeTag('v1.7.2'), '1.7.2');
    });
    test('日期格式原样：2025.10.22', () {
      expect(ToolUpdateService.normalizeTag('2025.10.22'), '2025.10.22');
    });
    test('null -> null 且前缀大小写不敏感', () {
      expect(ToolUpdateService.normalizeTag(null), isNull);
      expect(ToolUpdateService.normalizeTag('B7.0.1'), '7.0.1');
    });
  });

  group('hasUpdate', () {
    test('ffmpeg：normalize 后相等无更新（6.0 vs b6.0）', () {
      expect(
        ToolUpdateService.hasUpdate(
          localVersion: '6.0',
          remoteTag: 'b6.0',
          kind: MediaToolKind.ffmpeg,
          storedSourceTag: null,
        ),
        isFalse,
      );
    });
    test('ffmpeg：normalize 后不同有更新（6.0 vs b7.0）', () {
      expect(
        ToolUpdateService.hasUpdate(
          localVersion: '6.0',
          remoteTag: 'b7.0',
          kind: MediaToolKind.ffmpeg,
          storedSourceTag: null,
        ),
        isTrue,
      );
    });
    test('ytDlp：相等无更新 / 不等有更新', () {
      const kind = MediaToolKind.ytDlp;
      expect(
        ToolUpdateService.hasUpdate(
          localVersion: '2025.10.22',
          remoteTag: '2025.10.22',
          kind: kind,
          storedSourceTag: null,
        ),
        isFalse,
      );
      expect(
        ToolUpdateService.hasUpdate(
          localVersion: '2025.10.22',
          remoteTag: '2025.11.01',
          kind: kind,
          storedSourceTag: null,
        ),
        isTrue,
      );
    });
    test('whisperCli：stored 为 null 不误报 / 有基线且不同报更新', () {
      expect(
        ToolUpdateService.hasUpdate(
          localVersion: null,
          remoteTag: 'v1.8.0',
          kind: MediaToolKind.whisperCli,
          storedSourceTag: null,
        ),
        isFalse,
      );
      expect(
        ToolUpdateService.hasUpdate(
          localVersion: 'ready',
          remoteTag: 'v1.8.0',
          kind: MediaToolKind.whisperCli,
          storedSourceTag: 'v1.7.2',
        ),
        isTrue,
      );
    });
    test('任一参数空 -> false', () {
      const kind = MediaToolKind.ffmpeg;
      expect(
        ToolUpdateService.hasUpdate(
          localVersion: '6.0',
          remoteTag: null,
          kind: kind,
          storedSourceTag: null,
        ),
        isFalse,
      );
      expect(
        ToolUpdateService.hasUpdate(
          localVersion: '',
          remoteTag: 'b7.0',
          kind: kind,
          storedSourceTag: null,
        ),
        isFalse,
      );
    });
  });

  group('whisperTagFromUrl', () {
    test('从 release 直链解析 tag', () {
      expect(
        ToolUpdateService.whisperTagFromUrl(
          'https://github.com/ggml-org/whisper.cpp/releases/download/'
          'v1.7.2/whisper-macos-arm64.tar.gz',
        ),
        'v1.7.2',
      );
    });
    test('URL 无 download 段时返回 null', () {
      expect(
        ToolUpdateService.whisperTagFromUrl('https://example.com/file.tar.gz'),
        isNull,
      );
    });
  });

  group('fetchLatestVersion', () {
    test('成功解析 tag_name（GitHub latest API + Accept 头）', () async {
      String? requestedUrl;
      Options? requestedOptions;
      final svc = ToolUpdateService(
        fetcher: (url, options) async {
          requestedUrl = url;
          requestedOptions = options;
          return Response<dynamic>(
            data: {'tag_name': 'b7.0'},
            requestOptions: RequestOptions(path: url),
          );
        },
      );
      final tag = await svc.fetchLatestVersion(MediaToolKind.ffmpeg);
      expect(tag, 'b7.0');
      expect(
        requestedUrl,
        'https://api.github.com/repos/eugeneware/ffmpeg-static/releases/latest',
      );
      expect(
        requestedOptions?.headers?['Accept'],
        'application/vnd.github+json',
      );
    });
    test('fetcher 抛异常时静默返回 null', () async {
      final svc = ToolUpdateService(
        fetcher: (url, options) async => throw Exception('network down'),
      );
      expect(await svc.fetchLatestVersion(MediaToolKind.ytDlp), isNull);
    });
  });
}
