import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:wechat_lan_transfer/Chat/chat_list.dart';
import 'package:wechat_lan_transfer/Services/launch_args.dart';
import 'package:wechat_lan_transfer/Services/log.dart';
import 'package:wechat_lan_transfer/Services/tls_identity_service.dart';

// U2：桌面"发送到/打开方式"文件参数（Windows runner 透传；Linux/macOS 同理）。
void main([List<String> args = const []]) {
  WidgetsFlutterBinding.ensureInitialized();
  // 新库 logging：统一日志入口（默认转发 debugPrint，行为不变）。
  initLogging();
  // P0-1：尽早初始化本端 TLS 身份（自签证书），供 UDP 握手携带指纹、
  // TCP 传输 TLS 升级使用；不阻塞 UI 启动
  TlsIdentityService.instance.init();
  runApp(MyApp(launchSendPaths: LaunchArgs.pendingPaths(args)));
}

class MyApp extends StatelessWidget {
  // U2：桌面启动时透传的待发送文件/目录路径（"发送到/打开方式"进入）。
  final List<String> launchSendPaths;

  const MyApp({super.key, this.launchSendPaths = const []});

  @override
  Widget build(BuildContext context) {
    // U8：字体不再写死 Roboto，跟随系统（中文回退链见 theme）。
    return MaterialApp(
      title: '局域网快传',
      debugShowCheckedModeBanner: false,
      // U5：跟随系统 locale（null），不再强制 zh-CN；fallback 保留中英。
      locale: null,
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
        // U8：不写死字体，跟随系统；中文回退链覆盖各桌面平台。
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
      // U5：跟随系统深色模式（ThemeMode 默认跟随系统，需配 darkTheme）。
      darkTheme: ThemeData.dark(useMaterial3: true),
      // U8：系统「减少动效」开启时，把主题动画时长压成 0（框架自身已尊重该开关）。
      builder: (context, child) {
        if (!MediaQuery.disableAnimationsOf(context)) {
          return child ?? const SizedBox.shrink();
        }
        return Theme(
          data: Theme.of(context).copyWith(
            pageTransitionsTheme: const PageTransitionsTheme(
              builders: {
                TargetPlatform.android: _InstantPageTransitionsBuilder(),
                TargetPlatform.iOS: _InstantPageTransitionsBuilder(),
                TargetPlatform.macOS: _InstantPageTransitionsBuilder(),
                TargetPlatform.windows: _InstantPageTransitionsBuilder(),
                TargetPlatform.linux: _InstantPageTransitionsBuilder(),
              },
            ),
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: ChatListPage(initialSendPaths: launchSendPaths),
    );
  }
}

/// U8：无动画的页面切换，系统「减少动效」开启时使用。
class _InstantPageTransitionsBuilder extends PageTransitionsBuilder {
  const _InstantPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => child;
}
