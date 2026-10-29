// lib/widgets/media_import/media_manual_guide_dialog.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/strings.g.dart';
import '../../services/media/media_tool_service.dart';
import '../../services/media/whisper_model_service.dart';

/// 指引段：标题 / 链接列表 / 目标目录 / 说明，四要素均可选。
class GuideSection {
  final String? heading;
  final List<String> links;
  final String? dirLabel;
  final Future<String?>? directory;
  final String? note;

  const GuideSection({
    this.heading,
    this.links = const [],
    this.dirLabel,
    this.directory,
    this.note,
  });
}

/// 手动指引对话框：内容可选中复制，关键段带独立复制按钮。
/// 段列表模型泛化，工具安装与识别模型下载共用同一渲染。
class MediaManualGuideDialog extends StatelessWidget {
  final String title;
  final String? monoBody;
  final List<GuideSection> sections;

  const MediaManualGuideDialog({
    super.key,
    required this.title,
    this.monoBody,
    this.sections = const [],
  });

  static const _whisperReleasesUrl =
      'https://github.com/ggml-org/whisper.cpp/releases';
  static const _whisperMirrorUrl =
      'https://gh-proxy.com/https://github.com/ggml-org/whisper.cpp/releases';

  /// 工具安装指引：首段为安装命令；仅 whisperCli+Windows 追加
  /// 下载页/目标目录/放置说明段。
  static Future<void> show(
    BuildContext context, {
    required MediaToolKind kind,
    required String guide,
    MediaToolService? toolService,
  }) {
    final t = Translations.of(context);
    final isWindowsWhisper = kind == MediaToolKind.whisperCli &&
        Theme.of(context).platform == TargetPlatform.windows;
    return showDialog<void>(
      context: context,
      builder: (_) => MediaManualGuideDialog(
        title: t.media_guide_title,
        monoBody: guide,
        sections: isWindowsWhisper
            ? [
                GuideSection(
                  heading: t.media_guide_stepDownload,
                  links: const [_whisperReleasesUrl, _whisperMirrorUrl],
                ),
                GuideSection(
                  heading: t.media_guide_stepPlace,
                  dirLabel: t.media_guide_targetDir,
                  directory: toolService?.toolDir(kind),
                  note: t.media_guide_stepRefresh,
                ),
              ]
            : const [],
      ),
    );
  }

  /// 识别模型手动下载指引：镜像/官方直链 + 目标目录 + 放置说明。
  static Future<void> showModel(
    BuildContext context, {
    required WhisperModelTier tier,
    WhisperModelService? modelService,
  }) {
    final t = Translations.of(context);
    final info = WhisperModelService.infoFor(tier);
    return showDialog<void>(
      context: context,
      builder: (_) => MediaManualGuideDialog(
        title: t.media_model_guide_title,
        sections: [
          GuideSection(
            heading: t.media_model_guide_stepDownload,
            links: [
              WhisperModelService.modelUrl(info, mirror: true).toString(),
              WhisperModelService.modelUrl(info, mirror: false).toString(),
            ],
          ),
          GuideSection(
            dirLabel: t.media_guide_targetDir,
            directory: modelService?.modelsDir(),
            note: t.media_model_guide_stepPlace,
          ),
        ],
      ),
    );
  }

  void _copy(BuildContext context, String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(Translations.of(context).media_env_copied)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    const mono = TextStyle(fontFamily: 'monospace', fontSize: 12);
    return AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: SelectionArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (monoBody != null) ...[
                  _copyableRow(context, Text(monoBody!, style: mono)),
                  const SizedBox(height: 16),
                ],
                for (final (i, section) in sections.indexed) ...[
                  if (i > 0) const SizedBox(height: 16),
                  if (section.heading != null) ...[
                    Text(
                      section.heading!,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                  ],
                  for (final link in section.links)
                    _copyableRow(context, Text(link, style: mono)),
                  if (section.dirLabel != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      section.dirLabel!,
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                  ],
                  if (section.directory != null)
                    _targetDirRow(context, section.directory!, mono),
                  if (section.note != null) ...[
                    const SizedBox(height: 16),
                    Text(section.note!,
                        style: const TextStyle(fontSize: 13)),
                  ],
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

  Widget _targetDirRow(
      BuildContext context, Future<String?> future, TextStyle mono) {
    final t = Translations.of(context);
    return FutureBuilder<String?>(
      future: future,
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
