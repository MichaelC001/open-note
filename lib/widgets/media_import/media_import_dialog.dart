// lib/widgets/media_import/media_import_dialog.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.g.dart';
import '../../providers/media_import_provider.dart';
import '../../services/media/media_import_service.dart';
import 'confirm_step.dart';
import 'done_step.dart';
import 'env_check_step.dart';
import 'processing_step.dart';
import 'source_step.dart';

class MediaImportDialog extends StatefulWidget {
  final void Function(String noteId)? onOpenNote;
  final Future<String?> Function(MediaImportResult result)? onSaveNote;

  const MediaImportDialog({super.key, this.onOpenNote, this.onSaveNote});

  static Future<void> show(
    BuildContext context, {
    void Function(String)? onOpenNote,
    Future<String?> Function(MediaImportResult)? onSaveNote,
  }) {
    return showDialog(
      context: context,
      builder: (_) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
          child: MediaImportDialog(
            onOpenNote: onOpenNote,
            onSaveNote: onSaveNote,
          ),
        ),
      ),
    );
  }

  @override
  State<MediaImportDialog> createState() => _MediaImportDialogState();
}

class _MediaImportDialogState extends State<MediaImportDialog> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final p = context.read<MediaImportProvider>();
      if (p.step == MediaImportStep.envCheck && !p.operationInProgress) {
        p.checkEnvironment();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) return;
        final p = context.read<MediaImportProvider>();
        if (p.operationInProgress) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(t.media_env_background)),
          );
          return;
        }
        p.cancel();
        p.reset();
      },
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    t.media_import_title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Flexible(
              child: Consumer<MediaImportProvider>(
                builder: (context, p, _) => switch (p.step) {
                  MediaImportStep.source => const SourceStep(),
                  MediaImportStep.envCheck => const EnvCheckStep(),
                  MediaImportStep.confirm => ConfirmStep(
                    saveNote: widget.onSaveNote,
                  ),
                  MediaImportStep.processing => const ProcessingStep(),
                  MediaImportStep.done => DoneStep(
                    onOpenNote: widget.onOpenNote,
                  ),
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
