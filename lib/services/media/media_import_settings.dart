// lib/services/media/media_import_settings.dart
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'media_downloader.dart';

/// 视频转笔记用户偏好（下载源 / 完成后删除源文件）。
class MediaImportSettings {
  static const _kSource = 'media_import_download_source';
  static const _kDelete = 'media_import_delete_source_after';
  static const _kVerifyCache = 'media_tool_verify_cache';
  static const _kLastUpdateCheckAt = 'media_tool_last_update_check_at';
  static const _kWhisperSourceTag = 'media_tool_whisper_cli_source_tag';

  /// 工具验证缓存（kind -> JSON 条目），避免每次检测 spawn 慢二进制。
  Future<Map<String, String>> readVerifyCache() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kVerifyCache);
    if (raw == null) return {};
    try {
      return Map<String, String>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  Future<void> writeVerifyCache(Map<String, String> cache) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kVerifyCache, jsonEncode(cache));
  }

  Future<MediaDownloadSourceMode> downloadSource() async {
    final prefs = await SharedPreferences.getInstance();
    return MediaDownloadSourceMode.values.firstWhere(
      (m) => m.name == prefs.getString(_kSource),
      orElse: () => MediaDownloadSourceMode.mirror,
    );
  }

  Future<void> setDownloadSource(MediaDownloadSourceMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSource, mode.name);
  }

  Future<bool> deleteSourceAfter() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kDelete) ?? true;
  }

  Future<void> setDeleteSourceAfter(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kDelete, v);
  }

  /// 上次工具新版本检查时间（毫秒时间戳），用于 24h 节流。
  Future<DateTime?> lastUpdateCheckAt() async {
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt(_kLastUpdateCheckAt);
    if (ms == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }

  Future<void> setLastUpdateCheckAt(DateTime t) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kLastUpdateCheckAt, t.millisecondsSinceEpoch);
  }

  /// whisper-cli 安装包来源 release tag（作为版本比较基线；null 表示无基线）。
  Future<String?> whisperCliSourceTag() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kWhisperSourceTag);
  }

  Future<void> setWhisperCliSourceTag(String? tag) async {
    final prefs = await SharedPreferences.getInstance();
    if (tag == null || tag.isEmpty) {
      await prefs.remove(_kWhisperSourceTag);
    } else {
      await prefs.setString(_kWhisperSourceTag, tag);
    }
  }
}
