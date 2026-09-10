import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/voice_agent_session.dart';
import '../state/voice_conversation.dart';
import 'theme.dart';
import 'widgets/common.dart';
import 'widgets/mic_button.dart';

/// The conversation.
///
/// Everything here is drawn from [VoiceConversationState] and nothing else —
/// no session, no socket, no microphone — so the whole screen can be driven by
/// a fake in a test, which is the only way any of it gets exercised without a
/// browser and a person talking.
class VoiceAgentScreen extends ConsumerWidget {
  const VoiceAgentScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final voice = ref.watch(voiceConversationProvider);
    final conversation = ref.read(voiceConversationProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Say what is on your plate'),
        actions: [
          if (voice.lastTurnLatencyMs case final ms?) _Latency(ms: ms),
          const SizedBox(width: Space.md),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _AgentState(state: voice),
            Expanded(
              child: voice.turns.isEmpty
                  ? _Waiting(live: voice.isLive)
                  : _Thread(turns: voice.turns),
            ),
            if (voice.failure case final failure?) _Failure(message: failure),
            Padding(
              padding: const EdgeInsets.only(bottom: Space.md),
              child: MicButton(
                onTap: voice.isLive ? conversation.stop : conversation.start,
                listening: voice.isLive,
                tooltip: voice.isLive ? 'End the conversation' : 'Start talking',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The one word for what is happening, and it has to be readable across a room
/// — a demo is watched, not used.
class _AgentState extends StatelessWidget {
  const _AgentState({required this.state});

  final VoiceConversationState state;

  @override
  Widget build(BuildContext context) {
    final (label, colour) = switch (state) {
      VoiceConversationState(starting: true) => ('Connecting…', PlateColors.inkSoft),
      VoiceConversationState(agent: VoiceAgentState.connecting) =>
        ('Connecting…', PlateColors.inkSoft),
      VoiceConversationState(agent: VoiceAgentState.listening) =>
        ('Listening', PlateColors.green),
      VoiceConversationState(agent: VoiceAgentState.thinking) =>
        ('Thinking', PlateColors.warn),
      VoiceConversationState(agent: VoiceAgentState.speaking) =>
        ('Speaking', PlateColors.green),
      VoiceConversationState(agent: VoiceAgentState.ended) => ('Ended', PlateColors.inkSoft),
      _ => ('Tap to talk', PlateColors.inkSoft),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.md),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
          ),
          const SizedBox(width: Space.sm),
          Text(
            label,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: colour, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _Thread extends StatelessWidget {
  const _Thread({required this.turns});

  final List<VoiceTurn> turns;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: Space.lg),
      itemCount: turns.length,
      itemBuilder: (context, i) => _Bubble(turn: turns[i]),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.turn});

  final VoiceTurn turn;

  @override
  Widget build(BuildContext context) {
    if (turn.text.isEmpty) return const SizedBox.shrink();

    final mine = turn.fromUser;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: Space.sm),
        padding: const EdgeInsets.symmetric(
          horizontal: Space.md,
          vertical: Space.sm,
        ),
        constraints: const BoxConstraints(maxWidth: 420),
        decoration: BoxDecoration(
          color: mine ? PlateColors.greenSel : PlateColors.card,
          borderRadius: BorderRadius.circular(kRadiusSmall),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              turn.text,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    // A partial redraws itself while it is being read, so it
                    // has to look provisional rather than wrong.
                    color: turn.settled ? PlateColors.ink : PlateColors.inkSoft,
                  ),
            ),
            if (turn.interrupted)
              Padding(
                padding: const EdgeInsets.only(top: Space.xs),
                child: Text(
                  'you jumped in',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: PlateColors.inkSoft,
                        fontStyle: FontStyle.italic,
                      ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Waiting extends StatelessWidget {
  const _Waiting({required this.live});

  final bool live;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.xl),
        child: Text(
          live
              ? 'Go ahead — what is on your plate?'
              : 'Tap the microphone and tell Plate One what you are eating.',
          textAlign: TextAlign.center,
          style: Theme.of(context)
              .textTheme
              .bodyLarge
              ?.copyWith(color: PlateColors.inkSoft),
        ),
      ),
    );
  }
}

/// A failure with a way out of it.
///
/// The standing rule: an AI failure is never a dead end. Whatever went wrong
/// with the conversation, the tap path is still there and has no network, no
/// allowance and no model in it.
class _Failure extends StatelessWidget {
  const _Failure({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.md),
      child: PlateCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: Space.sm),
            TextButton.icon(
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(LucideIcons.hand, size: 18),
              label: const Text('Build it by hand'),
            ),
          ],
        ),
      ),
    );
  }
}

/// The headline number, kept in front of whoever is watching the demo.
class _Latency extends StatelessWidget {
  const _Latency({required this.ms});

  final int ms;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Answered in $ms milliseconds',
      child: Text(
        '${ms}ms',
        style: Theme.of(context)
            .textTheme
            .labelMedium
            ?.copyWith(color: PlateColors.inkSoft),
      ),
    );
  }
}
