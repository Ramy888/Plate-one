import 'package:flutter/gestures.dart';
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
import 'widgets/promo_dialog.dart';
import 'widgets/toast.dart';
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

    final active = voice.isLive || voice.turns.isNotEmpty;
    // The app bar is built outside the LayoutBuilder, so it asks the window
    // rather than the box it is in.
    final narrow = MediaQuery.sizeOf(context).width < 840;

    void onMic() {
      if (voice.isLive) {
        conversation0.stop();
        return;
      }
      // Saving needs a context — it shows a toast — and the provider that
      // builds the agent's tools has none, so the screen hands one over. Here
      // rather than in `build`: reading the tools pulls in the catalogue, and a
      // screen that cannot be built without one is harder to test than it needs
      // to be. Nothing can call `save_patch` before the conversation it is
      // part of.
      ref.read(agentToolsProvider).onSave =
          ({required addition, required gapIds}) =>
              _keepPlate(context, ref, endConversation: false);
      conversation0.start();
    }

    return Scaffold(
      appBar: AppBar(
        titleSpacing: Space.lg,
        title: const _Brand(),
        actions: [
          if (voice.lastTurnLatencyMs case final ms?) _Latency(ms: ms),
          // On a phone the microphone comes up here once there is a
          // conversation: the thread wants the whole screen, and a control
          // that matters this much should not be something you scroll to.
          if (narrow && active) _AppBarMic(live: voice.isLive, onTap: onMic),
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
            // Idle is the plate on its own, centred, with the microphone under
            // it. Everything else is the conversation, which arrives beside the
            // plate rather than in place of it.
            final wide = constraints.maxWidth >= 840;

            final plateSize = wide
                ? (constraints.maxWidth / 3).clamp(200.0, 320.0)
                : (constraints.maxHeight * (active ? 0.28 : 0.38)).clamp(110.0, 260.0);

            final column = _PlateColumn(
              voice: voice,
              plateSize: plateSize,
              compact: !wide,
              onMic: onMic,
            );

            final thread = voice.turns.isEmpty
                ? _Waiting(live: voice.isLive)
                : _Thread(turns: voice.turns);

            if (!wide) {
              // Idle is the plate in the middle of the screen with the
              // microphone under it, and nothing else at all.
              if (!active) {
                return Center(child: SingleChildScrollView(child: column));
              }
              // Once there is a conversation the thread takes the phone, and
              // the plate comes down over it when it is wanted. Splitting a
              // small screen in half gave each half too little: a plate too
              // small to read and three messages of thread.
              return _MobileStage(
                voice: voice,
                thread: thread,
                plateSize: (constraints.maxWidth * 0.62).clamp(150.0, 260.0),
              );
            }

            final chatWidth = constraints.maxWidth * 2 / 3;
            return Stack(
              children: [
                // Grows in on the left; the plate gets out of its way.
                AnimatedPositioned(
                  duration: _move,
                  curve: Curves.easeOutCubic,
                  left: active ? 0 : -chatWidth,
                  top: 0,
                  bottom: 0,
                  width: chatWidth,
                  child: AnimatedOpacity(
                    duration: _move,
                    opacity: active ? 1 : 0,
                    child: thread,
                  ),
                ),
                // Centred when there is nothing else on screen, over to the
                // right once there is.
                AnimatedAlign(
                  duration: _move,
                  curve: Curves.easeOutCubic,
                  alignment: active ? Alignment.centerRight : Alignment.center,
                  child: SizedBox(
                    width: constraints.maxWidth / 3,
                    child: SingleChildScrollView(child: column),
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

/// How long the plate takes to get out of the way. Long enough to follow,
/// short enough that nobody waits for it.
const _move = Duration(milliseconds: 420);

/// The plate, what was chosen, and the microphone — the part of the screen
/// that is always there.
class _PlateColumn extends StatelessWidget {
  const _PlateColumn({
    required this.voice,
    required this.plateSize,
    required this.compact,
    required this.onMic,
  });

  final VoiceConversationState voice;
  final double plateSize;
  final bool compact;
  final VoidCallback onMic;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const _FavouriteBanner(),
        _Plate(size: plateSize),
        _SelectedPatch(compact: compact),
        // Idle on a phone is the one place this line earns its space: an empty
        // plate and a microphone, and the word for what to do with them. Once
        // there is a conversation it goes quiet again — see _MobileStage.
        _AgentState(state: voice),
        if (voice.failure case final failure?) _Failure(message: failure),
        Padding(
          padding: const EdgeInsets.only(bottom: Space.md, top: Space.xs),
          child: MicButton(
            onTap: onMic,
            listening: voice.isLive,
            tooltip: voice.isLive ? 'End the conversation' : 'Start talking',
          ),
        ),
      ],
    );
  }
}

/// The microphone, once it has moved up into the app bar.
///
/// Ringed rather than bare. Flat beside the bookmark and the cog it read as a
/// third icon of the same kind, and the one control that is holding a live
/// microphone open should not be the one nobody can pick out. The ring is the
/// recording light: terracotta and filled while it is listening.
class _AppBarMic extends StatelessWidget {
  const _AppBarMic({required this.live, required this.onTap});

  final bool live;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colour = live ? PlateColors.pro : PlateColors.green;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.xs),
      child: Tooltip(
        message: live ? 'End the conversation' : 'Start talking',
        child: Material(
          color: live ? PlateColors.proSoft : PlateColors.greenSoft,
          shape: CircleBorder(side: BorderSide(color: colour, width: 2)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              width: 36,
              height: 36,
              child: Icon(
                live ? LucideIcons.square : LucideIcons.mic,
                size: 16,
                color: colour,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The phone layout: the thread has the screen, the plate comes down over it.
///
/// A plate and a conversation do not both fit on a phone at a size where
/// either is worth looking at. So the thread gets the screen and the plate is
/// a sheet pulled down from the top — there when you want to see what your
/// meal looks like, out of the way while you are talking.
///
/// The chevron under the sheet pulses while it is closed. The plate is the
/// part of this app people do not expect, and a handle nobody notices is a
/// feature nobody finds.
class _MobileStage extends StatefulWidget {
  const _MobileStage({
    required this.voice,
    required this.thread,
    required this.plateSize,
  });

  final VoiceConversationState voice;
  final Widget thread;
  final double plateSize;

  @override
  State<_MobileStage> createState() => _MobileStageState();
}

class _MobileStageState extends State<_MobileStage>
    with SingleTickerProviderStateMixin {
  bool _open = false;
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The sheet holds the plate, its own padding, and the handle below it.
    // The plate plus a little clearance under the app bar, and nothing below
    // it: the handle hangs off the plate's own bottom edge rather than sitting
    // in a margin of its own.
    final sheetHeight = widget.plateSize + Space.md;

    return Stack(
      children: [
        // The conversation is the screen. It keeps its full height whether the
        // plate is down or not, so opening the sheet never reflows the thread
        // out from under someone's eye.
        Positioned.fill(
          child: Column(
            children: [
              // Whether it is listening, thinking or talking. This used to sit
              // under the plate; with the plate behind a handle it would have
              // gone with it, and "is this thing on?" is the one question a
              // voice interface must always answer.
              _AgentState(state: widget.voice, hideWhenIdle: true),
              if (widget.voice.failure case final failure?) _Failure(message: failure),
              Expanded(child: widget.thread),
            ],
          ),
        ),

        AnimatedPositioned(
          duration: _move,
          curve: Curves.easeOutCubic,
          top: _open ? 0 : -sheetHeight,
          left: 0,
          right: 0,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            // Stretched, so the sheet is the width of the screen. Centred — the
            // default — sizes it to the plate instead, and the conversation
            // shows through on both sides of a panel meant to cover it.
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _PlateSheet(size: widget.plateSize, height: sheetHeight),
              _SheetHandle(
                open: _open,
                pulse: _pulse,
                onTap: () => setState(() => _open = !_open),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The plate on a phone: the picture, and the one button that acts on it.
///
/// No chosen-patch card here. On a wide screen it sits under the plate with
/// room to spare; on a phone it is the difference between a plate you can see
/// and a plate you cannot, and the same words are already in the thread.
class _PlateSheet extends StatelessWidget {
  const _PlateSheet({required this.size, required this.height});

  final double size;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      // No panel behind it. The plate is already a round, lit object with its
      // own edge; putting it on a card meant drawing a second edge around the
      // first, and covering the conversation it is supposed to be sitting over.
      child: Align(
        alignment: Alignment.bottomCenter,
        child: SizedBox(
          width: size,
          height: size,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              _Plate(size: size),
              // On the rim, not in the corner of the box around it. The plate
              // is a circle inscribed in that box, so its top-left corner is
              // empty space — an icon parked there reads as floating beside
              // the plate rather than sitting on it. This is the point where
              // the diagonal meets the edge of the circle.
              Positioned(top: size * 0.15, left: size * 0.15, child: const _SaveIcon()),
            ],
          ),
        ),
      ),
    );
  }
}

/// Keeping the plate, as an icon rather than a banner.
class _SaveIcon extends ConsumerWidget {
  const _SaveIcon();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(chosenPatchProvider) == null) return const SizedBox.shrink();

    return Material(
      color: PlateColors.green,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: IconButton(
        tooltip: 'Add this plate to favourite plates',
        icon: const Icon(LucideIcons.heart, size: 18),
        color: PlateColors.neutral100,
        onPressed: () => _keepPlate(context, ref, endConversation: true),
      ),
    );
  }
}

/// The handle under the sheet. Pulses while the plate is hidden.
class _SheetHandle extends StatelessWidget {
  const _SheetHandle({
    required this.open,
    required this.pulse,
    required this.onTap,
  });

  final bool open;
  final Animation<double> pulse;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final chevron = Icon(
      open ? LucideIcons.chevronUp : LucideIcons.chevronDown,
      size: 18,
      color: PlateColors.neutral100,
    );

    return Center(
      // Flush against the plate's lower edge — a tab on the plate, not a
      // button that happens to be under one.
      child: Transform.translate(
        offset: const Offset(0, -Space.xs),
        child: Material(
          color: PlateColors.green,
          borderRadius: BorderRadius.circular(kRadius),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.md,
                vertical: Space.xs,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    open ? 'Hide plate' : 'See your plate',
                    style: Theme.of(context)
                        .textTheme
                        .labelLarge
                        ?.copyWith(color: PlateColors.neutral100),
                  ),
                  const SizedBox(width: Space.xs),
                  // Still while it is open: a control that blinks at someone
                  // who has already used it is just noise.
                  if (open)
                    chevron
                  else
                    FadeTransition(
                      opacity: Tween<double>(begin: 0.35, end: 1)
                          .animate(CurvedAnimation(parent: pulse, curve: Curves.easeInOut)),
                      child: chevron,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Keeps the plate, from the button or from the spoken tool.
///
/// One path for both. "Save it" and tapping the banner mean the same thing, and
/// a history that remembered only the ones reached by tapping would be a filing
/// decision nobody asked for.
///
/// [endConversation] is the difference: the button is a deliberate full stop,
/// so it ends the session and the plate returns to the middle. The spoken one
/// arrives while the agent is still mid-turn — stopping there would cut it off
/// saying "saved" — so the conversation carries on and the person ends it when
/// they are done.
Future<void> _keepPlate(
  BuildContext context,
  WidgetRef ref, {
  required bool endConversation,
}) async {
  final chosen = ref.read(chosenPatchProvider);
  if (chosen == null) return;

  final result = ref.read(patchResultProvider);
  final visual = ref.read(plateVisualProvider);

  await savePatch(
    context,
    ref,
    slot: result.slot,
    foodIds: result.foods.map((f) => f.id).toList(),
    addition: chosen.addition,
    gapIds: result.gaps.map((g) => g.id).toList(),
    image: visual.image,
    // The conversation is over once the plate is kept, and the screen says so
    // by clearing itself rather than by navigating somewhere.
    askHowItWent: false,
    returnToStart: false,
  );
  if (!context.mounted) return;

  Toast.show(context, 'Saved. That plate is in your favourites.');
  if (endConversation) await ref.read(voiceConversationProvider.notifier).stop();
}

/// Keeping the plate, offered above it once there is something to keep.
///
/// Above rather than below because it is about the picture, and because the
/// space under the plate is already spoken for by what was chosen.
class _FavouriteBanner extends ConsumerWidget {
  const _FavouriteBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chosen = ref.watch(chosenPatchProvider);
    if (chosen == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, Space.sm),
      child: FilledButton.icon(
        onPressed: () => _keepPlate(context, ref, endConversation: true),
        icon: const Icon(LucideIcons.heart, size: 18),
        label: const Text('Add this plate to favourite plates'),
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

    // A plate seen from above, lit from the upper left. Four layers, which is
    // what it takes for a circle to read as a dish rather than as a circle:
    // the shadow it casts, the rim, the well the food sits in, and the sheen.
    final rim = size * 0.085;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.sm),
      child: SizedBox(
        height: size,
        width: size,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            // The rim catches the light on one side and turns away from it on
            // the other. A flat fill here is what made it look printed on.
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFFFFFDF8), PlateColors.neutral300],
              stops: [0.15, 1.0],
            ),
            boxShadow: [
              // Contact: tight and close, where the plate meets the table.
              BoxShadow(
                color: PlateColors.ink.withValues(alpha: 0.16),
                blurRadius: size * 0.06,
                offset: Offset(0, size * 0.02),
              ),
              // Cast: wide and soft, which is what gives the height. Kept
              // tight enough that the plate sits on the table rather than
              // floating over it like a ball.
              BoxShadow(
                color: PlateColors.ink.withValues(alpha: 0.09),
                blurRadius: size * 0.13,
                offset: Offset(0, size * 0.06),
              ),
            ],
          ),
          child: Padding(
            padding: EdgeInsets.all(rim),
            // The step down from rim to well. Without a hard edge here the two
            // gradients blend and the whole thing goes soft again.
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: PlateColors.ink.withValues(alpha: 0.07),
                  width: 1.2,
                ),
              ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // The well is lit from the *opposite* side to the rim, and
                // that inversion is the whole trick: on a dish the near wall
                // turns away from the light and the far wall catches it, so a
                // rim bright at the top-left over a well bright at the
                // bottom-right reads as hollow. Matching them reads as a dome.
                DecoratedBox(
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      center: Alignment(0.45, 0.55),
                      radius: 1.1,
                      colors: [Color(0xFFFFFDF8), PlateColors.neutral300],
                      stops: [0.0, 1.0],
                    ),
                  ),
                ),
                // What the food sits in, not on: inset by the rim, so the rim
                // stays a rim even when the plate is full.
                if (visual.image case final bytes?)
                  ClipOval(child: Image.memory(bytes, fit: BoxFit.cover))
                else if (!visual.loading)
                  Center(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Padding(
                        padding: const EdgeInsets.all(Space.lg),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              visual.unavailable
                                  ? LucideIcons.imageOff
                                  : LucideIcons.utensils,
                              size: 30,
                              color: PlateColors.neutral400,
                            ),
                            // A plate that silently stays empty is what "the
                            // image generation is not working" looks like from
                            // the outside: no message, and no way to tell
                            // whether it is still coming.
                            if (visual.unavailable) ...[
                              const SizedBox(height: Space.sm),
                              Text(
                                'The picture could not\nbe drawn',
                                textAlign: TextAlign.center,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(color: PlateColors.inkSoft),
                              ),
                              const SizedBox(height: Space.xs),
                              Text(
                                'The suggestion still stands',
                                textAlign: TextAlign.center,
                                style: Theme.of(context)
                                    .textTheme
                                    .labelSmall
                                    ?.copyWith(color: PlateColors.inkSoft),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                if (visual.loading) const _PlateSkeleton(),
                // Said on the plate, because the plate is the thing that is not
                // happening. A message somewhere else leaves someone looking at
                // an empty dish wondering what they did wrong.
                if (visual.blocked) const _PlateBlocked(),
                // What a code just opened, until the next conversation starts.
                // A toast is gone in three seconds and the number is the thing
                // somebody wants to check.
                if (visual.granted case final plates?) _PlateGranted(plates: plates),
                // The shadow the rim casts down into the well. Always last, so
                // it falls across the food as well as the porcelain.
                IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          PlateColors.ink.withValues(alpha: 0.20),
                          PlateColors.ink.withValues(alpha: 0.04),
                          const Color(0x00000000),
                        ],
                        stops: const [0.0, 0.30, 0.62],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Why the plate is staying empty.
///
/// Not an error: the conversation is still going and still free. This is a
/// door with a key beside it, and it says where the key is.
///
/// The whole circle is the control. A button inside it does not fit — the
/// plate is as small as 110 points on a short phone — and a plate you can tap
/// is a bigger target than any button that would.
class _PlateBlocked extends StatelessWidget {
  const _PlateBlocked();

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: Material(
        color: PlateColors.neutral100.withValues(alpha: 0.93),
        child: InkWell(
          onTap: () => PromoDialog.show(context),
          child: Padding(
            padding: const EdgeInsets.all(Space.lg),
            child: Center(
              // Scaled rather than wrapped: the plate is a circle, and text
              // reflowing inside one looks like a mistake.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(LucideIcons.ticket, size: 26, color: PlateColors.warn),
                    const SizedBox(height: Space.sm),
                    Text(
                      'Today’s free plate\nis used',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: Space.xs),
                    Text(
                      'Tap to enter a code',
                      textAlign: TextAlign.center,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: PlateColors.green),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// What a redeemed code opened.
class _PlateGranted extends StatelessWidget {
  const _PlateGranted({required this.plates});

  final int plates;

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: ColoredBox(
        color: PlateColors.greenSoft.withValues(alpha: 0.95),
        child: Padding(
          padding: const EdgeInsets.all(Space.lg),
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(LucideIcons.check, size: 28, color: PlateColors.green),
                  const SizedBox(height: Space.sm),
                  Text(
                    plates == 1 ? '1 plate available' : '$plates plates available',
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(color: PlateColors.greenPress),
                  ),
                  const SizedBox(height: Space.xs),
                  Text(
                    'Tap the microphone',
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: PlateColors.green),
                  ),
                ],
              ),
            ),
          ),
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
  const _AgentState({required this.state, this.hideWhenIdle = false});

  final VoiceConversationState state;

  /// Says nothing at all when there is no conversation.
  ///
  /// Used by the phone's conversation layout, which keeps this line for what
  /// is happening now — listening, thinking, speaking — and says nothing at
  /// all between turns. The idle screen is the opposite case and does want it.
  final bool hideWhenIdle;

  @override
  Widget build(BuildContext context) {
    final idle = !state.isLive && !state.starting;
    if (hideWhenIdle && idle) return const SizedBox.shrink();

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
      // Idle and ended look the same and are the same: an empty plate waiting
      // to be told about. "Ended" describes what just happened rather than
      // what to do next, and it is the only thing on screen at that moment.
      _ => ('Describe your meal', PlateColors.inkSoft),
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
      padding: const EdgeInsets.only(
        left: Space.lg,
        right: Space.lg,
        top: Space.sm,
        // Room under the last line. Without it the newest message sits flush
        // against the bottom of the screen — the one message someone is
        // actually reading, hard up against the edge, and on a phone partly
        // under the browser's own chrome.
        bottom: Space.xxl,
      ),
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
            // Draggable with a mouse, not only flicked with a trackpad.
            // Flutter leaves PointerDeviceKind.mouse out of `dragDevices` by
            // default, which is right for a page — text selection wins there —
            // and wrong for a row of cards that is obviously a carousel. On a
            // desktop browser with a mouse the row simply refused to move.
            child: ScrollConfiguration(
              behavior: const _DragToScroll(),
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
          ),
        ],
      ),
    );
  }
}

/// Lets a mouse drag a row of cards the way a finger would.
class _DragToScroll extends MaterialScrollBehavior {
  const _DragToScroll();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
        PointerDeviceKind.touch,
        PointerDeviceKind.stylus,
        PointerDeviceKind.invertedStylus,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.mouse,
      };
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
                // Two short words. "Recommendations" is one long one, and at
                // this card's width it broke mid-word into "rec ommendations".
                'Show more',
                softWrap: false,
                overflow: TextOverflow.fade,
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
  const _SelectedPatch({this.compact = true});

  /// On a phone this sits between the plate and the conversation, and both
  /// need the room.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chosen = ref.watch(chosenPatchProvider);
    if (chosen == null) return const SizedBox.shrink();

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
            // Two ways on, side by side. One of them costs nothing and always
            // works, which is why it is not going anywhere.
            Wrap(
              spacing: Space.sm,
              children: [
                TextButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    slideUpRoute(FoodPickerScreen(slot: ref.read(mealDraftProvider).slot)),
                  ),
                  icon: const Icon(LucideIcons.hand, size: 18),
                  label: const Text('Build it by hand'),
                ),
                TextButton.icon(
                  onPressed: () => PromoDialog.show(context),
                  icon: const Icon(LucideIcons.ticket, size: 18),
                  label: const Text('Have a promo code?'),
                ),
              ],
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
