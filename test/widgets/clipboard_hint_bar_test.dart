// test/widgets/clipboard_hint_bar_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_note/l10n/strings.g.dart';
import 'package:open_note/widgets/home/clipboard_hint_bar.dart';

Widget _host({
  required bool isDark,
  required VoidCallback onWebclip,
  required VoidCallback onMedia,
  required VoidCallback onDismiss,
}) {
  return TranslationProvider(
    child: MaterialApp(
      home: Scaffold(
        body: ClipboardHintBar(
          isDark: isDark,
          onWebclip: onWebclip,
          onMedia: onMedia,
          onDismiss: onDismiss,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('渲染三按钮（网页剪报/从音视频中创建/忽略）并触发对应回调',
      (tester) async {
    var webclip = false;
    var media = false;
    var dismissed = false;
    await tester.pumpWidget(_host(
      isDark: false,
      onWebclip: () => webclip = true,
      onMedia: () => media = true,
      onDismiss: () => dismissed = true,
    ));

    expect(find.text('网页剪报'), findsOneWidget);
    expect(find.text('从音视频中创建'), findsOneWidget);
    expect(find.text('忽略'), findsOneWidget);

    await tester.tap(find.text('网页剪报'));
    await tester.tap(find.text('从音视频中创建'));
    await tester.tap(find.text('忽略'));
    expect(webclip, isTrue);
    expect(media, isTrue);
    expect(dismissed, isTrue);
  });

  testWidgets('400x400 窄视口不溢出', (tester) async {
    tester.view.physicalSize = const Size(400, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(_host(
      isDark: false,
      onWebclip: () {},
      onMedia: () {},
      onDismiss: () {},
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
