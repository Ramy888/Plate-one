import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../domain/models.dart';
import '../state/providers.dart';
import '../data/scan_api.dart';
import '../state/scan_providers.dart';
import 'legal_screen.dart';
import 'theme.dart';
import 'widgets/common.dart';

/// Everything chosen during onboarding, changeable afterwards.
///
/// Without this screen a goal picked in the first thirty seconds of using the
/// app was permanent, which is the kind of gap that only shows up when someone
/// tries to change their mind.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});



  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, Space.xl),
          children: [
            const _SectionHeading('Your goal', first: true),
            Text(
              'Changes which suggestion comes first.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: Space.md),
            for (final goal in Goal.values) ...[
              ChoiceRow(
                icon: goal.icon,
                title: goal.label,
                subtitle: goal.blurb,
                selected: settings.goal == goal,
                onTap: () => ref.read(settingsProvider.notifier).setGoal(goal),
              ),
              const SizedBox(height: Space.sm),
            ],

            const _SectionHeading('Leave out'),
            Text(
              'Suggestions will never include these.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: Space.md),
            for (final pref in DietPref.values) ...[
              ChoiceRow(
                icon: pref.icon,
                title: pref.label,
                subtitle: pref.blurb,
                selected: settings.dietPrefs.contains(pref),
                onTap: () => ref.read(settingsProvider.notifier).togglePref(pref),
              ),
              const SizedBox(height: Space.sm),
            ],

            const _SectionHeading('About'),
            _LinkRow(label: 'Privacy policy', onTap: () => LegalScreen.showPrivacy(context)),
            const SizedBox(height: Space.sm),
            _LinkRow(label: 'Terms of use', onTap: () => LegalScreen.showTerms(context)),
            const _SectionHeading('Your data'),
            const _ScanAllowance(),
            const SizedBox(height: Space.sm),
            const _DeleteMyData(),
            const SizedBox(height: Space.lg),
            const _VersionLine(),
          ],
        ),
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading(this.text, {this.first = false});

  final String text;
  final bool first;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: first ? Space.sm : Space.xl, bottom: Space.xs),
      // .pp-heading in the design: the body face at 16/700, not the display
      // face. Caprasimo is reserved for .pp-h2 — empty states, dialogs,
      // addition names and legal section heads.
      child: Text(
        text,
        style: Theme.of(context)
            .textTheme
            .titleMedium
            ?.copyWith(fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _LinkRow extends StatelessWidget {
  const _LinkRow({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return PlateCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.md),
      child: Row(
        children: [
          Expanded(child: Text(label, style: Theme.of(context).textTheme.titleMedium)),
          const Icon(LucideIcons.chevronRight, color: PlateColors.inkSoft),
        ],
      ),
    );
  }
}

/// What the scan allowance is, without spending one to find out.
class _ScanAllowance extends ConsumerWidget {
  const _ScanAllowance();

  static String _describe(ScanQuota? quota) {
    if (quota == null) return 'Scan a meal to see how many you have left.';
    if (!quota.hasScans) {
      return 'None left today. Tapping the meal and picking the food is unlimited.';
    }
    return '${quota.scans} left today';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quota = ref.watch(scanControllerProvider).quota;
    return PlateCard(
      padding: const EdgeInsets.all(Space.md),
      child: Row(
        children: [
          const Lead(LucideIcons.camera),
          const SizedBox(width: Space.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('AI meal scans', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 2),
                Text(_describe(quota), style: Theme.of(context).textTheme.bodyMedium),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Backs the promise made in the privacy policy and on the deletion page.
///
/// Deliberately understated: clay rather than red, and no warning triangle.
/// It is a legitimate thing to want, not a mistake to be talked out of.
class _DeleteMyData extends ConsumerWidget {
  const _DeleteMyData();

  Future<void> _confirm(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: PlateColors.card,
        title: const Text('Delete my data'),
        content: const Text(
          'This removes your saved patches, their pictures, your conversations '
          'and your preferences from this phone, and tells our server to forget '
          'your account — your name, your email, your allowance, and every '
          'record of a scan.\n\n'
          'It cannot be undone, and it does not cancel a subscription.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep it'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: PlateColors.pro),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete everything'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;

    await ref.read(scanControllerProvider.notifier).deleteEverything();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Your data has been deleted.')));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PlateCard(
      onTap: () => _confirm(context, ref),
      padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.md),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Delete my data',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: PlateColors.pro,
                  ),
            ),
          ),
          const Icon(LucideIcons.chevronRight, color: PlateColors.inkSoft),
        ],
      ),
    );
  }
}

class _VersionLine extends StatelessWidget {
  const _VersionLine();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PackageInfo>(
      future: PackageInfo.fromPlatform(),
      builder: (context, snapshot) {
        final info = snapshot.data;
        // No placeholder while it loads: a version number flickering in is
        // noisier than one that simply appears.
        final label = info == null ? '' : 'Plate One ${info.version} (${info.buildNumber})';
        return Center(
          child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
        );
      },
    );
  }
}
