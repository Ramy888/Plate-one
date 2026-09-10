import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/models.dart';
import '../state/providers.dart';
import 'theme.dart';
import 'widgets/common.dart';

/// The after-meal check. One tap, no scale, no judgement — and it is the only
/// signal Plate One uses to get better at suggesting.
class CheckScreen extends ConsumerWidget {
  const CheckScreen({super.key, required this.patchId});

  final String patchId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Later'),
          ),
          const SizedBox(width: Space.sm),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, Space.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Saved. How did it go?',
                  style: Theme.of(context).textTheme.displaySmall),
              const SizedBox(height: Space.sm),
              Text(
                'Answer after you have eaten, or skip it. Either is fine — it just '
                'helps Plate One aim better next time.',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: PlateColors.inkSoft,
                    ),
              ),
              const SizedBox(height: Space.xl),
              for (final s in Satisfaction.values) ...[
                ChoiceRow(
                  icon: s.icon,
                  title: s.label,
                  subtitle: _blurb(s),
                  selected: false,
                  showIndicator: false,
                  onTap: () async {
                    await ref
                        .read(historyProvider.notifier)
                        .recordSatisfaction(patchId, s);
                    if (!context.mounted) return;
                    Navigator.of(context).pop();
                  },
                ),
                const SizedBox(height: Space.sm),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _blurb(Satisfaction s) => switch (s) {
        Satisfaction.stillHungry => 'We will lean harder on protein next time.',
        Satisfaction.comfortable => 'Good. More of the same.',
        Satisfaction.tooFull => 'We will keep the additions lighter.',
      };
}
