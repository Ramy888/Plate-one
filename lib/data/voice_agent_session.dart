import 'dart:async';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'mic_source.dart';
import 'pcm_player.dart';
import 'scan_api.dart';
import 'voice_agent_events.dart';

/// What the conversation is doing, in the only terms worth showing someone.
enum VoiceAgentState {
  /// Not connected. Nothing is listening.
  idle,

  /// Opening the socket and configuring the agent.
  connecting,

  /// The microphone is open and the agent is waiting.
  listening,

  /// The user has stopped talking; the agent has not started.
  thinking,

  /// The agent is talking.
  speaking,

  /// Over, cleanly or otherwise. A new session needs a new object.
  ended,
}

/// A voice conversation, seen from the outside.
///
/// The screen renders from this and nothing else, so it can be driven by a
/// fake with no socket, no microphone and no browser behind it.
abstract class VoiceSession {
  /// Everything the server said, in order.
  Stream<VoiceEvent> get events;

  /// The current state, and every change to it.
  Stream<VoiceAgentState> get state;

  VoiceAgentState get currentState;

  /// Why it ended badly, if it did.
  String? get failure;

  Future<void> start();
  Future<void> stop();
  Future<void> dispose();
}

/// A voice conversation, from tap to teardown.
///
/// Owns the socket, the microphone and the speaker, and hands out two streams:
/// [events] for everything the server said, and [state] for the single word
/// the screen shows. Every dependency is injectable because none of them exist
/// in a test.
class VoiceAgentSession implements VoiceSession {
  VoiceAgentSession({
    required Future<VoiceToken> Function() mintToken,
    required this.systemPrompt,
    this.greeting,
    this.voiceId,
    this.tools = const [],
    this.onToolCall,
    WebSocketChannel Function(Uri url)? connect,
    MicSource? mic,
    PcmPlayer? player,
  })  : _mintToken = mintToken,
        _connect = connect ?? WebSocketChannel.connect,
        _mic = mic ?? RecorderMicSource(),
        _player = player ?? PcmPlayer();

  static final _endpoint = Uri.parse('wss://agents.assemblyai.com/v1/ws');

  final Future<VoiceToken> Function() _mintToken;
  final WebSocketChannel Function(Uri) _connect;
  final MicSource _mic;
  final PcmPlayer _player;

  final String systemPrompt;
  final String? greeting;
  final String? voiceId;

  /// Declared to the agent on connect. Flat JSON Schema — the API accepts a
  /// malformed one silently and then fails at call time, so these are built in
  /// code rather than written by hand.
  final List<Map<String, dynamic>> tools;

  /// Runs a tool the agent asked for. Returning normally sends a result;
  /// throwing sends one flagged as an error, which the agent can talk about.
  final Future<Object?> Function(ToolCall call)? onToolCall;

  final _events = StreamController<VoiceEvent>.broadcast();
  final _states = StreamController<VoiceAgentState>.broadcast();

  @override
  Stream<VoiceEvent> get events => _events.stream;

  @override
  Stream<VoiceAgentState> get state => _states.stream;

  @override
  VoiceAgentState get currentState => _state;
  VoiceAgentState _state = VoiceAgentState.idle;

  /// Set when the session ends badly, so the UI can say why.
  @override
  String? get failure => _failure;
  String? _failure;

  /// The live session, once the server has confirmed one.
  String? get sessionId => _sessionId;

  WebSocketChannel? _channel;
  StreamSubscription<Uint8List>? _micSubscription;
  StreamSubscription<dynamic>? _socketSubscription;
  Timer? _sessionTimer;

  /// Kept for `session.resume` after an unclean drop.
  String? _sessionId;

  /// Tool results waiting for a safe moment to be sent.
  final _pendingResults = <String>[];

  /// Whether `reply.done` is the most recent thing we heard. A `tool.result`
  /// sent at any other moment cuts the agent off mid-sentence, so this gate is
  /// the whole reason the queue above exists.
  bool _replyIsDone = true;

  /// Calls belonging to the reply currently being spoken. Cleared on barge-in,
  /// because their answers are to a question the user talked over.
  final _callsInFlight = <String>{};

  bool _closing = false;

  /// Opens the conversation.
  ///
  /// Mints a token, connects, configures the agent, then opens the microphone
  /// once the server says it is ready. Audio sent before `session.ready` is
  /// discarded, so the order matters.
  ///
  /// The caller must have started [PcmPlayer] from a user gesture first —
  /// see [PcmPlayer.start].
  @override
  Future<void> start() async {
    if (_state != VoiceAgentState.idle) return;
    _emitState(VoiceAgentState.connecting);

    try {
      // First, and before any await: a browser only lets audio start from a
      // user gesture, and this runs on the tap's own synchronous stack.
      await _player.start();

      if (!await _mic.hasPermission()) {
        throw const VoiceFailure('Plate One needs the microphone to listen.');
      }

      // Every await here is a window in which the user can tap stop, and the
      // session must not open behind them: a socket nobody is watching bills
      // until the server's own cap.
      if (_closing) return;

      final minted = await _mintToken();
      if (minted.token.isEmpty) {
        throw const VoiceFailure('Voice is not available right now.');
      }
      if (_closing) return;

      final channel = _channel = _connect(
        _endpoint.replace(queryParameters: {'token': minted.token}),
      );
      await channel.ready;
      if (_closing) {
        await _teardown();
        return;
      }

      _socketSubscription = channel.stream.listen(
        _onFrame,
        onError: (Object error) => _fail('The conversation dropped.'),
        onDone: () {
          // A clean teardown has already ended us; anything else is a drop.
          if (_state != VoiceAgentState.ended) _fail('The conversation dropped.');
        },
      );

      channel.sink.add(VoiceFrame.sessionUpdate(
        systemPrompt: systemPrompt,
        greeting: greeting,
        voiceId: voiceId,
        tools: tools,
      ));

      // The server cuts the session off at its own cap. Running the same clock
      // here means a tab someone walked away from stops billing on its own.
      _sessionTimer = Timer(
        Duration(seconds: minted.maxSessionSeconds),
        () => stop(),
      );
    } catch (error) {
      // Nothing partially opened may be left running — this path has already
      // spent a device's allowance, but it must not also hold a microphone.
      await _teardown();
      // A refusal usually arrives with something worth reading — "as many
      // questions as it can today" beats "voice could not start", and it is
      // the difference between a dead end and an explanation.
      _failure = switch (error) {
        VoiceFailure(:final message) => message,
        ScanFailure(:final message) => message,
        _ => 'Voice could not start.',
      };
      _emitState(VoiceAgentState.ended);
      rethrow;
    }
  }

  /// Ends the conversation and releases everything.
  ///
  /// Sends `session.end` first: closing the socket without it leaves the
  /// session billable for another 30 seconds while the server waits for a
  /// reconnect that is not coming.
  @override
  Future<void> stop() async {
    if (_closing || _state == VoiceAgentState.idle) return;
    _closing = true;
    try {
      _channel?.sink.add(VoiceFrame.sessionEnd());
    } catch (_) {
      // Already gone. The teardown below is what actually matters.
    }
    await _teardown();
    _emitState(VoiceAgentState.ended);
  }

  /// Releases everything and closes the streams. The object is spent.
  @override
  Future<void> dispose() async {
    await stop();
    await _mic.dispose();
    await _events.close();
    await _states.close();
  }

  void _onFrame(dynamic raw) {
    final event = VoiceEvent.decode(raw is String ? raw : '');
    if (!_events.isClosed) _events.add(event);

    // Any event that is not `reply.done` closes the window for sending tool
    // results. Set before the switch so an early return cannot skip it.
    final wasReplyDone = _replyIsDone;
    _replyIsDone = event is ReplyDone;

    switch (event) {
      case SessionReady():
        _sessionId = event.sessionId;
        unawaited(_openMicrophone());

      case SpeechStarted():
        // Not a barge-in. Turn detection fires on back-channels too — an
        // "mm-hmm" while the agent talks — and the server decides semantically
        // whether that counts. Flushing here would cut the agent off every
        // time someone agreed with it. The real interruption arrives as
        // `reply.done` with status `interrupted`.
        if (_state != VoiceAgentState.speaking) _emitState(VoiceAgentState.listening);

      case SpeechStopped():
        if (_state != VoiceAgentState.speaking) _emitState(VoiceAgentState.thinking);

      case ReplyStarted():
        _emitState(VoiceAgentState.speaking);

      case ReplyAudio():
        _player.enqueue(event.pcm16);

      case ReplyDone():
        if (event.interrupted) {
          _player.flush();
          _callsInFlight.clear();
          _pendingResults.clear();
        }
        // The set is *not* cleared on a normal finish. A tool may still be
        // running, and its answer is due on the next `reply.done` — clearing
        // here would drop it and leave the agent waiting.
        _flushToolResults();
        _emitState(VoiceAgentState.listening);

      case ToolCall():
        _callsInFlight.add(event.callId);
        unawaited(_runTool(event));

      case SessionEnded():
        unawaited(_finishCleanly());

      case VoiceSessionError():
        // A rejected frame is not a dead session. It is on [events] either
        // way; only the fatal ones end the conversation.
        if (event.endsSession) _fail(event.message);

      case UserTranscript() ||
            UserTranscriptDelta() ||
            AgentTranscript() ||
            AgentTranscriptDelta() ||
            SessionUpdated() ||
            UnknownVoiceEvent():
        // Carried on [events] for the transcript. No state of their own.
        break;
    }

    // A tool that answered while the agent was still talking has been waiting;
    // this is the moment it becomes sendable.
    if (!wasReplyDone && _replyIsDone) _flushToolResults();
  }

  Future<void> _openMicrophone() async {
    try {
      final audio = await _mic.start();
      _micSubscription = audio.listen(
        (chunk) {
          if (_closing || chunk.isEmpty) return;
          try {
            _channel?.sink.add(VoiceFrame.inputAudio(chunk));
          } catch (_) {
            // The socket went away between the check and the send. The
            // stream's onDone will report it; dropping a frame is not news.
          }
        },
        onError: (Object _) => _fail('The microphone stopped.'),
        cancelOnError: true,
      );
      _emitState(VoiceAgentState.listening);
    } catch (_) {
      _fail('The microphone could not be opened.');
    }
  }

  Future<void> _runTool(ToolCall call) async {
    final handler = onToolCall;
    String frame;
    if (handler == null) {
      frame = VoiceFrame.toolResult(
        callId: call.callId,
        result: {'error': 'unknown_tool', 'name': call.name},
        isError: true,
      );
    } else {
      try {
        frame = VoiceFrame.toolResult(callId: call.callId, result: await handler(call));
      } catch (_) {
        // The agent is told the tool failed rather than left waiting. It can
        // say so out loud, which is a better failure than silence.
        frame = VoiceFrame.toolResult(
          callId: call.callId,
          result: {'error': 'tool_failed'},
          isError: true,
        );
      }
    }

    // A barge-in during the call clears the set, and the answer with it: the
    // user has moved on, and replying to the old question would talk over them.
    if (!_callsInFlight.remove(call.callId)) return;

    _pendingResults.add(frame);
    _flushToolResults();
  }

  /// Sends queued tool results, but only in the one window the API allows.
  void _flushToolResults() {
    if (!_replyIsDone || _pendingResults.isEmpty) return;
    final channel = _channel;
    if (channel == null) return;
    for (final frame in _pendingResults) {
      try {
        channel.sink.add(frame);
      } catch (_) {
        // Socket gone; the session is ending anyway.
      }
    }
    _pendingResults.clear();
  }

  Future<void> _finishCleanly() async {
    _closing = true;
    await _teardown();
    _emitState(VoiceAgentState.ended);
  }

  void _fail(String message) {
    // A teardown already under way is not a failure. Without this, the
    // `session.ended` the server sends in reply to our own `session.end`
    // arrives as "the conversation dropped".
    if (_closing || _state == VoiceAgentState.ended) return;
    _failure = message;
    _closing = true;
    // Even on the way out: closing without it leaves 30 billable seconds.
    try {
      _channel?.sink.add(VoiceFrame.sessionEnd());
    } catch (_) {
      // The socket is what failed. Nothing to send it.
    }
    unawaited(_teardown().then((_) => _emitState(VoiceAgentState.ended)));
  }

  /// Releases every resource, in the order that stops the meter first.
  ///
  /// Each step is guarded on its own: one failing must not leave the next one
  /// unrun, which is exactly how a microphone stays lit after an error.
  Future<void> _teardown() async {
    _sessionTimer?.cancel();
    _sessionTimer = null;

    // First, and before any await. The server answers `session.end` with
    // `session.ended` and a close, and a listener still attached during the
    // steps below would read that as the conversation dropping.
    try {
      await _socketSubscription?.cancel();
    } catch (_) {}
    _socketSubscription = null;

    try {
      await _micSubscription?.cancel();
    } catch (_) {}
    _micSubscription = null;

    try {
      await _mic.stop();
    } catch (_) {}

    try {
      _player.flush();
      await _player.dispose();
    } catch (_) {}

    try {
      // Bounded: releasing a microphone must not wait on a socket that has
      // stopped answering. The session is over either way.
      await _channel?.sink.close().timeout(const Duration(seconds: 3));
    } catch (_) {}
    _channel = null;

    _pendingResults.clear();
    _callsInFlight.clear();
  }

  void _emitState(VoiceAgentState next) {
    if (_state == next || _state == VoiceAgentState.ended) return;
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }
}

/// A voice failure with something worth saying to the user.
class VoiceFailure implements Exception {
  const VoiceFailure(this.message);
  final String message;

  @override
  String toString() => message;
}
