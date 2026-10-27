import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/design_tokens.dart';

/// 菜单项悬停提示：浮层包裹 IgnorePointer，纯视觉层，
/// 即使遮住相邻菜单项也不拦截鼠标（hover/点击穿透）。
class HoverHint extends StatefulWidget {
  final String message;
  final Widget child;
  final Duration showDelay;

  const HoverHint({
    super.key,
    required this.message,
    required this.child,
    this.showDelay = const Duration(milliseconds: 400),
  });

  @override
  State<HoverHint> createState() => _HoverHintState();
}

class _HoverHintState extends State<HoverHint> {
  final LayerLink _link = LayerLink();
  OverlayEntry? _entry;
  Timer? _timer;

  void _show() {
    _timer?.cancel();
    _timer = Timer(widget.showDelay, () {
      if (!mounted || _entry != null) return;
      final isDark = Theme.of(context).brightness == Brightness.dark;
      _entry = OverlayEntry(
        builder: (_) => Positioned(
          left: 0,
          top: 0,
          child: CompositedTransformFollower(
            link: _link,
            targetAnchor: Alignment.bottomLeft,
            followerAnchor: Alignment.topLeft,
            offset: const Offset(4, 6),
            child: IgnorePointer(
              child: Material(
                type: MaterialType.transparency,
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 280),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: isDark
                        ? DesignTokens.darkSurface
                        : DesignTokens.gray700,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    widget.message,
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      Overlay.of(context, rootOverlay: true).insert(_entry!);
    });
  }

  void _hide() {
    _timer?.cancel();
    _timer = null;
    _entry?.remove();
    _entry = null;
  }

  @override
  void dispose() {
    _hide();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _link,
      child: MouseRegion(
        onEnter: (_) => _show(),
        onExit: (_) => _hide(),
        child: widget.child,
      ),
    );
  }
}
