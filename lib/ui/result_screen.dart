import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../domain/models.dart';
import '../state/plate_providers.dart';
import '../state/providers.dart';
import '../state/save_patch.dart';
import 'icons.g.dart';
import 'theme.dart';
import 'widgets/common.dart';
import 'widgets/report_sheet.dart';

/// The answer.
///
/// Everything else in this app is a way of getting here, so this page is
/// allowed to be the largest thing in it: the plate drawn with the addition on
/// it, the addition said in words, why it was chosen, and one button to take
/// it. The other two suggestions sit underneath, because a single answer with
/// no alternative reads as a decision made for you.
///
/// It must read with no network at all. The engine's answer is the page; the
/// picture and the written sentence are what get added when they can be.
class ResultScreen extends ConsumerStatefulWidget {
  const ResultScreen({super.key});

  @override
  ConsumerState<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends ConsumerState<ResultScreen> {
  /// Which of the three is showing. Null means the first one the engine chose.
  PickAngle? _chosen;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _draw());
  }

  /// The words are the engine's; the picture is the only part that costs
  /// anything, and it is drawn as soon as there is something to draw.
  void _draw() {
    final result = ref.read(patchResultProvider);
    final patch = _patchFor(result);
    if (patch == null) return;
    ref.read(plateVisualProvider.notifier).load(
          foodIds: result.foods.map((f) => f.id).toList(),
          additionId: patch.addition.id,
        );
  }

  Patch? _patchFor(PatchResult result) {
    if (result.patches.isEmpty) return null;
    return result.patches.firstWhere(
      (p) => p.angle == (_chosen ?? result.patches.first.angle),
      orElse: () => result.patches.first,
    );
  }

  @override
  Widget build(BuildContext context) {
    final result = ref.watch(patchResultProvider);
    final visual = ref.watch(plateVisualProvider);
    final patch = _patchFor(result);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Your patch'),
        actions: [
          // Play requires in-app reporting wherever an AI-derived result shows.
          IconButton(
            tooltip: 'Report this result',
            icon: const Icon(LucideIcons.flag),
            onPressed: () => ReportSheet.show(context),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, Space.xl),
          children: [
            _OnYourPlate(foods: result.foods),
            const SizedBox(height: Space.md),
            Text(result.headline, style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: Space.lg),

            if (result.isBalanced)
              const _Balanced()
            else if (patch == null)
              const _NoSuggestions()
            else ...[
              _Hero(patch: patch, visual: visual, onDraw: _draw),
              const SizedBox(height: Space.md),
              PatchHighlight(
                icon: catalogIcon(patch.addition.icon),
                name: patch.addition.name,
                how: patch.addition.how,
              ),
              const SizedBox(height: Space.md),
              _Why(result: result, patch: patch, caption: visual.caption),
              const SizedBox(height: Space.lg),
              FilledButton(
                onPressed: () => savePatch(
                  context,
                  ref,
                  slot: result.slot,
                  foodIds: result.foods.map((f) => f.id).toList(),
                  addition: patch.addition,
                  gapIds: result.gaps.map((g) => g.id).toList(),
                  image: visual.image,
                ),
                child: const Text("I'll add this"),
              ),
              if (result.patches.length > 1) ...[
                const SizedBox(height: Space.xl),
                Text('Or instead', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: Space.sm),
                for (final other in result.patches.where((p) => p.angle != patch.angle)) ...[
                  _Alternative(
                    patch: other,
                    onTap: () {
                      setState(() => _chosen = other.angle);
                      _draw();
                    },
                  ),
                  const SizedBox(height: Space.sm),
                ],
              ],
            ],
          ],
        ),
      ),
    );
  }
}

/// What is on the plate, as small chips. Named rather than counted.
class _OnYourPlate extends StatelessWidget {
  const _OnYourPlate({required this.foods});

  final List<FoodItem> foods;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('On your plate', style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: Space.sm),
        Wrap(
          spacing: Space.sm,
          runSpacing: Space.sm,
          children: [
            for (final food in foods)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: PlateColors.card,
                  borderRadius: BorderRadius.circular(kPill),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(catalogIcon(food.icon), size: 14, color: PlateColors.green),
                    const SizedBox(width: 6),
                    Text(food.name, style: const TextStyle(fontSize: 13.5)),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// The plate with the addition on it.
///
/// A placeholder rather than an absence when there is no picture: the page has
/// the same shape whether or not it could be drawn, so nothing jumps when one
/// arrives and nothing looks broken when one does not.
class _Hero extends StatelessWidget {
  const _Hero({
    required this.patch,
    required this.visual,
    required this.onDraw,
  });

  final Patch patch;
  final PlateVisual visual;

  /// A guest gets the whole answer in words and an offer to draw it.
  final VoidCallback onDraw;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(kRadius),
          child: SizedBox(
            height: 220,
            width: double.infinity,
            child: visual.image != null
                ? Image.memory(visual.image!, fit: BoxFit.cover)
                : Container(
                    color: PlateColors.card,
                    alignment: Alignment.center,
                    child: visual.loading
                        ? const SizedBox(
                            width: 26,
                            height: 26,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: PlateColors.green,
                            ),
                          )
                        : Icon(
                            catalogIcon(patch.addition.icon),
                            size: 52,
                            color: PlateColors.neutral400,
                          ),
                  ),
          ),
        ),
        if (visual.image != null) ...[
          const SizedBox(height: Space.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(LucideIcons.sparkles, size: 13, color: PlateColors.inkSoft),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'AI picture — appearance and serving size are illustrative.',
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(fontSize: 12.5, color: PlateColors.inkSoft),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Why this, and how much of it. The engine's reasoning first, because it is
/// the part that is always true; the written sentence is a gloss on it.
class _Why extends StatelessWidget {
  const _Why({required this.result, required this.patch, required this.caption});

  final PatchResult result;
  final Patch patch;
  final String caption;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (caption.isNotEmpty) ...[
          Text(caption, style: Theme.of(context).textTheme.bodyLarge),
          const SizedBox(height: Space.sm),
        ],
        Inset(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(patch.reason, style: Theme.of(context).textTheme.bodyMedium),
              if (result.gaps.isNotEmpty) ...[
                const SizedBox(height: Space.xs),
                Text(
                  result.gaps.first.benefit,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// One of the other two, compact.
class _Alternative extends StatelessWidget {
  const _Alternative({required this.patch, required this.onTap});

  final Patch patch;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return PlateCard(
      onTap: onTap,
      child: Row(
        children: [
          PlateThumb(catalogIcon(patch.addition.icon), small: true),
          const SizedBox(width: Space.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Pill(
                  label: patch.angle.label,
                  icon: patch.angle.icon,
                  background: PlateColors.neutral200,
                  foreground: PlateColors.inkSoft,
                ),
                const SizedBox(height: Space.xs),
                Text(patch.addition.name,
                    style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
          ),
          const Icon(LucideIcons.chevronRight, color: PlateColors.inkSoft),
        ],
      ),
    );
  }
}

class _Balanced extends StatelessWidget {
  const _Balanced();

  @override
  Widget build(BuildContext context) {
    return PlateCard.selected(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(LucideIcons.partyPopper, size: 26, color: PlateColors.green),
          const SizedBox(height: Space.sm),
          Text('Nothing to patch.', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: Space.xs),
          Text(
            'Protein, fibre and healthy fats are all covered here. Go and eat it.',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ],
      ),
    );
  }
}

class _NoSuggestions extends StatelessWidget {
  const _NoSuggestions();

  @override
  Widget build(BuildContext context) {
    return PlateCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(LucideIcons.filter, size: 26, color: PlateColors.green),
          const SizedBox(height: Space.sm),
          Text('Nothing fits your filters here.',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: Space.xs),
          Text(
            'Try loosening a preference for this meal.',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ],
      ),
    );
  }
}
