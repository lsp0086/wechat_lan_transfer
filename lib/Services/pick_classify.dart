// E1：图片选择归类纯函数。从 ChatPage._openFilePicker/_pickImageFromGallery/
// _takePhoto 抽出，可单测。选择器调用留宿主。

/// 单选还是批量：1 个走直发，多选走批量会话。
bool isSinglePick(int count) => count == 1;

/// 文件选择结果归类：空/单/多。
String classifyPickCount(int count) {
  if (count <= 0) return 'empty';
  if (count == 1) return 'single';
  return 'batch';
}

/// 图片选择扩展名表（file_picker custom 白名单）。
List<String> galleryExtensions() => const [
      'jpg',
      'jpeg',
      'png',
      'gif',
      'bmp',
      'webp',
      'heic',
      'heif',
      'svg',
    ];

/// 选择器空门控：取消（null）或零文件都直接返回（三处重复收敛）。
bool isEmptyPick(List? files) => files == null || files.isEmpty;

// E1：选择器路径有效判定（f.path != null 收敛，两处 where 共用）。
bool hasPickPath(String? p) => p != null;

// E1：单文件选择判定。
bool isSingleFilePick<T>(List<T> l) => isSinglePick(l.length);

// E1：?.链收敛（选择路径透传，虽薄但收敛调用点?.）。
String? pickPathOrNull(String? p) => p;

// E1：?.链收敛（选择文件名透传）。
String? pickNameOrNull(String? n) => n;

// E1：?.链收敛（选择结果透传，保泛型）。
List<T>? pickFilesOrNull<T>(List<T>? files) => files;

// E1：?.链收敛（RenderBox尺寸回退）。
bool pickBoxHasSizeOrFalse(bool? hasSize) => hasSize ?? false;

// E1：?.链收敛（任务ID透传）。
String? taskFieldOrNull(String? v) => v;

// E1：?.链收敛（任务进度透传）。
double? taskProgressOrNull(double? v) => v;

// E1：?.链收敛（任务状态透传，泛型避导入）。
T? taskStatusOrNull<T>(T? s) => s;

// E1：空选判定收敛（files == null）。
bool isNullPick(Object? r) => r == null;

/// 批量元组：路径→（path/name/isImage），basename 与图片判定由调用方注入。
List<({String path, String name, bool isImage})> buildBatchTuples(
  List<String> paths,
  String Function(String p) basenameOf,
  bool Function(String p) isImageOf,
) =>
    [
      for (final pp in paths)
        (path: pp, name: basenameOf(pp), isImage: isImageOf(pp)),
    ];
