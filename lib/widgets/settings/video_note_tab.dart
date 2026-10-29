// lib/widgets/settings/video_note_tab.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.g.dart';
import '../../providers/media_import_provider.dart';
import '../../services/media/media_downloader.dart';
import '../../services/media/media_import_settings.dart';
import '../../services/media/media_tool_service.dart';
import '../../services/media/transcript_formatter.dart';
import '../../services/media/whisper_model_service.dart';
import '../../theme/design_tokens.dart';
import '../media_import/model_list.dart';
import '../media_import/tool_status_row.dart';

class VideoNoteTab extends StatefulWidget {
  final WhisperModelService modelService;

  VideoNoteTab({super.key, WhisperModelService? modelService})
      : modelService = modelService ?? WhisperModelService();

  @override
  State<VideoNoteTab> createState() => _VideoNoteTabState();
}

class _VideoNoteTabState extends State<VideoNoteTab> {
  final MediaImportSettings _settings = MediaImportSettings();
  MediaDownloadSourceMode _source = MediaDownloadSourceMode.mirror;
  bool _deleteSource = true;
  bool _includeTimestamps = false;
  ContentPolishLevel _polish = ContentPolishLevel.structured;
  bool _loaded = false;
  late final Future<String> _modelsDirFuture =
      widget.modelService.modelsDir();
  // 源媒体目录基路径缓存一次；子目录随「完成后删除源媒体」开关动态切换：
  // 开=随任务删除（media_import_tmp），关=保留副本（media_import_media）
  late final Future<String> _sourceMediaBaseDirFuture =
      widget.modelService.resolveBaseDir();

  @override
  void initState() {
    super.initState();
    _load();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final p = context.read<MediaImportProvider>();
      final busyNow = p.operationInProgress;
      if (!busyNow) p.checkEnvironment();
    });
  }

  Future<void> _load() async {
    _source = await _settings.downloadSource();
    _deleteSource = await _settings.deleteSourceAfter();
    _includeTimestamps = await _settings.includeTimestamps();
    _polish = await _settings.polishLevel();
    _loaded = true;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox.shrink();
    final t = Translations.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final p = context.watch<MediaImportProvider>();
    final platformKey = Theme.of(context).platform == TargetPlatform.windows
        ? 'windows'
        : Theme.of(context).platform == TargetPlatform.linux
            ? 'linux'
            : 'macos';
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          _card(isDark, [
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(
                  icon: p.operationInProgress
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                  tooltip: t.media_env_recheck,
                  onPressed: p.operationInProgress
                      ? null
                      : () => p.checkEnvironment(forceVerify: true),
                ),
              ],
            ),
            if (p.errorMessage != null)
              ErrorBanner(message: p.errorMessage!, detail: p.errorDetail),
            Text(
              t.media_env_engines,
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            for (final kind in MediaToolKind.values)
              _toolRow(context, p, t, platformKey, kind),
            const Divider(height: 24),
            ModelList(onDelete: (tier) => _confirmDeleteModel(context, p, tier)),
            const SizedBox(height: 8),
            FutureBuilder<String>(
              future: _modelsDirFuture,
              builder: (context, snap) {
                final dir = snap.data ?? '';
                return Row(children: [
                  const Icon(Icons.folder_open,
                      size: 16, color: DesignTokens.gray500),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(dir,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 11, color: DesignTokens.gray500)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy, size: 16),
                    tooltip: t.media_settings_copyPath,
                    onPressed: dir.isEmpty
                        ? null
                        : () {
                            Clipboard.setData(ClipboardData(text: dir));
                            ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(t.media_env_copied)));
                          },
                  ),
                ]);
              },
            ),
          ],
              ribbonAsset: isDark
                  ? 'assets/svg/engine-ribbon-dark.svg'
                  : 'assets/svg/engine-ribbon-light.svg',
            ),
          const SizedBox(height: 16),
          _card(isDark, [
            Text(
              t.media_settings_title,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: isDark
                    ? DesignTokens.darkTextPrimary
                    : DesignTokens.gray900,
              ),
            ),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(t.media_settings_source),
              trailing: DropdownButton<MediaDownloadSourceMode>(
                value: _source,
                items: [
                  DropdownMenuItem(
                    value: MediaDownloadSourceMode.mirror,
                    child: Text(t.media_settings_sourceMirror),
                  ),
                  DropdownMenuItem(
                    value: MediaDownloadSourceMode.auto,
                    child: Text(t.media_settings_sourceAuto),
                  ),
                  DropdownMenuItem(
                    value: MediaDownloadSourceMode.direct,
                    child: Text(t.media_settings_sourceDirect),
                  ),
                ],
                onChanged: (v) async {
                  if (v == null) return;
                  await _settings.setDownloadSource(v);
                  setState(() => _source = v);
                },
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(t.media_settings_deleteSource),
              value: _deleteSource,
              activeThumbColor: DesignTokens.primary500,
              // Material3 暗色下默认拨杆色与轨道同色系不可见：off 白拨杆在灰轨道、
              // on 白拨杆在 primary 轨道均可见（thumbColor 优先于 activeThumbColor 解析）
              thumbColor: const WidgetStatePropertyAll(Colors.white),
              onChanged: (v) async {
                await _settings.setDeleteSourceAfter(v);
                setState(() => _deleteSource = v);
              },
            ),
            FutureBuilder<String>(
              future: _sourceMediaBaseDirFuture,
              builder: (context, snap) {
                final base = snap.data ?? '';
                final dir = base.isEmpty
                    ? ''
                    : '$base/'
                        '${_deleteSource ? 'media_import_tmp' : 'media_import_media'}';
                return Row(children: [
                  const Icon(Icons.folder_open,
                      size: 16, color: DesignTokens.gray500),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(dir,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 11, color: DesignTokens.gray500)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy, size: 16),
                    tooltip: t.media_settings_copyPath,
                    onPressed: dir.isEmpty
                        ? null
                        : () {
                            Clipboard.setData(ClipboardData(text: dir));
                            ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                    content: Text(t.media_env_copied)));
                          },
                  ),
                ]);
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(t.media_settings_timestamps),
              value: _includeTimestamps,
              activeThumbColor: DesignTokens.primary500,
              thumbColor: const WidgetStatePropertyAll(Colors.white),
              onChanged: (v) async {
                await _settings.setIncludeTimestamps(v);
                setState(() => _includeTimestamps = v);
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(t.media_settings_polish),
              trailing: Text(
                _polishLabel(t),
                style: const TextStyle(
                    fontSize: 12, color: DesignTokens.gray500),
              ),
              subtitle: Slider(
                value: _polish.index.toDouble(),
                min: 0,
                max: 2,
                divisions: 2,
                label: _polishLabel(t),
                activeColor: DesignTokens.primary500,
                onChanged: (v) async {
                  final level =
                      ContentPolishLevel.values[v.round().clamp(0, 2)];
                  await _settings.setPolishLevel(level);
                  setState(() => _polish = level);
                },
              ),
            ),
            Text(
              _polishDesc(t),
              style: const TextStyle(
                  fontSize: 11, color: DesignTokens.gray500),
            ),
          ]),
        ],
      ),
    );
  }

  String _polishLabel(Translations t) => switch (_polish) {
        ContentPolishLevel.raw => t.media_polish_raw,
        ContentPolishLevel.structured => t.media_polish_structured,
        ContentPolishLevel.organized => t.media_polish_organized,
      };

  String _polishDesc(Translations t) => switch (_polish) {
        ContentPolishLevel.raw => t.media_polish_desc_raw,
        ContentPolishLevel.structured => t.media_polish_desc_structured,
        ContentPolishLevel.organized => t.media_polish_desc_organized,
      };

  Widget _toolRow(BuildContext context, MediaImportProvider p, Translations t,
      String platformKey, MediaToolKind kind) {
    final st = p.toolStatuses[kind];
    final canUninstall = _uninstallable(context, p, kind);
    return ToolStatusRow(
      kind: kind,
      status: st,
      downloading: p.toolDownloading[kind] ?? false,
      finishing: p.toolFinishing[kind] ?? false,
      downloadStatus: p.toolDownloadStatus[kind],
      autoInstalling: p.toolInstalling[kind] ?? false,
      updateVersion: p.updateAvailableVersion[kind],
      checkingUpdate: p.updateChecking[kind] ?? false,
      uninstalling: p.toolUninstalling[kind] ?? false,
      systemHint: p.toolHints[kind] ??
          ((st?.ready ?? false) &&
                  st?.source == MediaToolSource.systemPath &&
                  !canUninstall
              ? t.media_env_useManager
              : null),
      guide: installGuides[kind]![platformKey]!,
      toolService: p.toolService,
      onAutoInstall: ToolStatusRow.canAutoInstall(kind, platformKey)
          ? () => p.autoInstallTool(kind)
          : null,
      onDownload: () => p.downloadTool(kind),
      onUninstall:
          canUninstall ? () => _confirmUninstall(context, p, kind) : null,
    );
  }

  bool _uninstallable(BuildContext context, MediaImportProvider p,
      MediaToolKind kind) {
    final st = p.toolStatuses[kind];
    if (st == null || !st.ready) return false;
    if (st.source == MediaToolSource.appManaged) return true;
    return Theme.of(context).platform == TargetPlatform.macOS ||
        (Theme.of(context).platform == TargetPlatform.windows &&
            kind == MediaToolKind.whisperCli);
  }

  Future<void> _confirmUninstall(
      BuildContext context, MediaImportProvider p, MediaToolKind kind) async {
    final t = Translations.of(context);
    final name = switch (kind) {
      MediaToolKind.ffmpeg => 'ffmpeg',
      MediaToolKind.ytDlp => 'yt-dlp',
      MediaToolKind.whisperCli => 'whisper.cpp',
    };
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.media_env_uninstallConfirmTitle(name: name)),
        content: Text(t.media_env_uninstallConfirmBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.common_cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.media_env_uninstall)),
        ],
      ),
    );
    if (ok == true) await p.uninstallTool(kind);
  }

  Future<void> _confirmDeleteModel(
      BuildContext context, MediaImportProvider p, WhisperModelTier tier) async {
    final t = Translations.of(context);
    final label = WhisperModelService.infoFor(tier).displayLabel;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.media_env_modelDeleteConfirmTitle(name: label)),
        content: Text(t.media_env_modelDeleteConfirmBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.common_cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.common_delete)),
        ],
      ),
    );
    if (ok == true) await p.deleteModel(tier);
  }

  Widget _card(bool isDark, List<Widget> children, {String? ribbonAsset}) {
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
    return Container(
      clipBehavior: Clip.antiAlias,
      width: double.infinity,
      decoration: BoxDecoration(
        color: isDark ? DesignTokens.darkSurface : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? DesignTokens.darkBorder : DesignTokens.gray200,
          width: 1,
        ),
      ),
      // ribbonAsset：顶部主题装饰图，顶满卡片宽度、贴卡片顶边（y=0），
      // 圆角由容器 Clip.antiAlias 裁剪；内容层 Padding(16) 浮上
      child: ribbonAsset == null
          ? Padding(
              padding: const EdgeInsets.all(16),
              child: content,
            )
          : Stack(
              children: [
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: SvgPicture.asset(ribbonAsset, fit: BoxFit.fitWidth),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: content,
                ),
              ],
            ),
    );
  }
}
