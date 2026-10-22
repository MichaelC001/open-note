// lib/widgets/media_import/source_step.dart
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.g.dart';
import '../../providers/media_import_provider.dart';

class SourceStep extends StatefulWidget {
  const SourceStep({super.key});

  @override
  State<SourceStep> createState() => _SourceStepState();
}

class _SourceStepState extends State<SourceStep> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
        text: context.read<MediaImportProvider>().urlInput);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _urlValid =>
      RegExp(r'^https?://\S+$').hasMatch(_controller.text.trim());

  static const _mediaExts = [
    'mp4', 'mkv', 'mov', 'avi', 'webm', 'flv', 'm4v', 'ts',
    'mp3', 'm4a', 'wav', 'aac', 'flac', 'ogg', 'opus', 'wma',
  ];

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.any);
    final path = result?.files.single.path;
    if (path == null) return;
    final ext = path.split('.').last.toLowerCase();
    if (!_mediaExts.contains(ext)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text(Translations.of(context).media_source_unsupported)));
      }
      return;
    }
    if (!mounted) return;
    await context.read<MediaImportProvider>().startForFile(File(path));
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _controller,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: t.media_source_urlHint,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _urlValid
              ? () => context
                  .read<MediaImportProvider>()
                  .startForUrl(_controller.text.trim())
              : null,
          icon: const Icon(Icons.link),
          label: Text(t.media_source_url),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _pickFile,
          icon: const Icon(Icons.folder_open),
          label: Text(t.media_source_file),
        ),
      ],
    );
  }
}
