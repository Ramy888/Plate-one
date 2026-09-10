import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/voice_agent_events.dart';
import '../data/voice_agent_session.dart';
import 'scan_providers.dart';

/// One line in the thread.
@immutable
class VoiceTurn {
  const VoiceTurn({
    required this.fromUser,
    required this.text,
    this.settled = false,
    this.interrupted = false,
  });

  final bool fromUser;
  final String text;

  /// Whether this is the final wording. Partials are shown differently — a
  /// transcript that redraws itself while being read needs to look provisional.
  final bool settled;

  /// The user talked over this one. Worth showing: an agent that stops when
  /// interrupted is the demo, not a bug.
  final bool interrupted;

  VoiceTurn copyWith({String? text, bool? settled, bool? interrupted}) => VoiceTurn(
        fromUser: fromUser,
        text: text ?? this.text,
        settled: settled ?? this.settled,
        interrupted: interrupted ?? this.interrupted,
      );
}

/// Everything the voice screen draws, and nothing it does not.
@immutable
class VoiceConversationState {
  const VoiceConversationState({
    this.agent = VoiceAgentState.idle,
    this.turns = const [],
    this.failure,
    this.starting = false,
    this.lastTurnLatencyMs,
  });

  final VoiceAgentState agent;

  /// The thread, oldest first. The last entry may still be a partial.
  final List<VoiceTurn> turns;

  /// Why it stopped, when it stopped badly.
  final String? failure;

  /// Between the tap and the socket. Its own flag rather than a state, because
  /// the session does not exist yet to have one.
  final bool starting;

  /// From the user finishing a sentence to the first sound of the answer.
  ///
  /// This is the number the demo is judged on, so it is measured from the
  /// first turn rather than bolted on later.
  final int? lastTurnLatencyMs;

  bool get isLive =>
      starting ||
      agent == VoiceAgentState.connecting ||
      agent == VoiceAgentState.listening ||
      agent == VoiceAgentState.thinking ||
      agent == VoiceAgentState.speaking;

  VoiceConversationState copyWith({
    VoiceAgentState? agent,
    List<VoiceTurn>? turns,
    String? failure,
    bool clearFailure = false,
    bool? starting,
    int? lastTurnLatencyMs,
  }) =>
      VoiceConversationState(
        agent: agent ?? this.agent,
        turns: turns ?? this.turns,
        failure: clearFailure ? null : (failure ?? this.failure),
        starting: starting ?? this.starting,
        lastTurnLatencyMs: lastTurnLatencyMs ?? this.lastTurnLatencyMs,
      );
}

/// Builds a session. Overridden in tests with one that has no socket.
typedef VoiceSessionFactory = VoiceSession Function();

/// The real thing: mints a token through the Worker, which is the only place
/// the AssemblyAI key exists.
final voiceSessionFactoryProvider = Provider<VoiceSessionFactory>((ref) {
  return () => VoiceAgentSession(
        mintToken: () async {
          final token = await ref.read(scanControllerProvider.notifier).deviceToken();
          final minted = await ref.read(scanApiProvider).voiceToken(token);
          // Keep the camera's "N left" honest after a conversation spends one.
          ref.read(scanControllerProvider.notifier).noteQuota(minted.quota);
          return minted;
        },
        systemPrompt: voiceSystemPrompt,
        greeting: 'What is on your plate?',
        voiceId: 'anna',
      );
});

/// Phase 2 has no tools yet, so this only has to hold a conversation and stop
/// short of the recommendation. The engine takes that job in Phase 3.
const voiceSystemPrompt = '''
You are Plate One. Someone is telling you what is on their plate right now.

Ask short questions until you know what the meal is. One question at a time,
one sentence each. Do not list options, do not explain nutrition, and do not
suggest anything to add yet — say you are still listening if asked.

Speak plainly, the way someone would across a table.''';

/// Owns the session and turns its events into a thread.
///
/// Autodisposed: leaving the screen ends the conversation. A microphone left
/// lit behind a back-swipe is the same billing leak as a socket left open,
/// one layer up.
class VoiceConversation extends Notifier<VoiceConversationState> {
  VoiceSession? _session;
  StreamSubscription<VoiceEvent>? _events;
  StreamSubscription<VoiceAgentState>? _states;

  /// When the user stopped talking, so the first sound of the answer can be
  /// measured against it.
  DateTime? _askedAt;

  /// The reply currently being spoken, so only its first audio chunk counts.
  String? _timedReply;

  @override
  VoiceConversationState build() {
    ref.onDispose(_release);
    return const VoiceConversationState();
  }

  /// Opens a conversation. Called straight from the tap, because the browser
  /// only lets audio start from a gesture.
  Future<void> start() async {
    if (state.isLive) return;
    state = const VoiceConversationState(starting: true);

    final session = _session = ref.read(voiceSessionFactoryProvider)();
    _events = session.events.listen(_onEvent);
    _states = session.state.listen(
      (agent) => state = state.copyWith(agent: agent, starting: false),
    );

    try {
      await session.start();
    } catch (_) {
      // The session already turned this into something worth reading, and
      // rethrowing here would only reach a tap handler with nowhere to put it.
      state = state.copyWith(
        starting: false,
        agent: VoiceAgentState.ended,
        failure: session.failure ?? 'Voice could not start.',
      );
    }
  }

  Future<void> stop() async {
    final session = _session;
    if (session == null) return;
    await session.stop();
    if (session.failure != null) state = state.copyWith(failure: session.failure);
  }

  void _onEvent(VoiceEvent event) {
    switch (event) {
      case SpeechStarted():
        // Only opens a turn when there is not already an unsettled one: turn
        // detection fires again on a back-channel mid-reply.
        if (!_hasOpen(fromUser: true)) _open(fromUser: true);

      case UserTranscriptDelta():
        // Each delta is the whole transcript so far, not the next word. It
        // replaces its predecessor — concatenating renders "rice rice and".
        _write(fromUser: true, text: event.text);

      case UserTranscript():
        _write(fromUser: true, text: event.text, settled: true);

      case SpeechStopped():
        _askedAt = DateTime.now();

      case ReplyStarted():
        _timedReply = event.replyId;
        _open(fromUser: false);

      case ReplyAudio():
        // The first sound of the answer. Everything after it is the same turn.
        if (_timedReply == event.replyId) {
          _timedReply = null;
          final asked = _askedAt;
          if (asked != null) {
            state = state.copyWith(
              lastTurnLatencyMs: DateTime.now().difference(asked).inMilliseconds,
            );
            _askedAt = null;
          }
        }

      case AgentTranscriptDelta():
        // This one *is* the next word, so it appends.
        _write(fromUser: false, text: _openText(fromUser: false) + event.delta);

      case AgentTranscript():
        _write(
          fromUser: false,
          text: event.text,
          settled: true,
          interrupted: event.interrupted,
        );

      case VoiceSessionError():
        // Surfaced only when it actually ended the conversation; the session
        // already decides which of those do.
        if (event.endsSession) state = state.copyWith(failure: event.message);

      case SessionReady() ||
            SessionUpdated() ||
            SessionEnded() ||
            ReplyDone() ||
            ToolCall() ||
            UnknownVoiceEvent():
        break;
    }
  }

  bool _hasOpen({required bool fromUser}) {
    final last = state.turns.isEmpty ? null : state.turns.last;
    return last != null && last.fromUser == fromUser && !last.settled;
  }

  String _openText({required bool fromUser}) =>
      _hasOpen(fromUser: fromUser) ? state.turns.last.text : '';

  void _open({required bool fromUser}) {
    if (_hasOpen(fromUser: fromUser)) return;
    state = state.copyWith(
      turns: [...state.turns, VoiceTurn(fromUser: fromUser, text: '')],
    );
  }

  /// Writes into the open turn on this side, opening one if there is none.
  void _write({
    required bool fromUser,
    required String text,
    bool settled = false,
    bool interrupted = false,
  }) {
    final turns = [...state.turns];
    if (_hasOpen(fromUser: fromUser)) {
      turns[turns.length - 1] = turns.last.copyWith(
        text: text,
        settled: settled,
        interrupted: interrupted,
      );
    } else {
      turns.add(VoiceTurn(
        fromUser: fromUser,
        text: text,
        settled: settled,
        interrupted: interrupted,
      ));
    }
    state = state.copyWith(turns: turns);
  }

  /// Cleanup, on the way out of the screen as much as on the way out of the
  /// conversation. The subscriptions go first so a closing session's last
  /// events cannot write into a disposed notifier.
  void _release() {
    unawaited(_events?.cancel());
    unawaited(_states?.cancel());
    _events = null;
    _states = null;
    unawaited(_session?.dispose());
    _session = null;
  }
}

final voiceConversationProvider =
    NotifierProvider<VoiceConversation, VoiceConversationState>(
  VoiceConversation.new,
  // Leaving the screen ends the conversation. A microphone left lit behind a
  // back-swipe is the billing leak the session guards against, one layer up.
  isAutoDispose: true,
);
