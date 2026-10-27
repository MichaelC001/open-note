// lib/widgets/home/clipboard_hint_bar.dart
import 'package:flutter/material.dart';

import '../../l10n/strings.g.dart';
import '../../theme/design_tokens.dart';

/// 剪贴板侦测提示条：网页剪报 / 从音视频中创建 / 忽略 三个入口。
class ClipboardHintBar extends StatelessWidget {
  final bool isDark;
  final VoidCallback onWebclip;
  final VoidCallback onMedia;
  final VoidCallback onDismiss;

  const ClipboardHintBar({
    super.key,
    required this.isDark,
    required this.onWebclip,
    required this.onMedia,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    return Material(
      color: DesignTokens.primary500.withValues(alpha: isDark ? 0.65 : 0.1),
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.symmetric(
          horizontal: DesignTokens.space8,
          vertical: DesignTokens.space6,
        ),
        child: Row(
          children: [
            Icon(Icons.link, size: 18, color: DesignTokens.primary500),
            SizedBox(width: DesignTokens.space6),
            Expanded(
              child: Text(
                t.home_clipboardUrlDetected,
                style: TextStyle(
                  color: DesignTokens.primary500,
                  fontSize: DesignTokens.fontSizeBody,
                ),
              ),
            ),
            TextButton(
              onPressed: onWebclip,
              style: TextButton.styleFrom(
                foregroundColor: DesignTokens.primary500,
              ),
              child: Text(
                t.home_clipWebclip,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(
              onPressed: onMedia,
              style: TextButton.styleFrom(
                foregroundColor: DesignTokens.primary500,
              ),
              child: Text(
                t.home_clipMedia,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(
              onPressed: onDismiss,
              style: TextButton.styleFrom(
                foregroundColor: DesignTokens.gray500,
              ),
              child: Text(
                t.home_dismiss,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
