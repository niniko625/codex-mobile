/// 终端键盘输入差分编码回归测试。
///
/// 终端页把软键盘提交的文本变化转换成 PTY 原始输入：普通字符原样写入，
/// 删除转成 DEL (`\x7f`)，换行转成 `\r`，输入法组词期间暂缓发送。
library;

import 'package:codex_mobile_pro/features/terminal/services/terminal_input.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('terminalInputDelta', () {
    test('追加普通字符只发送新增部分', () {
      final delta = terminalInputDelta(
        sentText: 'echo hi',
        nextText: 'echo hi2',
      );
      expect(delta.data, '2');
      expect(delta.sentText, 'echo hi2');
    });

    test('删除字符发送 DEL，Shell/readline 负责退格', () {
      final delta = terminalInputDelta(
        sentText: 'echo hi',
        nextText: 'echo h',
      );
      expect(delta.data, '\x7f');
      expect(delta.sentText, 'echo h');
    });

    test('中间替换先退格再重发剩余文本', () {
      final delta = terminalInputDelta(
        sentText: 'abcd',
        nextText: 'abXY',
      );
      expect(delta.data, '\x7f\x7fXY');
      expect(delta.sentText, 'abXY');
    });

    test('输入法组词期间不向 PTY 发送字符', () {
      final delta = terminalInputDelta(
        sentText: 'git ',
        nextText: 'git zhong',
        composing: true,
      );
      expect(delta.data, isEmpty);
      expect(delta.sentText, 'git ');
    });

    test('组词提交后一次性发送提交文本', () {
      final delta = terminalInputDelta(
        sentText: 'git ',
        nextText: 'git 中文',
        composing: false,
      );
      expect(delta.data, '中文');
      expect(delta.sentText, 'git 中文');
    });

    test('换行统一转换为回车，按终端 Enter 语义提交', () {
      final delta = terminalInputDelta(
        sentText: '',
        nextText: 'echo a\n',
      );
      expect(delta.data, 'echo a\r');
    });

    test('Unicode 退格按码点计数', () {
      final delta = terminalInputDelta(
        sentText: '😀x',
        nextText: '😀',
      );
      expect(delta.data, '\x7f');
    });
  });

  test('terminalBackspacesFor 生成等量 DEL', () {
    expect(terminalBackspacesFor('abc'), '\x7f\x7f\x7f');
    expect(terminalBackspacesFor(''), isEmpty);
  });
}
