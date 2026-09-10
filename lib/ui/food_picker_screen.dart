import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../domain/models.dart';
import '../state/providers.dart';
import 'icons.g.dart';
import 'result_screen.dart';
import 'theme.dart';
import 'widgets/common.dart';

/// What is on the plate.
///
/// Reached by tapping a meal on the hub, and it rises from where that tap was.
/// The meal it is about stays pinned at the top, so the answer to "which meal
/// is this?" never scrolls away while you are choosing food.
class FoodPickerScreen extends ConsumerStatefulWidget {
  const FoodPickerScreen({super.key, required this.slot});

  final MealSlot slot;

  @override
  ConsumerState<FoodPickerScreen> createState() => _FoodPickerScreenState();
}

class _FoodPickerScreenState extends ConsumerState<FoodPickerScreen> {
  /// Which rail is open. Null means the first one; `_noneOpen` means the user
  /// closed it and wants them all shut.
  String? _openRail;
  static const _noneOpen = '__none';

  @override
  Widget build(BuildContext context) {
    final draft = ref.watch(mealDraftProvider);
    final catalog = ref.watch(catalogProvider);
    final rails = _rails(catalog.foodsForSlot(widget.slot));

    final openId = _openRail == _noneOpen
        ? null
        : (rails.any((r) => r.group.id == _openRail)
            ? _openRail
            : (rails.isEmpty ? null : rails.first.group.id));

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Back',
          icon: const Icon(LucideIcons.chevronDown),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Row(
          children: [
            Icon(widget.slot.icon, size: 19, color: PlateColors.green),
            const SizedBox(width: Space.sm),
            Text(widget.slot.label),
          ],
        ),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, Space.lg),
                children: [
                  Text(
                    'Tap what is on the plate. Rough is fine.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: Space.md),
                  for (final rail in rails) ...[
                    _Rail(
                      rail: rail,
                      open: openId == rail.group.id,
                      chosen: rail.foods.where((f) => draft.foodIds.contains(f.id)).length,
                      selectedIds: draft.foodIds,
                      onToggleOpen: () => setState(
                        () => _openRail = openId == rail.group.id ? _noneOpen : rail.group.id,
                      ),
                      onTapFood: (f) =>
                          ref.read(mealDraftProvider.notifier).toggleFood(f.id),
                    ),
                    const SizedBox(height: Space.sm),
                  ],
                ],
              ),
            ),
            _PatchBar(
              count: draft.foodIds.length,
              onPressed: draft.isEmpty
                  ? null
                  : () => Navigator.of(context).push(
                        MaterialPageRoute<void>(builder: (_) => const ResultScreen()),
                      ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One rail's worth of food.
class _RailData {
  const _RailData(this.group, this.foods);

  final FoodGroup group;
  final List<FoodItem> foods;
}

List<_RailData> _rails(List<FoodItem> foods) {
  final rails = <_RailData>[];
  for (final group in FoodGroup.all) {
    final items = foods.where((f) => f.group == group.id).toList(growable: false);
    if (items.isNotEmpty) rails.add(_RailData(group, items));
  }
  return rails;
}

class _Rail extends StatelessWidget {
  const _Rail({
    required this.rail,
    required this.open,
    required this.chosen,
    required this.selectedIds,
    required this.onToggleOpen,
    required this.onTapFood,
  });

  final _RailData rail;
  final bool open;
  final int chosen;
  final Set<String> selectedIds;
  final VoidCallback onToggleOpen;
  final ValueChanged<FoodItem> onTapFood;

  @override
  Widget build(BuildContext context) {
    final shape = BorderRadius.circular(kPill);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          button: true,
          expanded: open,
          child: Material(
            color: open ? PlateColors.greenSoft : PlateColors.card,
            borderRadius: shape,
            child: InkWell(
              onTap: onToggleOpen,
              borderRadius: shape,
              child: Container(
                constraints: const BoxConstraints(minHeight: 48),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    Icon(rail.group.icon, size: 18, color: PlateColors.green),
                    const SizedBox(width: Space.sm),
                    Expanded(
                      child: Text(
                        rail.group.label,
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                      ),
                    ),
                    if (chosen > 0) ...[_Count(chosen), const SizedBox(width: Space.sm)],
                    Icon(
                      open ? LucideIcons.chevronUp : LucideIcons.chevronDown,
                      size: 19,
                      color: PlateColors.inkSoft,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (open)
          Padding(
            padding: const EdgeInsets.only(top: Space.sm),
            child: SizedBox(
              height: 130,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                // The rail bleeds to the screen edge, so a half-visible tile
                // says "there is more" without a scrollbar saying it.
                padding: const EdgeInsets.symmetric(horizontal: Space.xs),
                itemCount: rail.foods.length,
                separatorBuilder: (_, _) => const SizedBox(width: Space.sm),
                itemBuilder: (_, i) {
                  final food = rail.foods[i];
                  return FoodTile(
                    icon: catalogIcon(food.icon),
                    label: food.name,
                    selected: selectedIds.contains(food.id),
                    onTap: () => onTapFood(food),
                  );
                },
              ),
            ),
          ),
      ],
    );
  }
}

class _Count extends StatelessWidget {
  const _Count(this.value);

  final int value;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 22),
      height: 22,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 7),
      decoration: BoxDecoration(
        color: PlateColors.green,
        borderRadius: BorderRadius.circular(kPill),
      ),
      child: Text(
        '$value',
        style: const TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
          color: PlateColors.neutral100,
        ),
      ),
    );
  }
}

/// Sticky footer. Disabled until something is on the plate, because a patch
/// with no meal to patch is meaningless.
class _PatchBar extends StatelessWidget {
  const _PatchBar({required this.count, required this.onPressed});

  final int count;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(Space.lg, Space.md, Space.lg, Space.md),
      decoration: const BoxDecoration(
        color: PlateColors.cream,
        border: Border(top: BorderSide(color: PlateColors.line)),
      ),
      child: FilledButton(
        onPressed: onPressed,
        child: Text(
          count == 0 ? 'Pick what you are eating' : 'Patch this meal · $count selected',
        ),
      ),
    );
  }
}
