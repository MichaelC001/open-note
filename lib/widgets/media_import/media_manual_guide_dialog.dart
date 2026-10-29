// lib/widgets/media_import/media_manual_guide_dialog.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/strings.g.dart';
import '../../services/media/media_tool_service.dart';

/// 手动安装指引对话框：内容可选中复制，关键段带独立复制按钮。
/// 仅 whisperCli+Windows 追加下载页/目标目录/放置说明三段。
class MediaManualGuideDialog extends StatelessWidget {
  final MediaToolKind kind;
  final String guide;
  final MediaToolService? toolService;

  const MediaManualGuideDialog({
    super.key,
    required this.kind,
    required this.guide,
    this.toolService,
  });

  static Future<void> show(
    BuildContext context, {
    required MediaToolKind kind,
    required String guide,
    MediaToolService? toolService,
  }) =>
      showDialog<void>(
        context: context,
        builder: (_) => MediaManualGuideDialog(
          kind: kind,
          guide: guide,
          toolService: toolService,
        ),
      );

  static const _whisperReleasesUrl =
      'https://github.com/ggml-org/whisper.cpp/releases';
  static const _whisperMirrorUrl =
      'https://gh-proxy.com/https://github.com/ggml-org/whisper.cpp/releases';

  void _copy(BuildContext context, String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(Translations.of(context).media_env_copied)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final isWindowsWhisper = kind == MediaToolKind.whisperCli &&
        Theme.of(context).platform == TargetPlatform.windows;
    const mono = TextStyle(fontFamily: 'monospace', fontSize: 12);
    return AlertDialog(
      title: Text(t.media_guide_title),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: SelectionArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _copyableRow(context, Text(guide, style: mono)),
                if (isWindowsWhisper) ...[
                  const SizedBox(height: 16),
                  Text(
                    t.media_guide_stepDownload,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  _copyableRow(
                      context, const Text(_whisperReleasesUrl, style: mono)),
                  _copyableRow(
                      context, const Text(_whisperMirrorUrl, style: mono)),
                  const SizedBox(height: 16),
                  Text(
                    t.media_guide_stepPlace,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    t.media_guide_targetDir,
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  _targetDirRow(context, mono),
                  const SizedBox(height: 16),
                  Text(t.media_guide_stepRefresh,
                      style: const TextStyle(fontSize: 13)),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.common_close),
        ),
      ],
    );
  }

  Widget _copyableRow(BuildContext context, Widget child) {
    final t = Translations.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: child),
        IconButton(
          icon: const Icon(Icons.copy, size: 16),
          tooltip: t.media_guide_copy,
          onPressed: () => _copy(context, _childText(child)),
        ),
      ],
    );
  }

  static String _childText(Widget child) =>
      child is Text ? (child.data ?? '') : '';

  Widget _targetDirRow(BuildContext context, TextStyle mono) {
    final t = Translations.of(context);
    return FutureBuilder<String>(
      future: toolService?.toolDir(kind),
      builder: (context, snap) {
        final dir = snap.data;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                dir ?? t.media_guide_dirFailed,
                style: mono.copyWith(
                  color:
                      dir == null ? Theme.of(context).colorScheme.error : null,
                ),
              ),
            ),
            if (dir != null)
              IconButton(
                icon: const Icon(Icons.copy, size: 16),
                tooltip: t.media_guide_copy,
                onPressed: () => _copy(context, dir),
              ),
          ],
        );
      },
    );
  }
}
