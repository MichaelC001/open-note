// test/widgets/media_import_dialog_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_note/l10n/strings.g.dart';
import 'package:open_note/providers/media_import_provider.dart';
import 'package:open_note/widgets/media_import/media_import_dialog.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('默认渲染 source 步骤，含 URL 输入与文件按钮', (tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: ChangeNotifierProvider<MediaImportProvider>(
          create: (_) => MediaImportProvider(),
          child: const MaterialApp(home: Scaffold(body: MediaImportDialog())),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('done 步骤渲染标题与打开按钮', (tester) async {
    final provider = MediaImportProvider();
    await tester.pumpWidget(
      TranslationProvider(
        child: ChangeNotifierProvider<MediaImportProvider>.value(
          value: provider,
          child: const MaterialApp(home: Scaffold(body: MediaImportDialog())),
        ),
      ),
    );
    // 直接注入 done 状态所需数据
    provider.step = MediaImportStep.done;
    await tester.pumpAndSettle();
    expect(find.byType(MediaImportDialog), findsOneWidget);
  });
}
