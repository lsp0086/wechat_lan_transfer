// E1：安全事件记账纯函数。从 ChatListPage._logSecurityEvent 抽出，可单测。
// JSON 解析/事件追加纯逻辑；文件读写留宿主。

import 'dart:convert' show jsonDecode;

/// 解析 security_config.json 原文为 map（空/坏损回空 map）。
Map<String, dynamic> parseSecurityConfig(String? raw) {
  if (raw == null || raw.trim().isEmpty) return {};
  try {
    return jsonDecode(raw) as Map<String, dynamic>;
  } catch (_) {
    return {};
  }
}

/// 追加一条安全事件，返回新 map（调用方再 jsonEncode 落盘）。
Map<String, dynamic> appendSecurityEvent({
  required Map<String, dynamic> config,
  required String type,
  required String timeIso,
  required String fingerprint,
}) {
  final events = (config['events'] as List<dynamic>?) ?? <dynamic>[];
  events.add({'type': type, 'time': timeIso, 'fingerprint': fingerprint});
  return {...config, 'events': events};
}
