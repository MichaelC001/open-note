// test/widgets/video_note_tab_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_note/l10n/strings.g.dart';
import 'package:open_note/providers/language_provider.dart';
import 'package:open_note/providers/update_provider.dart';
import 'package:open_note/utils/app_info.dart';
import 'package:open_note/widgets/settings_dialog.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('设置页新增独立「视频转笔记」Tab 且偏好设置页不再包含该分区',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'OpenNote',
      packageName: 'net.zsdn.opennote',
      version: '1.2.0',
      buildNumber: '1',
      buildSignature: 'test',
    );
    await AppInfo.init();
    await tester.pumpWidget(
      TranslationProvider(
        child: MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => UpdateProvider()),
            ChangeNotifierProvider(create: (_) => LanguageProvider()),
          ],
          child: const MaterialApp(home: Scaffold(body: SettingsDialog())),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('视频转笔记'), findsOneWidget);
    expect(find.text('下载源'), findsNothing);

    await tester.tap(find.text('视频转笔记'));
    await tester.pumpAndSettle();

    expect(find.text('下载源'), findsOneWidget);
    expect(find.text('默认识别模型'), findsOneWidget);
    expect(find.text('完成后删除下载的源媒体'), findsOneWidget);

    // 回到首选项，确认分区已移出
    await tester.tap(find.text('首选项'));
    await tester.pumpAndSettle();
    expect(find.text('下载源'), findsNothing);
  });
}
