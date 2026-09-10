import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:plateone/data/mic_source.dart';
import 'package:plateone/data/pcm_player.dart';
import 'package:plateone/data/scan_api.dart';
import 'package:plateone/data/voice_agent_events.dart';
import 'package:plateone/data/voice_agent_session.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// A WebSocket that is really two controllers.
///
/// [serverSays] pushes a frame down as if AssemblyAI had sent it; [sent] is
/// everything the session wrote back. No network, no timing, no flakiness.
class FakeSocket extends StreamChannelMixin implements WebSocketChannel {
  final _inbound = StreamController<dynamic>();
  final sent = <String>[];

  bool sinkClosed = false;
  bool readyFails = false;

  void serverSays(Map<String, dynamic> event) => _inbound.add(jsonEncode(event));
  void drop() => _inbound.close();

  /// The frames the session sent, decoded, in order.
  List<Map<String, dynamic>> get sentJson =>
      sent.map((s) => jsonDecode(s) as Map<String, dynamic>).toList();

  List<Map<String, dynamic>> sentOfType(String type) =>
      sentJson.where((f) => f['type'] == type).toList();

  @override
  Stream<dynamic> get stream => _inbound.stream;

  @override
  late final WebSocketSink sink = _FakeSink(this);

  @override
  Future<void> get ready =>
      readyFails ? Future.error(StateError('no route to host')) : Future.value();

  @override
  String? get protocol => null;
  @override
  int? get closeCode => null;
  @override
  String? get closeReason => null;
}

class _FakeSink implements WebSocketSink {
  _FakeSink(this._socket);
  final FakeSocket _socket;

  @override
  void add(dynamic data) {
    if (_socket.sinkClosed) throw StateError('sink is closed');
    _socket.sent.add(data as String);
  }

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    _socket.sinkClosed = true;
    // Not awaited: a StreamController whose subscription has been cancelled
    // never completes its close future, and a real WebSocketSink does.
    unawaited(_socket._inbound.close());
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<dynamic> stream) async {}

  @override
  Future<void> get done => Future.value();
}

/// A microphone that never existed.
class FakeMic implements MicSource {
  FakeMic({this.permitted = true, this.startThrows = false, this.stopThrows = false});

  final bool permitted;
  final bool startThrows;
  final bool stopThrows;

  // Broadcast so closing it completes even when the session never got as far
  // as listening — a single-subscription controller would hang there.
  final _audio = StreamController<Uint8List>.broadcast();
  bool started = false;
  bool stopped = false;
  bool disposed = false;

  void speak(List<int> pcm) => _audio.add(Uint8List.fromList(pcm));

  @override
  Future<bool> hasPermission() async => permitted;

  @override
  Future<Stream<Uint8List>> start() async {
    if (startThrows) throw StateError('microphone busy');
    started = true;
    return _audio.stream;
  }

  @override
  Future<void> stop() async {
    stopped = true;
    if (stopThrows) throw StateError('microphone would not close');
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    if (!_audio.isClosed) await _audio.close();
  }
}

class FakePlayer implements PcmPlayer {
  final played = <int>[];
  int flushes = 0;
  bool disposed = false;

  @override
  Future<void> start() async {}

  @override
  void enqueue(Uint8List pcm16) => played.addAll(pcm16);

  @override
  void flush() => flushes++;

  @override
  Future<void> dispose() async => disposed = true;
}

VoiceToken _token({int maxSessionSeconds = 600, String token = 'tok_live'}) => VoiceToken(
      token: token,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(1789310995000),
      maxSessionSeconds: maxSessionSeconds,
      quota: ScanQuota(
        scans: 8,
        previews: 4,
        voice: 11,
        resetsAt: DateTime.fromMillisecondsSinceEpoch(1789310995000),
      ),
    );

void main() {
  late FakeSocket socket;
  late FakeMic mic;
  late FakePlayer player;
  late List<Uri> connectedTo;

  VoiceAgentSession build({
    VoiceToken? token,
    Future<VoiceToken> Function()? mint,
    List<Map<String, dynamic>> tools = const [],
    Future<Object?> Function(ToolCall)? onToolCall,
  }) =>
      VoiceAgentSession(
        mintToken: mint ?? () async => token ?? _token(),
        systemPrompt: 'Ask what is on the plate.',
        greeting: 'What is on your plate?',
        voiceId: 'anna',
        tools: tools,
        onToolCall: onToolCall,
        connect: (url) {
          connectedTo.add(url);
          return socket;
        },
        mic: mic,
        player: player,
      );

  setUp(() {
    socket = FakeSocket();
    mic = FakeMic();
    player = FakePlayer();
    connectedTo = [];
  });

  /// Gets a session to the point where the microphone is open.
  Future<VoiceAgentSession> live({
    List<Map<String, dynamic>> tools = const [],
    Future<Object?> Function(ToolCall)? onToolCall,
  }) async {
    final session = build(tools: tools, onToolCall: onToolCall);
    await session.start();
    socket.serverSays({'type': 'session.ready', 'session_id': 'sess_1'});
    await pumpEventQueue();
    return session;
  }

  group('connecting', () {
    test('carries the minted token in the URL and configures the agent first', () async {
      final session = build();
      await session.start();

      expect(connectedTo.single.toString(),
          'wss://agents.assemblyai.com/v1/ws?token=tok_live');

      // The very first frame, before any audio: a browser cannot set an
      // Authorization header, so the token in the URL is the whole handshake.
      final first = socket.sentJson.first;
      expect(first['type'], 'session.update');
      expect((first['session'] as Map)['greeting'], 'What is on your plate?');

      await session.dispose();
    });

    test('the microphone stays shut until the server says ready', () async {
      final session = build();
      await session.start();
      expect(mic.started, isFalse,
          reason: 'audio sent before session.ready is discarded by the server');

      socket.serverSays({'type': 'session.ready', 'session_id': 'sess_1'});
      await pumpEventQueue();
      expect(mic.started, isTrue);
      expect(session.currentState, VoiceAgentState.listening);

      await session.dispose();
    });

    test('a refused microphone ends the session without connecting', () async {
      mic = FakeMic(permitted: false);
      final session = build();

      await expectLater(session.start(), throwsA(isA<VoiceFailure>()));
      expect(connectedTo, isEmpty, reason: 'a token would have been spent for nothing');
      expect(session.currentState, VoiceAgentState.ended);
      expect(session.failure, contains('microphone'));
    });

    test('a socket that never opens leaves nothing running', () async {
      socket.readyFails = true;
      final session = build();

      await expectLater(session.start(), throwsA(anything));
      expect(session.currentState, VoiceAgentState.ended);
      // The failure path is where a half-open microphone gets forgotten.
      expect(mic.stopped, isTrue);
      expect(player.disposed, isTrue);
    });
  });

  group('the conversation', () {
    test('microphone audio goes out as input.audio', () async {
      final session = await live();
      mic.speak([0x01, 0x02, 0x03, 0x04]);
      await pumpEventQueue();

      final audio = socket.sentOfType('input.audio');
      expect(audio, hasLength(1));
      expect(base64Decode(audio.single['audio'] as String), [1, 2, 3, 4]);

      await session.dispose();
    });

    test('the state follows the turn: listening, thinking, speaking', () async {
      final session = await live();
      final seen = <VoiceAgentState>[];
      session.state.listen(seen.add);

      socket.serverSays({'type': 'input.speech.started'});
      socket.serverSays({'type': 'input.speech.stopped'});
      await pumpEventQueue();
      expect(session.currentState, VoiceAgentState.thinking);

      socket.serverSays({'type': 'reply.started', 'reply_id': 'r1'});
      await pumpEventQueue();
      expect(session.currentState, VoiceAgentState.speaking);

      socket.serverSays({'type': 'reply.done', 'reply_id': 'r1', 'status': 'completed'});
      await pumpEventQueue();
      expect(session.currentState, VoiceAgentState.listening);

      expect(seen, [
        VoiceAgentState.thinking,
        VoiceAgentState.speaking,
        VoiceAgentState.listening,
      ]);

      await session.dispose();
    });

    test('reply audio reaches the speaker decoded', () async {
      final session = await live();
      socket.serverSays({
        'type': 'reply.audio',
        'reply_id': 'r1',
        'data': base64Encode([0x10, 0x20]),
      });
      await pumpEventQueue();
      expect(player.played, [0x10, 0x20]);

      await session.dispose();
    });

    test('a barge-in drops the audio already buffered', () async {
      final session = await live();
      socket.serverSays({'type': 'reply.started', 'reply_id': 'r1'});
      socket.serverSays({
        'type': 'reply.audio',
        'reply_id': 'r1',
        'data': base64Encode([1, 2]),
      });
      await pumpEventQueue();
      expect(player.flushes, 0);

      // The user talked over it. What is queued answers a question they left.
      socket.serverSays({'type': 'input.speech.started'});
      await pumpEventQueue();
      expect(player.flushes, 1);
      expect(session.currentState, VoiceAgentState.listening);

      await session.dispose();
    });

    test('every event is offered to listeners, in order', () async {
      final session = await live();
      final seen = <VoiceEvent>[];
      session.events.listen(seen.add);

      socket.serverSays({'type': 'transcript.user', 'text': 'rice and chicken'});
      socket.serverSays({'type': 'transcript.agent', 'text': 'Add spinach.'});
      await pumpEventQueue();

      expect(seen.map((e) => e.runtimeType).toList(),
          [UserTranscript, AgentTranscript]);
      expect((seen.first as UserTranscript).text, 'rice and chicken');

      await session.dispose();
    });
  });

  group('tools', () {
    test('a result waits for reply.done and never arrives early', () async {
      final session = await live(
        onToolCall: (call) async => {'addition': 'spinach'},
      );

      socket.serverSays({
        'type': 'tool.call',
        'call_id': 'c1',
        'name': 'get_recommendation',
        'arguments': {'foods': ['rice']},
      });
      await pumpEventQueue();

      // Sending now would cut the agent off mid-transition-phrase.
      expect(socket.sentOfType('tool.result'), isEmpty);

      socket.serverSays({'type': 'reply.done', 'reply_id': 'fc-c1', 'status': 'completed'});
      await pumpEventQueue();

      final result = socket.sentOfType('tool.result').single;
      expect(result['call_id'], 'c1');
      expect(jsonDecode(result['result'] as String), {'addition': 'spinach'});
      expect(result['is_error'], isFalse);

      await session.dispose();
    });

    test('a tool that answers after reply.done is sent as soon as it can be', () async {
      final answer = Completer<Object?>();
      final session = await live(onToolCall: (call) => answer.future);

      socket.serverSays({
        'type': 'tool.call',
        'call_id': 'c1',
        'name': 'get_recommendation',
        'arguments': const {},
      });
      socket.serverSays({'type': 'reply.done', 'reply_id': 'fc-c1', 'status': 'completed'});
      await pumpEventQueue();
      expect(socket.sentOfType('tool.result'), isEmpty, reason: 'still running');

      answer.complete({'addition': 'lentils'});
      await pumpEventQueue();
      expect(socket.sentOfType('tool.result'), hasLength(1));

      await session.dispose();
    });

    test('a tool nobody registered is answered, not ignored', () async {
      // Silence here leaves the agent waiting forever on a call it made up.
      final session = await live();

      socket.serverSays({
        'type': 'tool.call',
        'call_id': 'c9',
        'name': 'launch_rocket',
        'arguments': const {},
      });
      socket.serverSays({'type': 'reply.done', 'reply_id': 'fc-c9', 'status': 'completed'});
      await pumpEventQueue();

      final result = socket.sentOfType('tool.result').single;
      expect(result['is_error'], isTrue);
      expect(jsonDecode(result['result'] as String), containsPair('error', 'unknown_tool'));

      await session.dispose();
    });

    test('a tool that throws tells the agent so', () async {
      final session = await live(onToolCall: (_) async => throw StateError('no catalogue'));

      socket.serverSays({
        'type': 'tool.call',
        'call_id': 'c2',
        'name': 'get_recommendation',
        'arguments': const {},
      });
      socket.serverSays({'type': 'reply.done', 'reply_id': 'fc-c2', 'status': 'completed'});
      await pumpEventQueue();

      final result = socket.sentOfType('tool.result').single;
      expect(result['is_error'], isTrue);
      // The message stays ours. Whatever the exception said is not for the
      // agent to read out loud.
      expect(result['result'], isNot(contains('no catalogue')));

      await session.dispose();
    });

    test('a result from a reply the user talked over is dropped', () async {
      final answer = Completer<Object?>();
      final session = await live(onToolCall: (_) => answer.future);

      socket.serverSays({
        'type': 'tool.call',
        'call_id': 'c3',
        'name': 'get_recommendation',
        'arguments': const {},
      });
      await pumpEventQueue();

      socket.serverSays({
        'type': 'reply.done',
        'reply_id': 'fc-c3',
        'status': 'interrupted',
      });
      await pumpEventQueue();

      answer.complete({'addition': 'spinach'});
      await pumpEventQueue();

      expect(socket.sentOfType('tool.result'), isEmpty,
          reason: 'the user has moved on; answering now talks over them');

      await session.dispose();
    });
  });

  group('ending', () {
    test('session.end goes out before the socket closes', () async {
      final session = await live();
      await session.stop();

      expect(socket.sentOfType('session.end'), hasLength(1),
          reason: 'closing without it leaves 30 billable seconds behind');
      expect(socket.sinkClosed, isTrue);
      expect(mic.stopped, isTrue);
      expect(player.disposed, isTrue);
      expect(session.currentState, VoiceAgentState.ended);
    });

    test('a microphone that refuses to close does not strand the socket', () async {
      // Cleanup lives in finally, one guard per step: a failure in the first
      // step is exactly how a socket stays open and a session stays billed.
      mic = FakeMic(stopThrows: true);
      final session = await live();

      await session.stop();

      expect(socket.sinkClosed, isTrue);
      expect(player.disposed, isTrue);
      expect(session.currentState, VoiceAgentState.ended);
    });

    test('the server ending it releases everything too', () async {
      final session = await live();
      socket.serverSays({
        'type': 'session.ended',
        'session_duration_seconds': 12.0,
        'audio_duration_seconds': 9.0,
      });
      await pumpEventQueue();

      expect(mic.stopped, isTrue);
      expect(player.disposed, isTrue);
      expect(session.currentState, VoiceAgentState.ended);

      await session.dispose();
    });

    test('a dropped socket ends the session with something to say', () async {
      final session = await live();
      socket.drop();
      await pumpEventQueue();

      expect(session.currentState, VoiceAgentState.ended);
      expect(session.failure, isNotNull);
      expect(mic.stopped, isTrue);

      await session.dispose();
    });

    test('a session error ends it and keeps the reason', () async {
      final session = await live();
      socket.serverSays({
        'type': 'session.error',
        'code': 'session_expired',
        'message': 'Session duration TTL reached.',
      });
      await pumpEventQueue();

      expect(session.currentState, VoiceAgentState.ended);
      expect(session.failure, 'Session duration TTL reached.');
      expect(player.disposed, isTrue);

      await session.dispose();
    });

    test('a tab left open stops costing money on its own', () async {
      final session = build(token: _token(maxSessionSeconds: 0));
      await session.start();
      socket.serverSays({'type': 'session.ready', 'session_id': 's'});
      await pumpEventQueue();
      // A zero-second cap fires on the next turn of the event loop. The point
      // is the timer exists at all: nothing else stops a forgotten tab.
      await pumpEventQueue();

      expect(session.currentState, VoiceAgentState.ended);
      expect(socket.sentOfType('session.end'), hasLength(1));
      expect(mic.stopped, isTrue);
    });

    test('dispose releases the microphone hardware, not just the stream', () async {
      final session = await live();
      await session.dispose();
      expect(mic.disposed, isTrue);
    });

    test('stopping twice is not an error', () async {
      final session = await live();
      await session.stop();
      await session.stop();
      expect(socket.sentOfType('session.end'), hasLength(1));
    });
  });
}
