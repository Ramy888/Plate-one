import 'dart:async';

import 'package:flutter/material.dart';

import '../theme.dart';

/// A short message that says something happened.
///
/// Not a `SnackBar`: that one stretches to the width of whatever it is in, so
/// on a browser four words arrive as a bar two thousand pixels wide. This is
/// the size of its own text, centred, and it does not push the screen around
/// or wait to be dismissed.
///
/// It is for confirmations only — "saved", "five more plates". Anything the
/// user has to act on belongs on the screen, where it will still be there in
/// three seconds.
abstract final class Toast {
  static OverlayEntry? _showing;

  static const _visible = Duration(seconds: 3);
  static const _fade = Duration(milliseconds: 220);

  static void show(BuildContext context, String message) {
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;

    // One at a time. Two confirmations stacked on each other is worse than the
    // second one replacing the first.
    dismiss();

    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => _Toast(
        message: message,
        fade: _fade,
        visible: _visible,
        onDone: () {
          if (_showing == entry) dismiss();
        },
      ),
    );
    _showing = entry;
    overlay.insert(entry);
  }

  /// Takes it away now. Safe to call when there is nothing showing.
  static void dismiss() {
    _showing?.remove();
    _showing = null;
  }
}

class _Toast extends StatefulWidget {
  const _Toast({
    required this.message,
    required this.fade,
    required this.visible,
    required this.onDone,
  });

  final String message;
  final Duration fade;
  final Duration visible;
  final VoidCallback onDone;

  @override
  State<_Toast> createState() => _ToastState();
}

class _ToastState extends State<_Toast> {
  double _opacity = 0;

  /// Owned by the widget, not by [Toast], so tearing down the tree cancels it.
  /// A static timer outlives the overlay it was going to remove, and then
  /// fires into nothing — which a test reports as a leak and a hot restart
  /// reports as a crash.
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    // The first frame is at zero, so the second one animates. Inserting at
    // full opacity would make it appear rather than arrive.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _opacity = 1);
    });
    _clock = Timer(widget.visible, widget.onDone);
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: MediaQuery.of(context).padding.bottom + Space.xl,
      child: IgnorePointer(
        child: AnimatedOpacity(
          opacity: _opacity,
          duration: widget.fade,
          curve: Curves.easeOut,
          child: Center(
            child: Material(
              color: Colors.transparent,
              child: Container(
                // Its own width, up to what a phone can hold.
                constraints: const BoxConstraints(maxWidth: 420),
                margin: const EdgeInsets.symmetric(horizontal: Space.lg),
                padding: const EdgeInsets.symmetric(
                  horizontal: Space.lg,
                  vertical: Space.md,
                ),
                decoration: BoxDecoration(
                  color: PlateColors.green,
                  borderRadius: BorderRadius.circular(kRadiusSmall),
                  boxShadow: [
                    BoxShadow(
                      color: PlateColors.ink.withValues(alpha: 0.18),
                      blurRadius: 18,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Text(
                  widget.message,
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: PlateColors.neutral100),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
