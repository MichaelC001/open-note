// lib/widgets/settings/video_note_tab.dart
import 'package:flutter/material.dart';

import '../../l10n/strings.g.dart';
import '../../services/media/media_downloader.dart';
import '../../services/media/media_import_settings.dart';
import '../../services/media/whisper_model_service.dart';
import '../../theme/design_tokens.dart';

class VideoNoteTab extends StatefulWidget {
  const VideoNoteTab({super.key});

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
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: SizedBox(
        width: double.infinity,
        child: Container(
          padding: const EdgeInsets.all(16),
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
            children: [
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
            ],
          ),
        ),
      ),
    );
  }
}
