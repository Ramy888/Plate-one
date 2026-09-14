import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/models.dart';
import '../state/providers.dart';
import 'theme.dart';
import 'widgets/common.dart';
import 'widgets/plate_fill_video.dart';

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
      children: const [
        SizedBox(height: Space.lg),
        Center(child: PlateFillVideo(size: 210)),
      ],
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
