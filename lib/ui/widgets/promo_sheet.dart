import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../data/api.dart';
import '../../state/api_providers.dart';
import '../theme.dart';
import 'common.dart';
import 'toast.dart';

/// Redeeming a promo code.
///
/// The way back in when today's plate is used. It is offered beside building
/// the meal by hand rather than instead of it: one of them costs nothing and
/// always works, and that one is not going anywhere.
class PromoSheet extends ConsumerStatefulWidget {
  const PromoSheet({super.key});

  static Future<bool> show(BuildContext context) async =>
      await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        backgroundColor: PlateColors.cream,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(kRadius)),
        ),
        builder: (_) => const PromoSheet(),
      ) ??
      false;

  @override
  ConsumerState<PromoSheet> createState() => _PromoSheetState();
}

class _PromoSheetState extends ConsumerState<PromoSheet> {
  final _code = TextEditingController();
  bool _sending = false;
  String? _refusal;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _redeem() async {
    final code = _code.text.trim();
    if (code.isEmpty || _sending) return;

    setState(() {
      _sending = true;
      _refusal = null;
    });

    try {
      final result = await ref.read(deviceProvider.notifier).redeem(code);
      if (!mounted) return;
      Navigator.of(context).pop(true);

      Toast.show(
        context,
        result.granted == 1
            ? 'One more plate. Go ahead.'
            : '${result.granted} more plates. Go ahead.',
      );
    } on ApiFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        // The server's own words. It knows whether the code is unknown, spent,
        // or already used by this device, and each of those is a different
        // thing to be told.
        _refusal = failure.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Padding(
      padding: EdgeInsets.only(
        left: Space.lg,
        right: Space.lg,
        top: Space.lg,
        // Above the keyboard, which is otherwise directly over the field.
        bottom: MediaQuery.of(context).viewInsets.bottom + Space.lg,
      ),
      child: Readable(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Have a promo code?', style: text.headlineSmall),
            const SizedBox(height: Space.sm),
            Text(
              'It opens more plates today. Building a meal by hand is unlimited '
              'either way.',
              style: text.bodyMedium?.copyWith(color: PlateColors.inkSoft),
            ),
            const SizedBox(height: Space.lg),
            TextField(
              controller: _code,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              textInputAction: TextInputAction.go,
              onSubmitted: (_) => _redeem(),
              // Codes are read off a screen and typed by hand. The server is
              // forgiving about case and spaces; this keeps the shape obvious.
              inputFormatters: [UpperCaseFormatter()],
              decoration: InputDecoration(
                hintText: 'PLATE-XXXXX',
                errorText: _refusal,
                prefixIcon: const Icon(LucideIcons.ticket),
              ),
            ),
            const SizedBox(height: Space.md),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _sending ? null : _redeem,
                child: _sending
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.2,
                          color: PlateColors.neutral100,
                        ),
                      )
                    : const Text('Redeem'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Keeps the field in the shape the codes are printed in.
class UpperCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue _, TextEditingValue next) =>
      next.copyWith(text: next.text.toUpperCase());
}
