import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/food_matcher.dart';
import '../domain/models.dart';
import '../state/providers.dart';
import '../state/scan_providers.dart';
import 'result_screen.dart';
import 'icons.g.dart';
import 'theme.dart';
import 'widgets/common.dart';
import 'widgets/report_sheet.dart';

/// "Is this what you are eating?"
///
/// The step that makes the whole feature honest. A vision model is confident
/// even when it is wrong, so nothing it says reaches the rule engine until a
/// person has looked at it. Removing a wrong item is one tap, and adding a
/// missed one opens the same catalogue the manual builder uses.
class ScanConfirmScreen extends ConsumerWidget {
  const ScanConfirmScreen({super.key, required this.slot});

  final MealSlot slot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scan = ref.watch(scanControllerProvider);
    final recognized = scan.recognized;
    final matchedCount = recognized.where((f) => f.isMatched).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Is this right?'),
        actions: [
          IconButton(
            tooltip: 'Report this result',
            icon: const Icon(LucideIcons.flag),
            onPressed: () => ReportSheet.show(context),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, Space.md),
                children: [
                  Text(
                    recognized.isEmpty
                        ? 'Nothing recognised yet'
                        : 'Plate One thinks it sees this',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: Space.xs),
                  Text(
                    'Remove anything that is wrong, and add anything it missed. '
                    'Nothing is suggested until this looks right to you.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: Space.lg),
                  for (final food in recognized) ...[
                    _RecognizedRow(
                      food: food,
                      onRemove: () =>
                          ref.read(scanControllerProvider.notifier).remove(food),
                    ),
                    const SizedBox(height: Space.sm),
                  ],
                  if (recognized.isEmpty)
                    const EmptyState(
                      icon: LucideIcons.circleHelp,
                      title: 'Nothing on the plate yet',
                      message: 'Add what you are eating and Plate One will take it from there.',
                    ),
                  const SizedBox(height: Space.md),
                  _AddMore(slot: slot),
                  const SizedBox(height: Space.lg),
                  const _AiNote(),
                ],
              ),
            ),
            _ConfirmBar(
              count: matchedCount,
              onConfirm: matchedCount == 0
                  ? null
                  : () {
                      ref.read(scanControllerProvider.notifier).confirm(slot);
                      Navigator.of(context).pushReplacement(
                        MaterialPageRoute<void>(builder: (_) => const ResultScreen()),
                      );
                    },
            ),
          ],
        ),
      ),
    );
  }
}

class _RecognizedRow extends StatelessWidget {
  const _RecognizedRow({required this.food, required this.onRemove});

  final RecognizedFood food;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return PlateCard(
      padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.md),
      border: food.isMatched ? null : PlateColors.warn,
      color: food.isMatched ? PlateColors.card : PlateColors.proSoft,
      child: Row(
        children: [
          Lead(
            catalogIcon(food.icon),
            tone: food.isMatched ? PlateColors.green : PlateColors.pro,
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(food.displayName, style: Theme.of(context).textTheme.titleMedium),
                if (!food.isMatched) ...[
                  const SizedBox(height: 2),
                  Text(
                    // Said plainly: this one will not affect the suggestion.
                    'Not in the food list, so it will not count towards the patch.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ] else if (food.confidence < 0.7) ...[
                  const SizedBox(height: 2),
                  Text('Not very sure about this one.',
                      style: Theme.of(context).textTheme.bodyMedium),
                ],
              ],
            ),
          ),
          IconButton(
            tooltip: 'Remove ${food.displayName}',
            icon: const Icon(LucideIcons.x, size: 20, color: PlateColors.inkSoft),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

/// Adds a food the model missed, from the same catalogue the manual builder
/// uses — so there is one food list in the app, not two.
class _AddMore extends ConsumerWidget {
  const _AddMore({required this.slot});

  final MealSlot slot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalog = ref.watch(catalogProvider);
    final already = ref
        .watch(scanControllerProvider)
        .recognized
        .map((f) => f.food?.id)
        .whereType<String>()
        .toSet();

    final options = catalog
        .foodsForSlot(slot)
        .where((f) => !already.contains(f.id))
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Add something it missed', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: Space.sm),
        Wrap(
          spacing: Space.sm,
          runSpacing: Space.sm,
          children: [
            for (final food in options)
              PlateChip(
                icon: catalogIcon(food.icon),
                label: food.name,
                onTap: () => ref.read(scanControllerProvider.notifier).add(food),
              ),
          ],
        ),
      ],
    );
  }
}

/// The disclosure Play expects, in the place it actually matters.
class _AiNote extends StatelessWidget {
  const _AiNote();

  @override
  Widget build(BuildContext context) {
    return PlateCard.quiet(
      padding: const EdgeInsets.all(Space.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(LucideIcons.sparkles, size: 17, color: PlateColors.green),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Text(
              'Recognised by AI, which gets things wrong. Your photo was cropped '
              'and stripped of location data on this phone, and is not stored on '
              'our servers.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

class _ConfirmBar extends StatelessWidget {
  const _ConfirmBar({required this.count, required this.onConfirm});

  final int count;
  final VoidCallback? onConfirm;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(Space.lg, Space.md, Space.lg, Space.md),
      decoration: const BoxDecoration(
        color: PlateColors.cream,
        border: Border(top: BorderSide(color: PlateColors.line)),
      ),
      child: FilledButton(
        onPressed: onConfirm,
        child: Text(count == 0 ? 'Add what you are eating' : 'Looks right · patch it'),
      ),
    );
  }
}
