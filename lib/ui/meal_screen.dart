import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../domain/models.dart';
import '../state/providers.dart';
import 'food_picker_screen.dart';
import 'saved_screen.dart';
import 'scan_camera_screen.dart';
import 'settings_screen.dart';
import 'theme.dart';
import 'voice_agent_screen.dart';
import 'widgets/mic_button.dart';
import 'widgets/transitions.dart';

/// The hub.
///
/// One question — which meal? — and two ways to answer what is on it: tap the
/// meal and pick the food, or photograph it. Everything below the pager is a
/// way in, and each opens a page of its own rather than growing this one.
///
/// Saying it is the third, and the one this app is about. It does not live here
/// — the voice session is the front door, and this screen is what you reach
/// when the room is too loud for it.
class MealScreen extends ConsumerStatefulWidget {
  const MealScreen({super.key});

  @override
  ConsumerState<MealScreen> createState() => _MealScreenState();
}

class _MealScreenState extends ConsumerState<MealScreen> {
  @override
  Widget build(BuildContext context) {
    final draft = ref.watch(mealDraftProvider);

    return Scaffold(
      appBar: AppBar(
        titleSpacing: Space.lg,
        title: const _Brand(),
        actions: [
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
            // The pager takes a share of what is left after the fixed
            // furniture, within limits — tall enough to read as the subject of
            // the screen, never so tall that the ways in are pushed off a small
            // phone. It is then centred in whatever room remains, so a tall
            // screen gets even margins rather than one dead band in the middle.
            final pagerHeight = (constraints.maxHeight * 0.40).clamp(200.0, 300.0);

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: Space.sm),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Space.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'What are you eating?',
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Center(
                    child: SizedBox(
                      height: pagerHeight,
                      child: _SlotPager(
                        selected: draft.slot,
                        onSelect: (s) => ref.read(mealDraftProvider.notifier).setSlot(s),
                        onOpen: (s) {
                          ref.read(mealDraftProvider.notifier).setSlot(s);
                          Navigator.of(context).push(slideUpRoute(FoodPickerScreen(slot: s)));
                        },
                      ),
                    ),
                  ),
                ),
                // Voice is the front door, so it sits above the other ways in
                // and is the only one drawn at full size.
                //
                // Web only, for now. The microphone works everywhere; nothing
                // plays the agent's voice back off the web yet, and a
                // conversation you can only talk into is worse than no button.
                if (kIsWeb)
                  Center(
                    child: MicButton(
                      tooltip: 'Say what is on your plate',
                      onTap: () => Navigator.of(context).push(
                        slideUpRoute(const VoiceAgentScreen()),
                      ),
                    ),
                  ),
                _WaysIn(slot: draft.slot),
                const SizedBox(height: Space.md),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The mark and the name together, so the top of the screen says whose app this
/// is without spending a whole row on it.
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

/// The ways in that are not speech: photograph the meal, or open what you have
/// already saved.
class _WaysIn extends ConsumerWidget {
  const _WaysIn({required this.slot});

  final MealSlot slot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.lg),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        spacing: Space.lg,
        children: [
          _RoundAction(
            icon: LucideIcons.camera,
            label: 'Scan my meal',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => ScanCameraScreen(slot: slot)),
            ),
          ),
          _RoundAction(
            icon: LucideIcons.bookmark,
            label: 'Saved patches',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SavedScreen()),
            ),
          ),
        ],
      ),
    );
  }
}

/// A quiet round action. Smaller and flatter than the mic, because the mic is
/// the one this screen is pointing at.
class _RoundAction extends StatelessWidget {
  const _RoundAction({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: Tooltip(
        message: label,
        child: Material(
          color: PlateColors.card,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: 54,
              height: 54,
              child: Icon(icon, size: 22, color: PlateColors.green),
            ),
          ),
        ),
      ),
    );
  }
}

/// The meal, as three big cards you swipe between.
///
/// Landing on a card selects it; tapping the one you are on opens the food for
/// it. A swipe is browsing and a tap is committing — the distinction a deck of
/// cards already teaches.
class _SlotPager extends StatefulWidget {
  const _SlotPager({
    required this.selected,
    required this.onSelect,
    required this.onOpen,
  });

  final MealSlot selected;
  final ValueChanged<MealSlot> onSelect;
  final ValueChanged<MealSlot> onOpen;

  @override
  State<_SlotPager> createState() => _SlotPagerState();
}

class _SlotPagerState extends State<_SlotPager> {
  late final PageController _controller = PageController(
    initialPage: MealSlot.values.indexOf(widget.selected),
    // A sliver of the neighbouring cards shows, so it reads as a deck.
    viewportFraction: 0.82,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PageView.builder(
      controller: _controller,
      itemCount: MealSlot.values.length,
      onPageChanged: (i) => widget.onSelect(MealSlot.values[i]),
      itemBuilder: (context, i) {
        final slot = MealSlot.values[i];
        final selected = slot == widget.selected;
        return Padding(
          padding: const EdgeInsets.fromLTRB(Space.xs, 0, Space.xs, Space.sm),
          child: _SlotCard(
            slot: slot,
            selected: selected,
            onTap: () => selected
                ? widget.onOpen(slot)
                : _controller.animateToPage(
                    i,
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOut,
                  ),
          ),
        );
      },
    );
  }
}

class _SlotCard extends StatefulWidget {
  const _SlotCard({required this.slot, required this.selected, required this.onTap});

  final MealSlot slot;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_SlotCard> createState() => _SlotCardState();
}

class _SlotCardState extends State<_SlotCard> with SingleTickerProviderStateMixin {
  /// A very slow drift across the photograph, so the card is alive without
  /// asking anyone to watch it. Only the card you are on moves: three looping
  /// animations behind a pager is motion nobody asked for and battery nobody
  /// agreed to spend.
  late final AnimationController _drift = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 18),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_SlotCard old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    // Decorative motion, so it honours the system's "remove animations"
    // setting. Someone who has asked their phone to stop moving things has
    // asked this too.
    final wanted = widget.selected && !MediaQuery.disableAnimationsOf(context);
    if (wanted && !_drift.isAnimating) {
      _drift.repeat(reverse: true);
    } else if (!wanted && _drift.isAnimating) {
      _drift.stop();
    }
  }

  @override
  void dispose() {
    _drift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final slot = widget.slot;
    final selected = widget.selected;
    final onTap = widget.onTap;
    final shape = BorderRadius.circular(kRadius);
    return Semantics(
      button: true,
      selected: selected,
      label: '${slot.label}. Tap to pick what is on the plate.',
      child: AnimatedScale(
        // The card you are on stands slightly proud of its neighbours.
        scale: selected ? 1 : 0.94,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        child: Material(
          color: selected ? PlateColors.green : PlateColors.card,
          borderRadius: shape,
          child: InkWell(
            onTap: onTap,
            borderRadius: shape,
            child: Padding(
              padding: const EdgeInsets.all(Space.md),
              child: Column(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(kRadiusSmall),
                      child: AnimatedBuilder(
                        animation: _drift,
                        builder: (context, child) {
                          // A hair over 1 so the pan never exposes an edge.
                          final t = Curves.easeInOut.transform(_drift.value);
                          return Transform.scale(
                            scale: 1.06 + 0.04 * t,
                            alignment: Alignment(0, -0.3 + 0.6 * t),
                            child: child,
                          );
                        },
                        child: Image.asset(
                          slot.image,
                          width: double.infinity,
                          height: double.infinity,
                          fit: BoxFit.cover,
                          filterQuality: FilterQuality.medium,
                          // A missing asset should not take the screen with it.
                          errorBuilder: (context, _, _) => Container(
                            color: PlateColors.neutral100,
                            alignment: Alignment.center,
                            child: Icon(slot.icon, size: 72, color: PlateColors.green),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: Space.md),
                  Text(
                    slot.label,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: selected ? PlateColors.neutral100 : PlateColors.ink,
                        ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    selected ? 'Tap to pick the food' : 'Swipe to choose',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontSize: 13,
                          color: selected
                              ? PlateColors.neutral100.withValues(alpha: 0.75)
                              : PlateColors.inkSoft,
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
