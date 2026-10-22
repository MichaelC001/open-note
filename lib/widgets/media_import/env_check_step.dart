// lib/widgets/media_import/env_check_step.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.g.dart';
import '../../providers/media_import_provider.dart';
import '../../services/media/media_tool_service.dart';
import '../../services/media/whisper_model_service.dart';

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
              progress: p.toolProgress[kind] ?? 0,
              guide: _installGuides[kind]![platformKey]!,
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
  final double progress;
  final String guide;

  const _ToolTile({
    required this.kind,
    required this.status,
    required this.downloading,
    required this.progress,
    required this.guide,
  });

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
      subtitle: Text(
        ready
            ? '${t.media_env_ready} · v${status!.version ?? ''}'
            : t.media_env_missing,
      ),
      trailing: ready
          ? null
          : downloading
          ? SizedBox(
              width: 120,
              child: LinearProgressIndicator(value: progress),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
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
    final hasModel = p.downloadedTiers.contains(p.selectedTier);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        hasModel ? Icons.check_circle : Icons.download_outlined,
        color: hasModel ? Colors.green : Colors.orange,
      ),
      title: Text(
        '${t.media_env_model} · ${WhisperModelService.infoFor(p.selectedTier).displayLabel}',
      ),
      subtitle: p.modelDownloading
          ? LinearProgressIndicator(value: p.modelProgress)
          : Text(
              hasModel
                  ? t.media_env_ready
                  : '~${(WhisperModelService.infoFor(p.selectedTier).downloadSizeBytes / 1024 / 1024).round()} MB',
            ),
      trailing: hasModel || p.modelDownloading
          ? null
          : TextButton(
              onPressed: () =>
                  context.read<MediaImportProvider>().downloadSelectedModel(),
              child: Text(t.media_env_downloadModel),
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
