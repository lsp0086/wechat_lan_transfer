// E1：设置 Tab。从 ChatListPage 拆出的 UI 层（单元格列表 + 对话框群），
// 状态与业务逻辑（持久化/重绑/通告）以回调注入宿主，宿主负责 toast 与落地。

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../Services/toast_utils.dart';
import '../Services/settings_texts.dart';
import '../Services/chat_list_texts.dart';

class SettingsTab extends StatelessWidget {
  const SettingsTab({
    super.key,
    required this.myDeviceName,
    required this.localIp,
    required this.udpPort,
    required this.tcpPort,
    required this.preferredUdpPort,
    required this.preferredTcpPort,
    required this.storagePathLabel,
    required this.tlsOnly,
    required this.stealthMode,
    required this.visibility,
    required this.receivePin,
    required this.onTlsOnlyChanged,
    required this.onStealthModeChanged,
    this.onPortChanged,
    required this.onVisibilityChanged,
    required this.onReceivePinSave,
    required this.onAddDeviceRequest,
    required this.onStoragePathRequest,
    required this.onFixFirewallRequest,
    required this.onResetIdentityRequest,
    required this.onDeleteAllDevicesRequest,
  });

  final String myDeviceName;
  final String localIp;
  final int udpPort;
  final int tcpPort;
  final int preferredUdpPort;
  final int preferredTcpPort;
  final String storagePathLabel;
  final bool tlsOnly;
  final bool stealthMode;
  final String visibility;
  final String receivePin;

  final ValueChanged<bool> onTlsOnlyChanged;
  final ValueChanged<bool> onStealthModeChanged;

  /// 端口落地回调（宿主注入；[udp] 区分 UDP/TCP，宿主保存首选端口+重绑+通告）。
  final void Function(bool udp, int port)? onPortChanged;

  /// N5：可见性三档变更（宿主 setState + 持久化 + toast）。
  final ValueChanged<String> onVisibilityChanged;

  /// S2：接收 PIN 保存（宿主校验格式 + 持久化 + toast）。
  final ValueChanged<String> onReceivePinSave;

  /// P1-N1：手动添加设备原始输入（"IP:端口"，宿主解析 + ping + 建条目）。
  final ValueChanged<String> onAddDeviceRequest;

  /// 存储路径选择结果（宿主校验 + 应用 + 持久化）。
  final ValueChanged<String> onStoragePathRequest;

  final VoidCallback onFixFirewallRequest;
  final VoidCallback onResetIdentityRequest;
  final VoidCallback onDeleteAllDevicesRequest;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEDF0F3),
      appBar: AppBar(
        title: Text(settingsTitle()),
        centerTitle: true,
        backgroundColor: const Color(0xFFF3F3F3),
        elevation: 0.5,
        titleTextStyle: const TextStyle(
          color: Colors.black87,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            const SizedBox(height: 12),
            Container(
              color: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              child: Row(
                children: [
                  Container(
                    width: 60,
                    height: 60,
                    decoration: BoxDecoration(
                      color: const Color(0xFF07C160),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.person,
                      color: Colors.white,
                      size: 36,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          myDeviceName,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          // E1：本机行抽至 settings_texts.localIpLine/portsLine。
                          localIpLine(localIp),
                          style: const TextStyle(
                            color: Colors.grey,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          portsLine(udpPort, tcpPort),
                          style: const TextStyle(
                            color: Colors.grey,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            // P1-N1：手动添加设备（IP:端口），跨子网/AP 隔离时兜底
            GestureDetector(
              onTap: () => _showAddDeviceDialog(context),
              // E1：标题抽至 settings_texts.cellManualAdd。
              child: _cell(cellManualAdd()),
            ),
            const Divider(
              height: 0.5,
              thickness: 0.5,
              indent: 16,
              color: Color(0xFFE5E5E5),
            ),
            GestureDetector(
              onTap: () => _changePort(context, udp: true),
              child: _cell(
                // E1：标题抽至 settings_texts.cellUdpPort。
                cellUdpPort(),
                value:
                    '$udpPort${portSuffix(actual: udpPort, preferred: preferredUdpPort)}',
              ),
            ),
            const Divider(
              height: 0.5,
              thickness: 0.5,
              indent: 16,
              color: Color(0xFFE5E5E5),
            ),
            GestureDetector(
              onTap: () => _changePort(context, udp: false),
              child: _cell(
                // E1：标题抽至 settings_texts.cellTcpPort。
                cellTcpPort(),
                value:
                    '$tcpPort${portSuffix(actual: tcpPort, preferred: preferredTcpPort)}',
              ),
            ),
            const SizedBox(height: 12),
            GestureDetector(
              onTap: () => _showFirewallHelp(context),
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                child: Row(
                  children: [
                    const Icon(Icons.security, size: 20, color: Colors.orange),
                    const SizedBox(width: 10),
                    Text(
                      // E1：标题抽至 settings_texts.cellFirewallGuide。
                      cellFirewallGuide(),
                      style: TextStyle(fontSize: 16, color: Colors.black87),
                    ),
                    const Spacer(),
                    Text(
                      // E1：后缀抽至 settings_texts.firewallPortsLabel。
                      firewallPortsLabel(tcpPort, udpPort),
                      style: const TextStyle(color: Colors.grey, fontSize: 13),
                    ),
                    const SizedBox(width: 4),
                    const Icon(Icons.chevron_right, color: Colors.grey),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            // 文件存储位置
            GestureDetector(
              onTap: () => _changeStoragePath(context),
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                constraints: const BoxConstraints(minHeight: 56),
                child: Row(
                  children: [
                    Text(
                      // E1：标题抽至 settings_texts.cellStoragePath。
                      cellStoragePath(),
                      style: TextStyle(fontSize: 16, color: Colors.black87),
                    ),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Text(
                          storagePathLabel,
                          textAlign: TextAlign.end,
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                          style: const TextStyle(
                            color: Colors.grey,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(Icons.chevron_right, color: Colors.grey),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            // P0-S3：仅TLS传输开关
            // E1：标题抽至 settings_texts.cellTlsOnly。
            _cell(
              cellTlsOnly(),
              isSwitch: true,
              switchValue: tlsOnly,
              onSwitchChanged: onTlsOnlyChanged,
              showArrow: false,
            ),
            // U4：隐身模式开关（开启后跳过主动广播，仅单播回包）
            // E1：标题抽至 settings_texts.cellStealth。
            _cell(
              cellStealth(),
              isSwitch: true,
              switchValue: stealthMode,
              onSwitchChanged: onStealthModeChanged,
              showArrow: false,
            ),
            // N5：发现可见性三档（所有人/仅已配对/隐身），对标 LocalSend Known devices only
            GestureDetector(
              onTap: () => _changeVisibility(context),
              child: _cell(
                // E1：标题抽至 settings_texts.cellVisibility。
                cellVisibility(),
                value: visibilityLabel(visibility),
              ),
            ),
            // S2：接收 PIN（4~8 位数字，空=不启用，对标 LocalSend PIN）
            GestureDetector(
              onTap: () => _changeReceivePin(context),
              child: _cell(
                // E1：标题抽至 settings_texts.cellReceivePin。
                cellReceivePin(),
                value: receivePinLabel(receivePin),
              ),
            ),
            const Divider(
              height: 0.5,
              thickness: 0.5,
              indent: 16,
              color: Color(0xFFE5E5E5),
            ),
            // 删除所有设备（清空设备列表及缓存）
            GestureDetector(
              onTap: () => _confirmDeleteAllDevices(context),
              child: _cell(
                // E1：标题抽至 settings_texts.cellDeleteAll。
                cellDeleteAll(),
                textColor: Colors.redAccent,
                showArrow: false,
              ),
            ),
            const Divider(
              height: 0.5,
              thickness: 0.5,
              indent: 16,
              color: Color(0xFFE5E5E5),
            ),
            // P0-S6：重置本机身份（换证），危险操作
            GestureDetector(
              onTap: () => _confirmResetIdentity(context),
              child: _cell(
                // E1：标题抽至 settings_texts.cellResetIdentity。
                cellResetIdentity(),
                textColor: Colors.redAccent,
                showArrow: false,
              ),
            ),
            const Divider(
              height: 0.5,
              thickness: 0.5,
              indent: 16,
              color: Color(0xFFE5E5E5),
            ),
            // E1：标题抽至 settings_texts.cellAbout。
            _cell(cellAbout()),
          ],
        ),
      ),
    );
  }

  Widget _cell(
    String title, {
    String? value,
    bool isSwitch = false,
    bool switchValue = false,
    ValueChanged<bool>? onSwitchChanged,
    Color textColor = Colors.black87,
    bool showArrow = true,
  }) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(title, style: TextStyle(fontSize: 16, color: textColor)),
          if (isSwitch)
            CupertinoSwitch(
              value: switchValue,
              onChanged: onSwitchChanged ?? (v) {},
              activeTrackColor: const Color(0xFF07C160),
            )
          else
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (value != null)
                    Expanded(
                      child: Text(
                        value,
                        textAlign: TextAlign.end,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  if (showArrow) ...[
                    const SizedBox(width: 4),
                    const Icon(
                      Icons.arrow_forward_ios,
                      size: 14,
                      color: Colors.grey,
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ================= 对话框群（UI；落地经回调注入宿主） =================

  /// P1-N1：手动添加设备输入框（"IP:端口"），解析与建条目在宿主。
  Future<void> _showAddDeviceDialog(BuildContext context) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(manualAddTitle()),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.text,
          decoration: InputDecoration(
            hintText: manualAddHint(),
            helperText: manualAddHelper(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(dialogCancelText()),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(dialogConfirmText()),
          ),
        ],
      ),
    );
    if (result == null || result.isEmpty) return;
    onAddDeviceRequest(result);
  }

  /// P1-1：端口修改输入框，范围校验后由宿主重绑并通告对端。
  Future<void> _changePort(BuildContext context, {required bool udp}) async {
    final current = udp ? preferredUdpPort : preferredTcpPort;
    final controller = TextEditingController(text: '$current');
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        // E1：标题/提示抽至 settings_texts.portDialogTitle/Hint/Helper。
        title: Text(portDialogTitle(udp: udp)),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            hintText: portDialogHint(udp: udp),
            helperText: portDialogHelper(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(dialogCancelText()),
          ),
          TextButton(
            onPressed: () {
              final v = int.tryParse(controller.text.trim());
              Navigator.pop(ctx, v);
            },
            child: Text(dialogConfirmText()),
          ),
        ],
      ),
    );
    if (result == null) return;
    if (!isValidPort(result)) {
      if (context.mounted) showCenterToast(context, portRangeText());
      return;
    }
    // 宿主落地：保存首选端口 + 重绑 + 通告（udp=true 重启发现，udp=false 重启 TCP）
    onPortChanged?.call(udp, result);
  }

  /// N5：三档选择对话框。
  Future<void> _changeVisibility(BuildContext context) async {
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(visibilityDialogTitle()),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'all'),
            // E1：选项文案抽至 settings_texts.visibilityOptAll。
            child: Text(visibilityOptAll()),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'paired'),
            // E1：选项文案抽至 settings_texts.visibilityOptPaired。
            child: Text(visibilityOptPaired()),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'stealth'),
            // E1：选项文案抽至 settings_texts.visibilityOptStealth。
            child: Text(visibilityOptStealth()),
          ),
        ],
      ),
    );
    if (result == null) return;
    onVisibilityChanged(result);
  }

  /// S2：设置接收 PIN（4~8 位数字，空=关闭）。校验与持久化在宿主。
  Future<void> _changeReceivePin(BuildContext context) async {
    final controller = TextEditingController(text: receivePin);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(receivePinTitle()),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              receivePinHelper(),
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              maxLength: 8,
              decoration: InputDecoration(
                hintText: receivePinHint(),
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(dialogCancelText()),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(saveText()),
          ),
        ],
      ),
    );
    if (result == null) return;
    onReceivePinSave(result);
  }

  /// 弹出文件夹选择器，校验存在后由宿主应用 + 持久化。
  Future<void> _changeStoragePath(BuildContext context) async {
    try {
      final String? selectedPath = await FilePicker.platform.getDirectoryPath(
        dialogTitle: storagePickTitle(),
      );
      if (selectedPath == null) return;

      final dir = Directory(selectedPath);
      if (!await dir.exists()) {
        if (context.mounted) showCenterToast(context, storageMissingText());
        return;
      }
      onStoragePathRequest(selectedPath);
    } catch (e) {
      if (context.mounted) showCenterToast(context, storageFailText());
    }
  }

  Future<void> _showFirewallHelp(BuildContext context) async {
    final content = firewallHelpContent(
      isWindows: Platform.isWindows,
      isMacOS: Platform.isMacOS,
      isLinux: Platform.isLinux,
      tcpPort: tcpPort,
      udpPort: udpPort,
    );
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(firewallGuideTitle()),
        content: Text(content),
        actions: [
          if (Platform.isWindows)
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                onFixFirewallRequest();
              },
              child: Text(addRuleText()),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(gotItText()),
          ),
        ],
      ),
    );
  }

  /// P0-S6：重置本机身份二次确认；确认后宿主执行换证 + 记账。
  Future<void> _confirmResetIdentity(BuildContext context) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(resetTitle()),
        content: Text(
          resetContent(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(dialogCancelText()),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: Text(resetConfirm()),
          ),
        ],
      ),
    );
    if (confirm == true) onResetIdentityRequest();
  }

  /// 删除所有设备二次确认；确认后宿主清空设备列表及缓存。
  Future<void> _confirmDeleteAllDevices(BuildContext context) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(deleteTitle()),
        content: Text(deleteContent()),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(dialogCancelText()),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: Text(deleteConfirm()),
          ),
        ],
      ),
    );
    if (confirm == true) onDeleteAllDevicesRequest();
  }
}
