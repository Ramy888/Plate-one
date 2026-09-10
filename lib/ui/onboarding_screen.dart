import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/models.dart';
import '../state/providers.dart';
import 'theme.dart';
import 'widgets/common.dart';

/// Welcome, goal, preferences — three steps, no account, no questions about
/// weight or calories. The whole point is that nothing here feels like a form.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _controller = PageController();
  int _page = 0;

  static const _pageCount = 3;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _next() {
    if (_page == _pageCount - 1) {
      ref.read(settingsProvider.notifier).completeOnboarding();
      return;
    }
    _controller.nextPage(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _ProgressDots(count: _pageCount, active: _page),
            Expanded(
              child: PageView(
                controller: _controller,
                onPageChanged: (i) => setState(() => _page = i),
                children: [
                  const _WelcomePage(),
                  _GoalPage(
                    selected: settings.goal,
                    onSelect: (g) => ref.read(settingsProvider.notifier).setGoal(g),
                  ),
                  _PrefsPage(
                    selected: settings.dietPrefs,
                    onToggle: (p) => ref.read(settingsProvider.notifier).togglePref(p),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, Space.lg),
              child: FilledButton(
                onPressed: _next,
                child: Text(_page == _pageCount - 1 ? 'Start patching' : 'Continue'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProgressDots extends StatelessWidget {
  const _ProgressDots({required this.count, required this.active});

  final int count;
  final int active;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: Space.md, bottom: Space.sm),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < count; i++)
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              margin: const EdgeInsets.symmetric(horizontal: 3),
              height: 6,
              width: i == active ? 24 : 6,
              decoration: BoxDecoration(
                color: i == active ? PlateColors.green : PlateColors.neutral300,
                borderRadius: BorderRadius.circular(kPill),
              ),
            ),
        ],
      ),
    );
  }
}

class _Page extends StatelessWidget {
  const _Page({required this.title, required this.subtitle, required this.children});

  final String title;
  final String subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(Space.lg, Space.lg, Space.lg, Space.lg),
      children: [
        Text(title, style: Theme.of(context).textTheme.displaySmall),
        const SizedBox(height: Space.sm),
        Text(subtitle, style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: PlateColors.inkSoft,
            )),
        const SizedBox(height: Space.lg),
        ...children,
      ],
    );
  }
}

class _WelcomePage extends StatelessWidget {
  const _WelcomePage();

  @override
  Widget build(BuildContext context) {
    return _Page(
      title: 'One small thing,\nadded to what you already eat.',
      subtitle:
          'Plate One looks at the meal in front of you and suggests one thing to '
          'add. No counting, no logging, and nothing you are eating is wrong. '
          'That is the whole app.',
      children: const [SizedBox(height: Space.xs), _HowItWorks()],
    );
  }
}

/// The app, in three beats, playing itself.
///
/// This replaced three paragraphs of promises. Telling someone the app is
/// simple takes longer than showing them, and a still picture of a plate never
/// explained what happens between tapping a food and being handed an answer.
///
/// The demo is built from the real [PlateThumb], [Pill] and [PatchHighlight]
/// rather than from pictures of them, so it cannot drift away from what the app
/// actually looks like — a screenshot would be stale by the end of the week
/// that produced it.
class _HowItWorks extends StatefulWidget {
  const _HowItWorks();

  @override
  State<_HowItWorks> createState() => _HowItWorksState();
}

class _HowItWorksState extends State<_HowItWorks>
    with SingleTickerProviderStateMixin {
  late final AnimationController _run;
  int _step = 0;

  static const _beat = Duration(milliseconds: 2300);
  static const _steps = <(String, String)>[
    ('Tap what is on your plate', 'No searching, no barcodes. Just tap.'),
    ('It finds the one gap', 'Worked out on your phone, in an instant.'),
    ('Add one thing', 'The fastest, the cheapest, or a plant-based one.'),
  ];

  @override
  void initState() {
    super.initState();
    _run = AnimationController(vsync: this, duration: _beat)
      ..addStatusListener((status) {
        if (status != AnimationStatus.completed) return;
        setState(() => _step = (_step + 1) % _steps.length);
        _run.forward(from: 0);
      });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A loop that never ends is a test that never settles, and someone who has
    // asked their phone to stop moving things has asked this to stop too. Both
    // get the same answer: every beat at once, standing still.
    final wanted = !MediaQuery.disableAnimationsOf(context);
    if (wanted && !_run.isAnimating) {
      _run.forward(from: 0);
    } else if (!wanted && _run.isAnimating) {
      _run.stop();
    }
  }

  @override
  void dispose() {
    _run.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return Column(
        children: [
          for (var i = 0; i < _steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.lg),
              child: _Beat(index: i, step: _steps[i]),
            ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Fixed so the beats do not shunt the page up and down between them.
        // The tallest beat — the food rail, whose tiles are the same 130 tall
        // as the ones in the picker — sets it.
        SizedBox(
          height: 220,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 420),
            switchInCurve: Curves.easeOutCubic,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween(
                  begin: const Offset(0, 0.06),
                  end: Offset.zero,
                ).animate(animation),
                child: child,
              ),
            ),
            child: _Beat(key: ValueKey(_step), index: _step, step: _steps[_step]),
          ),
        ),
        const SizedBox(height: Space.md),
        Row(
          children: [
            for (var i = 0; i < _steps.length; i++) ...[
              if (i > 0) const SizedBox(width: 6),
              Expanded(
                child: AnimatedBuilder(
                  animation: _run,
                  builder: (context, _) => _Rail(
                    fill: i < _step
                        ? 1
                        : i == _step
                            ? _run.value
                            : 0,
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

/// One beat: the numbered line, and the piece of the app it is talking about.
class _Beat extends StatelessWidget {
  const _Beat({super.key, required this.index, required this.step});

  final int index;
  final (String, String) step;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Numbered because these genuinely are a sequence: you cannot be
            // handed the answer before you have said what is on the plate.
            Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: PlateColors.green,
              ),
              child: Text(
                '${index + 1}',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: PlateColors.neutral100,
                ),
              ),
            ),
            const SizedBox(width: Space.sm + 2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(step.$1, style: text.titleMedium),
                  const SizedBox(height: 2),
                  Text(step.$2, style: text.bodyMedium),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: Space.md),
        Padding(
          padding: const EdgeInsets.only(left: 34),
          child: _Stage(index: index),
        ),
      ],
    );
  }
}

/// What that beat looks like in the app, drawn with the app's own parts.
class _Stage extends StatelessWidget {
  const _Stage({required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
    switch (index) {
      case 0:
        // The real tiles from the picker, two of them already chosen. Showing
        // three empty ones would have been accurate about the widget and
        // useless about the step, which is what tapping them does.
        return SizedBox(
          height: 130,
          child: Row(
            children: [
              FoodTile(
                icon: LucideIcons.wheat,
                label: 'Rice',
                selected: true,
                onTap: () {},
              ),
              const SizedBox(width: Space.sm),
              FoodTile(
                icon: LucideIcons.drumstick,
                label: 'Chicken',
                selected: true,
                onTap: () {},
              ),
              const SizedBox(width: Space.sm),
              FoodTile(
                icon: LucideIcons.egg,
                label: 'Egg',
                selected: false,
                onTap: () {},
              ),
            ],
          ),
        );
      case 1:
        return const Wrap(
          spacing: Space.sm,
          runSpacing: Space.sm,
          children: [
            Pill(label: 'Light on fibre', icon: LucideIcons.leafyGreen),
            Pill(
              label: 'Protein looks fine',
              background: PlateColors.neutral200,
              foreground: PlateColors.inkSoft,
            ),
          ],
        );
      default:
        return const PatchHighlight(
          icon: LucideIcons.salad,
          name: 'Add a side salad',
          compact: true,
        );
    }
  }
}

/// The rail under the beats. It fills as the beat plays, so the page reads as
/// something running rather than something stuck.
class _Rail extends StatelessWidget {
  const _Rail({required this.fill});

  final double fill;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(kPill),
      child: SizedBox(
        height: 3,
        child: Stack(
          children: [
            const SizedBox(
              width: double.infinity,
              height: 3,
              child: ColoredBox(color: PlateColors.neutral300),
            ),
            FractionallySizedBox(
              widthFactor: fill.clamp(0.0, 1.0),
              child: const SizedBox(
                height: 3,
                child: ColoredBox(color: PlateColors.green),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GoalPage extends StatelessWidget {
  const _GoalPage({required this.selected, required this.onSelect});

  final Goal selected;
  final ValueChanged<Goal> onSelect;


  @override
  Widget build(BuildContext context) {
    return _Page(
      title: 'What would help most?',
      subtitle: 'This only changes which suggestion comes first. Change it any time.',
      children: [
        for (final goal in Goal.values) ...[
          ChoiceRow(
            icon: goal.icon,
            title: goal.label,
            subtitle: goal.blurb,
            selected: selected == goal,
            onTap: () => onSelect(goal),
          ),
          const SizedBox(height: Space.sm),
        ],
      ],
    );
  }
}

class _PrefsPage extends StatelessWidget {
  const _PrefsPage({required this.selected, required this.onToggle});

  final Set<DietPref> selected;
  final ValueChanged<DietPref> onToggle;


  @override
  Widget build(BuildContext context) {
    return _Page(
      title: 'Anything to leave out?',
      subtitle: 'Pick as many as you like, or none at all.',
      children: [
        for (final pref in DietPref.values) ...[
          ChoiceRow(
            icon: pref.icon,
            title: pref.label,
            subtitle: pref.blurb,
            selected: selected.contains(pref),
            onTap: () => onToggle(pref),
          ),
          const SizedBox(height: Space.sm),
        ],
      ],
    );
  }
}
