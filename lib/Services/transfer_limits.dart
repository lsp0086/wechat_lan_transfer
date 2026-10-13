// E1：传输上限/时序常量。从 ChatPage 残留魔法数字抽出，可单测。
// 超时/节流/容量/体积上限集中收敛；定时器/IO 留宿主。
// （v2 重构：旧裸 TCP 握手的 TransferConnMode/inbound/outboundConnMode/
//   kFileAcceptTimeoutSec/kReceiveTimeoutSec 已随 file_transfer_service 删除，
//   传输改走 LocalSend v2 HTTPS，见 lib/Transfer/ls_*.dart）

/// 历史分页大小（E3 最近一页）。
const int kHistoryPageSize = 100;

/// 文字重传上限。
const int kMaxTextRetries = 3;

/// ACK 基础超时（指数退避 0.8s/1.6s/3.2s/6.4s）。
const int kAckBaseTimeoutMs = 800;

/// 心跳新鲜窗口（窗口内跳过 ping）。
const int kFreshHeartbeatSec = 5;

/// 文字发送队列最小间隔（防 UDP 突发）。
const int kTextSendGapMs = 40;

/// 接收去重窗口 TTL。
const int kRecvDedupTtlSec = 30;

/// 内存缓存上限（图片尺寸/存在性）。
const int kMaxCacheEntries = 50;

/// 进度节流间隔（80ms）。
const int kProgressThrottleMs = 80;

/// 批量会话上限（超限清空防内存增长）。
const int kMaxSessionCount = 200;

/// ZIP 解压累计上限（防 ZIP 炸弹）。
const int kMaxExtractTotalBytes = 500 * 1024 * 1024;

/// 打包预检：累计/单文件/文件数上限。
const int kMaxPackTotalBytes = 500 * 1024 * 1024;
const int kMaxPackSingleBytes = 200 * 1024 * 1024;
const int kMaxPackFileCount = 5000;

/// 待解压 zip 本体上限（超限保留原文件不解压）。
const int kMaxZipFileBytes = 1024 * 1024 * 1024;

/// 缩略图保留上限（LRU）。
const int kMaxThumbFiles = 200;

/// 广播包上限（超限丢弃，P1-T8）。
const int kMaxBroadcastBytes = 64 * 1024;

/// 缩略图压缩参数。
const int kThumbQuality = 70;
const int kThumbMinWidth = 400;
const int kThumbMinHeight = 400;

/// 看门狗/心跳/广播周期。
const int kWatchdogSec = 30;
const int kMdnsScanSec = 8;
const int kHeartbeatFreshSec = 5;
const int kBroadcastSec = 3;
const int kLaunchSendWaitSec = 15;
const int kLaunchSendDelaySec = 2;
const int kLaunchSendPollSec = 1;
const int kCacheSaveDebounceMs = 500;

/// 启动广播快发两条（加速首次发现）。
const int kBroadcastFastMs1 = 200;
const int kBroadcastFastMs2 = 600;

/// 在线探测 ping 超时。
const int kPingTimeoutSec = 2;

/// 居中提示/动作气泡自动消失时长。
const int kToastSec = 3;
const int kActionBubbleSec = 3;

/// PIN 错误限流上限（S2 per-IP）。
const int kPinMaxFails = 5;

/// 缩略图 LRU / 陈旧缓存清理阈值。
const int kStaleCacheDays = 7;
const int kStaleTempZipHours = 24;

/// 图片气泡上限。
const double kImageMaxHeight = 220;
const double kImageMinWidth = 120;
const double kImageMinHeight = 80;
const double kImageWidthRatio = 0.55;

/// 波形柱数（录音/气泡/降采样共用）。
const int kWaveformBars = 25;

/// 录音过短丢弃阈值 / 上滑取消因子。
const int kMinRecordMs = 500;
const double kRecordCancelFactor = 0.35;

/// 语音气泡宽度映射（90~200px，按 0~60s 线性）。
const double kAudioBubbleMinW = 90.0;
const double kAudioBubbleMaxW = 200.0;
const double kAudioBubbleFullMs = 60000.0;

/// 播放进度兜底总时长（duration<=0，避免除零）。
const int kAudioPlayFallbackMs = 1000;

/// 动作气泡宽度估算系数/上下限。
const double kBubblePerChar = 16.0;
const double kBubblePerLabel = 28.0;
const double kBubbleGap = 1.0;
const double kBubbleMinW = 76.0;
const double kBubbleEdge = 24.0;
const double kBubbleClampEdge = 12.0;

/// 无效 IP 哨兵（广播回退/设备过滤共用）。
const String kInvalidIp = '0.0.0.0';

/// PIN 输入重试轮数（file_notify→accept 等待，首发+1次输入重试）。
const int kPinRetryAttempts = 2;
