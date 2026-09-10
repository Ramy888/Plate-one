import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme.dart';

/// The mic, with the two bits of motion a mic is expected to have: a ring that
/// travels outward from the tap, and a squash-and-settle on the button itself.
///
/// Both are driven by one controller — a single gesture should read as a single
/// piece of movement, not two effects that happen to fire together.
class MicButton extends StatefulWidget {
  const MicButton({super.key, required this.onTap, this.size = 68, this.tooltip});

  final VoidCallback onTap;
  final double size;
  final String? tooltip;

  @override
  State<MicButton> createState() => _MicButtonState();
}

class _MicButtonState extends State<MicButton> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 620),
  );

  /// The ring: starts at the button's edge and fades as it grows.
  late final Animation<double> _ring = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );

  /// The button: dips under the finger, then overshoots back.
  late final Animation<double> _bounce = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(begin: 1.0, end: 0.88).chain(CurveTween(curve: Curves.easeOut)),
      weight: 22,
    ),
    TweenSequenceItem(
      tween: Tween(begin: 0.88, end: 1.0).chain(CurveTween(curve: Curves.elasticOut)),
      weight: 78,
    ),
  ]).animate(_controller);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _tap() {
    _controller.forward(from: 0);
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    // The ring needs room to travel, so the widget reserves more space than the
    // button occupies rather than being clipped by its parent.
    final extent = widget.size * 1.9;

    return Semantics(
      button: true,
      label: widget.tooltip ?? 'Speak your meal',
      child: SizedBox(
        width: extent,
        height: extent,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            return Stack(
              alignment: Alignment.center,
              children: [
                if (_controller.isAnimating)
                  Container(
                    width: widget.size + (extent - widget.size) * _ring.value,
                    height: widget.size + (extent - widget.size) * _ring.value,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: PlateColors.green.withValues(alpha: 0.18 * (1 - _ring.value)),
                    ),
                  ),
                Transform.scale(scale: _bounce.value, child: child),
              ],
            );
          },
          child: Material(
            color: PlateColors.green,
            shape: const CircleBorder(),
            elevation: 0,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: _tap,
              child: SizedBox(
                width: widget.size,
                height: widget.size,
                child: Icon(
                  LucideIcons.mic,
                  size: widget.size * 0.42,
                  color: PlateColors.neutral100,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
