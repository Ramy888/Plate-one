import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/voice_agent_session.dart';
import '../domain/models.dart';
import '../state/plate_providers.dart';
import '../state/providers.dart';
import '../state/save_patch.dart';
import '../state/voice_conversation.dart';
import 'food_picker_screen.dart';
import 'icons.g.dart';
import 'saved_screen.dart';
import 'settings_screen.dart';
import 'theme.dart';
import 'widgets/common.dart';
import 'widgets/mic_button.dart';
import 'widgets/transitions.dart';

/// The whole app, on one screen.
///
/// A plate at the top that fills in as you describe your meal, the
/// conversation underneath it, and a microphone. There is no other way in:
/// speaking is the product, and a screen offering three alternatives to it
/// would be saying otherwise.
///
/// Everything here is drawn from provider state and nothing else — no session,
/// no socket, no microphone — so the whole screen can be driven by a fake in a
/// test, which is the only way any of it gets exercised without a browser and
/// a person talking.
class VoiceAgentScreen extends ConsumerWidget {
  const VoiceAgentScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final voice = ref.watch(voiceConversationProvider);
    final conversation = ref.read(voiceConversationProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        titleSpacing: Space.lg,
        title: const _Brand(),
        actions: [
          if (voice.lastTurnLatencyMs case final ms?) _Latency(ms: ms),
          IconButton(
            tooltip: 'Saved patches',
            icon: const Icon(LucideIcons.bookmark),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SavedScreen()),
            ),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(LucideIcons.settings),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
            ),
          ),
          const SizedBox(width: Space.sm),
        ],
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // The plate takes a share of what is there rather than a fixed
            // size. At 260 on a short screen it pushes the microphone off the
            // bottom — and the microphone is the only control this app has.
            final plate = (constraints.maxHeight * 0.34).clamp(110.0, 260.0);
            return Column(
          children: [
            _Plate(size: plate),
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
            );
          },
        ),
      ),
    );
  }
}

/// The mark and the name, so the top of the screen says whose app this is
/// without spending a whole row on it.
class _Brand extends StatelessWidget {
  const _Brand();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.asset(
            'assets/icon/icon.png',
            width: 30,
            height: 30,
            filterQuality: FilterQuality.medium,
          ),
        ),
        const SizedBox(width: Space.sm),
        Text('Plate One', style: Theme.of(context).appBarTheme.titleTextStyle),
      ],
    );
  }
}

/// The plate. The subject of the screen, and the thing that answers back.
///
/// Empty before anyone has said anything, filling in as the meal is described,
/// and showing the addition once one has been chosen. It never blanks out
/// while a new picture is drawn — a plate that empties itself every time you
/// mention a food reads as a bug rather than as progress.
class _Plate extends ConsumerWidget {
  const _Plate({required this.size});

  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visual = ref.watch(plateVisualProvider);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.sm),
      child: SizedBox(
        height: size,
        width: size,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // The plate itself, always drawn, so there is something to look at
            // before there is anything to show.
            Container(
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: PlateColors.neutral100,
                border: Border.fromBorderSide(
                  BorderSide(color: PlateColors.line, width: 8),
                ),
              ),
            ),
            if (visual.image case final bytes?)
              ClipOval(child: Image.memory(bytes, fit: BoxFit.cover))
            else if (!visual.loading)
              const Center(
                child: Icon(
                  LucideIcons.utensils,
                  size: 44,
                  color: PlateColors.neutral400,
                ),
              ),
            if (visual.loading) const _PlateSkeleton(),
          ],
        ),
      ),
    );
  }
}

/// The plate while a picture is being drawn.
///
/// A sweep rather than a spinner: drawing takes tens of seconds, and a spinner
/// running that long reads as something being stuck.
class _PlateSkeleton extends StatefulWidget {
  const _PlateSkeleton();

  @override
  State<_PlateSkeleton> createState() => _PlateSkeletonState();
}

class _PlateSkeletonState extends State<_PlateSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = _controller.value;
          return DecoratedBox(
            decoration: BoxDecoration(
              color: PlateColors.neutral200.withValues(alpha: 0.55),
              gradient: LinearGradient(
                begin: Alignment(-1 + t * 3, -1),
                end: Alignment(t * 3, 1),
                colors: const [
                  Color(0x00FFFFFF),
                  Color(0x66FFFFFF),
                  Color(0x00FFFFFF),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The one word for what is happening, readable across a room — a demo is
/// watched, not used.
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
      padding: const EdgeInsets.only(bottom: Space.sm),
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

class _Bubble extends ConsumerWidget {
  const _Bubble({required this.turn});

  final VoiceTurn turn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // A turn carrying options is the engine's answer, not something anyone
    // said out loud. It gets the whole width.
    if (turn.options.isNotEmpty) return _Options(options: turn.options);
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
            // Every settled thing the agent says is a place you can stop
            // talking and just ask for the answer.
            if (!mine && turn.settled)
              Padding(
                padding: const EdgeInsets.only(top: Space.xs),
                child: TextButton.icon(
                  onPressed: () =>
                      ref.read(voiceConversationProvider.notifier).recommendNow(),
                  icon: const Icon(LucideIcons.sparkles, size: 16),
                  label: const Text('Add patch now'),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: Space.sm),
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// What the engine offered, as a row you can try.
///
/// The plate redraws for whichever one is selected, and the Worker caches by
/// content — so going back to one already seen is instant and costs nothing.
/// Trying all three is meant to be cheap.
class _Options extends ConsumerWidget {
  const _Options({required this.options});

  final List<Patch> options;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chosen = ref.watch(chosenPatchProvider)?.addition.id;

    return Padding(
      padding: const EdgeInsets.only(bottom: Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: Space.sm),
            child: Text(
              'Tap one to see it on your plate',
              style: Theme.of(context)
                  .textTheme
                  .labelMedium
                  ?.copyWith(color: PlateColors.inkSoft),
            ),
          ),
          SizedBox(
            height: 172,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: options.length,
              separatorBuilder: (_, _) => const SizedBox(width: Space.sm),
              itemBuilder: (context, i) => _OptionCard(
                patch: options[i],
                selected: options[i].addition.id == chosen,
                onTap: () =>
                    ref.read(voiceConversationProvider.notifier).choose(options[i]),
              ),
            ),
          ),
          const _KeepThis(),
        ],
      ),
    );
  }
}

class _OptionCard extends StatelessWidget {
  const _OptionCard({
    required this.patch,
    required this.selected,
    required this.onTap,
  });

  final Patch patch;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(kRadiusSmall),
        child: Container(
          width: 210,
          padding: const EdgeInsets.all(Space.md),
          decoration: BoxDecoration(
            color: selected ? PlateColors.greenSel : PlateColors.card,
            borderRadius: BorderRadius.circular(kRadiusSmall),
            border: Border.all(
              color: selected ? PlateColors.green : Colors.transparent,
              width: 2,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Lead(
                catalogIcon(patch.addition.icon),
                size: 18,
                tone: PlateColors.neutral100,
                background: PlateColors.green,
              ),
              const SizedBox(height: Space.sm),
              Text(patch.addition.name, style: text.titleSmall, maxLines: 2),
              const SizedBox(height: Space.xs),
              Expanded(
                child: Text(
                  patch.reason,
                  style: text.bodySmall?.copyWith(color: PlateColors.inkSoft),
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Keeping the plate, once one has been settled on.
class _KeepThis extends ConsumerWidget {
  const _KeepThis();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chosen = ref.watch(chosenPatchProvider);
    if (chosen == null) return const SizedBox.shrink();

    final visual = ref.watch(plateVisualProvider);
    final result = ref.watch(patchResultProvider);

    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: () => savePatch(
          context,
          ref,
          slot: result.slot,
          foodIds: result.foods.map((f) => f.id).toList(),
          addition: chosen.addition,
          gapIds: result.gaps.map((g) => g.id).toList(),
          image: visual.image,
        ),
        icon: const Icon(LucideIcons.bookmark, size: 18),
        label: const Text('Keep this'),
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
/// with the conversation, building the meal by hand has no network, no
/// allowance and no model in it, and it always works.
class _Failure extends ConsumerWidget {
  const _Failure({required this.message});

  final String message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.md),
      child: PlateCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: Space.sm),
            TextButton.icon(
              onPressed: () => Navigator.of(context).push(
                slideUpRoute(FoodPickerScreen(slot: ref.read(mealDraftProvider).slot)),
              ),
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
      child: Padding(
        padding: const EdgeInsets.only(right: Space.sm),
        child: Center(
          child: Text(
            '${ms}ms',
            style: Theme.of(context)
                .textTheme
                .labelMedium
                ?.copyWith(color: PlateColors.inkSoft),
          ),
        ),
      ),
    );
  }
}
