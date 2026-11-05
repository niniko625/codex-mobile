/// ====================================================================
/// CodexAppServerClient — 长驻 `codex app-server` JSON-RPC 客户端
///
/// App 内 AI 聊天不再每轮启动一次 `codex exec`，而是复用一个 app-server
/// 进程：线程、插件、Skills、MCP、动态工具和会话续聊全部由 Codex 本体
/// 维护。
///
/// 协议事实（codex-cli 0.166 实测）：
///   - stdio 上每行一个 JSON-RPC 消息（不是 Content-Length 帧）；
///   - 客户端先 `initialize`，再发送 `initialized` 通知；
///   - 对话：`thread/start` → `turn/start` → 通知流 → `turn/completed`；
///   - 续聊：`thread/resume` 后继续 `turn/start`；
///   - 服务端也会发请求（审批、用户输入、MCP elicitation、动态工具），
///     必须逐条应答，否则该轮会永久停在 working。
/// ====================================================================
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/logger/log_service.dart';
import '../../runtime/process/runner_models.dart';
import '../../runtime/provider/linux_runtime_provider.dart';
import 'codex_runner.dart';

/// app-server 启动/协议错误。
class CodexAppServerException implements Exception {
  final String message;
  final String? detail;

  const CodexAppServerException(this.message, {this.detail});

  @override
  String toString() => detail == null || detail!.isEmpty
      ? message
      : '$message\n$detail';
}

/// app-server 进程断开。
class CodexAppServerDisconnectedException extends CodexAppServerException {
  const CodexAppServerDisconnectedException(super.message, {super.detail});
}

/// 已保存的 thread 无法 resume（例如 rollout 被清理）。
class CodexAppServerThreadResumeException extends CodexAppServerException {
  const CodexAppServerThreadResumeException(super.message, {super.detail});
}

/// app-server 发出的原始通知。
class CodexAppServerNotification {
  final String method;
  final Map<String, dynamic> params;
  final int? emittedAtMs;

  const CodexAppServerNotification({
    required this.method,
    required this.params,
    this.emittedAtMs,
  });

  String? get threadId => params['threadId'] as String?;

  /// 不同通知携带 turn id 的位置不同：
  ///   - item/*、turn/* 多数为顶层 `turnId`
  ///   - `turn/started`、`turn/completed` 为 `turn.id`
  String? get turnId {
    final direct = params['turnId'];
    if (direct is String && direct.isNotEmpty) return direct;
    final turn = params['turn'];
    if (turn is Map) {
      final id = turn['id'];
      if (id is String && id.isNotEmpty) return id;
    }
    return null;
  }
}

/// 可注入的进程传输层（测试不需要真实 PRoot）。
abstract class CodexAppServerTransport {
  /// stdout JSONL
  Stream<String> get lines;

  /// stderr 增量（只用于诊断）
  Stream<String> get errors;

  /// 进程退出码
  Future<int> get exitCode;

  void sendLine(String line);

  Future<void> close();
}

/// 根据 LinuxProcessSpec 启动 app-server 传输层。
typedef CodexAppServerTransportFactory =
    Future<CodexAppServerTransport> Function(LinuxProcessSpec spec);

class _IoCodexAppServerTransport implements CodexAppServerTransport {
  final Process process;

  _IoCodexAppServerTransport(this.process);

  @override
  Stream<String> get lines =>
      process.stdout.transform(utf8.decoder).transform(const LineSplitter());

  @override
  Stream<String> get errors =>
      process.stderr.transform(utf8.decoder).transform(const LineSplitter());

  @override
  Future<int> get exitCode => process.exitCode;

  @override
  void sendLine(String line) {
    process.stdin.writeln(line);
  }

  @override
  Future<void> close() async {
    try {
      await process.stdin.close();
    } catch (_) {}
    try {
      process.kill(ProcessSignal.sigterm);
    } catch (_) {}
    try {
      await process.exitCode.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      try {
        process.kill(ProcessSignal.sigkill);
      } catch (_) {}
    }
  }
}

/// 一轮已启动的 app-server turn。
///
/// [events] 是对现有 [CodexEvent] 的适配：
///   - agentMessage delta         → [CodexAgentMessage]
///   - commandExecution item      → [CodexCommandStarted/Completed]
///   - turn/completed             → [CodexTurnCompleted]
/// 文本只发 delta；`item/completed` 的全文仅在没有 delta 时补发，避免重复。
class CodexAppServerTurn {
  final String threadId;
  final StreamController<CodexEvent> _controller =
      StreamController<CodexEvent>();
  final Completer<void> _done = Completer<void>();
  final List<CodexAppServerNotification> _pending = [];
  final Set<String> _agentItemsWithDelta = {};
  final Map<String, StringBuffer> _commandOutputs = {};

  String? turnId;
  String? failure;
  bool interrupted = false;
  int? _inputTokens;
  int? _outputTokens;
  bool _closed = false;

  CodexAppServerTurn({required this.threadId});

  Stream<CodexEvent> get events => _controller.stream;
  Future<void> get done => _done.future;
  bool get isClosed => _closed;

  void attachTurnId(String value) {
    if (_closed || turnId == value) return;
    turnId = value;
    final queued = List<CodexAppServerNotification>.from(_pending);
    _pending.clear();
    for (final notification in queued) {
      _accept(notification);
      if (_closed) break;
    }
  }

  void handle(CodexAppServerNotification notification) {
    if (_closed) return;
    final eventThreadId = notification.threadId;
    if (eventThreadId != null && eventThreadId != threadId) return;

    final eventTurnId = notification.turnId;
    if (turnId == null && eventTurnId != null) {
      _pending.add(notification);
      return;
    }
    if (turnId != null && eventTurnId != null && eventTurnId != turnId) {
      return;
    }
    _accept(notification);
  }

  void _accept(CodexAppServerNotification notification) {
    if (_closed) return;
    try {
      switch (notification.method) {
        case 'turn/started':
          _emit(const CodexTurnStarted());
        case 'item/agentMessage/delta':
          final delta = notification.params['delta'];
          final itemId = notification.params['itemId'];
          if (delta is String && delta.isNotEmpty) {
            if (itemId is String) _agentItemsWithDelta.add(itemId);
            _emit(CodexAgentMessage(text: delta));
          }
        case 'item/commandExecution/outputDelta':
          final itemId = notification.params['itemId'];
          final delta = notification.params['delta'];
          if (itemId is String && delta is String && delta.isNotEmpty) {
            (_commandOutputs[itemId] ??= StringBuffer()).write(delta);
          }
        case 'item/started':
          final item = _asMap(notification.params['item']);
          if (item['type'] == 'commandExecution') {
            final id = (item['id'] as String?) ?? '';
            final command = _commandText(item);
            if (id.isNotEmpty) {
              _commandOutputs.putIfAbsent(id, () => StringBuffer());
              _emit(CodexCommandStarted(id: id, command: command));
            }
          }
        case 'item/completed':
          _handleCompletedItem(notification.params);
        case 'thread/tokenUsage/updated':
          final usage = _asMap(notification.params['tokenUsage']);
          final last = _asMap(usage['last']);
          if (last.isNotEmpty) {
            _inputTokens = last['inputTokens'] as int?;
            _outputTokens = last['outputTokens'] as int?;
          }
        case 'turn/completed':
          _handleTurnCompleted(notification.params);
        case 'error':
          // ErrorNotification 的真实结构：
          //   {error: {message}, willRetry, threadId, turnId}
          // 此前误读 params.message，导致真实错误被静默吞掉，UI 只能一直
          // 停在 working。willRetry=true 是 Codex 自动重连，不应提前结束；
          // false 表示本轮已无法继续，立即结束以免永久转圈。
          final error = _asMap(notification.params['error']);
          final rawMessage = error['message'] ?? notification.params['message'];
          if (rawMessage is String && rawMessage.trim().isNotEmpty) {
            final willRetry = notification.params['willRetry'] == true;
            final message = willRetry ? '$rawMessage（Codex 将自动重试）' : rawMessage;
            _emit(CodexErrorEvent(message: message));
            if (!willRetry) {
              _fail(message);
              return;
            }
          }
        case 'codex/disconnected':
          final message = notification.params['message'];
          _fail(message is String && message.isNotEmpty
              ? message
              : 'Codex app-server 已断开');
      }
    } catch (e) {
      _fail('处理 Codex app-server 事件失败: $e');
    }
  }

  void _handleCompletedItem(Map<String, dynamic> params) {
    final item = _asMap(params['item']);
    switch (item['type']) {
      case 'agentMessage':
        final id = (item['id'] as String?) ?? '';
        if (id.isEmpty || !_agentItemsWithDelta.contains(id)) {
          final text = item['text'];
          if (text is String && text.isNotEmpty) {
            _emit(CodexAgentMessage(text: text));
          }
        }
      case 'commandExecution':
        final id = (item['id'] as String?) ?? '';
        if (id.isEmpty) return;
        final aggregated = item['aggregatedOutput'];
        final output = aggregated is String
            ? aggregated
            : (_commandOutputs[id]?.toString() ?? '');
        final exitCode = item['exitCode'];
        _emit(CodexCommandCompleted(
          id: id,
          command: _commandText(item),
          exitCode: exitCode is int ? exitCode : null,
          output: output,
        ));
        _commandOutputs.remove(id);
    }
  }

  void _handleTurnCompleted(Map<String, dynamic> params) {
    final turn = _asMap(params['turn']);
    final status = turn['status'];
    if (status == 'failed') {
      final error = _asMap(turn['error']);
      final message = error['message'];
      _fail(message is String && message.isNotEmpty
          ? message
          : 'Codex turn 执行失败');
      return;
    }
    if (status == 'interrupted') {
      interrupted = true;
      _emit(CodexTurnCompleted(
        inputTokens: _inputTokens,
        outputTokens: _outputTokens,
        status: 'interrupted',
      ));
      _close();
      return;
    }
    _emit(CodexTurnCompleted(
      inputTokens: _inputTokens,
      outputTokens: _outputTokens,
      status: status is String && status.isNotEmpty ? status : 'completed',
    ));
    _close();
  }

  void _emit(CodexEvent event) {
    if (!_closed && !_controller.isClosed) _controller.add(event);
  }

  void _fail(String message) {
    if (_closed) return;
    failure = message;
    _emit(CodexErrorEvent(message: message));
    _close();
  }

  /// 传输层断开时由客户端注入失败，避免 UI 永久停在 working。
  void failDisconnected(String message) => _fail(message);

  /// 引擎主动停止后，不再等待迟到通知。
  void detach() => _close();

  void _close() {
    if (_closed) return;
    _closed = true;
    if (!_controller.isClosed) {
      unawaited(_controller.close());
    }
    if (!_done.isCompleted) _done.complete();
  }

  static Map<String, dynamic> _asMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return const <String, dynamic>{};
  }

  static String _commandText(Map<String, dynamic> item) {
    final command = item['command'];
    if (command is String) return command;
    if (command is List) return command.join(' ');
    return '';
  }
}

/// 长驻 Codex app-server 客户端。
///
/// 一个实例通常只服务一个工作区；工作区变化时自动重启进程，因为宿主目录
/// 在 PRoot 启动参数里绑定到 guest `/workspace`。
class CodexAppServerClient {
  final LinuxRuntimeProvider _provider;
  final CodexAppServerTransportFactory? _transportFactory;
  final Duration handshakeTimeout;
  final Duration requestTimeout;

  CodexAppServerTransport? _transport;
  StreamSubscription<String>? _lineSubscription;
  StreamSubscription<String>? _errorSubscription;
  Future<void>? _startFuture;
  int _nextRequestId = 1;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  final StreamController<CodexAppServerNotification> _notifications =
      StreamController<CodexAppServerNotification>.broadcast();
  final Set<CodexAppServerTurn> _activeTurns = {};
  final Set<String> _knownThreads = {};
  final StringBuffer _stderrTail = StringBuffer();

  String? _workspaceHost;
  String? _workspaceGuest;
  String? userAgent;
  bool _initialized = false;
  bool _disposed = false;

  CodexAppServerClient({
    LinuxRuntimeProvider? provider,
    CodexAppServerTransportFactory? transportFactory,
    this.handshakeTimeout = const Duration(seconds: 60),
    this.requestTimeout = const Duration(seconds: 60),
  }) : _provider = provider ?? LinuxRuntimeProvider(),
       _transportFactory = transportFactory;

  bool get isRunning => _initialized && _transport != null;
  String? get workspaceHost => _workspaceHost;
  String? get stderrTail => _stderrTail.toString();

  /// 确保 app-server 已启动并完成握手。
  Future<void> ensureStarted({
    required String hostWorkspaceDir,
    String guestWorkingDirectory = '/workspace',
  }) async {
    if (_disposed) {
      throw const CodexAppServerException('Codex app-server 客户端已关闭');
    }
    if (isRunning &&
        _workspaceHost == hostWorkspaceDir &&
        _workspaceGuest == guestWorkingDirectory) {
      return;
    }

    final active = _startFuture;
    if (active != null) {
      await active;
      if (isRunning &&
          _workspaceHost == hostWorkspaceDir &&
          _workspaceGuest == guestWorkingDirectory) {
        return;
      }
    }

    final future = _start(hostWorkspaceDir, guestWorkingDirectory);
    _startFuture = future;
    try {
      await future;
    } finally {
      if (identical(_startFuture, future)) _startFuture = null;
    }
  }

  Future<void> _start(String hostWorkspaceDir, String guestWorkingDirectory) async {
    await _stopTransport();

    final spec = await _provider.buildCodexAppServerSpec(
      hostWorkspaceDir: hostWorkspaceDir,
      guestWorkingDirectory: guestWorkingDirectory,
    );
    if (spec == null) {
      throw const CodexAppServerException(
        '无法启动 Codex app-server：Linux Runtime 或 Codex CLI 未就绪',
        detail: '请先在部署中心完成 Linux 环境与 Codex CLI 安装。',
      );
    }

    LogService.info(
      'CodexAppServer',
      '启动 app-server: host=$hostWorkspaceDir guest=$guestWorkingDirectory',
    );

    CodexAppServerTransport transport;
    try {
      final factory = _transportFactory ?? _startIoTransport;
      transport = await factory(spec);
    } catch (e) {
      throw CodexAppServerException(
        '启动 Codex app-server 失败: $e',
        detail: spec.toString(),
      );
    }

    _transport = transport;
    _stderrTail.clear();
    _lineSubscription = transport.lines.listen(
      _handleLine,
      onError: (Object error, StackTrace stack) {
        LogService.warning('CodexAppServer', 'stdout 读取失败: $error');
      },
    );
    _errorSubscription = transport.errors.listen(
      (line) {
        _stderrTail.writeln(line);
        if (_stderrTail.length > 12000) {
          final text = _stderrTail.toString();
          _stderrTail
            ..clear()
            ..write(text.substring(text.length - 12000));
        }
        LogService.debug('CodexAppServer', 'stderr: $line');
      },
      onError: (Object error) {
        LogService.warning('CodexAppServer', 'stderr 读取失败: $error');
      },
    );
    unawaited(transport.exitCode.then(_handleExit));

    try {
      final result = await _request(
        'initialize',
        {
          'clientInfo': {
            'name': 'codex-mobile-pro',
            'title': 'Codex Mobile',
            'version': '1.0.0',
          },
          'capabilities': {'experimentalApi': true},
        },
        timeout: handshakeTimeout,
      );
      userAgent = result['userAgent'] as String?;
      _send({'method': 'initialized'});
      _initialized = true;
      _workspaceHost = hostWorkspaceDir;
      _workspaceGuest = guestWorkingDirectory;
      LogService.info('CodexAppServer', '握手完成: ${userAgent ?? "unknown"}');
    } catch (e) {
      await _stopTransport();
      throw CodexAppServerException(
        'Codex app-server 握手失败: $e',
        detail: _stderrTail.toString().trim(),
      );
    }
  }

  static Future<CodexAppServerTransport> _startIoTransport(
    LinuxProcessSpec spec,
  ) async {
    final process = await Process.start(
      spec.executable,
      spec.arguments,
      environment: spec.environment,
      // spec.workingDirectory 是 guest 路径（PRoot -w 已生效），
      // 不能传给宿主 Process.start。
      workingDirectory: null,
    );
    return _IoCodexAppServerTransport(process);
  }

  /// 新建 thread，返回 threadId。
  Future<String> startThread({
    required String cwd,
    required String developerInstructions,
  }) async {
    final result = await _request(
      'thread/start',
      {
        'cwd': cwd,
        'approvalPolicy': 'never',
        'sandbox': 'danger-full-access',
        'developerInstructions': developerInstructions,
        'config': {
          'features': {
            'plugins': true,
            'plugin_discovery_prefetch': false,
          },
        },
      },
      timeout: requestTimeout,
    );
    final thread = _asMap(result['thread']);
    final threadId = thread['id'];
    if (threadId is! String || threadId.isEmpty) {
      throw CodexAppServerException(
        'thread/start 未返回 threadId',
        detail: jsonEncode(result),
      );
    }
    _knownThreads.add(threadId);
    return threadId;
  }

  /// 确保 thread 在当前进程内可继续。
  Future<void> ensureThread({
    required String threadId,
    required String cwd,
    required String developerInstructions,
  }) async {
    if (_knownThreads.contains(threadId)) return;
    try {
      await _request(
        'thread/resume',
        {
          'threadId': threadId,
          'cwd': cwd,
          'approvalPolicy': 'never',
          'sandbox': 'danger-full-access',
          'developerInstructions': developerInstructions,
          'config': {
            'features': {
              'plugins': true,
              'plugin_discovery_prefetch': false,
            },
          },
        },
        timeout: requestTimeout,
      );
      _knownThreads.add(threadId);
    } catch (e) {
      throw CodexAppServerThreadResumeException(
        '无法恢复 Codex 会话 threadId=$threadId',
        detail: e.toString(),
      );
    }
  }

  /// 通用 JSON-RPC 请求入口（插件、Skills、MCP、审批策略等能力入口复用）。
  ///
  /// 调用方需保证 [ensureStarted] 已成功；返回服务端 `result` 对象。
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, dynamic> params, {
    Duration? timeout,
  }) {
    return _request(method, params, timeout: timeout);
  }

  /// 启动一轮，并返回可监听的事件对象。
  Future<CodexAppServerTurn> startTurn({
    required String threadId,
    required List<Map<String, dynamic>> input,
  }) async {
    final turn = CodexAppServerTurn(threadId: threadId);
    late final StreamSubscription<CodexAppServerNotification> subscription;
    subscription = _notifications.stream.listen(turn.handle);
    _activeTurns.add(turn);
    unawaited(turn.done.whenComplete(() {
      _activeTurns.remove(turn);
      unawaited(subscription.cancel());
    }));

    try {
      final result = await _request(
        'turn/start',
        {'threadId': threadId, 'input': input},
        timeout: requestTimeout,
      );
      final turnData = _asMap(result['turn']);
      final turnId = turnData['id'];
      if (turnId is! String || turnId.isEmpty) {
        throw CodexAppServerException(
          'turn/start 未返回 turnId',
          detail: jsonEncode(result),
        );
      }
      turn.attachTurnId(turnId);
      return turn;
    } catch (e) {
      turn.detach();
      unawaited(subscription.cancel());
      rethrow;
    }
  }

  /// 中断当前 turn；不杀长驻进程，后续消息仍可复用。
  Future<void> interruptTurn({
    required String threadId,
    required String turnId,
  }) async {
    try {
      await _request(
        'turn/interrupt',
        {'threadId': threadId, 'turnId': turnId},
        timeout: const Duration(seconds: 15),
      );
    } catch (e) {
      LogService.warning('CodexAppServer', 'turn/interrupt 失败: $e');
    }
  }

  void _handleLine(String line) {
    if (line.trim().isEmpty) return;
    Object? decoded;
    try {
      decoded = jsonDecode(line);
    } catch (e) {
      LogService.warning('CodexAppServer', '忽略非 JSON 输出: ${_clip(line)}');
      return;
    }
    if (decoded is! Map) return;
    final message = Map<String, dynamic>.from(decoded);
    final method = message['method'];
    final id = message['id'];

    if (method is String && id != null) {
      _handleServerRequest(id, method, _asMap(message['params']));
      return;
    }
    if (id != null) {
      _handleResponse(id, message);
      return;
    }
    if (method is String) {
      _notifications.add(CodexAppServerNotification(
        method: method,
        params: _asMap(message['params']),
        emittedAtMs: message['emittedAtMs'] as int?,
      ));
    }
  }

  void _handleResponse(Object id, Map<String, dynamic> message) {
    final requestId = id is int ? id : int.tryParse(id.toString());
    if (requestId == null) return;
    final completer = _pending.remove(requestId);
    if (completer == null || completer.isCompleted) return;

    final error = message['error'];
    if (error is Map) {
      final err = Map<String, dynamic>.from(error);
      completer.completeError(CodexAppServerException(
        (err['message'] as String?) ?? 'Codex app-server 请求失败',
        detail: jsonEncode(err),
      ));
      return;
    }
    final result = message['result'];
    completer.complete(result is Map
        ? Map<String, dynamic>.from(result)
        : <String, dynamic>{});
  }

  void _send(Map<String, dynamic> message) {
    final transport = _transport;
    if (transport == null) {
      throw const CodexAppServerDisconnectedException(
        'Codex app-server 尚未启动',
      );
    }
    transport.sendLine(jsonEncode(message));
  }

  Future<Map<String, dynamic>> _request(
    String method,
    Map<String, dynamic> params, {
    Duration? timeout,
  }) {
    final id = _nextRequestId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    try {
      _send({'id': id, 'method': method, 'params': params});
    } catch (e) {
      _pending.remove(id);
      rethrow;
    }

    final effectiveTimeout = timeout ?? requestTimeout;
    return completer.future.timeout(effectiveTimeout, onTimeout: () {
      _pending.remove(id);
      throw CodexAppServerException(
        'Codex app-server 请求超时: $method (${effectiveTimeout.inSeconds}s)',
        detail: _stderrTail.toString().trim(),
      );
    });
  }

  void _handleServerRequest(
    Object id,
    String method,
    Map<String, dynamic> params,
  ) {
    Map<String, dynamic>? result;
    switch (method) {
      case 'item/commandExecution/requestApproval':
        // app-server 已在 full access 下运行；若仍收到审批请求，明确接受，
        // 避免服务端等待客户端应答而永久 working。
        result = {'decision': 'accept'};
      case 'item/fileChange/requestApproval':
        result = {'decision': 'accept'};
      case 'item/permissions/requestApproval':
        result = {
          'permissions': <String, dynamic>{},
          'scope': 'turn',
        };
      case 'item/tool/requestUserInput':
        final answers = <String, dynamic>{};
        final questions = params['questions'];
        if (questions is List) {
          for (final raw in questions) {
            final question = _asMap(raw);
            final questionId = question['id'];
            if (questionId is String && questionId.isNotEmpty) {
              answers[questionId] = {
                'answers': ['请按最合理的默认方案继续执行；详细操作可在完成后说明。'],
              };
            }
          }
        }
        result = {'answers': answers};
      case 'mcpServer/elicitation/request':
        result = {'action': 'decline'};
      case 'item/tool/call':
        result = {
          'success': false,
          'contentItems': [
            {
              'type': 'inputText',
              'text': '当前 Codex Mobile 客户端未注册该动态工具。',
            },
          ],
        };
      case 'applyPatchApproval':
      case 'execCommandApproval':
        result = {'decision': 'approved'};
      default:
        _send({
          'id': id,
          'error': {
            'code': -32601,
            'message': 'Codex Mobile 不支持服务端请求: $method',
          },
        });
        return;
    }

    _send({'id': id, 'result': result});
  }

  void _handleExit(int exitCode) {
    final wasRunning = _transport != null;
    _initialized = false;
    final detail = _stderrTail.toString().trim();
    for (final entry in _pending.entries.toList()) {
      final completer = entry.value;
      if (!completer.isCompleted) {
        completer.completeError(CodexAppServerDisconnectedException(
          'Codex app-server 已退出（exitCode=$exitCode）',
          detail: detail,
        ));
      }
    }
    _pending.clear();
    _transport = null;
    if (wasRunning && !_notifications.isClosed) {
      _notifications.add(CodexAppServerNotification(
        method: 'codex/disconnected',
        params: {
          'message': 'Codex app-server 已退出（exitCode=$exitCode）'
              '${detail.isEmpty ? '' : '\n$detail'}',
        },
      ));
      LogService.warning(
        'CodexAppServer',
        'app-server 退出: code=$exitCode stderr=${_clip(detail)}',
      );
    }
  }

  Future<void> _stopTransport() async {
    for (final turn in _activeTurns.toList()) {
      turn.failDisconnected('Codex app-server 正在重启或已关闭');
    }
    _activeTurns.clear();

    final lineSub = _lineSubscription;
    final errorSub = _errorSubscription;
    _lineSubscription = null;
    _errorSubscription = null;
    await lineSub?.cancel();
    await errorSub?.cancel();

    final transport = _transport;
    _transport = null;
    _initialized = false;
    _knownThreads.clear();
    _workspaceHost = null;
    _workspaceGuest = null;
    if (transport != null) {
      await transport.close();
    }
  }

  Future<void> shutdown() async {
    if (_disposed) return;
    _disposed = true;
    for (final turn in _activeTurns.toList()) {
      turn.failDisconnected('Codex app-server 客户端已关闭');
    }
    _activeTurns.clear();
    await _stopTransport();
    if (!_notifications.isClosed) {
      await _notifications.close();
    }
  }

  static Map<String, dynamic> _asMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return const <String, dynamic>{};
  }

  static String _clip(String text, {int max = 2000}) {
    final trimmed = text.trim();
    if (trimmed.length <= max) return trimmed;
    return trimmed.substring(trimmed.length - max);
  }
}
