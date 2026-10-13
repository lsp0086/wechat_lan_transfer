// 应用冒烟测试：MyApp 可启动并渲染底部导航（消息/设置）。
import 'package:flutter_test/flutter_test.dart';
import 'package:wechat_lan_transfer/main.dart';

void main() {
  testWidgets('MyApp 启动并显示底部导航', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pump();
    expect(find.text('消息'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
  });
}
