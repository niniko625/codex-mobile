import 'attachment.dart';

/// 对话角色
enum ChatRole {
  system,
  user,
  assistant,

  /// 工具调用（预留）
  tool;

  String get apiValue {
    switch (this) {
      case ChatRole.system:
        return 'system';
      case ChatRole.user:
        return 'user';
      case ChatRole.assistant:
        return 'assistant';
      case ChatRole.tool:
        return 'tool';
    }
  }

  static ChatRole fromApi(String value) {
    switch (value) {
      case 'system':
        return ChatRole.system;
      case 'user':
        return ChatRole.user;
      case 'assistant':
        return ChatRole.assistant;
      case 'tool':
        return ChatRole.tool;
      default:
        return ChatRole.user;
    }
  }
}

/// 单条聊天消息
///
/// 用于 Provider 架构的消息模型。
/// [metadata] 用于携带文件引用、Selection、Token 信息等扩展属性。
class ChatMessage {
  final String id;
  final ChatRole role;
  final String content;
  final DateTime timestamp;
  final bool isStreaming;

  /// 扩展元数据
  ///
  /// 不参与 API 序列化，仅用于引擎层内部传递上下文。
  /// 支持：文件引用、Selection、Workspace Context、Token 信息、Provider 信息等。
  final Map<String, dynamic>? metadata;

  /// 本地附件（图片 / 文件 / 项目文件）。
  ///
  /// [toApiMap] 不序列化附件本身；Codex 对话由引擎把附件复制到工作区，
  /// 图片走 `codex exec -i`，其他文件把路径写进 prompt。
  final List<Attachment> attachments;

  const ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.timestamp,
    this.isStreaming = false,
    this.metadata,
    this.attachments = const [],
  });

  ChatMessage copyWith({
    String? id,
    ChatRole? role,
    String? content,
    DateTime? timestamp,
    bool? isStreaming,
    Map<String, dynamic>? metadata,
    List<Attachment>? attachments,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      role: role ?? this.role,
      content: content ?? this.content,
      timestamp: timestamp ?? this.timestamp,
      isStreaming: isStreaming ?? this.isStreaming,
      metadata: metadata ?? this.metadata,
      attachments: attachments ?? this.attachments,
    );
  }

  /// 转换为 API 请求格式
  ///
  /// 注意：[metadata] 不参与序列化，不影响现有调用方。
  Map<String, dynamic> toApiMap() {
    return {
      'role': role.apiValue,
      'content': content,
    };
  }

  /// 本地持久化格式。
  ///
  /// 与 [toApiMap] 不同，这里保留消息、附件和工具调用状态，供 App 重启
  /// 后恢复会话。临时诊断日志（debugLog）和过长的命令输出不落盘，避免
  /// SharedPreferences 被大段 stdout 撑爆。
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'role': role.name,
      'content': content,
      'timestamp': timestamp.toIso8601String(),
      'isStreaming': isStreaming,
      'metadata': _persistableMetadata(),
      'attachments': attachments.map((a) => a.toJson()).toList(),
    };
  }

  static ChatMessage? fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String?;
    if (id == null || id.isEmpty) return null;
    final rawTimestamp = json['timestamp'] as String?;
    final attachments = <Attachment>[];
    final rawAttachments = json['attachments'];
    if (rawAttachments is List) {
      for (final item in rawAttachments) {
        if (item is Map) {
          final attachment = Attachment.fromJson(
            Map<String, dynamic>.from(item),
          );
          if (attachment != null) attachments.add(attachment);
        }
      }
    }
    return ChatMessage(
      id: id,
      role: ChatRole.values.firstWhere(
        (role) => role.name == json['role'],
        orElse: () => ChatRole.user,
      ),
      content: (json['content'] as String?) ?? '',
      timestamp: DateTime.tryParse(rawTimestamp ?? '') ?? DateTime.now(),
      isStreaming: json['isStreaming'] == true,
      metadata: json['metadata'] is Map
          ? Map<String, dynamic>.from(json['metadata'] as Map)
          : null,
      attachments: attachments,
    );
  }

  Map<String, dynamic>? _persistableMetadata() {
    final source = metadata;
    if (source == null || source.isEmpty) return null;
    final result = <String, dynamic>{};
    for (final entry in source.entries) {
      // 诊断日志只用于当次排障，可能包含完整 stdout/stderr，不持久化。
      if (entry.key == 'debugLog') continue;
      final value = entry.value;
      if (entry.key == 'codex_tool_calls' && value is List) {
        result[entry.key] = value.map((item) {
          if (item is! Map) return item;
          final call = Map<String, dynamic>.from(item);
          final output = call['output'];
          if (output is String && output.length > 2000) {
            call['output'] = '${output.substring(0, 2000)}\n…（已截断）';
          }
          return call;
        }).toList();
      } else if (value is String && value.length > 8000) {
        result[entry.key] = '${value.substring(0, 8000)}\n…（已截断）';
      } else {
        result[entry.key] = value;
      }
    }
    return result.isEmpty ? null : result;
  }
}

/// API 请求参数
class ChatCompletionRequest {
  final String model;
  final List<ChatMessage> messages;
  final bool stream;
  final double temperature;
  final int maxTokens;

  const ChatCompletionRequest({
    this.model = 'deepseek-flash',
    required this.messages,
    this.stream = true,
    this.temperature = 0.7,
    this.maxTokens = 4096,
  });

  Map<String, dynamic> toJson() {
    return {
      'model': model,
      'messages': messages.map((m) => m.toApiMap()).toList(),
      'stream': stream,
      'temperature': temperature,
      'max_tokens': maxTokens,
    };
  }
}

/// API 响应（非流式）
class ChatCompletionResponse {
  final String id;
  final String model;
  final List<ChatChoice> choices;
  final ChatUsage? usage;

  const ChatCompletionResponse({
    required this.id,
    required this.model,
    required this.choices,
    this.usage,
  });

  factory ChatCompletionResponse.fromJson(Map<String, dynamic> json) {
    return ChatCompletionResponse(
      id: json['id'] ?? '',
      model: json['model'] ?? '',
      choices: (json['choices'] as List<dynamic>?)
              ?.map((c) => ChatChoice.fromJson(c as Map<String, dynamic>))
              .toList() ??
          [],
      usage: json['usage'] != null ? ChatUsage.fromJson(json['usage'] as Map<String, dynamic>) : null,
    );
  }
}

/// API 选择
class ChatChoice {
  final int index;
  final ChatMessage message;
  final String? finishReason;

  const ChatChoice({
    required this.index,
    required this.message,
    this.finishReason,
  });

  factory ChatChoice.fromJson(Map<String, dynamic> json) {
    final msg = json['message'] as Map<String, dynamic>? ?? json['delta'] as Map<String, dynamic>? ?? {};
    final now = DateTime.now();
    return ChatChoice(
      index: json['index'] ?? 0,
      message: ChatMessage(
        id: now.microsecondsSinceEpoch.toString(),
        role: ChatRole.fromApi(msg['role'] ?? 'assistant'),
        content: msg['content'] ?? '',
        timestamp: now,
      ),
      finishReason: json['finish_reason'],
    );
  }
}

/// API 用量
class ChatUsage {
  final int promptTokens;
  final int completionTokens;
  final int totalTokens;

  const ChatUsage({
    required this.promptTokens,
    required this.completionTokens,
    required this.totalTokens,
  });

  factory ChatUsage.fromJson(Map<String, dynamic> json) {
    return ChatUsage(
      promptTokens: json['prompt_tokens'] ?? 0,
      completionTokens: json['completion_tokens'] ?? 0,
      totalTokens: json['total_tokens'] ?? 0,
    );
  }
}
