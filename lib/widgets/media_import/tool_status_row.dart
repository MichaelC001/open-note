// lib/widgets/media_import/tool_status_row.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/strings.g.dart';
import '../../services/media/download_stats.dart';
import '../../services/media/media_tool_service.dart';
import '../../theme/design_tokens.dart';

const Map<MediaToolKind, Map<String, String>> installGuides = {
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

class ErrorBanner extends StatelessWidget {
  final String message;
  final String? detail;

  const ErrorBanner({super.key, required this.message, this.detail});

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

class DownloadProgressText extends StatelessWidget {
  final DownloadStatus status;

  const DownloadProgressText({super.key, required this.status});

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

class ToolStatusRow extends StatelessWidget {
  final MediaToolKind kind;
  final MediaToolStatus? status;
  final bool downloading;
  final bool finishing;
  final DownloadStatus? downloadStatus;
  final bool autoInstalling;
  final bool uninstalling;
  final String? systemHint;
  final String guide;
  final VoidCallback? onAutoInstall;
  final VoidCallback? onDownload;
  final VoidCallback? onUninstall;

  const ToolStatusRow({
    super.key,
    required this.kind,
    required this.status,
    required this.downloading,
    required this.finishing,
    this.downloadStatus,
    required this.autoInstalling,
    this.uninstalling = false,
    this.systemHint,
    required this.guide,
    this.onAutoInstall,
    this.onDownload,
    this.onUninstall,
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
          ? DownloadProgressText(
              status: downloadStatus ?? const DownloadStatus(),
            )
          : ready
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${t.media_env_ready} · v${status!.version ?? ''}'),
                if (systemHint != null)
                  Text(
                    systemHint!,
                    style: const TextStyle(
                      fontSize: 11,
                      color: DesignTokens.gray500,
                    ),
                  ),
              ],
            )
          : Text(t.media_env_missing),
      trailing: uninstalling
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : downloading
          ? null
          : ready
          ? onUninstall != null
                ? IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: t.media_env_uninstall,
                    onPressed: onUninstall,
                  )
                : null
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
                    onPressed: onDownload,
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
                if (onUninstall != null)
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: t.media_env_uninstall,
                    onPressed: onUninstall,
                  ),
              ],
            ),
    );
  }
}
