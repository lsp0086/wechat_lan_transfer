// E1：录音策略纯函数。从 ChatPage 录音控制残留魔法数字抽出，可单测。
// 定时器/权限/文件 IO 留宿主。

/// 录音上限 60 秒（到点自动结束并发送）。
const int kMaxRecordMs = 60000;

/// 录音 tick 步长 100ms。
const int kRecordTickMs = 100;

/// 全程振幅采样上限（超量丢最旧，防内存膨胀）。
const int kMaxWaveSamples = 750;

/// 实时 UI 振幅保留数。
const int kMaxUiAmps = 30;

/// 是否达到录音上限（到点自动结束）。
bool shouldAutoStopRecord(int durationMs, {int limitMs = kMaxRecordMs}) =>
    durationMs >= limitMs;

/// 采样是否超上限（超量调用方移除最旧）。
bool exceedsSampleCap(int length, {int cap = kMaxWaveSamples}) =>
    length > cap;

/// UI 振幅是否超上限。
bool exceedsUiAmpCap(int length, {int cap = kMaxUiAmps}) => length > cap;

/// 推进录音时长（tick 步长累加）。
int nextRecordDuration(int current, {int stepMs = kRecordTickMs}) =>
    current + stepMs;
