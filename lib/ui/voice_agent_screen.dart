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
    final conversation0 = ref.read(voiceConversationProvider.notifier);

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
            // Side by side once there is room for it. On a phone the plate sits
            // above the conversation; on a tablet or a browser window they are
            // columns, because a chat stretched across 1600 pixels is a chat
            // nobody can read a line of.
            final wide = constraints.maxWidth >= 840;

            final conversation = Column(
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
                    onTap: voice.isLive ? conversation0.stop : conversation0.start,
                    listening: voice.isLive,
                    tooltip: voice.isLive ? 'End the conversation' : 'Start talking',
                  ),
                ),
              ],
            );

            if (!wide) {
              final plate = (constraints.maxHeight * 0.30).clamp(110.0, 240.0);
              return Column(
                children: [
                  _Plate(size: plate),
                  const _SelectedPatch(compact: true),
                  Expanded(child: conversation),
                ],
              );
            }

            // A third of the width for the plate and what was chosen, the rest
            // for the conversation.
            final plate = (constraints.maxWidth / 3).clamp(200.0, 340.0);
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: constraints.maxWidth / 3,
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        _Plate(size: plate),
                        const _SelectedPatch(compact: false),
                      ],
                    ),
                  ),
                ),
                const VerticalDivider(width: 1, color: PlateColors.line),
                Expanded(child: conversation),
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

/// The conversation, which follows itself.
///
/// A transcript that does not scroll is a transcript nobody reads: the newest
/// line is the one being spoken, and it has to be the one on screen.
class _Thread extends StatefulWidget {
  const _Thread({required this.turns});

  final List<VoiceTurn> turns;

  @override
  State<_Thread> createState() => _ThreadState();
}

class _ThreadState extends State<_Thread> {
  final _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    // The thread replaces the "tap to talk" panel, so its first frame is a
    // build rather than an update — and by then there can already be a
    // conversation's worth of lines above the fold.
    WidgetsBinding.instance.addPostFrameCallback((_) => _toBottom());
  }

  @override
  void didUpdateWidget(_Thread old) {
    super.didUpdateWidget(old);
    // Growing partials change the last line's height without adding a turn, so
    // this follows every rebuild rather than only new entries.
    WidgetsBinding.instance.addPostFrameCallback((_) => _toBottom());
  }

  void _toBottom() {
    if (!_controller.hasClients) return;
    final end = _controller.position.maxScrollExtent;
    // Jump rather than animate when a long way off — an animation chasing a
    // transcript that is still growing never arrives.
    if ((end - _controller.offset).abs() > 400) {
      _controller.jumpTo(end);
    } else {
      _controller.animateTo(
        end,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: _controller,
      padding: const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.sm),
      itemCount: widget.turns.length,
      itemBuilder: (context, i) => _Bubble(turn: widget.turns[i], index: i),
    );
  }
}

class _Bubble extends ConsumerWidget {
  const _Bubble({required this.turn, required this.index});

  final VoiceTurn turn;

  /// Where this sits in the thread, so "show more" knows which row to grow.
  final int index;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // A turn carrying options is the engine's answer, not something anyone
    // said out loud. It gets the whole width.
    if (turn.options.isNotEmpty) return _Options(turn: turn, index: index);
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
            // A pointer, not a control. The cards below are the thing to
            // press; a second button that did the same job would only make
            // someone wonder which of the two was the real one.
            if (!mine && turn.settled)
              Padding(
                padding: const EdgeInsets.only(top: Space.xs),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(LucideIcons.arrowDown, size: 14, color: PlateColors.inkSoft),
                    const SizedBox(width: Space.xs),
                    Text(
                      'Select from patches below',
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(color: PlateColors.inkSoft),
                    ),
                  ],
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
/// Trying them is meant to be cheap.
///
/// Three at a time. The engine has more, and they are behind the last card,
/// because three is a choice and nine is a menu.
class _Options extends ConsumerWidget {
  const _Options({required this.turn, required this.index});

  final VoiceTurn turn;
  final int index;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chosen = ref.watch(chosenPatchProvider)?.addition.id;
    final shown = turn.options.take(turn.shown).toList();

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
            height: 176,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: shown.length + (turn.hasMore ? 1 : 0),
              separatorBuilder: (_, _) => const SizedBox(width: Space.sm),
              itemBuilder: (context, i) {
                if (i == shown.length) {
                  return _MoreCard(
                    onTap: () =>
                        ref.read(voiceConversationProvider.notifier).revealMore(index),
                  );
                }
                return _OptionCard(
                  patch: shown[i],
                  selected: shown[i].addition.id == chosen,
                  onTap: () =>
                      ref.read(voiceConversationProvider.notifier).choose(shown[i]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// The last card in the row: one more suggestion, if none of these fit.
class _MoreCard extends StatelessWidget {
  const _MoreCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(kRadiusSmall),
        child: Container(
          width: 150,
          padding: const EdgeInsets.all(Space.md),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(kRadiusSmall),
            border: Border.all(color: PlateColors.line, width: 2),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(LucideIcons.plus, size: 20, color: PlateColors.green),
              const SizedBox(height: Space.sm),
              Text(
                'Show more recommendations',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: PlateColors.green,
                    ),
              ),
            ],
          ),
        ),
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

/// What is on the plate right now, under the plate.
///
/// It changes with the selection rather than appearing once at the end: the
/// point of tapping through the options is seeing each one land.
class _SelectedPatch extends ConsumerWidget {
  const _SelectedPatch({required this.compact});

  /// On a phone this sits between the plate and the conversation, and both
  /// need the room.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chosen = ref.watch(chosenPatchProvider);
    if (chosen == null) return const SizedBox.shrink();

    final visual = ref.watch(plateVisualProvider);
    final result = ref.watch(patchResultProvider);

    return Padding(
      padding: EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, compact ? Space.sm : Space.md),
      child: PlateCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PatchHighlight(
              icon: catalogIcon(chosen.addition.icon),
              name: chosen.addition.name,
              how: compact ? null : chosen.addition.how,
              compact: compact,
            ),
            if (!compact) ...[
              const SizedBox(height: Space.sm),
              Text(
                chosen.reason,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: PlateColors.inkSoft),
              ),
            ],
            const SizedBox(height: Space.xs),
            Align(
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
