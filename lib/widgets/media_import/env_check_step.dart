// lib/widgets/media_import/env_check_step.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.g.dart';
import '../../providers/media_import_provider.dart';
import '../../services/media/media_tool_service.dart';
import 'model_list.dart';
import 'tool_status_row.dart';

class EnvCheckStep extends StatelessWidget {
  const EnvCheckStep({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final p = context.watch<MediaImportProvider>();
    final platformKey = Theme.of(context).platform == TargetPlatform.windows
        ? 'windows'
        : Theme.of(context).platform == TargetPlatform.linux
        ? 'linux'
        : 'macos';
    // 「下一步」固定底部：内容放 Expanded+滚动区，按钮不被滚出视口
    //（外层 dialog 的 maxHeight 640 / Scaffold body 均有界，Expanded 可用）
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
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
                                .checkEnvironment(forceVerify: true),
                    ),
                  ],
                ),
                if (p.errorMessage != null)
                  ErrorBanner(message: p.errorMessage!, detail: p.errorDetail),
                Text(
                  t.media_env_engines,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                for (final kind in MediaToolKind.values.where(p.isToolRequired))
                  ToolStatusRow(
                    kind: kind,
                    status: p.toolStatuses[kind],
                    downloading: p.toolDownloading[kind] ?? false,
                    finishing: p.toolFinishing[kind] ?? false,
                    downloadStatus: p.toolDownloadStatus[kind],
                    autoInstalling: p.toolInstalling[kind] ?? false,
                    updateVersion: p.updateAvailableVersion[kind],
                    checkingUpdate: p.updateChecking[kind] ?? false,
                    systemHint: p.toolHints[kind],
                    guide: installGuides[kind]![platformKey]!,
                    toolService: p.toolService,
                    onAutoInstall: ToolStatusRow.canAutoInstall(kind, platformKey)
                        ? () => context.read<MediaImportProvider>().autoInstallTool(
                            kind,
                          )
                        : null,
                    onDownload: () =>
                        context.read<MediaImportProvider>().downloadTool(kind),
                  ),
                const Divider(height: 24),
                ModelList(modelService: p.modelService),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: FilledButton(
            onPressed: p.environmentReady ? () => _goConfirm(context) : null,
            child: Text(t.media_confirm_next),
          ),
        ),
      ],
    );
  }

  void _goConfirm(BuildContext context) {
    context.read<MediaImportProvider>().gotoConfirm();
  }
}
