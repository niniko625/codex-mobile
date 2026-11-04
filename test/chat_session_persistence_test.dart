import 'dart:convert';

import 'package:codex_mobile_pro/core/ai/ai_message.dart';
import 'package:codex_mobile_pro/core/ai/attachment.dart';
import 'package:codex_mobile_pro/core/ai/chat_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChatMessage 本地持久化', () {
    test('messages、附件和 metadata 往返；debugLog 不落盘', () {
      final message = ChatMessage(
        id: 'm1',
        role: ChatRole.user,
        content: '查看附件',
        timestamp: DateTime.utc(2026, 11, 4, 10, 30),
        metadata: {
          'threadId': 'thread-1',
          'debugLog': '包含完整 stdout，不应持久化',
          'codex_tool_calls': [
            {'id': 'call-1', 'command': 'ls', 'output': 'file.txt'},
          ],
        },
        attachments: const [
          Attachment(
            id: 'att-1',
            type: AttachmentType.image,
            name: 'photo.png',
            mimeType: 'image/png',
            size: 123,
            path: '/tmp/photo.png',
          ),
        ],
      );

      final json = message.toJson();
      final metadata = json['metadata'] as Map<String, dynamic>;
      expect(metadata['threadId'], 'thread-1');
      expect(metadata.containsKey('debugLog'), isFalse);

      final restored = ChatMessage.fromJson(
        jsonDecode(jsonEncode(json)) as Map<String, dynamic>,
      );
      expect(restored, isNotNull);
      expect(restored!.id, 'm1');
      expect(restored.content, '查看附件');
      expect(restored.timestamp, DateTime.utc(2026, 11, 4, 10, 30));
      expect(restored.metadata?['threadId'], 'thread-1');
      expect(restored.metadata?.containsKey('debugLog'), isFalse);
      expect(restored.attachments, hasLength(1));
      expect(restored.attachments.single.type, AttachmentType.image);
      expect(restored.attachments.single.path, '/tmp/photo.png');
    });

    test('超长工具输出持久化时截断', () {
      final message = ChatMessage(
        id: 'm2',
        role: ChatRole.assistant,
        content: '完成',
        timestamp: DateTime.utc(2026, 11, 4),
        metadata: {
          'codex_tool_calls': [
            {
              'id': 'call-1',
              'command': 'cat large.log',
              'output': List.filled(2500, 'x').join(),
            },
          ],
        },
      );

      final metadata = message.toJson()['metadata'] as Map<String, dynamic>;
      final calls = metadata['codex_tool_calls'] as List<dynamic>;
      final output = (calls.single as Map<String, dynamic>)['output'] as String;
      expect(output.length, lessThan(2500));
      expect(output, contains('已截断'));
    });

    test('isStreaming 往返持久化；旧数据默认非流式', () {
      final message = ChatMessage(
        id: 'm3',
        role: ChatRole.assistant,
        content: '生成中',
        timestamp: DateTime.utc(2026, 11, 4),
        isStreaming: true,
      );

      final json = message.toJson();
      expect(json['isStreaming'], isTrue);
      final restored = ChatMessage.fromJson(
        jsonDecode(jsonEncode(json)) as Map<String, dynamic>,
      );
      expect(restored?.isStreaming, isTrue);

      final legacy = Map<String, dynamic>.from(json)..remove('isStreaming');
      expect(ChatMessage.fromJson(legacy)?.isStreaming, isFalse);
    });
  });

  group('ChatSession 本地持久化', () {
    test('会话字段和 metadata 往返；缺失 metadata 恢复为空 Map', () {
      final session = ChatSession(
        sessionId: 'session-1',
        title: '持久化会话',
        createdAt: DateTime.utc(2026, 11, 4, 9),
        updatedAt: DateTime.utc(2026, 11, 4, 10),
        metadata: {'threadId': 'thread-1'},
      );
      session.addMessage(ChatMessage(
        id: 'm1',
        role: ChatRole.user,
        content: '你好',
        timestamp: DateTime.utc(2026, 11, 4, 9, 1),
      ));

      final restored = ChatSession.fromJson(
        jsonDecode(jsonEncode(session.toJson())) as Map<String, dynamic>,
      );
      expect(restored, isNotNull);
      expect(restored!.sessionId, 'session-1');
      expect(restored.title, '持久化会话');
      expect(restored.metadata?['threadId'], 'thread-1');
      expect(restored.messages.single.content, '你好');

      final withoutMetadata = ChatSession.fromJson({
        'sessionId': 'session-2',
        'messages': const [],
      });
      expect(withoutMetadata, isNotNull);
      expect(withoutMetadata!.metadata, isNotNull);
      expect(withoutMetadata.metadata, isEmpty);
      withoutMetadata.metadata!['threadId'] = 'thread-new';
      expect(withoutMetadata.metadata?['threadId'], 'thread-new');
    });

    test('重启恢复时丢弃空流式占位，非空流式消息结束转圈', () {
      final session = ChatSession.fromJson({
        'sessionId': 'session-3',
        'messages': [
          {
            'id': 'empty-streaming',
            'role': 'assistant',
            'content': '',
            'timestamp': '2026-11-04T09:00:00.000Z',
            'isStreaming': true,
          },
          {
            'id': 'partial-streaming',
            'role': 'assistant',
            'content': '已完成一半',
            'timestamp': '2026-11-04T09:01:00.000Z',
            'isStreaming': true,
          },
          {
            'id': 'user-message',
            'role': 'user',
            'content': '继续',
            'timestamp': '2026-11-04T09:02:00.000Z',
          },
        ],
      });

      expect(session, isNotNull);
      expect(session!.messages, hasLength(2));
      expect(session.messages.first.id, 'partial-streaming');
      expect(session.messages.first.content, '已完成一半');
      expect(session.messages.first.isStreaming, isFalse);
      expect(session.messages.last.id, 'user-message');
    });
  });
}
