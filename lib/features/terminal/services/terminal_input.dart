/// 终端键盘输入的文本差分编码。
///
/// Flutter 软键盘只能通过 [TextEditingValue] 提供字符，不能直接提供
/// PTY 按键事件。终端输入框因此保留一条当前输入行，并把每次（已提交的）
/// 文本变化转换成 PTY 需要的原始字节：
///
///   - 新增字符 → 原样写入；
///   - 删除字符 → 写入 DEL (`\x7f`)，由 Shell/readline 执行退格；
///   - 输入法组合中 → 暂不发送，避免拼音字母被提前写进 Shell；
///   - 换行 → `\r`，与终端 Enter 语义一致。
///
/// 该文件不依赖 Flutter，便于对编码规则做纯 Dart 回归测试。
library;

/// 一次文本变化对应的 PTY 写入结果。
class TerminalInputDelta {
  /// 要写入 PTY 的原始数据；为空表示无需写入。
  final String data;

  /// 写入成功后，Shell 当前输入行应包含的文本。
  final String sentText;

  const TerminalInputDelta({required this.data, required this.sentText});

  bool get isEmpty => data.isEmpty;
}

/// 计算从 [sentText] 到 [nextText] 需要发送给 PTY 的增量。
///
/// [composing] 为 true 时表示输入法仍在组词，返回空增量且不推进
/// [sentText]，等组词提交后再一次性发送。输入框发生中间插入/替换时，
/// 按公共前缀计算需要退格的数量，再重发剩余文本。
TerminalInputDelta terminalInputDelta({
  required String sentText,
  required String nextText,
  bool composing = false,
}) {
  if (composing) {
    return TerminalInputDelta(data: '', sentText: sentText);
  }

  final sentRunes = sentText.runes.toList(growable: false);
  final nextRunes = nextText.runes.toList(growable: false);
  var prefix = 0;
  while (prefix < sentRunes.length &&
      prefix < nextRunes.length &&
      sentRunes[prefix] == nextRunes[prefix]) {
    prefix++;
  }

  final backspaces = sentRunes.length - prefix;
  final inserted = String.fromCharCodes(nextRunes.sublist(prefix));
  final data = _repeatDel(backspaces) + _toPtyText(inserted);
  return TerminalInputDelta(data: data, sentText: nextText);
}

/// 把输入框文本转换为 PTY 文本：统一换行并按 Enter 语义发送 `\r`。
String _toPtyText(String text) {
  return text.replaceAll('\r\n', '\r').replaceAll('\n', '\r');
}

/// 构造用于清空当前 Shell 输入行的退格序列。
///
/// 仅在历史命令替换等“输入框文本被程序改写”的场景使用，避免把旧
/// 输入行残留在 Shell 中。按 Unicode 码点计数，不把 emoji 拆成多个退格。
String terminalBackspacesFor(String text) => _repeatDel(text.runes.length);

String _repeatDel(int count) => List<String>.filled(count, '\x7f').join();
