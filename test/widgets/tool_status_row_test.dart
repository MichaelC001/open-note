// test/widgets/tool_status_row_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_note/l10n/strings.g.dart';
import 'package:open_note/services/media/media_tool_service.dart';
import 'package:open_note/widgets/media_import/tool_status_row.dart';

const _readyFfmpeg = MediaToolStatus(
  kind: MediaToolKind.ffmpeg,
  ready: true,
  path: '/fake/ffmpeg',
  version: '6.0',
  source: MediaToolSource.appManaged,
);

Widget _host({String? systemHint}) => TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: ToolStatusRow(
            kind: MediaToolKind.ffmpeg,
            status: _readyFfmpeg,
            downloading: false,
            finishing: false,
            autoInstalling: false,
            guide: 'brew install ffmpeg',
            systemHint: systemHint,
          ),
        ),
      ),
    );

void main() {
  testWidgets('ready 行渲染 systemHint 提示文本', (tester) async {
    await tester.pumpWidget(_host(
      systemHint: '更新未生效（下载源内容未变化），已保留当前版本',
    ));
    expect(find.text('更新未生效（下载源内容未变化），已保留当前版本'), findsOneWidget);
  });

  testWidgets('无 systemHint 时不渲染提示行', (tester) async {
    await tester.pumpWidget(_host());
    expect(find.text('更新未生效（下载源内容未变化），已保留当前版本'), findsNothing);
  });
}
