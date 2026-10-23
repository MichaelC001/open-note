// lib/widgets/settings/video_note_tab.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.g.dart';
import '../../providers/media_import_provider.dart';
import '../../services/media/media_downloader.dart';
import '../../services/media/media_import_settings.dart';
import '../../services/media/media_tool_service.dart';
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
  MediaDownloadSourceMode _source = MediaDownloadSourceMode.auto;
  WhisperModelTier? _tier;
  bool _deleteSource = true;
  bool _loaded = false;
  late final Future<String> _modelsDirFuture =
      widget.modelService.modelsDir();

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
    _tier = await _settings.defaultTier();
    _deleteSource = await _settings.deleteSourceAfter();
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
          ]),
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
                    value: MediaDownloadSourceMode.auto,
                    child: Text(t.media_settings_sourceAuto),
                  ),
                  DropdownMenuItem(
                    value: MediaDownloadSourceMode.direct,
                    child: Text(t.media_settings_sourceDirect),
                  ),
                  DropdownMenuItem(
                    value: MediaDownloadSourceMode.mirror,
                    child: Text(t.media_settings_sourceMirror),
                  ),
                ],
                onChanged: (v) async {
                  if (v == null) return;
                  await _settings.setDownloadSource(v);
                  setState(() => _source = v);
                },
              ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(t.media_settings_defaultModel),
              trailing: DropdownButton<WhisperModelTier?>(
                value: _tier,
                items: [
                  DropdownMenuItem(
                    child: Text(t.media_settings_defaultModelAuto),
                  ),
                  for (final tier in WhisperModelTier.values)
                    DropdownMenuItem(
                      value: tier,
                      child: Text(
                        WhisperModelService.infoFor(tier).displayLabel,
                      ),
                    ),
                ],
                onChanged: (v) async {
                  await _settings.setDefaultTier(v);
                  setState(() => _tier = v);
                },
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(t.media_settings_deleteSource),
              value: _deleteSource,
              activeThumbColor: DesignTokens.primary500,
              onChanged: (v) async {
                await _settings.setDeleteSourceAfter(v);
                setState(() => _deleteSource = v);
              },
            ),
          ]),
        ],
      ),
    );
  }

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
      uninstalling: p.toolUninstalling[kind] ?? false,
      systemHint: (st?.ready ?? false) &&
              st?.source == MediaToolSource.systemPath &&
              !canUninstall
          ? t.media_env_useManager
          : null,
      guide: installGuides[kind]![platformKey]!,
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

  Widget _card(bool isDark, List<Widget> children) => Container(
        padding: const EdgeInsets.all(16),
        width: double.infinity,
        decoration: BoxDecoration(
          color: isDark ? DesignTokens.darkSurface : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isDark ? DesignTokens.darkBorder : DesignTokens.gray200,
            width: 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      );
}
