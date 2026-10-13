# 文件传输层完全重构：对齐 LocalSend Protocol v2

## Context

Android→macOS 发文件多次修复后仍持续失败/重试。自研「UDP file_notify/file_accept 握手 + 裸 TCP/TLS 直传 + 接收方注册表/token/断点续传」管线状态机复杂、跨端耦合点过多，是问题根源。用户决定：

- **保留全部 UI**，传输层按 LocalSend protocol v2 完全重写
- **全端重构**：两端同步升级，删除旧握手（无旧版兼容负担）
- **兼容官方 LocalSend App 直接互传**（用户已确认）：端口/发现/协议全对齐 v2

## v2 协议规格（已从官方源码 packages/core 锚定）

- **端口**：TCP+UDP 均为 **53317**
- **发现**：UDP 组播 `224.0.0.167:53317`，JSON：`{"v":"2","alias":...,"fingerprint":...,"port":53317,"protocol":"https","download":false}`（官方 socket 绑定 0.0.0.0:53317 + 加组，广播包也能收到）
- **身份**：fingerprint = SHA-256(证书 DER) hex 小写 —— 与本项目现有 deviceId 完全一致（TlsIdentityService 已实现，无需改动）
- **端点**（`/api/localsend/v2/` 前缀）：
  | 端点 | 方法 | 说明 |
  |---|---|---|
  | `/prepare-upload` | POST | body `{info:{alias,version,deviceModel?,deviceType?,fingerprint,port,protocol,download}, files:{fileId:{id,fileName,size,fileType,sha256?,preview?,metadata?}}}`，可选 `?pin=`。**请求挂起直到接收方决策**。200→`{sessionId, files:{fileId:token}}`；401 PIN 缺/错；403 拒绝；409 忙（单会话槽）；429 PIN 限流；204 无可传文件 |
  | `/upload?sessionId&fileId&token` | POST | 二进制流 body。200 成功；403 token/IP 不符；422 sha256 不匹配（同 token 可重试≤3 次）；500 落盘失败 |
  | `/cancel?sessionId` | POST | 发送方取消 pending/active 会话；接收方取消自己的发送会话也调对方此端点 |
  | `/info`、`/register` | GET/POST | 设备信息（register 校验声称 fingerprint 与 mTLS 客户端证书一致） |
- **PIN**：query `?pin=` 明文比对，per-IP 3 次失败 → 429
- **安全**：客户端 TLS `badCertificateCallback` 中比对对端证书指纹 == 发现层 fingerprint（TOFU 钉扎）；服务端 `requestClientCertificate:true` 取对端证书指纹（不可伪造，无证书则回退 info.fingerprint）

## 架构

### 新增 `lib/Transfer/`（5 个文件）

1. **ls_dto.dart** — v2 DTO（camelCase JSON、手写 toJson/fromJson）：`LsDeviceDto`/`LsFileDto`/`PrepareUploadRequest`/`PrepareUploadResponse`/`LsSendError`（401/403/409/429/422 类型化）
2. **file_utils.dart** — 从 [file_transfer_service.dart](file:///Users/mir002/liuyang/wechat_lan_transfer/lib/Services/file_transfer_service.dart) 迁移纯工具：`formatFileSize`/`sha256OfFile`/`sanitizeFileName`/`fitFileName`/`precheckSpace`/`ensureSaveDir`/`_resolveSavePath`/`bindWithProbe`/`fixWindowsFirewall`(端口改 53317)
3. **ls_client.dart** — 发送端：`prepareUpload`（**无短超时**，挂起等接收方决策；支持取消=断开连接；401→上层弹 PIN 重试带 `?pin=`）；`uploadFile`（分块流式+进度回调+422 重试≤2）；`cancel(sessionId)`
4. **ls_server.dart** — 接收端：`HttpServer.bindSecure(53317, TlsIdentityService.serverContext)`（bindWithProbe 兜底端口）；单会话槽 pending→active（对齐官方）；事件流 `onPrepareUpload(sessionId, sender, files, decisionCompleter)`、`onFileProgress`、`onSessionFinished`；upload 流式落盘 `.part`→改名+sha256 校验；`/cancel` 处理；IPv4-mapped IPv6 地址归一化（`::ffff:a.b.c.d`→IPv4，修复旧双栈匹配问题）
5. **ls_discovery.dart** — v2 组播发现：3s 周期 announce（同时发组播+255.255.255.255 广播兜底）+ 监听解析 + 对新设备 POST `/register`；Android 需 `WifiManager.MulticastLock`（MainActivity 加 MethodChannel）

### 保留不动

- UI 全部（chat_list/chat_page 气泡、设置、长按配对、PIN 设置、自动接收、存储路径、可见性三档）
- **TlsIdentityService**（deviceId=fingerprint，聊天缓存键/配对关系无缝延续）
- **UDP 8888 通道仅保留**：文字聊天、心跳、blockSync（拉黑同步）；`sendFileNotify/sendFileAccept/sendFileReject/fileCancel` 及其解析全部删除
- `AppConfigStore`（getReceivePin/getVisibility/getStealthMode/getTlsOnly 等）
- paired_devices.json、拉黑列表、自动接收 store

### 小改

- [udp_message_service.dart](file:///Users/mir002/liuyang/wechat_lan_transfer/lib/Services/udp_message_service.dart)：新增 `fileMeta` side-channel cmd（`{fileName,fileSize,isVoice,isFolder,durationMs,waveformData}`，发送前连发 2 次；接收端 LRU+TTL 缓存，v2 会话到达时按 fileName+size 取回，官方 App 发来的没有 meta → 普通文件气泡）——语音波形/文件夹解压标记保真
- [chat_page.dart](file:///Users/mir002/liuyang/wechat_lan_transfer/lib/Chat/chat_page.dart) 发送管线（L2123-2264 等 4 处）：`sendFileNotify→等 completer→sendFile` 全部替换为 `ls_client.prepareUpload→逐文件 upload`；批量多图 = 一个 v2 会话多文件（原生支持，替代 sessionId/fileCount/fileIndex 透传）；文件夹维持 zip 后按普通文件发；401→PIN 弹框重试；403→失败；409→"对方正忙"；进度回调→气泡 progress
- [chat_list.dart](file:///Users/mir002/liuyang/wechat_lan_transfer/lib/Chat/chat_list.dart) 接收管线（L1208-1360、L530-630、L942/L1075）：删 file_notify 处理块/ReceiveGate/pendingMeta/manualAcceptFiles/超时注册表；server 事件 `onPrepareUpload` → 沿用现有判定顺序（PIN→拉黑→手动/会话/自动接收→空间预检）填 decisionCompleter（挂起=对齐官方"接收方主导"）；`onFileProgress/onSessionFinished` → 更新到达消息气泡与落盘路径
- 设备注册表：`ls_discovery` 事件按 fingerprint 合入现有设备列表（alias/deviceId 对齐），`peerTcpPort` 统一取设备注册端口（默认 53317）
- [settings_tab.dart](file:///Users/mir002/liuyang/wechat_lan_transfer/lib/Chat/settings_tab.dart) 端口显示 TCP 53317/UDP 53317；防火墙文案同步

### 删除（全端重构，无兼容包袱）

- `lib/Services/`：accept_waiter.dart、receive_gate.dart、file_payload.dart、accept_credential_store.dart、keepalive_counter.dart
- [file_transfer_service.dart](file:///Users/mir002/liuyang/wechat_lan_transfer/lib/Services/file_transfer_service.dart) 整个裸 TCP/TLS 服务（保留部分已迁 file_utils.dart）
- [transfer_limits.dart](file:///Users/mir002/liuyang/wechat_lan_transfer/lib/Services/transfer_limits.dart)：`TransferConnMode`/`inboundConnMode`/`outboundConnMode`/`kFileAcceptTimeoutSec`/`kReceiveTimeoutSec` 等 TCP 握手常量（保留 UI 布局/节流类常量）
- `FileTransferTask`/`TransferStatus` → 新 `LsSessionState`/`LsFileProgress` 模型替代
- 8888 广播中的 tcpPort 发现字段（传输端口改由 v2 发现提供）

## 实现顺序

1. ls_dto.dart + file_utils.dart（纯函数，含单测）
2. ls_client.dart
3. ls_server.dart（含单测：单会话槽/PIN 限流/地址归一化纯逻辑）
4. ls_discovery.dart + Android MulticastLock
5. udp_message_service 瘦身 + fileMeta side-channel
6. chat_page 发送管线改造（单文件/批量/语音/zip/重试/PIN）
7. chat_list 接收管线改造（弹窗/自动接收/进度/完成）
8. 删除死代码 + settings_tab 端口 + fixWindowsFirewall
9. `flutter analyze` 清零 → 串行构建（**严禁 build_*.command 并行**）→ dist/ 两端产物

## 验证

- `flutter analyze` 0 error；`flutter test`（新增 DTO/纯函数测试）
- 端到端真机：Android→macOS 与 macOS→Android 互传图片/文件/语音/文件夹/批量多图；PIN 场景；自动接收场景；传输中取消
- 与官方 LocalSend App（macOS 装 App Store 版）双向互传验证互操作
