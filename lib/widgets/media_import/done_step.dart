// lib/widgets/media_import/done_step.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.g.dart';
import '../../providers/media_import_provider.dart';
import '../../services/media/transcript_formatter.dart';

class DoneStep extends StatelessWidget {
  final void Function(String noteId)? onOpenNote;

  const DoneStep({super.key, this.onOpenNote});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final p = context.watch<MediaImportProvider>();
    final r = p.result;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.check_circle, size: 48, color: Colors.green),
        const SizedBox(height: 12),
        Center(child: Text(r?.title ?? '')),
        // raw 档本就不调用 AI，无「未完成」可言；structured/organized 档
        // AI 失败走兜底原文时仍需提示
        if (r?.formattedByAI == false &&
            p.donePolishLevel != ContentPolishLevel.raw)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Center(
              child: Text(t.media_done_fallback,
                  style: const TextStyle(fontSize: 12, color: Colors.orange)),
            ),
          ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: p.resultNoteId == null || onOpenNote == null
              ? null
              : () => onOpenNote!(p.resultNoteId!),
          child: Text(t.media_done_open),
        ),
        TextButton(
          onPressed: () => context.read<MediaImportProvider>().reset(),
          child: Text(t.media_done_again),
        ),
      ],
    );
  }
}
