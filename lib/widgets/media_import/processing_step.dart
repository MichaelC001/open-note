// lib/widgets/media_import/processing_step.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.g.dart';
import '../../providers/media_import_provider.dart';
import '../../services/media/media_import_service.dart';

class ProcessingStep extends StatelessWidget {
  const ProcessingStep({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final p = context.watch<MediaImportProvider>();
    final label = switch (p.phase) {
      MediaImportPhase.acquiring => t.media_proc_acquire,
      MediaImportPhase.extractingAudio => t.media_proc_audio,
      MediaImportPhase.transcribing => t.media_proc_transcribe,
      MediaImportPhase.formatting => t.media_proc_format,
      null => t.media_proc_prepare,
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (p.errorMessage != null) ...[
          Icon(Icons.error_outline, size: 48, color: Colors.red.shade400),
          const SizedBox(height: 12),
          Text(p.errorMessage!,
              style: TextStyle(color: Colors.red.shade700)),
          if (p.errorDetail != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SelectionArea(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 160),
                  child: SingleChildScrollView(
                    child: Text(
                      p.errorDetail!,
                      style:
                          const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ),
                ),
              ),
            ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () => context.read<MediaImportProvider>().reset(),
            child: Text(t.media_error_back),
          ),
        ] else ...[
          Text(label, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 20),
          SizedBox(
            width: 220,
            child: p.phaseProgress == null
                ? const LinearProgressIndicator()
                : LinearProgressIndicator(value: p.phaseProgress),
          ),
          if (p.phaseProgress != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('${(p.phaseProgress! * 100).toStringAsFixed(0)}%'),
            ),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: () => context.read<MediaImportProvider>().cancel(),
            icon: const Icon(Icons.stop),
            label: Text(t.media_proc_cancel),
          ),
        ],
      ],
    );
  }
}
