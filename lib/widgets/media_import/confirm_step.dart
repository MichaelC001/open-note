// lib/widgets/media_import/confirm_step.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.g.dart';
import '../../providers/media_import_provider.dart';
import '../../services/media/media_import_service.dart';
import '../../services/media/whisper_model_service.dart';

class ConfirmStep extends StatefulWidget {
  final Future<String?> Function(MediaImportResult result)? saveNote;

  const ConfirmStep({super.key, this.saveNote});

  @override
  State<ConfirmStep> createState() => _ConfirmStepState();
}

class _ConfirmStepState extends State<ConfirmStep> {
  String _language = 'auto';

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final p = context.watch<MediaImportProvider>();
    final info = WhisperModelService.infoFor(p.selectedTier);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(t.media_confirm_model),
          subtitle: Text(
              '${info.displayLabel}（推荐 ${WhisperModelService.infoFor(p.recommendedTier).displayLabel}）'),
          trailing: DropdownButton<WhisperModelTier>(
            value: p.selectedTier,
            items: [
              for (final tier in WhisperModelTier.values)
                DropdownMenuItem(
                  value: tier,
                  child: Text(WhisperModelService.infoFor(tier).displayLabel),
                ),
            ],
            onChanged: (v) {
              if (v != null) {
                context.read<MediaImportProvider>().selectTier(v);
              }
            },
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(t.media_confirm_language),
          trailing: DropdownButton<String>(
            value: _language,
            items: [
              DropdownMenuItem(
                  value: 'auto', child: Text(t.media_confirm_auto)),
              const DropdownMenuItem(value: 'zh', child: Text('中文')),
              const DropdownMenuItem(value: 'en', child: Text('English')),
              const DropdownMenuItem(value: 'ja', child: Text('日本語')),
            ],
            onChanged: (v) => setState(() => _language = v ?? 'auto'),
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: p.busy || widget.saveNote == null
              ? null
              : () => context
                  .read<MediaImportProvider>()
                  .startProcessing(
                      language: _language, saveNote: widget.saveNote!),
          icon: const Icon(Icons.play_arrow),
          label: Text(t.media_confirm_start),
        ),
      ],
    );
  }
}
