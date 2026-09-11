import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/agent_prompt.dart';
import '../data/agent_tools.dart';
import '../data/voice_agent_events.dart';
import '../data/voice_agent_session.dart';
import '../domain/food_matcher.dart';
import '../domain/models.dart';
import 'plate_providers.dart';
import 'providers.dart';
import 'api_providers.dart';

/// One line in the thread.
@immutable
class VoiceTurn {
  const VoiceTurn({
    required this.fromUser,
    required this.text,
    this.settled = false,
    this.interrupted = false,
    this.options = const [],
    this.shown = 3,
  });

  final bool fromUser;
  final String text;

  /// Whether this is the final wording. Partials are shown differently — a
  /// transcript that redraws itself while being read needs to look provisional.
  final bool settled;

  /// The user talked over this one. Worth showing: an agent that stops when
  /// interrupted is the demo, not a bug.
  final bool interrupted;

  /// What the engine offered at this point in the conversation, if anything.
  /// Rendered as a row of cards the person can tap instead of speaking.
  final List<Patch> options;

  /// How many of [options] are on screen. The rest sit behind "show more" —
  /// three is a choice, nine is a menu.
  final int shown;

  VoiceTurn copyWith({String? text, bool? settled, bool? interrupted, int? shown}) =>
      VoiceTurn(
        fromUser: fromUser,
        text: text ?? this.text,
        settled: settled ?? this.settled,
        interrupted: interrupted ?? this.interrupted,
        options: options,
        shown: shown ?? this.shown,
      );

  /// Whether anything is still held back.
  bool get hasMore => options.length > shown;
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

/// What the conversation settled on, or null before it has.
///
/// Held here rather than inside the tools because the screen has to rebuild
/// when it changes, and the tools are deliberately free of Riverpod.
class ChosenPatch extends Notifier<Patch?> {
  @override
  Patch? build() => null;

  void set(Patch? patch) => state = patch;
}

final chosenPatchProvider = NotifierProvider<ChosenPatch, Patch?>(ChosenPatch.new);

/// The engine, wired to the app's own draft and given to the agent as tools.
///
/// `ref.read` throughout: the factory runs once per session, and the tools are
/// called much later — a watched value read here would be a snapshot of the
/// moment the conversation started.
final agentToolsProvider = Provider<AgentTools>((ref) {
  final catalog = ref.read(catalogProvider);

  return AgentTools(
    matcher: FoodMatcher(catalog.foods),
    // Deliberately the same provider the result screen reads. One
    // recommendation path, so the agent and the app cannot come to different
    // conclusions about the same plate.
    recommend: () => ref.read(patchResultProvider),
    setSlot: (slot) => ref.read(mealDraftProvider.notifier).setSlot(slot),
    setFoods: (ids) {
      final draft = ref.read(mealDraftProvider.notifier);
      final already = ref.read(mealDraftProvider).foodIds;
      for (final id in already.where((id) => !ids.contains(id))) {
        draft.toggleFood(id);
      }
      for (final id in ids.where((id) => !already.contains(id))) {
        draft.toggleFood(id);
      }
    },
    currentFoodIds: () => ref.read(mealDraftProvider).foodIds.toList(),
    currentSlot: () => ref.read(mealDraftProvider).slot,
    // Fire-and-forget: drawing is a model call and an image, and the agent
    // must not go quiet for the half-minute it takes. The card appears at
    // once; the picture catches up.
    onChoose: ({required patch, required foodIds}) {
      ref.read(chosenPatchProvider.notifier).set(patch);
      ref.read(plateVisualProvider.notifier).request(
            foodIds: foodIds,
            additionId: patch.addition.id,
            // Somebody is waiting for this one.
            now: true,
          );
    },
    // The plate catches up with the meal, without an addition on it yet. Not
    // at once: the conversation is still going, and drawing every food as it
    // is named costs a picture each and leaves the plate a draw behind.
    onMealChanged: (foodIds) {
      ref.read(chosenPatchProvider.notifier).set(null);
      ref.read(plateVisualProvider.notifier).request(foodIds: foodIds);
    },
    onRecommendations: (options) =>
        ref.read(voiceConversationProvider.notifier).offer(options),
  );
});

/// The real thing: mints a token through the Worker, which is the only place
/// the AssemblyAI key exists.
final voiceSessionFactoryProvider = Provider<VoiceSessionFactory>((ref) {
  final tools = ref.read(agentToolsProvider);

  return () => VoiceAgentSession(
        mintToken: () async {
          final token = await ref.read(deviceProvider.notifier).token();
          final minted = await ref.read(apiProvider).voiceToken(token);
          // Keep the camera's "N left" honest after a conversation spends one.
          ref.read(deviceProvider.notifier).noteQuota(minted.quota);
          return minted;
        },
        systemPrompt: voiceSystemPrompt,
        greeting: 'What is on your plate?',
        voiceId: 'anna',
        tools: AgentTools.schemas,
        onToolCall: tools.dispatch,
      );
});

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

  /// Puts a row of options into the conversation.
  ///
  /// They arrive as their own entry rather than as text, because three things
  /// to choose between is a thing you tap, not a sentence you listen to twice.
  void offer(List<Patch> options) {
    if (options.isEmpty) return;
    state = state.copyWith(
      turns: [...state.turns, VoiceTurn(fromUser: false, text: '', settled: true, options: options)],
    );
  }

  /// Reveals one more option in the row at [turnIndex].
  void revealMore(int turnIndex) {
    if (turnIndex < 0 || turnIndex >= state.turns.length) return;
    final turn = state.turns[turnIndex];
    if (!turn.hasMore) return;

    final turns = [...state.turns];
    turns[turnIndex] = turn.copyWith(shown: turn.shown + 1);
    state = state.copyWith(turns: turns);
  }

  /// Draws one of the offered options, as though it had been agreed out loud.
  void choose(Patch patch) {
    ref.read(chosenPatchProvider.notifier).set(patch);
    ref.read(plateVisualProvider.notifier).request(
          foodIds: ref.read(mealDraftProvider).foodIds.toList(),
          additionId: patch.addition.id,
          now: true,
        );
  }

  Future<void> stop() async {
    final session = _session;
    if (session != null) {
      await session.stop();
      if (session.failure != null) {
        // A conversation that ended badly keeps its reason on screen; one the
        // person ended themselves has nothing to explain.
        state = VoiceConversationState(
          agent: VoiceAgentState.ended,
          failure: session.failure,
        );
        _clearPlate();
        return;
      }
    }
    reset();
  }

  /// Back to an empty plate and an empty thread.
  ///
  /// Ending the conversation ends the meal with it. Leaving the last plate and
  /// its transcript on screen would mean the next person to speak starts by
  /// clearing away somebody else's dinner.
  void reset() {
    state = const VoiceConversationState();
    _clearPlate();
  }

  void _clearPlate() {
    ref.read(chosenPatchProvider.notifier).set(null);
    ref.read(plateVisualProvider.notifier).clear();
    ref.read(mealDraftProvider.notifier).reset();
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
