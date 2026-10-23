// lib/widgets/media_import/model_list.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.g.dart';
import '../../providers/media_import_provider.dart';
import '../../services/media/download_stats.dart';
import '../../services/media/whisper_model_service.dart';
import '../../theme/design_tokens.dart';
import 'tool_status_row.dart';

class ModelList extends StatelessWidget {
  final void Function(WhisperModelTier tier)? onDelete;

  const ModelList({super.key, this.onDelete});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final p = context.watch<MediaImportProvider>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t.media_env_model,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        for (final tier in WhisperModelTier.values)
          _ModelTile(
            tier: tier,
            selected: p.selectedTier == tier,
            recommended: p.recommendedTier == tier,
            downloaded: p.downloadedTiers.contains(tier),
            downloadingThis: p.modelDownloading && p.selectedTier == tier,
            downloadStatus: p.modelDownloadStatus,
            enabled: !p.modelDownloading,
            onSelect: () => p.selectTier(tier),
            onDownload: () {
              p.selectTier(tier);
              p.downloadSelectedModel();
            },
            onDelete: onDelete,
          ),
      ],
    );
  }
}

class _ModelTile extends StatelessWidget {
  final WhisperModelTier tier;
  final bool selected;
  final bool recommended;
  final bool downloaded;
  final bool downloadingThis;
  final DownloadStatus downloadStatus;
  final bool enabled;
  final VoidCallback onSelect;
  final VoidCallback onDownload;
  final void Function(WhisperModelTier tier)? onDelete;

  const _ModelTile({
    required this.tier,
    required this.selected,
    required this.recommended,
    required this.downloaded,
    required this.downloadingThis,
    required this.downloadStatus,
    required this.enabled,
    required this.onSelect,
    required this.onDownload,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final label = WhisperModelService.infoFor(tier).displayLabel;
    return InkWell(
      onTap: enabled ? onSelect : null,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 20,
              color: selected
                  ? DesignTokens.primary500
                  : DesignTokens.gray400,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        style: const TextStyle(fontSize: 14),
                      ),
                      if (recommended) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: DesignTokens.primary500.withValues(
                              alpha: 0.1,
                            ),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            t.media_env_recommended,
                            style: const TextStyle(
                              fontSize: 10,
                              color: DesignTokens.primary500,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  if (downloadingThis)
                    DownloadProgressText(status: downloadStatus)
                  else
                    Text(
                      downloaded
                          ? t.media_env_ready
                          : '~${(WhisperModelService.infoFor(tier).downloadSizeBytes / 1024 / 1024).round()} MB',
                      style: const TextStyle(
                        fontSize: 12,
                        color: DesignTokens.gray500,
                      ),
                    ),
                  const SizedBox(height: 2),
                  Text(
                    switch (tier) {
                      WhisperModelTier.base => t.media_tier_desc_base,
                      WhisperModelTier.medium => t.media_tier_desc_medium,
                      WhisperModelTier.largeV3Turbo =>
                        t.media_tier_desc_largeV3Turbo,
                    },
                    style: const TextStyle(
                      fontSize: 11,
                      color: DesignTokens.gray500,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (!downloaded && !downloadingThis)
              TextButton(
                onPressed: enabled ? onDownload : null,
                child: Text(t.media_env_downloadModel),
              )
            else if (downloaded)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (onDelete != null)
                    IconButton(
                      icon: const Icon(Icons.delete_outline, size: 18),
                      tooltip: t.common_delete,
                      onPressed: enabled ? () => onDelete!(tier) : null,
                    ),
                  const Icon(
                    Icons.check_circle,
                    size: 18,
                    color: Colors.green,
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
