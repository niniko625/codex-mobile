import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/ai/ai_message.dart';
import '../../../core/ai/ai_provider_manager.dart';
import '../../../core/ai/attachment.dart';
import '../../../core/ai/chat_engine.dart';
import '../../../core/ai/chat_session.dart';
import '../../../core/ai/codex_chat_engine.dart';
import '../../../core/ai/providers/deepseek_provider.dart';
import '../models/ai_chat_view_mode.dart';

// ══════════════════════════════════════════════
// Provider 注入（Sprint 9 可移至独立文件）
// ══════════════════════════════════════════════

/// IAIProviderManager Riverpod Provider
///
/// 保留的旧方案（本地 mimo :8788 直连）后备 Provider；主聊天引擎已切换为
/// [CodexChatEngine]（Codex CLI 驱动），本 Provider 仅供回退/扩展使用。
final aiProviderManagerProvider = Provider<IAIProviderManager>((ref) {
  final manager = AIProviderManager();
  // 默认 DeepSeek Provider：AiConfig 默认指向本地 mimo :8788（zero-auth 模式）
  final deepSeek = DeepSeekProvider();
  manager.register(deepSeek, priority: ProviderPriority.primary);
  unawaited(deepSeek.initialize());
  ref.onDispose(manager.dispose);
  return manager;
});

/// IChatEngine Riverpod Provider
///
/// 使用 [CodexChatEngine]：把「AI 对话」桥接到 rootfs 内的 Codex CLI，
/// AI 可以真实读写选定的项目目录、执行命令并迭代完成任务。
/// 默认工作目录 = App 文档目录（无项目被选中时的兜底）。
final chatEngineProvider = Provider<IChatEngine>((ref) {
  return CodexChatEngine(
    workspaceDirResolver: () async {
      try {
        final dir = await getApplicationDocumentsDirectory();
        return dir.path;
      } catch (_) {
        // 非 Android 环境或目录不可用时回退
        return '/workspace';
      }
    },
  );
});

// ══════════════════════════════════════════════
// 状态定义
// ══════════════════════════════════════════════

/// 对话加载状态
enum ChatLoadingState {
  idle,
  loading,
  streaming,
  error,
}

/// 对话状态
class ChatState {
  /// 当前会话 ID
  final String? currentSessionId;

  /// 所有会话列表
  final List<ChatSession> sessions;

  /// 当前会话的消息列表
  final List<ChatMessage> messages;

  /// 加载状态
  final ChatLoadingState loadingState;

  /// 错误信息
  final String? errorMessage;

  /// 引擎生成状态
  final GenerationStatus generationStatus;

  /// 当前选中的工作目录（Codex 引擎的 hostWorkingDir）
  final String? workspaceDir;

  /// AI 对话界面模式（气泡 / 流式）
  final AiChatViewMode viewMode;

  const ChatState({
    this.currentSessionId,
    this.sessions = const [],
    this.messages = const [],
    this.loadingState = ChatLoadingState.idle,
    this.errorMessage,
    this.generationStatus = GenerationStatus.idle,
    this.workspaceDir,
    this.viewMode = AiChatViewMode.bubble,
  });

  ChatState copyWith({
    String? currentSessionId,
    List<ChatSession>? sessions,
    List<ChatMessage>? messages,
    ChatLoadingState? loadingState,
    String? errorMessage,
    GenerationStatus? generationStatus,
    String? workspaceDir,
    AiChatViewMode? viewMode,
    bool clearErrorMessage = false,
    bool clearWorkspaceDir = false,
  }) {
    return ChatState(
      currentSessionId: currentSessionId ?? this.currentSessionId,
      sessions: sessions ?? this.sessions,
      messages: messages ?? this.messages,
      loadingState: loadingState ?? this.loadingState,
      errorMessage: clearErrorMessage ? null : (errorMessage ?? this.errorMessage),
      generationStatus: generationStatus ?? this.generationStatus,
      workspaceDir: clearWorkspaceDir ? null : (workspaceDir ?? this.workspaceDir),
      viewMode: viewMode ?? this.viewMode,
    );
  }
}

// ══════════════════════════════════════════════
// ChatNotifier
// ══════════════════════════════════════════════

/// 对话 Provider（主聊天入口）
///
/// 文本和图片都走 [chatEngineProvider]（Codex / DeepSeek）。
final chatProvider = StateNotifierProvider<ChatNotifier, ChatState>((ref) {
  final engine = ref.watch(chatEngineProvider);
  return ChatNotifier(engine: engine);
});

class ChatNotifier extends StateNotifier<ChatState> {
  final IChatEngine _engine;

  /// 会话列表 / 当前会话 / 工作目录持久化 key（SharedPreferences）
  static const String _sessionsPrefKey = 'ai_chat_sessions_v1';
  static const String _currentSessionPrefKey = 'ai_chat_current_session_v1';
  static const String _workspaceDirPrefKey = 'ai_chat_workspace_dir_v1';

  /// 避免 SharedPreferences 无限增长：只保留最近 20 个会话、每个 100 条消息。
  static const int _maxStoredSessions = 20;
  static const int _maxStoredMessagesPerSession = 100;
  static const int _maxStoredPayloadChars = 1200000;

  /// 当前选中的工作目录（null = 使用引擎默认）
  String? _workspaceDir;

  /// 当前界面模式（气泡 / 流式）
  AiChatViewMode _viewMode = AiChatViewMode.bubble;

  /// 界面模式持久化 key（SharedPreferences）
  static const String _viewModePrefKey = 'ai_chat_view_mode';

  bool _restoreCompleted = false;
  Future<void> _saveQueue = Future<void>.value();

  ChatNotifier({required IChatEngine engine})
      : _engine = engine,
        super(const ChatState()) {
    _initDefaultSession();
    _loadViewMode();
    unawaited(_restoreSessions());
  }

  /// 从 SharedPreferences 恢复界面模式（异步，不阻塞 UI）
  Future<void> _loadViewMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_viewModePrefKey);
      final mode = AiChatViewMode.fromName(saved);
      if (!mounted) return; // Provider 已销毁（如页面退出），不再更新 state
      _viewMode = mode;
      state = state.copyWith(viewMode: mode);
    } catch (_) {
      // 读取失败保持默认气泡模式
    }
  }

  /// 切换界面模式（只换渲染层，不重新请求 AI / 不重复执行命令）。
  /// 持久化选择；AI 正在生成时也允许切换。
  Future<void> setViewMode(AiChatViewMode mode) async {
    if (_viewMode == mode) return;
    _viewMode = mode;
    state = state.copyWith(viewMode: mode);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_viewModePrefKey, mode.name);
    } catch (_) {}
  }

  /// 设置当前工作目录（Codex 引擎的 hostWorkingDir）
  void setWorkspaceDir(String? dir) {
    _workspaceDir = (dir == null || dir.isEmpty) ? null : dir;
    state = state.copyWith(
      workspaceDir: _workspaceDir,
      clearWorkspaceDir: _workspaceDir == null,
    );
    _queueSave();
  }

  /// 初始化默认会话
  void _initDefaultSession() {
    final session = _engine.createSession();
    _syncFromEngine(session.sessionId);
  }

  /// 从 SharedPreferences 恢复最近会话、当前选中会话和工作目录。
  ///
  /// 构造时先创建的空默认会话只在「没有可恢复会话」时保留，避免 App
  /// 重启后列表里多出一个空对话。
  Future<void> _restoreSessions() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final restored = _decodeSessions(prefs.getString(_sessionsPrefKey));
      if (!mounted) return;

      final savedWorkspace = prefs.getString(_workspaceDirPrefKey);
      _workspaceDir =
          (savedWorkspace == null || savedWorkspace.isEmpty)
              ? null
              : savedWorkspace;

      if (restored.isEmpty) {
        if (_workspaceDir != null) {
          state = state.copyWith(workspaceDir: _workspaceDir);
        }
        return;
      }

      final defaultSessionId = state.currentSessionId;
      for (final session in restored) {
        _engine.restoreSession(session);
      }

      // 启动时创建的空占位会话不在持久化列表中，直接移除。
      if (defaultSessionId != null &&
          !restored.any((session) => session.sessionId == defaultSessionId)) {
        _engine.deleteSession(defaultSessionId);
      }

      final savedCurrent = prefs.getString(_currentSessionPrefKey);
      final currentSessionId = restored.any(
        (session) => session.sessionId == savedCurrent,
      )
          ? savedCurrent!
          : restored.first.sessionId;
      _syncFromEngine(currentSessionId);
    } catch (_) {
      // 持久化数据损坏或平台不可用 → 保留构造时的默认新会话。
    } finally {
      if (mounted) {
        _restoreCompleted = true;
        _queueSave();
      }
    }
  }

  List<ChatSession> _decodeSessions(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final result = <ChatSession>[];
      final seen = <String>{};
      for (final item in decoded) {
        if (item is! Map) continue;
        final session = ChatSession.fromJson(
          Map<String, dynamic>.from(item),
        );
        if (session == null || !seen.add(session.sessionId)) continue;
        result.add(session);
      }
      return result;
    } catch (_) {
      return const [];
    }
  }

  void _queueSave() {
    _saveQueue = _saveQueue
        .then((_) => _persistSessions())
        .catchError((Object _) {});
  }

  Future<void> _persistSessions() async {
    if (!_restoreCompleted) {
      return;
    }
    if (!mounted) return;

    final sessions = _engine.listSessions();
    final currentSessionId = state.currentSessionId;
    final workspaceDir = _workspaceDir;
    final payload = _encodeSessions(sessions);

    try {
      final prefs = await SharedPreferences.getInstance();
      if (payload == null) {
        await prefs.remove(_sessionsPrefKey);
      } else {
        await prefs.setString(_sessionsPrefKey, payload);
      }
      if (currentSessionId == null) {
        await prefs.remove(_currentSessionPrefKey);
      } else {
        await prefs.setString(_currentSessionPrefKey, currentSessionId);
      }
      if (workspaceDir == null) {
        await prefs.remove(_workspaceDirPrefKey);
      } else {
        await prefs.setString(_workspaceDirPrefKey, workspaceDir);
      }
    } catch (_) {
      // 本地保存失败不影响当前对话。
    }
  }

  String? _encodeSessions(List<ChatSession> sessions) {
    if (sessions.isEmpty) return null;

    final entries = sessions
        .take(_maxStoredSessions)
        .map((session) {
          final json = session.toJson();
          final messages = List<dynamic>.from(
            json['messages'] as List<dynamic>? ?? const [],
          );
          if (messages.length > _maxStoredMessagesPerSession) {
            json['messages'] = messages.sublist(
              messages.length - _maxStoredMessagesPerSession,
            );
          }
          return json;
        })
        .toList();

    var payload = jsonEncode(entries);
    while (payload.length > _maxStoredPayloadChars && entries.length > 1) {
      entries.removeLast();
      payload = jsonEncode(entries);
    }

    // 单个超长会话：逐步丢弃较早消息，保留最近上下文。
    while (payload.length > _maxStoredPayloadChars && entries.isNotEmpty) {
      final messages = List<dynamic>.from(
        entries.first['messages'] as List<dynamic>? ?? const [],
      );
      if (messages.length <= 2) break;
      entries.first['messages'] = messages.sublist(messages.length ~/ 2);
      payload = jsonEncode(entries);
    }
    return payload;
  }

  /// 从引擎同步最新状态
  void _syncFromEngine(String sessionId, {bool keepCurrentSession = false}) {
    final targetSessionId =
        keepCurrentSession ? (state.currentSessionId ?? sessionId) : sessionId;
    final session = _engine.getSession(targetSessionId);
    final sessions = _engine.listSessions();
    state = ChatState(
      currentSessionId: targetSessionId,
      sessions: sessions,
      messages: session?.messages ?? [],
      loadingState: _deriveLoadingState(targetSessionId),
      generationStatus: _engine.getGenerationStatus(targetSessionId),
      workspaceDir: _workspaceDir,
      viewMode: _viewMode,
    );
  }

  /// 从引擎 GenerationStatus 推导 UI 加载状态
  ChatLoadingState _deriveLoadingState(String sessionId) {
    final status = _engine.getGenerationStatus(sessionId);
    switch (status) {
      case GenerationStatus.streaming:
        return ChatLoadingState.streaming;
      case GenerationStatus.error:
        return ChatLoadingState.error;
      case GenerationStatus.completed:
      case GenerationStatus.idle:
        return ChatLoadingState.idle;
    }
  }

  // ── Session 管理 ──

  /// 创建新会话
  void createSession({String? title}) {
    final session = _engine.createSession(title: title);
    _syncFromEngine(session.sessionId);
    _queueSave();
  }

  /// 切换会话
  void switchSession(String sessionId) {
    if (state.currentSessionId == sessionId) return;
    // 先停止当前会话的生成
    if (state.currentSessionId != null) {
      _engine.stopGeneration(state.currentSessionId!);
    }
    _syncFromEngine(sessionId);
    _queueSave();
  }

  /// 删除会话
  void deleteSession(String sessionId) {
    final wasCurrentSession = state.currentSessionId == sessionId;
    _engine.deleteSession(sessionId);
    final sessions = _engine.listSessions();
    if (sessions.isEmpty) {
      _initDefaultSession();
    } else if (!wasCurrentSession &&
        state.currentSessionId != null &&
        _engine.getSession(state.currentSessionId!) != null) {
      // 删除历史会话时保留当前会话，避免用户被意外切走。
      _syncFromEngine(state.currentSessionId!);
    } else {
      _syncFromEngine(sessions.first.sessionId);
    }
    _queueSave();
  }

  // ── 消息操作 ──

  /// 发送消息（流式）。
  ///
  /// [attachments] 随用户消息绑定；图片由 Codex 引擎复制到工作区后通过
  /// `codex exec -i` 传入，其他文件复制后把路径写进 prompt。
  Future<void> sendMessage(
    String content, {
    List<Attachment> attachments = const [],
  }) async {
    if (content.trim().isEmpty && attachments.isEmpty) return;

    final sessionId = state.currentSessionId;
    if (sessionId == null) return;

    state = state.copyWith(
      loadingState: ChatLoadingState.streaming,
    );

    try {
      final meta = <String, dynamic>{
        if (_workspaceDir != null) 'workspaceDir': _workspaceDir,
        if (attachments.isNotEmpty)
          'attachments': attachments.map((a) => a.toJson()).toList(),
      };
      await for (final _ in _engine.streamMessage(
        sessionId: sessionId,
        content: content.trim(),
        metadata: meta.isEmpty ? null : meta,
      )) {
        // 每收到一个 chunk 就同步状态（引擎会实时更新占位消息内容）
        _syncFromEngine(sessionId, keepCurrentSession: true);
      }

      // 流结束，同步最终状态
      _syncFromEngine(sessionId, keepCurrentSession: true);
      _queueSave();
    } catch (e) {
      // 发生错误时同步状态（引擎已将占位消息替换为错误消息）
      _syncFromEngine(sessionId, keepCurrentSession: true);
      // 生成期间可能已切换会话；旧会话的错误不能冒泡到当前会话。
      if (state.currentSessionId == sessionId) {
        // ChatEngineException 展示其 message（不含 [type] 前缀），其余异常按原样
        final message = e is ChatEngineException ? e.message : e.toString();
        state = state.copyWith(
          errorMessage: message,
          loadingState: ChatLoadingState.error,
        );
      }
      _queueSave();
    }
  }

  /// 停止生成
  void stopGeneration() {
    final sessionId = state.currentSessionId;
    if (sessionId == null) return;
    _engine.stopGeneration(sessionId);
    _syncFromEngine(sessionId);
    _queueSave();
  }

  /// 重试最后一条消息
  Future<void> retryLastMessage() async {
    final sessionId = state.currentSessionId;
    if (sessionId == null) return;

    state = state.copyWith(
      loadingState: ChatLoadingState.streaming,
    );

    try {
      await _engine.retryLastMessage(sessionId);
      _syncFromEngine(sessionId, keepCurrentSession: true);
      _queueSave();
    } catch (e) {
      _syncFromEngine(sessionId, keepCurrentSession: true);
      if (state.currentSessionId == sessionId) {
        state = state.copyWith(
          errorMessage: e.toString(),
          loadingState: ChatLoadingState.error,
        );
      }
      _queueSave();
    }
  }

  /// 清除错误
  void clearError() {
    state = state.copyWith(
      loadingState: ChatLoadingState.idle,
      clearErrorMessage: true,
    );
  }

  // ── 生命周期 ──

  @override
  void dispose() {
    _engine.dispose();
    super.dispose();
  }
}
