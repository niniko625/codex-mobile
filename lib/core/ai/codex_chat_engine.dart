/// ====================================================================
/// CodexChatEngine — 基于 Codex CLI 的聊天引擎
///
/// 实现 [IChatEngine]，把 UI 的消息流桥接到 rootfs 内的
/// `codex exec --json`（见 [CodexRunner]）：
///   - `agent_message` 事件 → 流式文本 chunk
///   - `command_execution` 事件 → 实时更新会话占位消息的
///     `codex_tool_calls` metadata（UI 据此显示工具调用状态）
///   - `thread.started` → 记录 thread_id，后续消息用 `codex exec resume`
///   - `turn.completed` / 进程退出 → 结束流
///
/// 目标目录（[CodexRunner] 的 hostWorkingDir）来源优先级：
///   1. `streamMessage.metadata['workspaceDir']`
///   2. `createSession(metadata: {'workspaceDir': ...})`
///   3. 构造注入的 [defaultWorkspaceDir]
///   4. 运行时解析 App 文档目录
/// ====================================================================
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/logger/log_service.dart';
import 'ai_message.dart';
import 'attachment.dart';
import 'chat_engine.dart';
import 'chat_session.dart';
import 'codex_runner.dart';
import 'workspace_dir_resolver.dart';

/// 工具调用状态（用于 UI 展示）
class CodexToolCall {
  final String id;
  final String command;

  /// in_progress / completed / error
  final String status;
  final int? exitCode;
  final String output;

  const CodexToolCall({
    required this.id,
    required this.command,
    required this.status,
    this.exitCode,
    this.output = '',
  });

  CodexToolCall copyWith({
    String? status,
    int? exitCode,
    String? output,
  }) {
    return CodexToolCall(
      id: id,
      command: command,
      status: status ?? this.status,
      exitCode: exitCode ?? this.exitCode,
      output: output ?? this.output,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'command': command,
    'status': status,
    'exitCode': exitCode,
    'output': output,
  };

  static CodexToolCall fromJson(Map<String, dynamic> json) => CodexToolCall(
    id: (json['id'] as String?) ?? '',
    command: (json['command'] as String?) ?? '',
    status: (json['status'] as String?) ?? 'in_progress',
    exitCode: json['exitCode'] as int?,
    output: (json['output'] as String?) ?? '',
  );
}

/// 已复制到工作区的附件。
///
/// [images] 为传给 `codex exec -i` 的 guest 路径；[files] 为需要在 prompt
/// 中告知 Codex 的文件（避免把文件内容直接塞进 prompt）。
class _StagedAttachments {
  final List<String> images;
  final List<({String name, String guestPath})> files;

  const _StagedAttachments({
    this.images = const [],
    this.files = const [],
  });
}

/// CodexChatEngine
class CodexChatEngine implements IChatEngine {
  /// 附件暂存目录（位于 host 工作目录内，作为 bind 根的子目录可由
  /// rootfs 内的 Codex 读取）。
  static const String _attachmentDir = '.codex-mobile/attachments';

  /// 真机诊断固定文件名；Android 侧会覆盖同名文件，便于 Termux 读取。
  static const String _diagnosticFileName = 'codex_mobile_latest.log';

  /// Codex / DeepSeek 支持的图片扩展名。
  static const Set<String> _supportedImageExtensions = {
    '.png',
    '.jpg',
    '.jpeg',
    '.webp',
    '.gif',
  };

  final CodexRunner _runner;

  /// 默认工作目录（测试注入；null 时运行时解析 App 文档目录）
  final String? defaultWorkspaceDir;

  /// 运行时解析默认工作目录（App 文档目录等）
  final Future<String> Function()? workspaceDirResolver;

  /// 单轮硬超时。传给 [CodexRunner] 后由底层杀死卡死的 PRoot/codex。
  final Duration? turnTimeout;

  /// 无有效事件看门狗。命令执行期间暂停计时，避免误杀长时间构建；
  /// 模型请求卡住（如 turn.started 后永久无 agent_message）时触发。
  final Duration? idleTimeout;

  final Map<String, ChatSession> _sessions = {};
  final Map<String, GenerationStatus> _generationStatuses = {};
  final Map<String, String> _threadIds = {};

  /// sessionId → 工作目录解析结果缓存。
  /// 会话内缓存：同一请求解析一次后不再每轮重新猜测；用户显式切换工作
  /// 目录或解析目录失效时重新解析（见 [_resolveWorkspaceDir]）。
  ///   - requested:    用户/会话请求的目录（host 或 /workspace 兜底）
  ///   - host:         CodexRunner 的 bind 根（= requested）
  ///   - guest:        解析出的项目 guest 路径（Codex cwd，如 `/workspace/git/<repo>`）
  ///   - resolvedHost: 解析出的 host 项目路径
  ///   - isGit:        resolvedHost 是否为 Git 仓库
  final Map<
    String,
    ({
      String requested,
      String host,
      String guest,
      String resolvedHost,
      bool isGit,
    })
  >
      _resolvedWorkspaceDirs = {};

  /// 每会话正在运行的 run（供 stopGeneration）
  final Map<String, CodexRunner> _activeRunners = {};

  /// 明确由用户点击“停止”触发的会话。用于区分用户主动停止与意外取消：
  /// 后者意味着 cancel 信号污染了新的执行，需要显示错误并落盘诊断。
  final Set<String> _userStoppedSessions = {};

  @override
  String systemPrompt;

  CodexChatEngine({
    CodexRunner? runner,
    this.defaultWorkspaceDir,
    this.workspaceDirResolver,
    this.turnTimeout = const Duration(minutes: 10),
    this.idleTimeout = const Duration(seconds: 90),
    this.systemPrompt = '你是一个 AI 编程助手。你可以读取和修改用户项目目录里的文件、'
        '运行命令、迭代完成任务。当前工作目录是你的目标项目目录，可以直接操作其中的文件。'
        '请用简体中文回答。',
  }) : _runner = runner ?? CodexRunner();

  // ── Session 管理 ────────────────────────────────────────────

  @override
  ChatSession createSession({String? title, Map<String, dynamic>? metadata}) {
    final session = ChatSession(
      sessionId: _generateId(),
      title: title,
      metadata: Map<String, dynamic>.from(metadata ?? const {}),
    );
    _sessions[session.sessionId] = session;
    _generationStatuses[session.sessionId] = GenerationStatus.idle;
    final threadId = session.metadata?['threadId'];
    if (threadId is String && threadId.isNotEmpty) {
      _threadIds[session.sessionId] = threadId;
    }
    return session;
  }

  @override
  ChatSession restoreSession(ChatSession session) {
    _sessions[session.sessionId] = session;
    _generationStatuses[session.sessionId] = GenerationStatus.idle;
    final threadId = session.metadata?['threadId'];
    if (threadId is String && threadId.isNotEmpty) {
      _threadIds[session.sessionId] = threadId;
    }
    return session;
  }

  @override
  void deleteSession(String sessionId) {
    stopGeneration(sessionId);
    _sessions.remove(sessionId);
    _generationStatuses.remove(sessionId);
    _threadIds.remove(sessionId);
    _resolvedWorkspaceDirs.remove(sessionId);
    _activeRunners.remove(sessionId);
  }

  @override
  ChatSession? getSession(String sessionId) => _sessions[sessionId];

  @override
  List<ChatSession> listSessions() {
    final list = _sessions.values.toList();
    list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  // ── 消息操作 ─────────────────────────────────────────────────

  @override
  Future<List<ChatMessage>> getMessages(String sessionId) async {
    final session = _getSessionOrThrow(sessionId);
    return List.from(session.messages);
  }

  @override
  Future<ChatMessage> sendMessage({
    required String sessionId,
    required String content,
    Map<String, dynamic>? metadata,
  }) async {
    final buffer = StringBuffer();
    await for (final chunk in streamMessage(
      sessionId: sessionId,
      content: content,
      metadata: metadata,
    )) {
      buffer.write(chunk);
    }
    final session = _getSessionOrThrow(sessionId);
    return session.messages.last;
  }

  @override
  Stream<String> streamMessage({
    required String sessionId,
    required String content,
    Map<String, dynamic>? metadata,
  }) async* {
    final session = _getSessionOrThrow(sessionId);

    if (isGenerating(sessionId)) {
      throw const ChatEngineException(
        type: ChatEngineErrorType.sessionBusy,
        message: '该会话正在生成中，请等待完成或停止当前生成',
      );
    }
    // 附件会复制到工作区：图片作为 `codex exec -i` 输入，其他文件把
    // guest 路径追加到 prompt，由 Codex 直接读取。
    final attachments = _attachmentsFromMetadata(metadata);

    if (content.trim().isEmpty && attachments.isEmpty) {
      throw const ChatEngineException(
        type: ChatEngineErrorType.internal,
        message: '消息内容不能为空',
      );
    }

    // 创建用户消息（attachments 来自 metadata，图片随后会交给 Codex）
    final userMessage = ChatMessage(
      id: _generateId(),
      role: ChatRole.user,
      content: content.trim(),
      timestamp: DateTime.now(),
      metadata: metadata,
      attachments: attachments,
    );
    session.addMessage(userMessage);

    // 自动更新标题（首条用户消息）
    if (session.title.startsWith('对话 ') &&
        session.messagesByRole(ChatRole.user).length == 1) {
      session.title = content.trim().isEmpty
          ? (attachments.every((a) => a.isImage) ? '图片消息' : '附件消息')
          : _generateTitle(content.trim());
    }

    // 确定目标目录
    final workspace = await _resolveWorkspaceDir(metadata, session);

    // 附件复制到 bind 根下的固定目录，再交给 Codex。
    final staged = await _stageAttachments(
      attachments,
      hostWorkingDir: workspace.host,
    );
    final requestPrompt = _buildRequestPrompt(content.trim(), staged);

    // 占位消息（实时承载文本 + 工具调用状态）
    final placeholderId = 'streaming-${_generateId()}';
    session.addMessage(ChatMessage(
      id: placeholderId,
      role: ChatRole.assistant,
      content: '',
      timestamp: DateTime.now(),
      isStreaming: true,
      metadata: {
        'workspaceDir': workspace.host,
        'workspaceDirGuest': workspace.guest,
        'codex_tool_calls': <Map<String, dynamic>>[],
      },
    ));

    _generationStatuses[sessionId] = GenerationStatus.streaming;
    _activeRunners[sessionId] = _runner;

    // 事件桥接：CodexRunner 回调式 → 此处 StreamController
    final controller = StreamController<CodexEvent>();
    final done = Completer<CodexRunResult>();
    final toolCalls = <CodexToolCall>[];
    final textBuffer = StringBuffer();
    final stderrTail = StringBuffer();
    var runError = '';
    var activeCommands = 0;
    Timer? idleTimer;
    Timer? hardTimer;

    void cancelTimers() {
      idleTimer?.cancel();
      idleTimer = null;
      hardTimer?.cancel();
      hardTimer = null;
    }

    // run 结束（无论正常/取消/错误）都要 close controller，
    // 否则下方 `await for` 永不结束（死锁）
    void finishStream() {
      cancelTimers();
      if (!controller.isClosed) {
        controller.close();
      }
    }

    String formatTimeout(Duration duration) {
      if (duration.inSeconds >= 1) return '${duration.inSeconds} 秒';
      return '${duration.inMilliseconds} 毫秒';
    }

    void triggerWatchdog(String reason) {
      if (done.isCompleted) return;
      final tail = stderrTail.toString().trim();
      final message = StringBuffer(reason)
        ..write('\n\n已请求强制停止本轮 Codex 进程。');
      if (tail.isNotEmpty) {
        message
          ..write('\n\n最近 stderr：\n')
          ..write(_clipDiagnostic(tail));
      }
      final error = message.toString();
      runError = error;
      done.complete(CodexRunResult(
        exitCode: -2,
        timedOut: true,
        error: error,
        stderr: tail,
      ));
      finishStream();
      try {
        _runner.stop();
      } catch (e) {
        LogService.warning('CodexChatEngine', '看门狗停止 Codex 失败: $e');
      }
    }

    void resetIdleTimer() {
      idleTimer?.cancel();
      idleTimer = null;
      if (idleTimeout == null || activeCommands > 0 || done.isCompleted) {
        return;
      }
      idleTimer = Timer(idleTimeout!, () {
        if (done.isCompleted || activeCommands > 0) return;
        triggerWatchdog(
          'Codex 长时间无输出（已等待 ${formatTimeout(idleTimeout!)}），'
          '已停止本轮执行。',
        );
      });
    }

    resetIdleTimer();
    if (turnTimeout != null) {
      hardTimer = Timer(turnTimeout!, () {
        if (done.isCompleted) return;
        triggerWatchdog(
          'Codex 本轮执行超过 ${formatTimeout(turnTimeout!)}，'
          '已停止本轮执行。',
        );
      });
    }

    final currentThreadId = _threadIds[sessionId];
    unawaited(_runner
        .run(
          prompt: requestPrompt,
          // bind 根保持 requested；Codex cwd 用解析出的项目 guest 路径，
          // 避免 /workspace 空壳被当作 Git 项目目录。
          hostWorkingDir: workspace.host,
          guestWorkingDir: workspace.guest,
          resolveWorkspace: false,
          systemPrompt: systemPrompt,
          images: staged.images,
          threadId: currentThreadId,
          timeout: turnTimeout,
          onStderrChunk: (chunk) {
            stderrTail.write(chunk);
            if (stderrTail.length > 8000) {
              final text = stderrTail.toString();
              stderrTail
                ..clear()
                ..write(text.substring(text.length - 8000));
            }
            // 有 stderr 说明进程仍在工作/报错，重置空闲计时；命令执行
            // 期间由 activeCommands 保持暂停，避免误杀长时间构建。
            if (activeCommands == 0) resetIdleTimer();
          },
          listener: _CodexEventListener(
            onEvent: (event) {
              if (!controller.isClosed) {
                controller.add(event);
              }
            },
            onExit: (_) {},
          ),
        )
        .then((result) {
          if (!done.isCompleted) {
            done.complete(result);
            if (result.error != null && result.error!.isNotEmpty) {
              runError = result.error!;
            }
          }
          finishStream();
        })
        .catchError((Object e) {
          if (!done.isCompleted) {
            done.complete(
              CodexRunResult(exitCode: -1, error: 'codex 执行异常: $e'),
            );
            runError = 'codex 执行异常: $e';
          }
          finishStream();
        }));

    bool cancelled = false;
    bool timedOut = false;

    try {
      await for (final event in controller.stream) {
        switch (event) {
          case CodexThreadStarted(:final threadId):
            _recordThreadId(session, threadId);
            resetIdleTimer();
          case CodexTurnStarted():
            resetIdleTimer();
            break;
          case CodexAgentMessage(:final text):
            if (text.isNotEmpty) {
              textBuffer.write(text);
              _updatePlaceholder(
                session,
                placeholderId,
                content: textBuffer.toString(),

                workspaceHost: workspace.host,

                workspaceGuest: workspace.guest,
                toolCalls: toolCalls,
              );
              yield text;
            }
            resetIdleTimer();
          case CodexCommandStarted(:final id, :final command):
            activeCommands++;
            idleTimer?.cancel();
            idleTimer = null;
            _upsertToolCall(
              toolCalls,
              CodexToolCall(id: id, command: command, status: 'in_progress'),
            );
            _updatePlaceholder(
              session,
              placeholderId,
              content: textBuffer.toString(),

              workspaceHost: workspace.host,

              workspaceGuest: workspace.guest,
              toolCalls: toolCalls,
            );
          case CodexCommandCompleted(
            :final id,
            :final command,
            :final exitCode,
            :final output,
          ):
            _upsertToolCall(
              toolCalls,
              CodexToolCall(
                id: id,
                command: command,
                status: exitCode == 0 ? 'completed' : 'error',
                exitCode: exitCode,
                output: output,
              ),
            );
            _updatePlaceholder(
              session,
              placeholderId,
              content: textBuffer.toString(),

              workspaceHost: workspace.host,

              workspaceGuest: workspace.guest,
              toolCalls: toolCalls,
            );
            if (activeCommands > 0) activeCommands--;
            resetIdleTimer();
          case CodexTurnCompleted():
            resetIdleTimer();
            break;
          case CodexErrorEvent():
            // 无害 fallback 警告静默；真实错误由 exit 结果承载
            resetIdleTimer();
            break;
        }
      }
    } finally {
      cancelTimers();
      if (!controller.isClosed) {
        await controller.close();
      }
    }

    // 等待进程真正结束（含超时/取消/错误信息）
    final result = await done.future;
    _activeRunners.remove(sessionId);
    final userStopped = _userStoppedSessions.remove(sessionId);
    if (result.threadId != null && result.threadId!.isNotEmpty) {
      _recordThreadId(session, result.threadId!);
    }
    cancelled = result.cancelled;
    timedOut = result.timedOut;

    if (result.error != null && result.error!.isNotEmpty) {
      runError = result.error!;
    }

    if (cancelled) {
      final diagnosticPath = await _exportRunDiagnostics(
        sessionId: sessionId,
        workspace: workspace,
        result: result,
        toolCalls: toolCalls,
        generatedChars: textBuffer.length,
        userStopped: userStopped,
      );
      _generationStatuses[sessionId] = userStopped
          ? GenerationStatus.completed
          : GenerationStatus.error;
      final visibleText = textBuffer.toString().trimRight();
      final marker = userStopped
          ? '⚠️ 已停止生成'
          : '⚠️ 执行被意外取消（exitCode=${result.exitCode}）';
      final parts = <String>[
        if (visibleText.isNotEmpty) visibleText,
        marker,
        if (!userStopped && result.debugLog.isNotEmpty)
          '[AI-DEBUG]\n${_clipDiagnostic(result.debugLog)}',
        if (diagnosticPath != null) '诊断日志：$diagnosticPath',
      ];
      session.replaceLastMessage(ChatMessage(
        id: _generateId(),
        role: ChatRole.assistant,
        content: parts.join('\n\n'),
        timestamp: DateTime.now(),
        metadata: {
          'stopped': userStopped,
          'unexpectedCancellation': !userStopped,
          'exitCode': result.exitCode.toString(),
          'workspaceDir': workspace.host,
          'workspaceDirGuest': workspace.guest,
          'codex_tool_calls': toolCalls.map((t) => t.toJson()).toList(),
          if (diagnosticPath != null) 'diagnosticLog': diagnosticPath,
          'debugLog': result.debugLog,
        },
      ));
      if (!userStopped) {
        throw ChatEngineException(
          type: ChatEngineErrorType.internal,
          message: '执行被意外取消（exitCode=${result.exitCode}）；'
              '诊断日志已写入 Download/$_diagnosticFileName',
        );
      }
      return;
    }

    if (timedOut || runError.isNotEmpty) {
      _generationStatuses[sessionId] = GenerationStatus.error;
      final errorMsg = runError.isNotEmpty
          ? runError
          : '执行超时（exitCode=${result.exitCode}）';
      final diagnosticPath = await _exportRunDiagnostics(
        sessionId: sessionId,
        workspace: workspace,
        result: result,
        toolCalls: toolCalls,
        generatedChars: textBuffer.length,
        userStopped: false,
      );
      final detail = <String>[
        '❌ $errorMsg',
        if (result.debugLog.isNotEmpty)
          '[AI-DEBUG]\n${_clipDiagnostic(result.debugLog)}',
        if (diagnosticPath != null) '诊断日志：$diagnosticPath',
      ].join('\n\n');
      session.replaceLastMessage(ChatMessage(
        id: _generateId(),
        role: ChatRole.assistant,
        content: detail,
        timestamp: DateTime.now(),
        metadata: {
          'error': errorMsg,
          'exitCode': result.exitCode.toString(),
          'workspaceDir': workspace.host,
          'workspaceDirGuest': workspace.guest,
          'codex_tool_calls': toolCalls.map((t) => t.toJson()).toList(),
          if (diagnosticPath != null) 'diagnosticLog': diagnosticPath,
          'debugLog': result.debugLog,
        },
      ));
      throw ChatEngineException(
        type: timedOut
            ? ChatEngineErrorType.timeout
            : ChatEngineErrorType.internal,
        message: errorMsg,
      );
    }

    // 正常结束。成功也覆盖写同一个固定诊断文件：若下一轮突然停止，
    // Download/codex_mobile_latest.log 仍能看到上一轮真实 exitCode/stdout。
    final diagnosticPath = await _exportRunDiagnostics(
      sessionId: sessionId,
      workspace: workspace,
      result: result,
      toolCalls: toolCalls,
      generatedChars: textBuffer.length,
      userStopped: false,
    );
    final fullContent = textBuffer.toString();
    if (fullContent.isEmpty) {
      _generationStatuses[sessionId] = GenerationStatus.error;
      final diag = _buildNoReplyDiagnostic(result);
      // [AI-DEBUG] 取证期：只要 runner 积累了 debugLog（真实命令/exitCode/
      // stdout/stderr/事件），一律贴出；否则回退到原有轻量诊断
      final diagnosticText = result.debugLog.isNotEmpty
          ? '⚠️ 未收到有效回复\n\n[AI-DEBUG]\n${result.debugLog}'
          : diag == null
              ? '⚠️ 未收到有效回复'
              : '⚠️ 未收到有效回复\n\n[诊断] 未解析到 agent_message\n$diag';
      final content = diagnosticPath == null
          ? diagnosticText
          : '$diagnosticText\n\n诊断日志：$diagnosticPath';
      session.replaceLastMessage(ChatMessage(
        id: _generateId(),
        role: ChatRole.assistant,
        content: content,
        timestamp: DateTime.now(),
        metadata: {
          'exitCode': result.exitCode.toString(),
          'workspaceDir': workspace.host,
          'workspaceDirGuest': workspace.guest,
          'codex_tool_calls': toolCalls.map((t) => t.toJson()).toList(),
          if (diagnosticPath != null) 'diagnosticLog': diagnosticPath,
        },
      ));
    } else {
      _generationStatuses[sessionId] = GenerationStatus.completed;
      session.replaceLastMessage(ChatMessage(
        id: _generateId(),
        role: ChatRole.assistant,
        content: fullContent,
        timestamp: DateTime.now(),
        metadata: {
          'threadId': _threadIds[sessionId],
          'exitCode': result.exitCode.toString(),
          'workspaceDir': workspace.host,
          'workspaceDirGuest': workspace.guest,
          'codex_tool_calls': toolCalls.map((t) => t.toJson()).toList(),
          if (diagnosticPath != null) 'diagnosticLog': diagnosticPath,
          // [AI-DEBUG] 取证期：正常回复也把诊断挂到 metadata（UI 可查）
          'debugLog': result.debugLog,
        },
      ));
    }
  }

  @override
  Future<ChatMessage> retryLastMessage(String sessionId) async {
    final session = _getSessionOrThrow(sessionId);

    final userMessages = session.messagesByRole(ChatRole.user);
    if (userMessages.isEmpty) {
      throw const ChatEngineException(
        type: ChatEngineErrorType.internal,
        message: '没有可重试的消息',
      );
    }

    if (session.messages.isNotEmpty &&
        session.messages.last.role == ChatRole.assistant) {
      session.messages.removeLast();
    }
    if (session.messages.isNotEmpty &&
        session.messages.last.role == ChatRole.user) {
      session.messages.removeLast();
    }

    // 重试会重新发送同一条用户消息；继续 resume 旧 thread 会把同一指令
    // 追加两遍，因此这里从新 thread 开始。后续正常消息仍可继续 resume。
    _threadIds.remove(sessionId);
    session.metadata?.remove('threadId');

    final lastUserMessage = userMessages.last;
    return sendMessage(
      sessionId: sessionId,
      content: lastUserMessage.content,
      metadata: lastUserMessage.metadata,
    );
  }

  @override
  void stopGeneration(String sessionId) {
    // 只有正在生成时才停止。切换会话/删除会话/页面销毁也会调用本方法，
    // 空闲时若仍向共享 runner 发送 cancel，会污染后续所有对话，表现为
    // 每次发送都立刻变成「已停止生成」。
    if (_generationStatuses[sessionId] != GenerationStatus.streaming) {
      return;
    }

    final runner = _activeRunners.remove(sessionId);
    if (runner != null) {
      _userStoppedSessions.add(sessionId);
      runner.stop();
    }
    _generationStatuses[sessionId] = GenerationStatus.completed;

    final session = _sessions[sessionId];
    if (session != null && session.messages.isNotEmpty) {
      final last = session.messages.last;
      if (last.isStreaming) {
        session.replaceLastMessage(ChatMessage(
          id: _generateId(),
          role: ChatRole.assistant,
          content: last.content.isNotEmpty ? last.content : '⚠️ 已停止生成',
          timestamp: DateTime.now(),
          metadata: {...?last.metadata, 'stopped': true},
        ));
      }
    }
  }

  // ── 上下文管理 ───────────────────────────────────────────────

  @override
  void addContext(String key, String value) {}

  @override
  void removeContext(String key) {}

  @override
  void clearContext() {}

  // ── 状态 ─────────────────────────────────────────────────────

  @override
  bool isGenerating(String sessionId) {
    return _generationStatuses[sessionId] == GenerationStatus.streaming;
  }

  @override
  GenerationStatus getGenerationStatus(String sessionId) {
    return _generationStatuses[sessionId] ?? GenerationStatus.idle;
  }

  // ── 生命周期 ─────────────────────────────────────────────────

  @override
  void dispose() {
    for (final sessionId in _sessions.keys.toList()) {
      stopGeneration(sessionId);
    }
    _sessions.clear();
    _generationStatuses.clear();
    _threadIds.clear();
    _activeRunners.clear();
    _userStoppedSessions.clear();
  }

  // ── 内部 ─────────────────────────────────────────────────────

  void _recordThreadId(ChatSession session, String threadId) {
    _threadIds[session.sessionId] = threadId;
    session.metadata?['threadId'] = threadId;
  }

  ChatSession _getSessionOrThrow(String sessionId) {
    final session = _sessions[sessionId];
    if (session == null) {
      throw ChatEngineException(
        type: ChatEngineErrorType.sessionNotFound,
        message: '会话不存在: $sessionId',
      );
    }
    return session;
  }

  Future<({String host, String guest, String resolvedHost, bool isGit})>
      _resolveWorkspaceDir(
    Map<String, dynamic>? messageMetadata,
    ChatSession session,
  ) async {
    // 确定「请求的工作目录」：用户/消息显式指定 > 会话 metadata >
    // 构造注入的默认 > 运行时解析 App 文档目录 > 兜底 /workspace
    String? requested;
    final fromMessage = messageMetadata?['workspaceDir'] as String?;
    if (fromMessage != null && fromMessage.isNotEmpty) {
      requested = fromMessage;
    } else {
      final fromSession = session.metadata?['workspaceDir'] as String?;
      if (fromSession != null && fromSession.isNotEmpty) {
        requested = fromSession;
      } else if (defaultWorkspaceDir != null && defaultWorkspaceDir!.isNotEmpty) {
        requested = defaultWorkspaceDir;
      } else if (workspaceDirResolver != null) {
        try {
          final dir = await workspaceDirResolver!();
          if (dir.isNotEmpty) requested = dir;
        } catch (_) {}
      }
    }
    requested = (requested == null || requested.isEmpty)
        ? CodexRunner.guestWorkspaceDir
        : requested;

    // 会话内缓存：同一请求目录且解析目录仍有效 → 直接复用，避免每轮重新
    // 扫描文件系统（除非用户主动切换工作目录，或目录已失效）。
    final cached = _resolvedWorkspaceDirs[session.sessionId];
    if (cached != null && cached.requested == requested) {
      final bindRootValid = cached.host == CodexRunner.guestWorkspaceDir ||
          Directory(cached.host).existsSync();
      final resolvedValid = cached.resolvedHost.isEmpty ||
          Directory(cached.resolvedHost).existsSync();
      if (bindRootValid && resolvedValid) {
        return (
          host: cached.host,
          guest: cached.guest,
          resolvedHost: cached.resolvedHost,
          isGit: cached.isGit,
        );
      }
    }

    // Codex 启动前统一工作目录解析：
    //   1) 判断目录是否存在；2) 判断是否为 Git 仓库；3) 不是 Git 仓库时
    //   检查已知项目根目录（requested/git/ 下的 git clone 仓库）。
    final resolved = resolveCodexWorkspaceDir(requested);
    // bind 根 = requested（CodexRunner 把 host 根 bind 到 guest /workspace）
    final host = requested;
    // Codex cwd = 项目 guest 路径（如 /workspace/git/codex-mobile-pro）
    final guest = _hostPathToGuestCwd(requested, resolved.path);
    _resolvedWorkspaceDirs[session.sessionId] = (
      requested: requested,
      host: host,
      guest: guest,
      resolvedHost: resolved.path,
      isGit: resolved.isGitRepository,
    );
    LogService.info('CodexChatEngine', 'requestedWorkingDirectory = $requested');
    LogService.info('CodexChatEngine',
        'resolvedWorkingDirectory = ${resolved.path}');
    LogService.info('CodexChatEngine',
        'isGitRepository = ${resolved.isGitRepository}');
    LogService.info('CodexChatEngine', 'codex cwd = $guest');
    return (
      host: host,
      guest: guest,
      resolvedHost: resolved.path,
      isGit: resolved.isGitRepository,
    );
  }

  /// 把解析出的 host 项目路径映射为 PRoot guest cwd。
  ///
  /// host 根（requested）被 bind 到 guest /workspace，因此：
  ///   requested=/data/.../app_flutter，resolved=/data/.../app_flutter/git/repo
  ///   → guest=/workspace/git/repo
  /// 若 requested 本身就是 /workspace（兜底）→ guest 保持 resolved。
  /// 若 resolved 不在 requested 下（异常）→ 退回 /workspace（bind 根）。
  String _hostPathToGuestCwd(String requested, String resolvedHost) {
    if (requested == CodexRunner.guestWorkspaceDir) return resolvedHost;
    if (resolvedHost == requested) return CodexRunner.guestWorkspaceDir;
    if (resolvedHost.startsWith(requested)) {
      return '${CodexRunner.guestWorkspaceDir}${resolvedHost.substring(requested.length)}';
    }
    return CodexRunner.guestWorkspaceDir;
  }


  /// 从 metadata['attachments'] 解析附件列表；图片随后交给 `codex exec -i`，
  /// 其他文件复制到工作区并把路径写进 prompt。
  List<Attachment> _attachmentsFromMetadata(Map<String, dynamic>? metadata) {
    final raw = metadata?['attachments'];
    if (raw is! List || raw.isEmpty) return const [];
    return raw
        .map((e) =>
            Attachment.fromJson((e as Map).cast<String, dynamic>()))
        .whereType<Attachment>()
        .toList();
  }

  /// 把附件复制到 host 工作目录，并返回 Codex 可读取的 guest 路径。
  Future<_StagedAttachments> _stageAttachments(
    List<Attachment> attachments, {
    required String hostWorkingDir,
  }) async {
    if (attachments.isEmpty) return const _StagedAttachments();

    for (final attachment in attachments) {
      if (attachment.status == AttachmentStatus.error) {
        throw ChatEngineException(
          type: ChatEngineErrorType.unsupported,
          message: '附件「${attachment.name}」无效：'
              '${attachment.error ?? '请重新选择文件'}',
        );
      }
      if (attachment.status != AttachmentStatus.ready) {
        throw const ChatEngineException(
          type: ChatEngineErrorType.unsupported,
          message: '附件仍在处理中，请稍后重试',
        );
      }
    }

    final targetDir = Directory(p.join(hostWorkingDir, _attachmentDir));
    try {
      await targetDir.create(recursive: true);
      await _excludeAttachmentDirFromGit(hostWorkingDir);
    } catch (_) {
      throw const ChatEngineException(
        type: ChatEngineErrorType.internal,
        message: '无法创建附件暂存目录，请重试',
      );
    }

    final images = <String>[];
    final files = <({String name, String guestPath})>[];
    final stamp = DateTime.now().microsecondsSinceEpoch;
    for (var i = 0; i < attachments.length; i++) {
      final attachment = attachments[i];
      final sourcePath = attachment.path;
      if (sourcePath == null || sourcePath.isEmpty) {
        throw ChatEngineException(
          type: ChatEngineErrorType.unsupported,
          message: attachment.isImage
              ? '图片读取失败，请重新选择图片后重试'
              : '附件读取失败，请重新选择文件后重试',
        );
      }
      final source = File(sourcePath);
      if (!await source.exists()) {
        throw ChatEngineException(
          type: ChatEngineErrorType.unsupported,
          message: attachment.isImage
              ? '图片读取失败，请重新选择图片后重试'
              : '附件读取失败，请重新选择文件后重试',
        );
      }

      String fileName;
      if (attachment.isImage) {
        final ext = _imageExtension(attachment);
        if (ext.isEmpty) {
          throw const ChatEngineException(
            type: ChatEngineErrorType.unsupported,
            message: '图片格式不支持，请使用 PNG、JPEG、WebP 或 GIF。',
          );
        }
        fileName = '${stamp}_$i$ext';
      } else {
        fileName = '${stamp}_${i}_${_safeAttachmentName(attachment.name)}';
      }

      final target = File(p.join(targetDir.path, fileName));
      try {
        await source.copy(target.path);
      } catch (_) {
        throw ChatEngineException(
          type: ChatEngineErrorType.internal,
          message: attachment.isImage
              ? '复制图片到工作区失败，请重试'
              : '复制附件到工作区失败，请重试',
        );
      }

      final guestPath = p.posix.join(
        CodexRunner.guestWorkspaceDir,
        _attachmentDir,
        fileName,
      );
      if (attachment.isImage) {
        images.add(guestPath);
      } else {
        files.add((
          name: _safeAttachmentName(attachment.name),
          guestPath: guestPath,
        ));
      }
    }
    return _StagedAttachments(images: images, files: files);
  }

  /// 生成实际发送给 Codex 的 prompt。
  ///
  /// 文件附件只传路径，避免大文件（PDF/PPT/Word）把上下文撑爆；Codex 可在
  /// 工作区内自行读取、解析或调用脚本处理。
  String _buildRequestPrompt(String content, _StagedAttachments staged) {
    final parts = <String>[];
    if (content.isNotEmpty) {
      parts.add(content);
    } else if (staged.images.isNotEmpty && staged.files.isEmpty) {
      parts.add('请查看附件图片。');
    } else {
      parts.add('请查看附件。');
    }

    if (staged.files.isNotEmpty) {
      final lines = staged.files
          .map((f) => '- ${f.guestPath} （${f.name}）')
          .join('\n');
      parts.add('以下附件已放入工作区，可直接读取：\n$lines');
    }
    return parts.join('\n\n');
  }

  /// 附件文件名只保留安全的 basename，避免路径穿越或控制字符。
  String _safeAttachmentName(String name) {
    final base = p
        .basename(name)
        .replaceAll(RegExp(r'[/\\\x00-\x1F]'), '_')
        .trim();
    if (base.isEmpty || base == '.' || base == '..') return 'attachment';
    return base.length > 80 ? base.substring(base.length - 80) : base;
  }

  /// 若工作目录本身是 Git 仓库，把附件暂存目录加入本地排除列表，
  /// 避免 `git status` 出现 `.codex-mobile/`。不修改用户的 .gitignore。
  Future<void> _excludeAttachmentDirFromGit(String hostWorkingDir) async {
    try {
      final gitDir = Directory(p.join(hostWorkingDir, '.git'));
      if (!await gitDir.exists()) return;
      final infoDir = Directory(p.join(gitDir.path, 'info'));
      await infoDir.create(recursive: true);
      final exclude = File(p.join(infoDir.path, 'exclude'));
      const marker = '$_attachmentDir/';
      final existing = await exclude.exists()
          ? await exclude.readAsString()
          : '';
      final alreadyExcluded = existing
          .split('\n')
          .map((line) => line.trim())
          .any((line) => line == marker || line == '.codex-mobile/');
      if (alreadyExcluded) return;
      final prefix = existing.isEmpty || existing.endsWith('\n') ? '' : '\n';
      await exclude.writeAsString(
        '$prefix$marker\n',
        mode: FileMode.append,
      );
    } catch (_) {
      // 本地 Git 排除只是体验优化，失败不影响附件发送。
    }
  }

  String _imageExtension(Attachment attachment) {
    final fromName = p.extension(attachment.name).toLowerCase();
    if (_supportedImageExtensions.contains(fromName)) return fromName;
    final fromPath = p.extension(attachment.path ?? '').toLowerCase();
    if (_supportedImageExtensions.contains(fromPath)) return fromPath;
    switch (attachment.mimeType.toLowerCase()) {
      case 'image/png':
        return '.png';
      case 'image/jpeg':
      case 'image/jpg':
        return '.jpg';
      case 'image/webp':
        return '.webp';
      case 'image/gif':
        return '.gif';
    }
    return '';
  }

  void _updatePlaceholder(
    ChatSession session,
    String placeholderId,
    {required String content,
     required String workspaceHost,
     required String workspaceGuest,
     required List<CodexToolCall> toolCalls}) {
    final idx = session.messages.indexWhere((m) => m.id == placeholderId);
    if (idx < 0) return;
    session.messages[idx] = ChatMessage(
      id: placeholderId,
      role: ChatRole.assistant,
      content: content,
      timestamp: DateTime.now(),
      isStreaming: true,
      metadata: {
        'workspaceDir': workspaceHost,
        'workspaceDirGuest': workspaceGuest,
        'codex_tool_calls': toolCalls.map((t) => t.toJson()).toList(),
      },
    );
    session.updatedAt = DateTime.now();
  }

  void _upsertToolCall(List<CodexToolCall> toolCalls, CodexToolCall call) {
    final idx = toolCalls.indexWhere((t) => t.id == call.id);
    if (idx >= 0) {
      toolCalls[idx] = toolCalls[idx].copyWith(
        status: call.status,
        exitCode: call.exitCode,
        output: call.output,
      );
    } else {
      toolCalls.add(call);
    }
  }

  String _generateId() {
    return DateTime.now().microsecondsSinceEpoch.toString();
  }

  String _generateTitle(String content) {
    final cleaned = content.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.length <= 30) return cleaned;
    return '${cleaned.substring(0, 30)}...';
  }

  /// 空回复时构造真实诊断（仅当存在真实失败信号时返回非 null）。
  ///
  /// 触发条件（满足其一）：
  ///  1. exitCode != 0 —— codex 崩溃/退出非 0（ENOENT、API 401 等真实失败）
  ///  2. stderr 非空且非无害提示（如 codex 的 stdin 提示行）
  ///  3. stdout 含真实错误事件（type=error / turn.failed，排除无害 config 警告）
  ///
  /// 排除的无害噪音：
  ///  - "Ignored unsupported project-local config keys ..."（config 键忽略警告）
  ///  - "Defaulting to fallback metadata ..."（模型元数据降级警告）
  ///  - "Reading additional input from stdin..."（stdin 非 TTY 提示）
  String? _buildNoReplyDiagnostic(CodexRunResult result) {
    final lines = <String>[];

    if (result.exitCode != 0) {
      lines.add('exitCode=${result.exitCode}');
    }

    final stderr = result.stderr.trim();
    if (stderr.isNotEmpty &&
        !stderr.contains('Reading additional input from stdin')) {
      lines.add('stderr: $stderr');
    }

    // stdout JSONL：提取真实错误事件，去重、排除无害警告
    final errorMessages = <String>{};
    for (final raw in const LineSplitter().convert(result.stdout)) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      Object? decoded;
      try {
        decoded = jsonDecode(line);
      } catch (_) {
        continue;
      }
      if (decoded is! Map<String, dynamic>) continue;
      String? message;
      if (decoded['type'] == 'error' && decoded['message'] is String) {
        message = decoded['message'] as String;
      } else if (decoded['type'] == 'turn.failed') {
        final err = decoded['error'];
        if (err is Map && err['message'] is String) {
          message = err['message'] as String;
        }
      }
      if (message == null || message.isEmpty) continue;
      if (_isBenignCodexMessage(message)) continue;
      errorMessages.add(message);
    }
    for (final m in errorMessages.take(3)) {
      lines.add('codex: $m');
    }

    if (lines.isEmpty) return null;
    return lines.join('\n');
  }

  /// 将一次失败/取消的完整现场写入公共 Download。
  ///
  /// 真机上 App 私有目录与 logcat 通常无法从 Termux 读取；固定文件名日志
  /// 是唯一稳定、无需 root 的取证通道。API Key 在 CodexRunner 中已掩码。
  Future<String?> _exportRunDiagnostics({
    required String sessionId,
    required ({String host, String guest, String resolvedHost, bool isGit})
        workspace,
    required CodexRunResult result,
    required List<CodexToolCall> toolCalls,
    required int generatedChars,
    required bool userStopped,
  }) async {
    if (!Platform.isAndroid) return null;
    try {
      LogService.warning(
        'CodexChatEngine',
        'run diagnostic: session=$sessionId exitCode=${result.exitCode} '
            'cancelled=${result.cancelled} timedOut=${result.timedOut} '
            'cleanupTimedOut=${result.cleanupTimedOut} '
            'userStopped=$userStopped',
      );
      await LogService.flush();
      final recentLogs = await LogService.getRecentLogs(maxLines: 500);

      final buffer = StringBuffer()
        ..writeln('Codex Mobile — 最近一次运行诊断')
        ..writeln('timestamp=${DateTime.now().toIso8601String()}')
        ..writeln('sessionId=$sessionId')
        ..writeln('userStopped=$userStopped')
        ..writeln('exitCode=${result.exitCode}')
        ..writeln('cancelled=${result.cancelled}')
        ..writeln('timedOut=${result.timedOut}')
        ..writeln('cleanupTimedOut=${result.cleanupTimedOut}')
        ..writeln('threadId=${result.threadId ?? "(null)"}')
        ..writeln('error=${result.error ?? "(null)"}')
        ..writeln('workspaceHost=${workspace.host}')
        ..writeln('workspaceGuest=${workspace.guest}')
        ..writeln('workspaceResolvedHost=${workspace.resolvedHost}')
        ..writeln('workspaceIsGit=${workspace.isGit}')
        ..writeln('generatedChars=$generatedChars')
        ..writeln('stdoutChars=${result.stdout.length}')
        ..writeln('stderrChars=${result.stderr.length}')
        ..writeln('toolCalls=${toolCalls.length}');
      for (final call in toolCalls) {
        buffer.writeln(
          '  - ${call.status} exit=${call.exitCode ?? "(null)"} '
          'command=${call.command}',
        );
      }
      buffer
        ..writeln()
        ..writeln('===== RUN DEBUG =====')
        ..writeln(result.debugLog.isEmpty ? '(empty)' : result.debugLog)
        ..writeln()
        ..writeln('===== RECENT APP LOG =====')
        ..writeln(recentLogs.isEmpty ? '(empty)' : recentLogs);

      final path = await LogService.exportTextToDownload(
        fileName: _diagnosticFileName,
        content: buffer.toString(),
      );
      if (path != null) {
        LogService.info('CodexChatEngine', '诊断日志已导出: $path');
      }
      return path;
    } catch (e) {
      LogService.error('CodexChatEngine', '导出诊断日志失败: $e');
      return null;
    }
  }

  String _clipDiagnostic(String text, {int maxChars = 6000}) {
    if (text.length <= maxChars) return text;
    return '${text.substring(0, maxChars)}\n…（已截断，完整内容见 Download/$_diagnosticFileName）';
  }

  /// codex 输出中的无害警告（不影响对话回复，不纳入诊断）
  bool _isBenignCodexMessage(String message) {
    if (message.contains('Ignored unsupported project-local config keys')) {
      return true;
    }
    if (message.contains('Defaulting to fallback metadata')) {
      return true;
    }
    return false;
  }
}

/// CodexRunner 事件监听器适配（把事件转发给回调）
class _CodexEventListener implements CodexEventListener {
  final void Function(CodexEvent event) onEvent;
  final void Function(int exitCode) onExit;

  _CodexEventListener({required this.onEvent, required this.onExit});

  @override
  void onCodexEvent(CodexEvent event) => onEvent(event);

  @override
  void onCodexExit(int exitCode) => onExit(exitCode);
}
