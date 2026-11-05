import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/ai/providers/chat_provider.dart';
import '../../features/terminal/providers/terminal_provider.dart';
import '../../features/terminal/services/terminal_service.dart';
import '../ai/ai_message.dart';
import '../logger/log_service.dart';

/// 真机端到端自测。
///
/// 仅在启动 Intent 携带 `codex_self_test=true` 时运行。自测通过真实的聊天
/// Provider 连续发送三轮消息，既验证 Codex CLI / Runtime 链路，也验证后续轮次
/// 不会被上一轮遗留的取消信号误伤。普通启动不会读取或执行任何测试逻辑。
class AppSelfTest {
  AppSelfTest._();

  static const String _channelName = 'com.codexmobile.app/launch';
  static const String _fileName = 'codex_mobile_selftest.log';
  static const Duration _turnTimeout = Duration(minutes: 3);

  static bool _listening = false;
  static bool _running = false;

  /// 注册原生侧「自测已请求」回调，并检查首次启动参数。
  static Future<void> start(WidgetRef ref) async {
    if (!Platform.isAndroid) return;

    if (!_listening) {
      _listening = true;
      const MethodChannel(_channelName).setMethodCallHandler((call) async {
        if (call.method != 'selfTestRequested') return null;
        await runIfRequested(ref);
        return null;
      });
    }
    await runIfRequested(ref);
  }

  /// 停止监听；仅用于根组件销毁（正常进程生命周期内不会发生）。
  static void stopListening() {
    if (!_listening) return;
    _listening = false;
    const MethodChannel(_channelName).setMethodCallHandler(null);
  }

  static Future<void> runIfRequested(WidgetRef ref) async {
    if (!Platform.isAndroid || _running) return;

    var requested = false;
    try {
      requested = await const MethodChannel(_channelName)
              .invokeMethod<bool>('consumeSelfTest') ??
          false;
    } catch (e) {
      LogService.warning('AppSelfTest', '读取启动参数失败: $e');
      return;
    }
    if (!requested) return;

    _running = true;
    try {
      await _run(ref);
    } finally {
      _running = false;
    }
  }

  static Future<void> _run(WidgetRef ref) async {
    final output = StringBuffer()
      ..writeln('Codex Mobile 真机自测')
      ..writeln('startedAt=${DateTime.now().toIso8601String()}')
      ..writeln('status=RUNNING');
    await _write(output);

    var terminalPassed = false;
    var aiPassed = false;
    try {
      await _runTerminal(ref: ref, output: output);
      terminalPassed = true;
    } catch (e, stack) {
      output
        ..writeln('\n[terminal][error] $e')
        ..writeln('[terminal][stack]\n$stack');
    }

    try {
      final notifier = ref.read(chatProvider.notifier);
      await _waitForSessionRestore(notifier);
      notifier.createSession(title: 'App 自测');

      output.writeln('\n[session] ${notifier.currentSessionId}');
      await _runTurn(
        notifier: notifier,
        prompt: '这是 App 自测。请只回复 SELFTEST1，不要执行命令，不要修改文件。',
        expected: 'SELFTEST1',
        label: '第一轮',
        output: output,
      );
      await _runTurn(
        notifier: notifier,
        prompt: '这是 App 自测第二轮。请只回复 SELFTEST2，不要执行命令，不要修改文件。',
        expected: 'SELFTEST2',
        label: '第二轮',
        output: output,
      );
      await _runTurn(
        notifier: notifier,
        prompt: '这是 App 自测第三轮。请只回复：手机端 Codex 已确认可正常使用。不要执行命令，不要修改文件。',
        expected: '手机端 Codex 已确认可正常使用',
        label: '第三轮',
        output: output,
      );
      aiPassed = true;
    } catch (e, stack) {
      output
        ..writeln('\n[ai][error] $e')
        ..writeln('[ai][stack]\n$stack');
    } finally {
      final passed = terminalPassed && aiPassed;
      output
        ..writeln('\nfinishedAt=${DateTime.now().toIso8601String()}')
        ..writeln('terminal=${terminalPassed ? 'PASS' : 'FAIL'}')
        ..writeln('ai=${aiPassed ? 'PASS' : 'FAIL'}')
        ..writeln('status=${passed ? 'PASS' : 'FAIL'}');
      await _write(output);
      LogService.info(
        'AppSelfTest',
        '真机自测结束: terminal=${terminalPassed ? 'PASS' : 'FAIL'}, '
        'ai=${aiPassed ? 'PASS' : 'FAIL'}',
      );
    }
  }

  /// 终端真机自测：直接走 Native PTY 的原始字符写入通道。
  ///
  /// 与终端页键盘模式使用同一个 `writeRaw` 路径，覆盖：
  ///   - 普通字符逐段写入；
  ///   - DEL (`\x7f`) 退格；
  ///   - `\r` 提交回车；
  ///   - PTY 输出回传与 Shell 实际执行结果。
  ///
  /// 命令里故意使用 `$((40+2))`，避免命令本身的 ECHO 文本包含
  /// `CODEX_TERM_42` 造成假阳性。
  static Future<void> _runTerminal({
    required WidgetRef ref,
    required StringBuffer output,
  }) async {
    const marker = 'CODEX_TERM_42';
    final notifier = ref.read(terminalProvider.notifier);
    String? sessionId;
    output
      ..writeln('\n[terminal] startedAt=${DateTime.now().toIso8601String()}')
      ..writeln('[terminal] command=echo CODEX_TERM_4<DEL>2');
    await _write(output);

    try {
      sessionId = await notifier
          .createSession(name: '自测终端')
          .timeout(const Duration(seconds: 60));
      final sessions = ref
          .read(terminalProvider)
          .sessions
          .where((item) => item.id == sessionId);
      if (sessions.isEmpty) {
        throw StateError('终端会话创建后未出现在状态中');
      }
      final session = sessions.first;

      output
        ..writeln('[terminal] sessionId=${session.id}')
        ..writeln('[terminal] shellPath=${session.shellPath}')
        ..writeln('[terminal] args=${session.shellInfo.args.join(' ')}')
        ..writeln('[terminal] backend=${session.backendName}')
        ..writeln('[terminal] status=${session.status.name}');
      await _write(output);

      if (session.status != TerminalSessionStatus.running) {
        throw StateError('终端会话未运行: ${session.status.name}');
      }

      // 给 PRoot / bash 留出启动时间；PTY 会缓冲提前写入的输入。
      await Future<void>.delayed(const Duration(milliseconds: 800));
      for (final chunk in <String>[
        'echo CODEX_TERM_4',
        '9',
        '\x7f',
        '2',
        '\r',
      ]) {
        notifier.writeRaw(chunk);
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }

      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (!session.outputText.contains(marker)) {
        if (DateTime.now().isAfter(deadline)) {
          final tail = _tail(session.outputText);
          throw TimeoutException('等待终端输出 $marker 超时；最近输出:\n$tail');
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }

      output
        ..writeln('[terminal] received=$marker')
        ..writeln('[terminal] outputTail=${_tail(session.outputText)}')
        ..writeln('[terminal] status=PASS')
        ..writeln('[terminal] finishedAt=${DateTime.now().toIso8601String()}');
      await _write(output);
    } finally {
      if (sessionId != null) {
        try {
          await notifier.closeSession(sessionId);
        } catch (_) {}
      }
    }
  }

  static String _tail(String text, {int maxChars = 1200}) {
    if (text.length <= maxChars) return text;
    return text.substring(text.length - maxChars);
  }

  static Future<void> _runTurn({
    required ChatNotifier notifier,
    required String prompt,
    required String expected,
    required String label,
    required StringBuffer output,
  }) async {
    output
      ..writeln('\n[$label] prompt=$prompt')
      ..writeln('[$label] startedAt=${DateTime.now().toIso8601String()}');
    await _write(output);

    await notifier
        .sendMessage(prompt)
        .timeout(
          _turnTimeout,
          onTimeout: () {
            notifier.stopGeneration();
            throw TimeoutException('$label 超过 ${_turnTimeout.inMinutes} 分钟');
          },
        );

    final assistant = notifier.currentMessages.lastWhere(
      (message) => message.role == ChatRole.assistant,
      orElse: () => ChatMessage(
        id: 'missing',
        role: ChatRole.assistant,
        content: '',
        timestamp: DateTime.now(),
      ),
    );
    final content = assistant.content.trim();
    final exitCode = assistant.metadata?['exitCode']?.toString();
    output
      ..writeln('[$label] exitCode=${exitCode ?? '(null)'}')
      ..writeln('[$label] assistant=$content');

    if (content.isEmpty) {
      throw StateError('$label 没有收到助手回复');
    }
    if (!content.contains(expected)) {
      throw StateError('$label 回复不包含 $expected');
    }
    if (content.contains('已停止生成') ||
        content.contains('执行被意外取消') ||
        content.contains('未收到有效回复')) {
      throw StateError('$label 出现异常停止标记');
    }
    if (exitCode != null && exitCode != '0') {
      throw StateError('$label exitCode=$exitCode');
    }
    output
      ..writeln('[$label] status=PASS')
      ..writeln('[$label] finishedAt=${DateTime.now().toIso8601String()}');
    await _write(output);
  }

  static Future<void> _waitForSessionRestore(ChatNotifier notifier) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!notifier.restoreCompleted) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('等待会话恢复超时');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  static Future<void> _write(StringBuffer output) async {
    await LogService.exportTextToDownload(
      fileName: _fileName,
      content: output.toString(),
    );
  }
}
