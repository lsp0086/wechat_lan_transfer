import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:wechat_lan_transfer/Chat/chat_list.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '局域网快传',
      debugShowCheckedModeBanner: false,
      // 显式指定中文语言环境，避免字体回退异常
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF07C160),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFEDF0F3),
        // 显式指定中文字体族，跨平台统一字体渲染
        fontFamily: 'Roboto',
        fontFamilyFallback: const [
          'Noto Sans SC',
          'Microsoft YaHei',
          'PingFang SC',
          'Hiragino Sans GB',
          'SimHei',
        ],
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF3F3F3),
          elevation: 0.5,
          iconTheme: IconThemeData(color: Colors.black87),
          titleTextStyle: TextStyle(
            color: Colors.black87,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      home: const ChatListPage(),
    );
  }
}
