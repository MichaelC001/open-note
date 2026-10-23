// lib/services/media/tool_update_service.dart
import 'package:dio/dio.dart';

import 'media_tool_service.dart';

/// 工具静默新版本检查：拉取 GitHub releases/latest 的 tag 并判定是否有更新。
/// 任何网络/解析异常均静默处理（返回 null），绝不影响主流程。
class ToolUpdateService {
  /// 可注入的 HTTP fetcher（默认 Dio().get），便于测试。
  final Future<Response<dynamic>> Function(String, Options)? fetcher;

  ToolUpdateService({this.fetcher});

  static const _latestApi = {
    MediaToolKind.ffmpeg:
        'https://api.github.com/repos/eugeneware/ffmpeg-static/releases/latest',
    MediaToolKind.ytDlp:
        'https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest',
    MediaToolKind.whisperCli:
        'https://api.github.com/repos/ggml-org/whisper.cpp/releases/latest',
  };

  /// 拉取远端最新 tag；任何异常返回 null（静默）。
  Future<String?> fetchLatestVersion(MediaToolKind kind) async {
    try {
      final fetch = fetcher ?? _defaultFetch;
      final resp = await fetch(
        _latestApi[kind]!,
        Options(headers: {'Accept': 'application/vnd.github+json'}),
      );
      final tag = (resp.data as Map?)?['tag_name'];
      if (tag == null) return null;
      final s = tag.toString().trim();
      return s.isEmpty ? null : s;
    } catch (_) {
      return null;
    }
  }

  static Future<Response<dynamic>> _defaultFetch(String url, Options options) {
    return Dio().get<dynamic>(url, options: options);
  }

  /// 归一化 tag：去前缀 b/v/N（大小写不敏感）+ trim。
  /// 'b6.0'->'6.0'，'v1.7.2'->'1.7.2'，'2025.10.22'->原样。
  static String? normalizeTag(String? tag) {
    if (tag == null) return null;
    var t = tag.trim();
    if (t.isEmpty) return null;
    final head = t[0].toLowerCase();
    if (head == 'b' || head == 'v' || head == 'n') {
      t = t.substring(1).trim();
    }
    return t.isEmpty ? null : t;
  }

  /// 版本比较判定（任一参数空 -> false）：
  /// - ytDlp：localVersion 与 remoteTag 直接字符串比较
  /// - ffmpeg：双侧 normalizeTag 后比较
  /// - whisperCli：storedSourceTag vs remoteTag（stored 空 -> false，无基线不误报）
  static bool hasUpdate({
    required String? localVersion,
    required String? remoteTag,
    required MediaToolKind kind,
    required String? storedSourceTag,
  }) {
    if (remoteTag == null || remoteTag.trim().isEmpty) return false;
    switch (kind) {
      case MediaToolKind.ffmpeg:
        final local = normalizeTag(localVersion);
        final remote = normalizeTag(remoteTag);
        if (local == null || local.isEmpty) return false;
        if (remote == null || remote.isEmpty) return false;
        return local != remote;
      case MediaToolKind.ytDlp:
        final local = localVersion?.trim();
        if (local == null || local.isEmpty) return false;
        return local != remoteTag.trim();
      case MediaToolKind.whisperCli:
        final stored = storedSourceTag?.trim();
        if (stored == null || stored.isEmpty) return false;
        return stored != remoteTag.trim();
    }
  }

  /// 从 whisper.cpp release 资产直链解析 tag，URL 形如：
  /// `https://github.com/ggml-org/whisper.cpp/releases/download/{tag}/{asset}`
  static String? whisperTagFromUrl(String url) {
    final m = RegExp(r'/download/([^/]+)/').firstMatch(url);
    if (m == null) return null;
    final tag = m.group(1);
    if (tag == null || tag.isEmpty) return null;
    return tag;
  }
}
