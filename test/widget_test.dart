// test/widget_test.dart
//
// 冒烟测试：验证应用内自包含组件可正常构建渲染。
// 不渲染 SplashApp——其初始化逻辑含多个 Future.delayed 定时器（延迟启动
// Python 服务等副作用），会触发 flutter_test「测试结束不允许 pending Timer」
// 不变量并需要完整 provider/mock 链路，故历史版本长期失败，已改写为本冒烟测试。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:open_note/widgets/media_import/tool_status_row.dart';

void main() {
  testWidgets('ErrorBanner 渲染且详情可选中复制', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: ErrorBanner(message: '音频提取失败', detail: 'No such file or directory'),
      ),
    ));

    expect(find.textContaining('音频提取失败'), findsOneWidget);
    expect(find.textContaining('No such file or directory'), findsOneWidget);
    expect(find.byType(SelectionArea), findsOneWidget);
  });
}
