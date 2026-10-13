# 📦 wechat_lan_transfer
基于 **Flutter** 的局域网文件/文字传输工具，支持 **Android / iOS / Windows / macOS / Linux**。  
轻量、快速、无需登录：同一局域网内自动发现设备，文字、文件、语音、图片互传。

> ⚠️ Web 端暂不支持：传输层基于 `dart:io`（UDP 发现 + TCP/TLS 文件通道），Web 编译即挂。
> `web/` 默认模板已删除，避免误编译。
> U1 roadmap：长期视需求做局域网 Web share 只读页（对标 PairDrop/LocalSend receive via link）。
> U4：Windows 永久 `asInvoker`，不声明 requireAdministrator 后每次启动无 UAC 弹窗；防火墙规则走安装器一次性提权写（见 manifest 注释）。

---

## 🚀 功能特性

- ⚡ **局域网自动发现**：UDP 广播心跳（按接口真实掩码算广播地址，大子网可用）
- 💬 **文字聊天**：ACK 确认 + 指数退避重传（0.8/1.6/3.2/6.4s）+ 收发去重
- 📂 **文件传输**：TCP 直传 + TLS 加密（自签证书 + 指纹钉扎，旧端明文兼容）
- ✅ **完整性校验**：发送前 SHA-256，接收落盘后校验，不一致删文件标失败
- 🎙️ **语音消息**：真实录音时长 + 真振幅波形透传
- 🆔 **持久设备身份**：deviceId = 证书指纹，换 IP 不丢历史
- 🔌 **端口可配置**：UDP/TCP 首选端口 + 占用探测回退
- 🛡️ **拉黑/自动接收**：按设备持久化

---

## 📁 项目结构说明

```
wechat_lan_transfer/
├── lib/
│   ├── main.dart
│   ├── Chat/            # UI：chat_list（设备列表+设置）/ chat_page（会话）/ audio_bubble
│   ├── Model/           # chat_model（消息）/ device_info（设备身份）
│   └── Services/
│       ├── udp_message_service.dart     # UDP 握手/文字/ACK（8888 可配置）
│       ├── file_transfer_service.dart   # TCP/TLS 文件引擎（8899 可配置）
│       ├── tls_identity_service.dart    # 自签证书 + 指纹（deviceId）
│       ├── message_cache_service.dart   # 聊天缓存（设备锁 + msgId 幂等）
│       ├── app_config_store.dart        # 配置收敛 documents/config/ + 原子写
│       ├── protocol_codec.dart          # 纯协议逻辑（可单测）
│       ├── audio_service.dart / toast_utils.dart
├── test/                # protocol_codec_test（header/握手key/退避）
└── pubspec.yaml
```

---

## 📡 工作原理

```
发送方                          接收方
  │  UDP file_notify（文件名/大小/sha256/transferId/tlsFp）  │
  ├─────────────────────────────────────────────────────────►│
  │                    UDP file_accept（tlsFp）               │
  │◄────────────────────────────────────────────────────────╡
  │  TCP/TLS（1024B JSON头 + 4B头长 + 文件体，指纹钉扎）     │
  ├─────────────────────────────────────────────────────────►│
  │                    落盘后 SHA-256 校验                     │
```

- 握手三态：accepted / rejected / timeout（超时≠拒绝，迟到 accept 可重发完成）
- 传输取消：UDP `file_cancel` + 两端 abort 并删半文件
- 文字 40ms 发送队列 + 30s msgId 去重窗口
- N3：与 LocalSend **不互通**（自创 UDP 8888 + TCP 8899 + 自定义 header，对方 53317 + HTTP/REST v1/v2）
- N4：30s 看门狗巡检广播/TCP 存活，die 则自动重启（对标 LocalSend 自动重启）
- S2：可选接收 PIN（4~8 位），缺/错直接拒绝 + per-IP 限流；S7：一次性 token 一次即焚

---

## 🛠️ 运行

```bash
flutter pub get
flutter run -d windows   # 或 macos / linux / android / ios
flutter test             # 协议单测
```

### 端口
设置页可改 UDP 发现端口（默认 8888）/ TCP 文件端口（默认 8899），占用自动探测相邻 10 个。

### Windows 防火墙
应用启动自动加 TCP/UDP 入站规则；失败时设置页「防火墙引导」可一键重试（需管理员权限）。

---

## 📄 License

MIT License
