// lib/services/media/media_import_settings.dart
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'media_downloader.dart';
import 'whisper_model_service.dart';

/// 视频转笔记用户偏好（下载源 / 默认模型档 / 完成后删除源文件）。
class MediaImportSettings {
  static const _kSource = 'media_import_download_source';
  static const _kModel = 'media_import_default_model';
  static const _kDelete = 'media_import_delete_source_after';
  static const _kVerifyCache = 'media_tool_verify_cache';

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
      orElse: () => MediaDownloadSourceMode.auto,
    );
  }

  Future<void> setDownloadSource(MediaDownloadSourceMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSource, mode.name);
  }

  /// null 表示自动推荐。
  Future<WhisperModelTier?> defaultTier() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_kModel);
    if (v == null) return null;
    final matches =
        WhisperModelTier.values.where((t) => t.name == v).toList();
    return matches.isEmpty ? null : matches.first;
  }

  Future<void> setDefaultTier(WhisperModelTier? tier) async {
    final prefs = await SharedPreferences.getInstance();
    if (tier == null) {
      await prefs.remove(_kModel);
    } else {
      await prefs.setString(_kModel, tier.name);
    }
  }

  Future<bool> deleteSourceAfter() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kDelete) ?? true;
  }

  Future<void> setDeleteSourceAfter(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kDelete, v);
  }
}
