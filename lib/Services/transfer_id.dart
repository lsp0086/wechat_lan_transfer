// E1：传输 ID 工厂。从 ChatPage 抽出的 ID 生成，可单测可注入。
// 新库 uuid：v4 真随机（去碰撞，对标 LocalSend sessionId）；
// 旧 newUniqueShortId(prefix) 保留作 legacy 兼容（旧端握手键格式）。

import 'package:uuid/uuid.dart';

/// 传输/会话 ID：默认 uuid v4（36 字符）；legacy 模式回退 prefix_微秒_随机。
class TransferIdFactory {
  TransferIdFactory({Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  final Uuid _uuid;

  /// 新建传输 ID（uuid v4）。
  String newTransferId() => _uuid.v4();

  /// 新建批量会话 ID（uuid v4）。
  String newSessionId() => _uuid.v4();
}
