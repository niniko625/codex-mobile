import 'dart:async';
import 'dart:io';

import 'package:codex_mobile_pro/core/ai/ai_message.dart';
import 'package:codex_mobile_pro/core/ai/attachment.dart';
import 'package:codex_mobile_pro/core/ai/chat_engine.dart';
import 'package:codex_mobile_pro/core/ai/chat_session.dart';
import 'package:codex_mobile_pro/core/ai/codex_chat_engine.dart';
import 'package:codex_mobile_pro/core/ai/codex_runner.dart';
import 'package:codex_mobile_pro/runtime/process/process_runner.dart';
import 'package:codex_mobile_pro/runtime/provider/linux_runtime_provider.dart';
import 'package:flutter_test/flutter_test.dart';

// ══════════════════════════════════════════════════════════════
// Fake CodexRunner：不启动真实进程，按配置发出事件并返回固定结果
// ══════════════════════════════════════════════════════════════
class FakeCodexRunner extends CodexRunner {
  final List<CodexEvent> eventsToEmit;
  final CodexRunResult result;
  int runCount = 0;
  int stopCount = 0;
  String? lastPrompt;
  String? lastWorkingDir;
  String? lastGuestWorkingDir;
  bool? lastResolveWorkspace;
  String? lastSystemPrompt;
  List<String> lastImages = const [];
  String? lastThreadId;

  FakeCodexRunner({
    List<CodexEvent>? events,
    CodexRunResult? result,
  }) : eventsToEmit = events ?? const [],
       result = result ?? const CodexRunResult(exitCode: 0),
       super(provider: LinuxRuntimeProvider(), processExecution: LocalProcessExecution());

  @override
  Future<CodexRunResult> run({
    required String prompt,
    required String hostWorkingDir,
    String? systemPrompt,
    Duration? timeout,
    required CodexEventListener listener,
    String? guestWorkingDir,
    bool resolveWorkspace = true,
    List<String> images = const [],
    String? threadId,
  }) async {
    runCount++;
    lastPrompt = prompt;
    lastWorkingDir = hostWorkingDir;
    lastGuestWorkingDir = guestWorkingDir;
    lastResolveWorkspace = resolveWorkspace;
    lastSystemPrompt = systemPrompt;
    lastImages = images;
    lastThreadId = threadId;
    for (final e in eventsToEmit) {
      listener.onCodexEvent(e);
    }
    return result;
  }

  @override
  void stop() {
    stopCount++;
  }
}

/// 支持「停止后返回 cancelled」的 runner（模拟真实执行器取消语义）
class GateCodexRunner extends FakeCodexRunner {
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();
  bool stopped = false;

  GateCodexRunner({required List<CodexEvent> events, super.result})
    : super(events: events);

  @override
  void stop() {
    stopped = true;
    super.stop();
  }

  @override
  Future<CodexRunResult> run({
    required String prompt,
    required String hostWorkingDir,
    String? systemPrompt,
    Duration? timeout,
    required CodexEventListener listener,
    String? guestWorkingDir,
    bool resolveWorkspace = true,
    List<String> images = const [],
    String? threadId,
  }) async {
    runCount++;
    lastPrompt = prompt;
    lastWorkingDir = hostWorkingDir;
    lastGuestWorkingDir = guestWorkingDir;
    lastResolveWorkspace = resolveWorkspace;
    lastSystemPrompt = systemPrompt;
    lastImages = images;
    lastThreadId = threadId;
    started.complete();
    await release.future;
    if (stopped) {
      return const CodexRunResult(exitCode: -3, cancelled: true);
    }
    for (final e in eventsToEmit) {
      listener.onCodexEvent(e);
    }
    return result;
  }
}

List<CodexEvent> _happyEvents() => [
  const CodexThreadStarted(threadId: 'thread-1'),
  const CodexAgentMessage(text: '我来看看目录：'),
  const CodexCommandStarted(id: 'c1', command: 'ls -la'),
  const CodexCommandCompleted(
    id: 'c1',
    command: 'ls -la',
    exitCode: 0,
    output: 'main.dart\npubspec.yaml\n',
  ),
  const CodexAgentMessage(text: '共 2 个文件。'),
  const CodexTurnCompleted(inputTokens: 10, outputTokens: 3),
];

void main() {
  group('CodexChatEngine — Session 管理', () {
    test('create/delete/list/get 会话', () {
      final engine = CodexChatEngine(runner: FakeCodexRunner());
      final s1 = engine.createSession();
      final s2 = engine.createSession(title: '标题');

      expect(engine.listSessions().length, 2);
      expect(engine.getSession(s1.sessionId), isNotNull);
      expect(engine.getSession(s2.sessionId)?.title, '标题');

      engine.deleteSession(s1.sessionId);
      expect(engine.getSession(s1.sessionId), isNull);
      expect(engine.listSessions().length, 1);

      engine.dispose();
      expect(engine.listSessions(), isEmpty);
    });

    test('首条用户消息自动生成标题', () async {
      final engine = CodexChatEngine(runner: FakeCodexRunner());
      final session = engine.createSession();

      await for (final _ in engine.streamMessage(
        sessionId: session.sessionId,
        content: '帮我优化这段 Flutter 代码',
      )) {}

      expect(session.title, contains('帮我优化这段'));
      engine.dispose();
    });

    test('restoreSession 从 metadata 恢复 threadId，下一轮直接续聊', () async {
      final runner = FakeCodexRunner();
      final engine = CodexChatEngine(
        runner: runner,
        defaultWorkspaceDir: '/ws',
      );
      final session = ChatSession(
        sessionId: 'restored-session',
        metadata: {'threadId': 'thread-restored'},
      );
      engine.restoreSession(session);

      await for (final _ in engine.streamMessage(
        sessionId: session.sessionId,
        content: '继续上次的话题',
      )) {}

      expect(runner.lastThreadId, 'thread-restored');
      engine.dispose();
    });

    test('新会话首轮不带 threadId，收到 thread.started 后第二轮自动续聊', () async {
      final runner = FakeCodexRunner(events: _happyEvents());
      final engine = CodexChatEngine(
        runner: runner,
        defaultWorkspaceDir: '/ws',
      );
      final session = engine.createSession();

      await for (final _ in engine.streamMessage(
        sessionId: session.sessionId,
        content: '第一轮',
      )) {}
      expect(runner.lastThreadId, isNull);

      await for (final _ in engine.streamMessage(
        sessionId: session.sessionId,
        content: '第二轮',
      )) {}
      expect(runner.lastThreadId, 'thread-1');
      engine.dispose();
    });

    test('普通文件附件 → 复制到工作区并把 guest 路径写入 prompt', () async {
      final workspace = await Directory.systemTemp.createTemp('codex-file-ws');
      final sourceDir = await Directory.systemTemp.createTemp('codex-file-src');
      addTearDown(() async {
        if (workspace.existsSync()) await workspace.delete(recursive: true);
        if (sourceDir.existsSync()) await sourceDir.delete(recursive: true);
      });

      final report = File('${sourceDir.path}/report.txt');
      await report.writeAsString('季度报告内容');
      final spec = File('${sourceDir.path}/pubspec.yaml');
      await spec.writeAsString('name: demo\n');

      final runner = FakeCodexRunner();
      final engine = CodexChatEngine(
        runner: runner,
        defaultWorkspaceDir: workspace.path,
      );
      final session = engine.createSession();

      final attJson = <Map<String, dynamic>>[
        {
          'id': 'att-1',
          'type': 'file',
          'name': 'report.txt',
          'mimeType': 'text/plain',
          'size': 18,
          'path': report.path,
          'status': 'ready',
        },
        {
          'id': 'att-2',
          'type': 'projectFile',
          'name': 'pubspec.yaml',
          'mimeType': 'application/yaml',
          'size': 11,
          'path': spec.path,
          'status': 'ready',
        },
      ];

      await for (final _ in engine.streamMessage(
        sessionId: session.sessionId,
        content: '看看附件',
        metadata: {'attachments': attJson},
      )) {}

      expect(runner.runCount, 1);
      expect(runner.lastImages, isEmpty);
      expect(runner.lastPrompt, contains('以下附件已放入工作区，可直接读取'));
      expect(runner.lastPrompt, contains('report.txt'));
      expect(runner.lastPrompt, contains('pubspec.yaml'));

      final stagedDir =
          Directory('${workspace.path}/.codex-mobile/attachments');
      final stagedFiles = await stagedDir
          .list()
          .where((e) => e is File)
          .toList();
      expect(stagedFiles, hasLength(2));

      final user = session.messages.first;
      expect(user.role, ChatRole.user);
      expect(user.content, '看看附件');
      expect(user.attachments, hasLength(2));
      expect(user.attachments[0].type, AttachmentType.file);
      expect(user.attachments[0].name, 'report.txt');
      expect(user.attachments[1].type, AttachmentType.projectFile);
      expect(user.attachments[1].name, 'pubspec.yaml');
      expect(session.title, '看看附件');

      // 附件对象本身不参与 API 序列化；工作区路径由 Codex prompt 传递。
      final api = user.toApiMap();
      expect(api.containsKey('attachments'), isFalse);

      // 无附件 metadata → 空列表
      final engine2 = CodexChatEngine(runner: FakeCodexRunner());
      final session2 = engine2.createSession();
      await for (final _ in engine2.streamMessage(
        sessionId: session2.sessionId,
        content: '没有附件',
      )) {}
      expect(session2.messages.first.attachments, isEmpty);
      engine2.dispose();

      engine.dispose();
    });

    test('仅普通文件无文字 → 自动补充提示并标记为附件消息', () async {
      final workspace = await Directory.systemTemp.createTemp('codex-file-ws');
      final sourceDir = await Directory.systemTemp.createTemp('codex-file-src');
      addTearDown(() async {
        if (workspace.existsSync()) await workspace.delete(recursive: true);
        if (sourceDir.existsSync()) await sourceDir.delete(recursive: true);
      });

      final source = File('${sourceDir.path}/notes.pdf');
      await source.writeAsBytes([1, 2, 3]);
      final att = Attachment(
        id: 'att-pdf',
        type: AttachmentType.file,
        name: 'notes.pdf',
        mimeType: 'application/pdf',
        size: 3,
        path: source.path,
      );

      final runner = FakeCodexRunner();
      final engine = CodexChatEngine(
        runner: runner,
        defaultWorkspaceDir: workspace.path,
      );
      final session = engine.createSession();

      await for (final _ in engine.streamMessage(
        sessionId: session.sessionId,
        content: '',
        metadata: {'attachments': [att.toJson()]},
      )) {}

      expect(runner.runCount, 1);
      expect(runner.lastImages, isEmpty);
      expect(runner.lastPrompt, startsWith('请查看附件。'));
      expect(runner.lastPrompt, contains('notes.pdf'));
      expect(session.messages.first.content, isEmpty);
      expect(session.title, '附件消息');
      engine.dispose();
    });
  });

  group('CodexChatEngine — streamMessage 正常流程', () {
    test('文本流 + 占位消息实时更新 + 最终消息替换 + 工具调用 metadata', () async {
      final runner = FakeCodexRunner(events: _happyEvents());
      final engine = CodexChatEngine(
        runner: runner,
        defaultWorkspaceDir: '/ws',
      );
      final session = engine.createSession();

      final chunks = <String>[];
      await for (final c in engine.streamMessage(
        sessionId: session.sessionId,
        content: '列出文件',
      )) {
        chunks.add(c);
      }

      // 用户消息 + 最终 assistant 消息
      expect(session.messages.length, 2);
      expect(session.messages.first.role, ChatRole.user);
      expect(session.messages.first.content, '列出文件');
      expect(session.messages.last.role, ChatRole.assistant);
      expect(session.messages.last.isStreaming, isFalse);

      // 流式文本 = agent_message 拼接
      expect(chunks.join(), '我来看看目录：共 2 个文件。');
      expect(session.messages.last.content, '我来看看目录：共 2 个文件。');

      // 工具调用 metadata
      final meta = session.messages.last.metadata!;
      expect(meta['threadId'], 'thread-1');
      final calls = meta['codex_tool_calls'] as List;
      expect(calls, hasLength(1));
      final call = CodexToolCall.fromJson(
        (calls.single as Map).cast<String, dynamic>(),
      );
      expect(call.command, 'ls -la');
      expect(call.status, 'completed');
      expect(call.exitCode, 0);
      expect(call.output, contains('main.dart'));

      // 引擎状态
      expect(engine.getGenerationStatus(session.sessionId),
          GenerationStatus.completed);
      expect(engine.isGenerating(session.sessionId), isFalse);
      engine.dispose();
    });

    test('运行期间占位消息实时携带工具调用状态', () async {
      final runner = FakeCodexRunner(events: _happyEvents());
      final engine = CodexChatEngine(runner: runner, defaultWorkspaceDir: '/ws');
      final session = engine.createSession();

      // 逐 chunk 观察占位消息
      final observedDuring = <List<dynamic>>[];
      await for (final _ in engine.streamMessage(
        sessionId: session.sessionId,
        content: '看看',
      )) {
        final last = session.messages.last;
        if (last.isStreaming) {
          final calls = last.metadata?['codex_tool_calls'] as List?;
          if (calls != null && calls.isNotEmpty) {
            observedDuring.add(calls);
          }
        }
      }

      // 流进行中已能看到工具调用（in_progress 或 completed）
      expect(observedDuring, isNotEmpty);
      engine.dispose();
    });
  });

  group('CodexChatEngine — 工作目录解析优先级', () {
    test('streamMessage metadata 优先于其余来源', () async {
      final runner = FakeCodexRunner();
      final engine = CodexChatEngine(
        runner: runner,
        defaultWorkspaceDir: '/default',
        workspaceDirResolver: () async => '/resolved',
      );
      final session = engine.createSession(
        metadata: {'workspaceDir': '/session'},
      );

      await for (final _ in engine.streamMessage(
        sessionId: session.sessionId,
        content: 'hi',
        metadata: {'workspaceDir': '/message'},
      )) {}

      expect(runner.lastWorkingDir, '/message');
      engine.dispose();
    });

    test('session metadata 优先于 defaultWorkspaceDir 与 resolver', () async {
      final runner = FakeCodexRunner();
      final engine = CodexChatEngine(
        runner: runner,
        defaultWorkspaceDir: '/default',
        workspaceDirResolver: () async => '/resolved',
      );
      final session = engine.createSession(
        metadata: {'workspaceDir': '/session'},
      );

      await for (final _ in engine.streamMessage(
        sessionId: session.sessionId,
        content: 'hi',
      )) {}

      expect(runner.lastWorkingDir, '/session');
      engine.dispose();
    });

    test('defaultWorkspaceDir 优先于 resolver', () async {
      final runner = FakeCodexRunner();
      final engine = CodexChatEngine(
        runner: runner,
        defaultWorkspaceDir: '/default',
        workspaceDirResolver: () async => '/resolved',
      );
      final session = engine.createSession();

      await for (final _ in engine.streamMessage(
        sessionId: session.sessionId,
        content: 'hi',
      )) {}

      expect(runner.lastWorkingDir, '/default');
      engine.dispose();
    });

    test('无 default 时用 resolver；都无时回退 /workspace', () async {
      // resolver 生效
      final runner1 = FakeCodexRunner();
      final engine1 = CodexChatEngine(
        runner: runner1,
        workspaceDirResolver: () async => '/resolved',
      );
      final s1 = engine1.createSession();
      await for (final _ in engine1.streamMessage(
        sessionId: s1.sessionId,
        content: 'hi',
      )) {}
      expect(runner1.lastWorkingDir, '/resolved');

      // 全部缺失 → /workspace
      final runner2 = FakeCodexRunner();
      final engine2 = CodexChatEngine(runner: runner2);
      final s2 = engine2.createSession();
      await for (final _ in engine2.streamMessage(
        sessionId: s2.sessionId,
        content: 'hi',
      )) {}
      expect(runner2.lastWorkingDir, '/workspace');

      engine1.dispose();
      engine2.dispose();
    });
  });

  group('CodexChatEngine — 异常 / 停止', () {
    test('空内容抛 ChatEngineException', () async {
      final engine = CodexChatEngine(runner: FakeCodexRunner());
      final session = engine.createSession();

      await expectLater(
        engine.streamMessage(sessionId: session.sessionId, content: '   '),
        emitsError(isA<ChatEngineException>()),
      );
      engine.dispose();
    });

    test('不存在的会话抛 ChatEngineException', () async {
      final engine = CodexChatEngine(runner: FakeCodexRunner());
      await expectLater(
        engine.streamMessage(sessionId: 'nope', content: 'hi'),
        emitsError(isA<ChatEngineException>()),
      );
      engine.dispose();
    });

    test('图片附件 → 复制到工作区并作为 -i 传给 Codex', () async {
      final workspace = await Directory.systemTemp.createTemp('codex-img-ws');
      final sourceDir = await Directory.systemTemp.createTemp('codex-img-src');
      addTearDown(() async {
        if (workspace.existsSync()) await workspace.delete(recursive: true);
        if (sourceDir.existsSync()) await sourceDir.delete(recursive: true);
      });

      final source = File('${sourceDir.path}/photo.png');
      final bytes = [0x89, 0x50, 0x4e, 0x47, 1, 2, 3];
      await source.writeAsBytes(bytes);
      final att = Attachment(
        id: 'att-img',
        type: AttachmentType.image,
        name: 'photo.png',
        mimeType: 'image/png',
        size: bytes.length,
        path: source.path,
        thumbnail: source.path,
      );

      final runner = FakeCodexRunner();
      final engine = CodexChatEngine(
        runner: runner,
        defaultWorkspaceDir: workspace.path,
      );
      final session = engine.createSession();

      await for (final _ in engine.streamMessage(
        sessionId: session.sessionId,
        content: '请描述这张图片',
        metadata: {'attachments': [att.toJson()]},
      )) {}

      expect(runner.runCount, 1);
      expect(runner.lastImages, hasLength(1));
      final guestPath = runner.lastImages.single;
      expect(guestPath, startsWith('/workspace/.codex-mobile/attachments/'));
      final fileName = guestPath.split('/').last;
      final copied = File(
        '${workspace.path}/.codex-mobile/attachments/$fileName',
      );
      expect(await copied.exists(), isTrue);
      expect(await copied.readAsBytes(), bytes);

      expect(session.messages.first.role, ChatRole.user);
      expect(session.messages.first.content, '请描述这张图片');
      expect(session.messages.first.attachments, hasLength(1));
      expect(session.messages.first.attachments.single.isImage, isTrue);
      engine.dispose();
    });

    test('仅图片无文字 → 自动补充提示并正常调用 Codex', () async {
      final workspace = await Directory.systemTemp.createTemp('codex-img-ws');
      final sourceDir = await Directory.systemTemp.createTemp('codex-img-src');
      addTearDown(() async {
        if (workspace.existsSync()) await workspace.delete(recursive: true);
        if (sourceDir.existsSync()) await sourceDir.delete(recursive: true);
      });

      final source = File('${sourceDir.path}/photo.webp');
      await source.writeAsBytes([1, 2, 3]);
      final att = Attachment(
        id: 'att-img2',
        type: AttachmentType.image,
        name: 'photo.webp',
        mimeType: 'image/webp',
        size: 3,
        path: source.path,
      );

      final runner = FakeCodexRunner();
      final engine = CodexChatEngine(
        runner: runner,
        defaultWorkspaceDir: workspace.path,
      );
      final session = engine.createSession();

      await for (final _ in engine.streamMessage(
        sessionId: session.sessionId,
        content: '',
        metadata: {'attachments': [att.toJson()]},
      )) {}

      expect(runner.runCount, 1);
      expect(runner.lastPrompt, '请查看附件图片。');
      expect(runner.lastImages.single, endsWith('.webp'));
      expect(session.messages.first.content, isEmpty);
      expect(session.title, '图片消息');
      engine.dispose();
    });

    test('不支持的图片格式 → 清晰报错且不调用后端', () async {
      final workspace = await Directory.systemTemp.createTemp('codex-img-ws');
      final sourceDir = await Directory.systemTemp.createTemp('codex-img-src');
      addTearDown(() async {
        if (workspace.existsSync()) await workspace.delete(recursive: true);
        if (sourceDir.existsSync()) await sourceDir.delete(recursive: true);
      });

      final source = File('${sourceDir.path}/photo.heic');
      await source.writeAsBytes([1, 2, 3]);
      final att = Attachment(
        id: 'att-heic',
        type: AttachmentType.image,
        name: 'photo.heic',
        mimeType: 'image/heic',
        size: 3,
        path: source.path,
      );

      final runner = FakeCodexRunner();
      final engine = CodexChatEngine(
        runner: runner,
        defaultWorkspaceDir: workspace.path,
      );
      final session = engine.createSession();

      await expectLater(
        engine.streamMessage(
          sessionId: session.sessionId,
          content: '看看这张图',
          metadata: {'attachments': [att.toJson()]},
        ),
        emitsError(
          isA<ChatEngineException>()
              .having((e) => e.type, 'type', ChatEngineErrorType.unsupported)
              .having((e) => e.message, 'message', contains('图片格式不支持')),
        ),
      );
      expect(runner.runCount, 0);
      engine.dispose();
    });

    test('run 返回 error → 抛异常 + 错误消息落盘', () async {
      final runner = FakeCodexRunner(
        events: [const CodexAgentMessage(text: '部分输出')],
        result: const CodexRunResult(
          exitCode: 1,
          error: 'codex 进程异常退出',
        ),
      );
      final engine = CodexChatEngine(runner: runner, defaultWorkspaceDir: '/ws');
      final session = engine.createSession();

      final chunks = <String>[];
      Object? caught;
      try {
        await for (final c in engine.streamMessage(
          sessionId: session.sessionId,
          content: 'hi',
        )) {
          chunks.add(c);
        }
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<ChatEngineException>());
      expect(
        (caught as ChatEngineException).message,
        contains('codex 进程异常退出'),
      );
      expect(chunks, contains('部分输出'));

      final last = session.messages.last;
      expect(last.role, ChatRole.assistant);
      expect(last.content, contains('❌'));
      expect(last.content, contains('codex 进程异常退出'));
      expect(engine.getGenerationStatus(session.sessionId),
          GenerationStatus.error);
      engine.dispose();
    });

    test('空文本回复 → 未收到有效回复', () async {
      final runner = FakeCodexRunner(); // 无事件，exitCode 0
      final engine = CodexChatEngine(runner: runner, defaultWorkspaceDir: '/ws');
      final session = engine.createSession();

      await for (final _ in engine.streamMessage(
        sessionId: session.sessionId,
        content: 'hi',
      )) {}

      expect(session.messages.last.content, '⚠️ 未收到有效回复');
      expect(engine.getGenerationStatus(session.sessionId),
          GenerationStatus.error);
      engine.dispose();
    });

    test('空回复 + exitCode!=0 + stderr 错误 → UI 显示真实诊断', () async {
      final runner = FakeCodexRunner(
        result: const CodexRunResult(
          exitCode: 1,
          stderr: 'Error: No such file or directory (os error 2)',
        ),
      );
      final engine = CodexChatEngine(runner: runner, defaultWorkspaceDir: '/ws');
      final session = engine.createSession();

      await for (final _ in engine.streamMessage(
        sessionId: session.sessionId,
        content: 'hi',
      )) {}

      final last = session.messages.last;
      expect(last.content, contains('⚠️ 未收到有效回复'));
      expect(last.content, contains('exitCode=1'));
      expect(last.content, contains('No such file or directory'));
      expect(engine.getGenerationStatus(session.sessionId),
          GenerationStatus.error);
      engine.dispose();
    });

    test('空回复 + stdout 真实错误事件（401）→ 显示诊断，无害 config 警告被排除', () async {
      final runner = FakeCodexRunner(
        result: const CodexRunResult(
          exitCode: 1,
          stdout: '{"type":"error","message":"Ignored unsupported project-local config keys in /workspace/.codex/config.toml: model_provider, model_providers. If you want these settings to apply, manually set them in your user-level config.toml."}\n'
              '{"type":"error","message":"unexpected status 401 Unauthorized: Authentication Fails, Your api key: ****3456 is invalid, url: https://api.deepseek.com/responses"}\n'
              '{"type":"turn.failed","error":{"message":"unexpected status 401 Unauthorized: Authentication Fails, Your api key: ****3456 is invalid, url: https://api.deepseek.com/responses"}}',
        ),
      );
      final engine = CodexChatEngine(runner: runner, defaultWorkspaceDir: '/ws');
      final session = engine.createSession();

      await for (final _ in engine.streamMessage(
        sessionId: session.sessionId,
        content: 'hi',
      )) {}

      final last = session.messages.last;
      expect(last.content, contains('⚠️ 未收到有效回复'));
      expect(last.content, contains('401'));
      expect(last.content, contains('api key'));
      // 无害 config 警告不进入诊断
      expect(last.content, isNot(contains('Ignored unsupported project-local config keys')));
      engine.dispose();
    });

    test('stopGeneration → runner.stop 被调用 + 占位替换为已停止', () async {
      final runner = GateCodexRunner(events: _happyEvents());
      final engine = CodexChatEngine(runner: runner, defaultWorkspaceDir: '/ws');
      final session = engine.createSession();

      final streamFut = engine
          .streamMessage(sessionId: session.sessionId, content: 'hi')
          .toList();
      await runner.started.future;

      engine.stopGeneration(session.sessionId);
      expect(runner.stopCount, 1);

      runner.release.complete();
      await streamFut;

      final last = session.messages.last;
      expect(last.content, contains('已停止生成'));
      expect(last.metadata?['stopped'], isTrue);
      expect(engine.getGenerationStatus(session.sessionId),
          GenerationStatus.completed);
      engine.dispose();
    });

    test('非用户主动的 cancelled → 标记异常并抛错，不显示普通已停止', () async {
      final runner = FakeCodexRunner(
        events: [const CodexAgentMessage(text: '部分输出')],
        result: const CodexRunResult(exitCode: -3, cancelled: true),
      );
      final engine = CodexChatEngine(runner: runner, defaultWorkspaceDir: '/ws');
      final session = engine.createSession();

      Object? caught;
      try {
        await for (final _ in engine.streamMessage(
          sessionId: session.sessionId,
          content: 'hi',
        )) {}
      } catch (e) {
        caught = e;
      }

      expect(caught, isA<ChatEngineException>());
      expect(
        (caught as ChatEngineException).message,
        contains('执行被意外取消'),
      );
      final last = session.messages.last;
      expect(last.content, contains('部分输出'));
      expect(last.content, contains('执行被意外取消'));
      expect(last.content, isNot(contains('已停止生成')));
      expect(last.metadata?['stopped'], isFalse);
      expect(last.metadata?['unexpectedCancellation'], isTrue);
      expect(engine.getGenerationStatus(session.sessionId),
          GenerationStatus.error);
      engine.dispose();
    });

    test('空闲 stopGeneration 不调用 runner.stop，不影响后续生成', () async {
      final runner = FakeCodexRunner(events: _happyEvents());
      final engine = CodexChatEngine(runner: runner, defaultWorkspaceDir: '/ws');
      final session = engine.createSession();

      engine.stopGeneration(session.sessionId);
      expect(runner.stopCount, 0);

      final msg = await engine.sendMessage(
        sessionId: session.sessionId,
        content: '空闲停止后仍应正常对话',
      );

      expect(msg.content, '我来看看目录：共 2 个文件。');
      expect(session.messages.last.content, isNot(contains('已停止生成')));
      expect(engine.getGenerationStatus(session.sessionId),
          GenerationStatus.completed);
      engine.dispose();
    });

    test('sendMessage（非流式）聚合返回最后一条消息', () async {
      final runner = FakeCodexRunner(events: _happyEvents());
      final engine = CodexChatEngine(runner: runner, defaultWorkspaceDir: '/ws');
      final session = engine.createSession();

      final msg = await engine.sendMessage(
        sessionId: session.sessionId,
        content: '列出文件',
      );

      expect(msg.content, '我来看看目录：共 2 个文件。');
      expect(session.messages.length, 2);
      engine.dispose();
    });

    test('retryLastMessage 移除旧回合并重新发送', () async {
      final runner = FakeCodexRunner(events: _happyEvents());
      final engine = CodexChatEngine(runner: runner, defaultWorkspaceDir: '/ws');
      final session = engine.createSession();

      await engine.sendMessage(sessionId: session.sessionId, content: '第一次');
      expect(session.messages.length, 2);

      final msg = await engine.retryLastMessage(session.sessionId);
      expect(msg.role, ChatRole.assistant);
      // 旧回合（user + assistant）被移除后重建
      expect(session.messages.length, 2);
      expect(session.messages.first.content, '第一次');
      expect(runner.lastPrompt, '第一次');
      engine.dispose();
    });
  });
  group('CodexChatEngine — 工作目录解析（真实目录 + 会话内缓存）', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('codex-ws-cache');
    });

    tearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    Directory createGitRepo(String path) {
      final repo = Directory(path)..createSync(recursive: true);
      Directory('$path/.git').createSync(recursive: true);
      return repo;
    }

    test('默认目录（App 文档目录）非 Git 仓库 → 解析到 文档目录/git/<repo>', () async {
      final runner = FakeCodexRunner();
      final engine = CodexChatEngine(
        runner: runner,
        workspaceDirResolver: () async => temp.path,
      );
      final session = engine.createSession();
      createGitRepo('${temp.path}/git/codex-mobile-pro');

      await for (final _ in engine.streamMessage(
        sessionId: session.sessionId,
        content: 'hi',
      )) {}

      // hostWorkingDir = bind 根（requested）；Codex cwd = 项目 guest 路径
      expect(runner.lastWorkingDir, temp.path);
      expect(runner.lastGuestWorkingDir, '/workspace/git/codex-mobile-pro');
      expect(runner.lastResolveWorkspace, isFalse);
      engine.dispose();
    });

    test('会话内缓存：解析一次后不再每轮重新扫描（新增仓库不影响结果）', () async {
      final runner = FakeCodexRunner();
      final engine = CodexChatEngine(
        runner: runner,
        workspaceDirResolver: () async => temp.path,
      );
      final session = engine.createSession();
      createGitRepo('${temp.path}/git/codex-mobile-pro');

      await for (final _ in engine.streamMessage(
        sessionId: session.sessionId,
        content: '第一轮',
      )) {}
      expect(runner.lastWorkingDir, temp.path);
      expect(runner.lastGuestWorkingDir, '/workspace/git/codex-mobile-pro');

      // 第二轮前新增另一个 Git 仓库；缓存命中 → 仍用第一轮解析结果
      createGitRepo('${temp.path}/git/newer-repo');
      await for (final _ in engine.streamMessage(
        sessionId: session.sessionId,
        content: '第二轮',
      )) {}
      expect(runner.lastWorkingDir, temp.path);
      expect(runner.lastGuestWorkingDir, '/workspace/git/codex-mobile-pro');
      engine.dispose();
    });

    test('缓存目录失效 → 重新解析（回退到文档目录）', () async {
      final runner = FakeCodexRunner();
      final engine = CodexChatEngine(
        runner: runner,
        workspaceDirResolver: () async => temp.path,
      );
      final session = engine.createSession();
      final proj = createGitRepo('${temp.path}/git/codex-mobile-pro');

      await for (final _ in engine.streamMessage(
        sessionId: session.sessionId,
        content: '第一轮',
      )) {}
      expect(runner.lastWorkingDir, temp.path);
      expect(runner.lastGuestWorkingDir, '/workspace/git/codex-mobile-pro');

      // 删除缓存的项目目录（目录失效）→ 重新解析：无候选 → guest 回退 /workspace
      proj.deleteSync(recursive: true);
      await for (final _ in engine.streamMessage(
        sessionId: session.sessionId,
        content: '第二轮',
      )) {}
      expect(runner.lastWorkingDir, temp.path);
      expect(runner.lastGuestWorkingDir, '/workspace');
      engine.dispose();
    });

    test('用户显式切换工作目录 → 重新解析（不被缓存锁定）', () async {
      final runner = FakeCodexRunner();
      final engine = CodexChatEngine(
        runner: runner,
        workspaceDirResolver: () async => temp.path,
      );
      final session = engine.createSession();
      createGitRepo('${temp.path}/git/codex-mobile-pro');

      await for (final _ in engine.streamMessage(
        sessionId: session.sessionId,
        content: '第一轮',
      )) {}
      expect(runner.lastWorkingDir, temp.path);
      expect(runner.lastGuestWorkingDir, '/workspace/git/codex-mobile-pro');

      // 用户显式选另一个 Git 仓库目录 → 直接使用该目录（本身是 git 仓库，
      // resolved == requested → guest 回退 /workspace）
      final other = createGitRepo('${temp.path}/other-repo');
      await for (final _ in engine.streamMessage(
        sessionId: session.sessionId,
        content: '第二轮',
        metadata: {'workspaceDir': other.path},
      )) {}
      expect(runner.lastWorkingDir, other.path);
      expect(runner.lastGuestWorkingDir, '/workspace');
      engine.dispose();
    });
  });
}

