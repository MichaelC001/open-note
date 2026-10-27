import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:open_note/widgets/hover_hint.dart';

void main() {
  testWidgets('悬停显示提示浮层，浮层为 IgnorePointer 且随移出消失', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Overlay(
          initialEntries: [
            OverlayEntry(
              builder: (_) => Center(
                child: SizedBox(
                  width: 100,
                  height: 40,
                  child: HoverHint(
                    message: '提示文案',
                    showDelay: Duration(milliseconds: 10),
                    child: SizedBox.expand(),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    expect(find.text('提示文案'), findsNothing);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.byType(HoverHint)));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('提示文案'), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text('提示文案'),
        matching: find.byType(IgnorePointer),
      ),
      findsOneWidget,
    );

    await gesture.moveTo(Offset.zero);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('提示文案'), findsNothing);
  });
}
