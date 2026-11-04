/// ====================================================================
/// Runtime Process Runner
///
/// 统一、可靠、可测试地执行 Runtime 命令。
///
/// 职责（只做四件事）：
///   1. 选择正确的 ExecutionAdapter
///   2. 合并环境变量
///   3. 执行命令（带超时/取消）
///   4. 返回统一结果
///
/// 不负责：
///   - 解析 executable（由 Provider 负责）
///   - 管理 Runtime（由 RuntimeManager 负责）
///   - PTY / 交互式 session（由 TerminalSessionRunner 负责）
///
/// 使用方式：
///   final runner = RuntimeProcessRunner();
///   final result = await runner.run(RuntimeProcessRequest(
///     executable: '/path/to/node',
///     arguments: ['--version'],
///   ));
/// ====================================================================
library;

import 'dart:async';
import 'dart:io';

import '../../core/logger/log_service.dart';
import 'runner_models.dart';

/// ====================================================================
/// LocalProcessExecution
///
/// 在本地进程中直接执行命令。
/// 包装 dart:io Process.run / Process.start。
///
/// 适用于：
///   - Android System Runtime（/system/bin/sh, /system/bin/curl）
///   - App Bundled Runtime（已安装的 node/python/git）
/// ====================================================================
/// execute 结束原因（决定 kill 后 bounded cleanup 路径）
enum _ExitReason { exit, timeout, cancel }

/// ====================================================================
/// LocalProcessExecution
///
/// 在本地进程中直接执行命令。
/// 包装 dart:io Process.run / Process.start。
///
/// 适用于：
///   - Android System Runtime（/system/bin/sh, /system/bin/curl）
///   - App Bundled Runtime（已安装的 node/python/git）
///
/// 超时/取消安全（修复 Coding Runtime 30% 永久卡死）：
///   PRoot 场景中 apt-get 卡 TCP connect（D 状态不可中断），
///   kill PRoot 后 tracee 可能仍存活并持有 stdout/stderr 管道写端，
///   导致 stream 永不 done。因此：
///   1. timeout/cancel 后立即进入 bounded cleanup；
///   2. stdout/stderr drain 有最大等待时间（cleanupTimeout）；
///   3. cleanup 超时后强制返回，绝不无限等待；
///   4. 结果明确区分 command timeout / process cleanup timeout / cancel。
/// ====================================================================
class LocalProcessExecution implements IExecutionAdapter {
  /// 超时/取消 kill 后，等待 stdout/stderr 管道排空的最长时间。
  ///
  /// 超过该时间判定为 process cleanup timeout：cancel 监听并强制返回。
  /// 测试可注入短时长，避免真实等待 10 秒。
  final Duration cleanupTimeout;

  /// kill（SIGTERM）后等待进程退出的时间；超时则升级 SIGKILL。
  final Duration killWaitTimeout;

  /// 外部取消信号（测试注入）。null 表示无外部取消（保持原行为）。
  final Future<void>? cancelSignal;

  /// 当前执行的取消信号（供运行中动态停止，如 AI 停止生成）。
  ///
  /// 每次 execute 使用独立 Completer：一次取消只作用于当前（或尚未启动的
  /// 下一次）执行，结束后立即清理，避免旧取消信号让后续所有命令被误判为
  /// cancelled（真机「对话一直显示已停止生成」根因）。
  Completer<void>? _activeCancel;

  /// 执行尚未启动时收到的取消请求，只消费一次。
  bool _cancelPending = false;

  LocalProcessExecution({
    this.cleanupTimeout = const Duration(seconds: 10),
    this.killWaitTimeout = const Duration(seconds: 3),
    this.cancelSignal,
  });

  /// 请求取消当前（或下一次）执行。
  ///
  /// 与构造参数 [cancelSignal] 取并集：任一触发即取消。
  void requestCancel() {
    final active = _activeCancel;
    if (active == null || active.isCompleted) {
      // 没有正在执行的进程时，停止按钮不应留下任何跨执行状态。
      // 需要覆盖“任务已开始但子进程尚未启动”的窗口时，业务层必须调用
      // [requestCancelNext]，由任务生命周期负责清理。
      LogService.warning(
        'ProcessRunner',
        'requestCancel: 当前无活动进程，忽略\n'
        '${_stackSummary(StackTrace.current)}',
      );
      return;
    }
    active.complete();
    LogService.warning(
      'ProcessRunner',
      'requestCancel: 已取消当前执行\n'
      '${_stackSummary(StackTrace.current)}',
    );
  }

  /// 取消当前执行；若命令已经在任务内排队但尚未启动，则消费一次取消。
  ///
  /// 仅供拥有明确任务生命周期的调用方（CodexRunner）使用：任务结束时会
  /// 调用 [clearPendingCancel]，因此不会把取消信号泄漏给下一轮对话。
  void requestCancelNext() {
    final active = _activeCancel;
    if (active != null && !active.isCompleted) {
      active.complete();
      return;
    }
    _cancelPending = true;
    LogService.warning(
      'ProcessRunner',
      'requestCancelNext: 当前进程尚未启动，标记本任务下一次执行取消',
    );
  }

  /// 清除尚未被任何执行消费的取消标记。
  void clearPendingCancel() {
    if (_cancelPending) {
      _cancelPending = false;
      LogService.debug('ProcessRunner', 'clearPendingCancel: 已清除遗留取消标记');
    }
  }

  static String _stackSummary(StackTrace stack, {int maxLines = 12}) {
    final lines = stack.toString().split('\n');
    return lines.take(maxLines).join('\n');
  }

  /// 合并外部与本次执行的取消信号
  Future<void> _effectiveCancel(Completer<void> runCancel) {
    if (cancelSignal == null) return runCancel.future;
    return Future.any([cancelSignal!, runCancel.future]);
  }

  @override
  String get id => 'local';

  @override
  bool supports(RuntimeProcessRequest request) {
    // 本地执行支持 android / app 请求
    // Linux Runtime 由 LinuxExecutionAdapter 处理（PRoot）
    return request.runtimeId == null ||
        request.runtimeId == 'android' ||
        request.runtimeId == 'app';
  }

  @override
  Future<RuntimeProcessResult> execute(RuntimeProcessRequest request) async {
    final start = DateTime.now();
    final runCancel = Completer<void>();
    _activeCancel = runCancel;
    var consumedPendingCancel = false;
    if (_cancelPending) {
      _cancelPending = false;
      consumedPendingCancel = true;
      runCancel.complete();
    }
    LogService.debug(
      'ProcessRunner',
      'execute start: label=${request.label ?? request.executable} '
      'pendingCancel=$consumedPendingCancel',
    );
    try {
      final result = await _execute(request, start, runCancel);
      LogService.debug(
        'ProcessRunner',
        'execute end: label=${request.label ?? request.executable} '
        'exitCode=${result.exitCode} cancelled=${result.cancelled} '
        'timedOut=${result.timedOut} '
        'durationMs=${result.duration.inMilliseconds}',
      );
      return result;
    } finally {
      if (identical(_activeCancel, runCancel)) {
        _activeCancel = null;
      }
    }
  }

  Future<RuntimeProcessResult> _execute(
    RuntimeProcessRequest request,
    DateTime start,
    Completer<void> runCancel,
  ) async {
    try {
      // ─── Shell 模式下使用 Process.run with runInShell ───────
      if (request.runInShell) {
        final result = await Process.run(
          request.executable,
          request.arguments,
          environment: request.environment,
          workingDirectory: request.workingDirectory,
          runInShell: true,
        );

        return RuntimeProcessResult(
          exitCode: result.exitCode,
          stdout: (result.stdout as String?) ?? '',
          stderr: (result.stderr as String?) ?? '',
          duration: DateTime.now().difference(start),
          request: request,
        );
      }

      // ─── Direct execution ────────────────────────────────────
      // 使用 Process.start 以获得更好的超时/取消控制
      final process = await Process.start(
        request.executable,
        request.arguments,
        environment: request.environment,
        workingDirectory: request.workingDirectory,
      );

      // ─── 结束原因竞态：exit / timeout / cancel 谁先完成 ──────
      final reasonCompleter = Completer<_ExitReason>();
      process.exitCode.then((_) {
        if (!reasonCompleter.isCompleted) {
          reasonCompleter.complete(_ExitReason.exit);
        }
      });

      Timer? timeoutTimer;
      if (request.timeout != null) {
        timeoutTimer = Timer(request.timeout!, () {
          if (!reasonCompleter.isCompleted) {
            reasonCompleter.complete(_ExitReason.timeout);
          }
        });
      }

      final cancelFuture = _effectiveCancel(runCancel);
      cancelFuture.then((_) {
        if (!reasonCompleter.isCompleted) {
          reasonCompleter.complete(_ExitReason.cancel);
        }
      });

      // ─── 收集输出（保存 subscription：cleanup 超时需 cancel） ─
      final stdoutBuf = StringBuffer();
      final stderrBuf = StringBuffer();
      final stdoutSub = process.stdout
          .transform(const SystemEncoding().decoder)
          .listen((data) {
        stdoutBuf.write(data);
        // 流式回调：只读消费 stdout 增量（如 codex --json 事件流）
        request.onStdoutChunk?.call(data);
      });
      final stderrSub = process.stderr
          .transform(const SystemEncoding().decoder)
          .listen((data) => stderrBuf.write(data));
      final stdoutDone = stdoutSub.asFuture<void>();
      final stderrDone = stderrSub.asFuture<void>();

      // ─── 等待进程完成（可被超时/取消中断） ────────────────────
      final reason = await reasonCompleter.future;

      int exitCode;
      bool timedOut = false;
      bool cancelled = false;

      if (reason == _ExitReason.timeout) {
        // command timeout → kill，短等待后升级 SIGKILL
        timedOut = true;
        exitCode = -2;
        await _killAndWait(process);
      } else if (reason == _ExitReason.cancel) {
        // cancellation → kill，短等待后升级 SIGKILL
        cancelled = true;
        exitCode = -3;
        await _killAndWait(process);
      } else {
        exitCode = await process.exitCode;
      }

      timeoutTimer?.cancel();

      // ─── bounded cleanup ─────────────────────────────────────
      // 超时/取消后 tracee 可能仍持有管道写端 → stream 永不 done。
      // 并行 drain，各自限时；超时则 cancel 对应监听强制结束。
      final drainTimedOut = await Future.wait([
        _drainWithTimeout(stdoutDone, stdoutSub, cleanupTimeout),
        _drainWithTimeout(stderrDone, stderrSub, cleanupTimeout),
      ]);
      final cleanupTimedOut = drainTimedOut.contains(true);

      return RuntimeProcessResult(
        exitCode: exitCode,
        stdout: stdoutBuf.toString(),
        stderr: stderrBuf.toString(),
        duration: DateTime.now().difference(start),
        timedOut: timedOut,
        cancelled: cancelled,
        cleanupTimedOut: cleanupTimedOut,
        error: cleanupTimedOut
            ? '进程已${timedOut ? "超时" : cancelled ? "取消" : "退出"}，'
                '但 stdout/stderr 管道未在 '
                '${cleanupTimeout.inSeconds}s 内关闭'
                '（可能子进程仍存活并持有管道），已强制结束清理'
            : null,
        request: request,
      );
    } on ProcessException catch (e) {
      return RuntimeProcessResult(
        exitCode: -1,
        error: _processExceptionMessage(e),
        duration: DateTime.now().difference(start),
        request: request,
      );
    } on ArgumentError catch (e) {
      return RuntimeProcessResult(
        exitCode: -1,
        error: '参数错误: $e',
        duration: DateTime.now().difference(start),
        request: request,
      );
    } catch (e) {
      return RuntimeProcessResult(
        exitCode: -1,
        error: '启动失败: $e',
        duration: DateTime.now().difference(start),
        request: request,
      );
    }
  }

  /// kill 进程（SIGTERM），短等待后升级 SIGKILL。
  ///
  /// tracee 处于 D 状态时 SIGKILL 也会排队，真正的兜底是后续
  /// bounded drain（_drainWithTimeout），这里只负责尽力终止。
  Future<void> _killAndWait(Process process) async {
    process.kill(); // SIGTERM
    try {
      await process.exitCode.timeout(killWaitTimeout);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
    }
  }

  /// bounded drain：等待 stream 完成，超时则 cancel 监听。
  ///
  /// 返回 true 表示 cleanup 超时（stream 未在 [timeout] 内完成）。
  static Future<bool> _drainWithTimeout(
    Future<void> done,
    StreamSubscription<String> sub,
    Duration timeout,
  ) async {
    try {
      await done.timeout(timeout);
      return false;
    } on TimeoutException {
      await sub.cancel();
      return true;
    }
  }

  /// 将 ProcessException 转为人类可读的消息
  ///
  /// 注意：Dart 3.12 起 ProcessException 不再暴露 osError/errno，
  /// 因此保留完整 toString（含 Command 行）作为诊断上下文，
  /// 便于真机区分「无执行权限」「文件不存在」「ABI 不匹配」。
  static String _processExceptionMessage(ProcessException e) {
    final msg = e.toString();
    if (msg.contains('No such file or directory')) {
      return '可执行文件不存在: ${e.executable}\n$msg';
    }
    if (msg.contains('Permission denied')) {
      return '权限不足: ${e.executable}\n$msg';
    }
    return msg;
  }
}

/// ====================================================================
/// RuntimeProcessRunner
///
/// 统一入口：选择适配器 → 执行 → 返回统一结果。
///
/// 所有 Runtime 命令执行都应通过此 Runner。
/// ====================================================================
class RuntimeProcessRunner {
  final List<IExecutionAdapter> _adapters;

  RuntimeProcessRunner({
    List<IExecutionAdapter>? adapters,
  }) : _adapters = adapters ?? [LocalProcessExecution()];

  /// 注册执行适配器
  void registerAdapter(IExecutionAdapter adapter) {
    _adapters.add(adapter);
  }

  /// 执行命令
  ///
  /// 自动选择适配器，合并环境，执行并返回结果。
  Future<RuntimeProcessResult> run(RuntimeProcessRequest request) async {
    // ─── 1. 选择适配器 ──────────────────────────────────────────
    final adapter = _selectAdapter(request);
    if (adapter == null) {
      return RuntimeProcessResult(
        exitCode: -1,
        error: '没有适配器支持此请求 (runtimeId=${request.runtimeId}, '
            'executable=${request.executable})',
        request: request,
      );
    }

    LogService.debug(
      'ProcessRunner',
      '${request.label ?? adapter.id}: ${request.executable} '
      '${request.arguments.join(" ")}',
    );

    // ─── 2. 执行 ────────────────────────────────────────────────
    try {
      final result = await adapter.execute(request);
      return result;
    } catch (e) {
      return RuntimeProcessResult(
        exitCode: -1,
        error: '适配器执行失败: $e',
        request: request,
      );
    }
  }

  /// 便捷方法：运行并获取 stdout（自动 trim）
  ///
  /// 如果执行失败，返回 null。
  Future<String?> runAndGetStdout(RuntimeProcessRequest request) async {
    final result = await run(request);
    if (result.isSuccess && result.stdout.trim().isNotEmpty) {
      return result.stdout.trim();
    }
    return null;
  }

  /// 便捷方法：运行并检查 exitCode == 0
  Future<bool> runAndCheck(RuntimeProcessRequest request) async {
    final result = await run(request);
    return result.isSuccess;
  }

  /// 选择适配器
  IExecutionAdapter? _selectAdapter(RuntimeProcessRequest request) {
    // 优先级：注册顺序
    for (final adapter in _adapters) {
      if (adapter.supports(request)) return adapter;
    }
    return null;
  }

  /// 获取已注册的适配器列表
  List<IExecutionAdapter> get registeredAdapters =>
      List.unmodifiable(_adapters);
}
