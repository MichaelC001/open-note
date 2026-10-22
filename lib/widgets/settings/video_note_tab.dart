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

  @override
  void initState() {
    super.initState();
    _load();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final p = context.read<MediaImportProvider>();
      final busyNow = p.busy ||
          p.toolDownloading.values.any((v) => v) ||
          p.modelDownloading;
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
                  icon: p.busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                  tooltip: t.media_env_recheck,
                  onPressed:
                      p.busy ? null : () => p.checkEnvironment(),
                ),
              ],
            ),
            if (p.errorMessage != null)
              ErrorBanner(message: p.errorMessage!, detail: p.errorDetail),
            for (final kind in MediaToolKind.values)
              ToolStatusRow(
                kind: kind,
                status: p.toolStatuses[kind],
                downloading: p.toolDownloading[kind] ?? false,
                finishing: p.toolFinishing[kind] ?? false,
                downloadStatus: p.toolDownloadStatus[kind],
                autoInstalling: p.toolInstalling[kind] ?? false,
                guide: installGuides[kind]![platformKey]!,
                onAutoInstall: ToolStatusRow.canAutoInstall(kind, platformKey)
                    ? () => p.autoInstallTool(kind)
                    : null,
                onDownload: () => p.downloadTool(kind),
              ),
            const Divider(height: 24),
            const ModelList(),
            const SizedBox(height: 8),
            FutureBuilder<String>(
              future: widget.modelService.modelsDir(),
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
