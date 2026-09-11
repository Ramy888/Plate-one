import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../data/api.dart';
import '../../state/api_providers.dart';
import '../theme.dart';
import 'toast.dart';

/// Redeeming a promo code.
///
/// The way back in when today's plate is used. It is offered beside building
/// the meal by hand rather than instead of it: one of those costs nothing and
/// always works, and that one is not going anywhere.
///
/// A dialog rather than a sheet. This is one short question with one short
/// answer, and a sheet tall enough to hold a keyboard leaves it floating in
/// the middle of a mostly empty screen.
class PromoDialog extends ConsumerStatefulWidget {
  const PromoDialog({super.key});

  static Future<bool> show(BuildContext context) async =>
      await showDialog<bool>(
        context: context,
        barrierColor: PlateColors.ink.withValues(alpha: 0.45),
        builder: (_) => const PromoDialog(),
      ) ??
      false;

  @override
  ConsumerState<PromoDialog> createState() => _PromoDialogState();
}

class _PromoDialogState extends ConsumerState<PromoDialog> {
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
        // or already used on this device, and each of those is a different
        // thing to be told.
        _refusal = failure.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Dialog(
      backgroundColor: PlateColors.cream,
      insetPadding: const EdgeInsets.all(Space.lg),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRadius),
      ),
      child: ConstrainedBox(
        // Its own size. A dialog that fills a browser window is a sheet with
        // extra steps.
        constraints: const BoxConstraints(maxWidth: 400),
        child: Padding(
          padding: const EdgeInsets.all(Space.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: const BoxDecoration(
                      color: PlateColors.greenSoft,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      LucideIcons.ticket,
                      size: 20,
                      color: PlateColors.green,
                    ),
                  ),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: Text('Have a promo code?', style: text.titleLarge),
                  ),
                ],
              ),
              const SizedBox(height: Space.md),
              Text(
                'It opens more plates today. Building a meal by hand is '
                'unlimited either way.',
                style: text.bodyMedium?.copyWith(color: PlateColors.inkSoft),
              ),
              const SizedBox(height: Space.lg),
              TextField(
                controller: _code,
                autofocus: true,
                enabled: !_sending,
                textCapitalization: TextCapitalization.characters,
                textInputAction: TextInputAction.go,
                onSubmitted: (_) => _redeem(),
                // Codes are read off a screen and typed by hand. The server is
                // forgiving about case and spaces; this keeps the shape plain.
                inputFormatters: [UpperCaseFormatter()],
                decoration: InputDecoration(
                  hintText: 'PLATE-XXXXX',
                  errorText: _refusal,
                  filled: true,
                  fillColor: PlateColors.neutral100,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(kRadiusSmall),
                    borderSide: const BorderSide(color: PlateColors.line),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(kRadiusSmall),
                    borderSide: const BorderSide(color: PlateColors.line),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(kRadiusSmall),
                    borderSide: const BorderSide(color: PlateColors.green, width: 2),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: Space.md,
                    vertical: Space.md,
                  ),
                ),
              ),
              const SizedBox(height: Space.lg),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _sending ? null : () => Navigator.of(context).pop(false),
                    child: const Text('Not now'),
                  ),
                  const SizedBox(width: Space.sm),
                  FilledButton(
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
                ],
              ),
            ],
          ),
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
