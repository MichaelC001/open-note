// lib/widgets/media_import/env_check_step.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.g.dart';
import '../../providers/media_import_provider.dart';
import '../../services/media/download_stats.dart';
import '../../services/media/media_tool_service.dart';
import '../../services/media/whisper_model_service.dart';
import '../../theme/design_tokens.dart';

class EnvCheckStep extends StatelessWidget {
  const EnvCheckStep({super.key});

  static const _installGuides = {
    MediaToolKind.ffmpeg: {
      'macos': 'brew install ffmpeg',
      'windows': 'winget install ffmpeg',
      'linux': 'sudo apt install ffmpeg',
    },
    MediaToolKind.ytDlp: {
      'macos': 'brew install yt-dlp',
      'windows': 'winget install yt-dlp.yt-dlp',
      'linux': 'python3 -m pip install -U yt-dlp',
    },
    MediaToolKind.whisperCli: {
      'macos': 'brew install whisper-cpp',
      'windows': 'winget install ggml.whisper-cpp',
      'linux': 'sudo apt install whisper-cpp || 见 whisper.cpp 仓库源码编译指引',
    },
  };

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final p = context.watch<MediaImportProvider>();
    final platformKey = Theme.of(context).platform == TargetPlatform.windows
        ? 'windows'
        : Theme.of(context).platform == TargetPlatform.linux
        ? 'linux'
        : 'macos';
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
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
                onPressed: p.busy
                    ? null
                    : () => context
                          .read<MediaImportProvider>()
                          .checkEnvironment(),
              ),
            ],
          ),
          if (p.errorMessage != null)
            _ErrorBanner(message: p.errorMessage!, detail: p.errorDetail),
          for (final kind in MediaToolKind.values.where(p.isToolRequired))
            _ToolTile(
              kind: kind,
              status: p.toolStatuses[kind],
              downloading: p.toolDownloading[kind] ?? false,
              finishing: p.toolFinishing[kind] ?? false,
              downloadStatus: p.toolDownloadStatus[kind],
              autoInstalling: p.toolInstalling[kind] ?? false,
              guide: _installGuides[kind]![platformKey]!,
              onAutoInstall: _ToolTile.canAutoInstall(kind, platformKey)
                  ? () => context.read<MediaImportProvider>().autoInstallTool(
                      kind,
                    )
                  : null,
            ),
          const Divider(height: 24),
          const _ModelSection(),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: p.environmentReady ? () => _goConfirm(context) : null,
            child: Text(t.media_confirm_next),
          ),
        ],
      ),
    );
  }

  void _goConfirm(BuildContext context) {
    context.read<MediaImportProvider>().gotoConfirm();
  }
}

class _ToolTile extends StatelessWidget {
  final MediaToolKind kind;
  final MediaToolStatus? status;
  final bool downloading;
  final bool finishing;
  final DownloadStatus? downloadStatus;
  final bool autoInstalling;
  final String guide;
  final VoidCallback? onAutoInstall;

  const _ToolTile({
    required this.kind,
    required this.status,
    required this.downloading,
    required this.finishing,
    this.downloadStatus,
    required this.autoInstalling,
    required this.guide,
    this.onAutoInstall,
  });

  static bool canAutoInstall(MediaToolKind kind, String platformKey) =>
      kind == MediaToolKind.whisperCli &&
      (platformKey == 'macos' || platformKey == 'windows');

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final ready = status?.ready ?? false;
    // whisper.cpp 官方 Release 无 macOS CLI 资产，隐藏应用内下载，仅保留指引
    final hideDownload =
        kind == MediaToolKind.whisperCli &&
        Theme.of(context).platform == TargetPlatform.macOS;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        ready ? Icons.check_circle : Icons.error_outline,
        color: ready ? Colors.green : Colors.orange,
      ),
      title: Text(switch (kind) {
        MediaToolKind.ffmpeg => 'ffmpeg',
        MediaToolKind.ytDlp => 'yt-dlp',
        MediaToolKind.whisperCli => 'whisper.cpp',
      }),
      subtitle: finishing
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text(t.media_env_finishing),
              ],
            )
          : downloading
          ? _DownloadProgressText(
              status: downloadStatus ?? const DownloadStatus(),
            )
          : Text(
              ready
                  ? '${t.media_env_ready} · v${status!.version ?? ''}'
                  : t.media_env_missing,
            ),
      trailing: ready || downloading
          ? null
          : autoInstalling
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text(t.media_env_installing),
              ],
            )
          : downloading
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (onAutoInstall != null)
                  TextButton(
                    onPressed: onAutoInstall,
                    child: Text(t.media_env_autoInstall),
                  ),
                if (!hideDownload)
                  TextButton(
                    onPressed: () =>
                        context.read<MediaImportProvider>().downloadTool(kind),
                    child: Text(t.media_env_download),
                  ),
                IconButton(
                  icon: const Icon(Icons.help_outline),
                  tooltip: guide,
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: guide));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          Translations.of(context).media_env_copied,
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
    );
  }
}

class _ModelSection extends StatelessWidget {
  const _ModelSection();

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
                    _DownloadProgressText(status: downloadStatus)
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
              const Icon(
                Icons.check_circle,
                size: 18,
                color: Colors.green,
              ),
          ],
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  final String? detail;

  const _ErrorBanner({required this.message, this.detail});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.red.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$message${detail == null ? '' : '\n$detail'}',
        style: const TextStyle(fontSize: 12, color: Colors.red),
      ),
    );
  }
}

class _DownloadProgressText extends StatelessWidget {
  final DownloadStatus status;

  const _DownloadProgressText({required this.status});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final pct = (status.progress * 100).toStringAsFixed(0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(value: status.progress),
        ),
        const SizedBox(height: 4),
        Text(
          '$pct% · ${formatBytesRate(status.speedBps)} · '
          '${t.media_dl_eta(time: formatEtaClock(status.etaSeconds))}',
          style: const TextStyle(fontSize: 11),
        ),
      ],
    );
  }
}
