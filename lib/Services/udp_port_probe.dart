// E1/P1-1：端口探测回退。从 ChatListPage/FileTransferService 抽出的高阶纯函数
// （可单测，注入假 binder）。对标 LocalSend 端口占用回退。

import 'dart:io';

/// 通用探测：从首选端口起连续试 [attempts] 个候选端口，[bindPort] 封装单端口
/// 绑定策略（失败抛 SocketException 则尝试下一候选）；成功即返回，全败抛最后错误。
/// [bindPort] 由调用方注入（真机传真 bind，单测传假实现）。
Future<T> probeConsecutive<T>(
  int preferred,
  Future<T> Function(int port) bindPort, {
  void Function(String message)? log,
  int attempts = 10,
}) async {
  SocketException? lastError;
  for (int i = 0; i < attempts; i++) {
    final port = preferred + i;
    if (port > 65535) break;
    try {
      final socket = await bindPort(port);
      if (i > 0) log?.call('首选端口 $preferred 占用，回退到 $port');
      return socket;
    } on SocketException catch (e) {
      lastError = e;
      log?.call('端口 $port 绑定失败: $e');
    }
  }
  throw lastError ??
      SocketException('无法绑定端口 $preferred 起的 $attempts 个候选');
}

/// UDP 探测：每候选 v4 先试，SocketException 回退 anyIPv6（P1-N2）。
Future<T> probeUdpPort<T>(
  int preferred,
  Future<T> Function(InternetAddress addr, int port) bind, {
  void Function(String message)? log,
  int attempts = 10,
}) {
  return probeConsecutive<T>(
    preferred,
    (port) async {
      try {
        return await bind(InternetAddress.anyIPv4, port);
      } on SocketException catch (e) {
        log?.call('UDP 端口 $port/IPv4 绑定失败: $e，尝试 anyIPv6');
        return bind(InternetAddress.anyIPv6, port);
      }
    },
    log: log,
    attempts: attempts,
  );
}
