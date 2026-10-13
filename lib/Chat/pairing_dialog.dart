// E1：首次配对确认对话框。从 ChatListPage._ensurePaired 拆出的 UI 层，
// 流程控制（去重/持久化/拉黑落地）留在宿主。

import 'package:flutter/material.dart';
import '../Services/pairing_texts.dart';

/// 弹出指纹配对确认框。返回 true=信任并配对 / false=拉黑 / null=取消关闭。
/// P1-10：支持自定义标题（自动发现不再触发，仅手动长按入口使用）。
Future<bool?> showPairingDialog(
  BuildContext context,
  String deviceKey,
  String name, {
  String? title,
}) {
  // E1：截短/文案抽至 pairing_texts.shortFingerprint/各标题（防短指纹 RangeError）。
  final shortFp = shortFingerprint(deviceKey);
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: Text(title ?? pairingTitle()),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(pairingRequestLine(name)),
            const SizedBox(height: 8),
            SelectableText(
              pairingShortLine(shortFp),
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            ExpansionTile(
              // E1：标题抽至 pairing_texts.pairingFullTitle。
              title: Text(pairingFullTitle(), style: TextStyle(fontSize: 13)),
              tilePadding: EdgeInsets.zero,
              children: [
                SelectableText(
                  deviceKey,
                  style: const TextStyle(fontSize: 11, color: Colors.black87),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
          // E1：文案抽至 pairing_texts.pairingBlockText。
          child: Text(pairingBlockText()),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF07C160),
          ),
          // E1：文案抽至 pairing_texts.pairingTrustText。
          child: Text(pairingTrustText()),
        ),
      ],
    ),
  );
}
