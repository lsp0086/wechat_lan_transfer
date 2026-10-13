// E1：录音 UI 纯函数。从 ChatPage 录音遮罩/按钮 _isCancelling 三元簇抽出，可单测。
// 只用 int/bool 纯函数，不 import material；宿主再包 Color/IconData。

// E1：遮罩圆圈底色收敛（取消态红，否则半透明白）。
int recordMaskCircleColor({required bool cancelling}) =>
    cancelling ? 0xFFFF5252 : 0x3CFFFFFF;

// E1：maskCircleColor 别名（调用点薄委托用短名）。
int maskCircleColor({required bool cancelling}) =>
    recordMaskCircleColor(cancelling: cancelling);

// E1：遮罩圆圈描边收敛（取消态红，否则白54）。
int recordMaskBorderColor({required bool cancelling}) =>
    cancelling ? 0xFFFF5252 : 0x8AFFFFFF;

// E1：录音图标门控（取消态删图标，否则麦克风，宿主据 bool 选 IconData）。
bool recordIconIsDelete({required bool cancelling}) => cancelling;

// E1：录音图标/按钮前景收敛（取消态纯白，否则白70）。
int recordButtonFg({required bool cancelling}) =>
    cancelling ? 0xFFFFFFFF : 0xB3FFFFFF;

// E1：提示文案色收敛（取消态红，否则白54）。
int recordHintColor({required bool cancelling}) =>
    cancelling ? 0xFFFF5252 : 0x8AFFFFFF;

// E1：发送区底色收敛（取消态半透明白，否则品牌绿）。
int recordSendBg({required bool cancelling}) =>
    cancelling ? 0x28FFFFFF : 0xFF07C160;

// E1：录音条底色收敛（取消态半透红，否则灰）。
int recordBarBg({required bool cancelling}) =>
    cancelling ? 0xB4FF5252 : 0xFFC8C8C8;

// E1：遮罩底纱透明度收敛（Colors.black54 → alpha 0x8A）。
int recordMaskAlpha() => 0x8A;

// E1：遮罩底纱色收敛（Colors.black54 → ARGB int，宿主包 Color）。
int recordMaskScrim() => 0x8A000000;

// E1：波形区高度收敛（原值 40.0）。
double waveHeight() => 40.0;

// E1：录音条高度收敛（原值 40.0，与波形区同高）。
double recordBarHeight() => 40.0;

// E1：录音条圆角收敛（原值 6.0）。
double recordBarRadius() => 6.0;

// E1：松开发送提示圆角收敛（原值 20.0）。
double recordSendRadius() => 20.0;

// E1：波形指示器尺寸收敛（原值 40x16）。
double recordIndicatorW() => 40.0;
double recordIndicatorH() => 16.0;

// E1：录音时长文案色收敛（Colors.white70 → ARGB int）。
int recordDurationColor() => 0xB3FFFFFF;
