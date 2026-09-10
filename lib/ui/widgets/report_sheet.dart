import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/scan_providers.dart';
import '../theme.dart';
import 'common.dart';

/// Reporting an AI result.
///
/// Google Play requires apps that generate content to let people flag it
/// **without leaving the app**. This is that mechanism, so it is not optional
/// and it must never appear to fail — the request is fire-and-forget and the
/// confirmation shows either way.
class ReportSheet extends ConsumerStatefulWidget {
  const ReportSheet._();

  static const _reasons = <(String, IconData, String)>[
    ('wrong_food', LucideIcons.utensils, 'It got the food wrong'),
    ('unrealistic', LucideIcons.wandSparkles, 'The picture looks unrealistic'),
    ('offensive', LucideIcons.flag, 'Something offensive'),
    ('other', LucideIcons.messageCircle, 'Something else'),
  ];

  static Future<void> show(BuildContext context) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: PlateColors.cream,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(kRadius)),
        ),
        builder: (_) => const ReportSheet._(),
      );

  @override
  ConsumerState<ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends ConsumerState<ReportSheet> {
  final _note = TextEditingController();
  String? _reason;
  bool _sent = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final reason = _reason;
    if (reason == null) return;
    setState(() => _sent = true);
    // Deliberately not awaited into the UI: a report must never be the thing
    // that shows someone an error.
    unawaited(ref.read(scanControllerProvider.notifier).report(
          reason: reason,
          note: _note.text.trim(),
        ));
    await Future<void>.delayed(const Duration(milliseconds: 450));
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final insets = MediaQuery.of(context).viewInsets;

    return Padding(
      padding: EdgeInsets.only(bottom: insets.bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Space.lg, Space.md, Space.lg, Space.lg),
          child: _sent ? const _Thanks() : _form(context),
        ),
      ),
    );
  }

  Widget _form(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Grabber(),
        Text('Report this result', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: Space.xs),
        Text(
          'Plate One uses AI, and AI gets things wrong. Telling us which kind '
          'of wrong is how it improves.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: Space.md),
        for (final (id, icon, label) in ReportSheet._reasons) ...[
          ChoiceRow(
            icon: icon,
            title: label,
            subtitle: '',
            selected: _reason == id,
            onTap: () => setState(() => _reason = id),
          ),
          const SizedBox(height: Space.sm),
        ],
        const SizedBox(height: Space.xs),
        TextField(
          controller: _note,
          maxLength: 500,
          minLines: 2,
          maxLines: 4,
          decoration: InputDecoration(
            hintText: 'Anything else? (optional)',
            filled: true,
            fillColor: PlateColors.neutral100,
            counterText: '',
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(kRadiusSmall),
              borderSide: const BorderSide(color: Colors.transparent, width: 2),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(kRadiusSmall),
              borderSide: const BorderSide(color: Colors.transparent, width: 2),
            ),
            // The field only draws an edge once it has focus, which is the
            // one moment the edge is telling the user something.
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(kRadiusSmall),
              borderSide: const BorderSide(color: PlateColors.green, width: 2),
            ),
          ),
        ),
        const SizedBox(height: Space.md),
        FilledButton(
          onPressed: _reason == null ? null : _send,
          child: const Text('Send report'),
        ),
      ],
    );
  }
}

class _Thanks extends StatelessWidget {
  const _Thanks();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const _Grabber(),
        const SizedBox(height: Space.md),
        // The design's round mark, the same one every empty state uses.
        Container(
          width: 64,
          height: 64,
          alignment: Alignment.center,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: PlateColors.card,
          ),
          child: const Icon(LucideIcons.heartHandshake,
              size: 26, color: PlateColors.green),
        ),
        const SizedBox(height: Space.md),
        Text('Thank you', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: Space.xs),
        Text(
          'That helps. Reports are read and used to tune what Plate One suggests.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: Space.lg),
      ],
    );
  }
}

class _Grabber extends StatelessWidget {
  const _Grabber();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 40,
        height: 4,
        margin: const EdgeInsets.only(bottom: Space.md),
        decoration: BoxDecoration(
          color: PlateColors.line,
          borderRadius: BorderRadius.circular(kPill),
        ),
      ),
    );
  }
}
