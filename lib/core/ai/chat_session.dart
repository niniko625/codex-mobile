import 'ai_message.dart';

/// 聊天会话状态
enum SessionStatus {
  /// 活跃
  active,

  /// 正在生成
  generating,

  /// 已归档
  archived,
}

/// 聊天会话
///
/// 包含会话元数据和消息历史。
/// [metadata] 用于扩展属性（模型选择、Provider 信息等）。
class ChatSession {
  final String sessionId;
  String title;
  final DateTime createdAt;
  DateTime updatedAt;
  final List<ChatMessage> messages;
  SessionStatus status;
  final Map<String, dynamic>? metadata;

  ChatSession({
    required this.sessionId,
    String? title,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<ChatMessage>? messages,
    this.status = SessionStatus.active,
    this.metadata,
  }) : title = title ?? _defaultTitle(createdAt ?? DateTime.now()),
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now(),
       messages = messages ?? [];

  /// 添加消息到会话
  void addMessage(ChatMessage message) {
    messages.add(message);
    updatedAt = DateTime.now();
  }

  /// 替换最后一条消息（用于 streaming 结束更新）
  void replaceLastMessage(ChatMessage message) {
    if (messages.isNotEmpty) {
      messages.removeLast();
    }
    messages.add(message);
    updatedAt = DateTime.now();
  }

  /// 获取指定角色的消息
  List<ChatMessage> messagesByRole(ChatRole role) {
    return messages.where((m) => m.role == role).toList();
  }

  /// 获取最后 N 条消息
  List<ChatMessage> lastMessages(int count) {
    if (messages.length <= count) return List.from(messages);
    return messages.sublist(messages.length - count);
  }

  /// 本地持久化格式（供 App 重启后恢复会话列表）。
  Map<String, dynamic> toJson() {
    return {
      'sessionId': sessionId,
      'title': title,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'status': status.name,
      'messages': messages.map((m) => m.toJson()).toList(),
      'metadata': metadata,
    };
  }

  static ChatSession? fromJson(Map<String, dynamic> json) {
    final sessionId = json['sessionId'] as String?;
    if (sessionId == null || sessionId.isEmpty) return null;

    final messages = <ChatMessage>[];
    final rawMessages = json['messages'];
    if (rawMessages is List) {
      for (final item in rawMessages) {
        if (item is Map) {
          final message = ChatMessage.fromJson(
            Map<String, dynamic>.from(item),
          );
          if (message == null) continue;
          // 上次进程在生成中被杀时，占位消息会以 isStreaming=true 落盘。
          // 恢复后先结束流状态；空占位直接丢弃，避免界面永久转圈。
          if (message.role == ChatRole.assistant &&
              message.isStreaming &&
              message.content.trim().isEmpty) {
            continue;
          }
          messages.add(message.copyWith(isStreaming: false));
        }
      }
    }

    final statusName = json['status'] as String?;
    return ChatSession(
      sessionId: sessionId,
      title: json['title'] as String?,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? ''),
      messages: messages,
      status: SessionStatus.values.firstWhere(
        (status) => status.name == statusName,
        orElse: () => SessionStatus.active,
      ),
      metadata: json['metadata'] is Map
          ? Map<String, dynamic>.from(json['metadata'] as Map)
          : <String, dynamic>{},
    );
  }

  /// 创建默认标题（基于首条用户消息）
  static String _defaultTitle(DateTime time) {
    final month = time.month.toString().padLeft(2, '0');
    final day = time.day.toString().padLeft(2, '0');
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '对话 $month-$day $hour:$minute';
  }
}
