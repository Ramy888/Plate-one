import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../domain/models.dart';
import '../state/providers.dart';
import 'check_screen.dart';
import 'icons.g.dart';
import 'theme.dart';
import 'widgets/common.dart';

/// A patch you kept.
///
/// The same page as the result it came from, read back: the plate as it was
/// drawn, the addition said in words, what was on the plate, and how the meal
/// went. Nothing here calls a model — it is all what was written down at the
/// time, so it opens instantly and works with no network.
class SavedPatchScreen extends ConsumerStatefulWidget {
  const SavedPatchScreen({super.key, required this.patchId});

  final String patchId;

  @override
  ConsumerState<SavedPatchScreen> createState() => _SavedPatchScreenState();
}

class _SavedPatchScreenState extends ConsumerState<SavedPatchScreen> {
  Uint8List? _image;
  bool _looked = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final patch = _find();
    final bytes = await ref.read(patchImagesProvider).get(patch?.imagePath);
    if (!mounted) return;
    setState(() {
      _image = bytes;
      _looked = true;
    });
  }

  SavedPatch? _find() {
    for (final p in ref.read(historyProvider)) {
      if (p.id == widget.patchId) return p;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(historyProvider);
    final patch = history.where((p) => p.id == widget.patchId).firstOrNull;

    // Removed while it was open — go back rather than show a blank.
    if (patch == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
      return const Scaffold(body: SizedBox.shrink());
    }

    final catalog = ref.watch(catalogProvider);
    final foods = catalog.foodsByIds(patch.foodIds);
    final addition = catalog.additions.where((a) => a.id == patch.additionId).firstOrNull;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Saved patch'),
        actions: [
          IconButton(
            tooltip: 'Remove this patch',
            icon: const Icon(LucideIcons.trash2),
            onPressed: () => _confirmRemove(context, patch),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, Space.xl),
          children: [
            Text(
              '${patch.slot.label} · ${_when(patch.savedAt)}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: Space.md),
            _Picture(image: _image, looked: _looked, addition: addition),
            const SizedBox(height: Space.md),
            PatchHighlight(
              icon: catalogIcon(addition?.icon),
              name: patch.additionName,
              how: addition?.how,
            ),
            if (foods.isNotEmpty) ...[
              const SizedBox(height: Space.lg),
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
            const SizedBox(height: Space.lg),
            _HowItWent(patch: patch),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmRemove(BuildContext context, SavedPatch patch) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: PlateColors.cream,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kRadius)),
        title: Text('Remove this patch?',
            style: Theme.of(dialogContext).textTheme.titleLarge),
        content: Text(
          'It is only on this phone, so removing it takes the picture with it.',
          style: Theme.of(dialogContext).textTheme.bodyLarge,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep it'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: PlateColors.pro),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (yes ?? false) {
      await ref.read(historyProvider.notifier).remove(patch.id);
    }
  }

  static String _when(DateTime at) {
    final days = DateTime.now().difference(at).inDays;
    if (days <= 0) return 'today';
    if (days == 1) return 'yesterday';
    if (days < 7) return '$days days ago';
    return '${at.day}/${at.month}';
  }
}

/// The plate as it was drawn, or the reason it is not there.
class _Picture extends StatelessWidget {
  const _Picture({required this.image, required this.looked, required this.addition});

  final Uint8List? image;
  final bool looked;
  final Addition? addition;

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
            child: image != null
                ? Image.memory(image!, fit: BoxFit.cover)
                : Container(
                    color: PlateColors.card,
                    alignment: Alignment.center,
                    child: looked
                        ? Icon(catalogIcon(addition?.icon), size: 52,
                            color: PlateColors.neutral400)
                        : const SizedBox(
                            width: 26,
                            height: 26,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: PlateColors.green,
                            ),
                          ),
                  ),
          ),
        ),
        if (image != null) ...[
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

/// How the meal went, or an invitation to say.
class _HowItWent extends ConsumerWidget {
  const _HowItWent({required this.patch});

  final SavedPatch patch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final answered = patch.satisfaction;
    if (answered != null) {
      return PlateCard.selected(
        child: Row(
          children: [
            Lead(answered.icon),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('How it went', style: Theme.of(context).textTheme.bodyMedium),
                  const SizedBox(height: 2),
                  Text(answered.label, style: Theme.of(context).textTheme.titleMedium),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return OutlinedButton.icon(
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => CheckScreen(patchId: patch.id)),
      ),
      icon: const Icon(LucideIcons.smile, size: 17),
      label: const Text('How did it go?'),
    );
  }
}
