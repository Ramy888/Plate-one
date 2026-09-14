import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';
import 'common.dart';

/// The app's plate filling itself with a meal, in three seconds.
///
/// The first thing anyone sees. It opens on the same empty dish the home screen
/// opens on, then the four parts of a plate arrive in the order somebody would
/// say them out loud — the base, the protein, the vegetables, and last the one
/// addition that finishes it, which is the whole product in one gesture.
///
/// Drawn rather than filmed. A video would have to be re-shot every time the
/// plate changes, cannot be sharp at every size a browser might ask for, and
/// carries a licence and a watermark question into a public MIT repository.
/// This is a few hundred bytes of arithmetic over the real [PlateDish].
class PlateFill extends StatefulWidget {
  const PlateFill({super.key, this.size = 220});

  final double size;

  @override
  State<PlateFill> createState() => _PlateFillState();
}

class _PlateFillState extends State<PlateFill>
    with SingleTickerProviderStateMixin {
  /// Three seconds to fill, then a beat holding the finished plate before it
  /// begins again — without the hold the meal is never actually seen whole.
  static const _fill = Duration(milliseconds: 3000);
  static const _hold = Duration(milliseconds: 1400);

  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: _fill + _hold,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Somebody who has asked their system for less motion gets the finished
    // plate and no loop. It is also what lets a widget test settle: an
    // animation that repeats for ever is a tree that never comes to rest.
    if (MediaQuery.disableAnimationsOf(context)) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return PlateDish(
        size: widget.size,
        child: CustomPaint(painter: _MealPainter(progress: 1)),
      );
    }

    final fillFraction = _fill.inMilliseconds /
        (_fill.inMilliseconds + _hold.inMilliseconds);

    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        // 0..1 across the filling part only; pinned at 1 through the hold.
        final t = (_c.value / fillFraction).clamp(0.0, 1.0);
        return PlateDish(
          size: widget.size,
          child: CustomPaint(
            painter: _MealPainter(progress: t),
          ),
        );
      },
    );
  }
}

/// One part of the meal: where it sits on the plate and what colour it is.
class _Serving {
  const _Serving(this.start, this.sweep, this.colour, this.radius);

  /// Clockwise from twelve o'clock, in turns.
  final double start;
  final double sweep;
  final Color colour;

  /// How far out from the middle it reaches, as a fraction of the well.
  final double radius;
}

class _MealPainter extends CustomPainter {
  _MealPainter({required this.progress});

  final double progress;

  /// A plate that adds up: a base, something with protein in it, vegetables,
  /// and the addition. Warm, muted, and of the app's own palette rather than
  /// photographic — this is the drawing the app already uses when it has no
  /// picture, not an attempt at a photograph that would lose.
  static const _meal = [
    _Serving(0.50, 0.28, Color(0xFFF2E7D0), 0.92), // the base
    _Serving(0.78, 0.24, Color(0xFFC98A52), 0.88), // protein
    _Serving(0.02, 0.26, Color(0xFF7E9455), 0.90), // vegetables
    _Serving(0.28, 0.22, Color(0xFFE3B24E), 0.84), // the one addition
  ];

  /// Each serving gets its own slice of the three seconds, overlapping a little
  /// so the plate fills continuously rather than in four visible steps.
  static const _stagger = 0.22;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2);
    final well = size.width / 2;

    for (var i = 0; i < _meal.length; i++) {
      final serving = _meal[i];
      final begin = i * _stagger;
      final local =
          ((progress - begin) / (1 - _stagger * (_meal.length - 1))).clamp(0.0, 1.0);
      if (local <= 0) continue;

      // Eased: food is set down, it does not appear.
      final eased = Curves.easeOutCubic.transform(local);

      // Drawn as a thick band with rounded ends rather than a wedge running to
      // a point. Wedges meeting in the middle read as a pie chart — which is
      // what this looked like first time — where a band leaves the plate
      // showing under it and the round ends read as something spooned on.
      final band = well * 0.60 * serving.radius;
      final radius = well * 0.55;
      final rect = Rect.fromCircle(center: centre, radius: radius);

      // A gap between servings, so four helpings read as four things.
      const gap = 0.018;
      final start = (serving.start + gap) * 2 * math.pi - math.pi / 2;
      final sweep = (serving.sweep - gap * 2) * 2 * math.pi;

      // Its own soft shadow, so the food sits in the plate rather than being
      // printed on it.
      canvas.drawArc(
        rect.translate(0, well * 0.012),
        start,
        sweep,
        false,
        Paint()
          ..color = PlateColors.ink.withValues(alpha: 0.10 * eased)
          ..style = PaintingStyle.stroke
          ..strokeWidth = band
          ..strokeCap = StrokeCap.round
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, well * 0.03),
      );

      canvas.drawArc(
        rect,
        start,
        // Grows along the plate as it is served, rather than fading in place.
        sweep * eased,
        false,
        Paint()
          ..color = serving.colour
          ..style = PaintingStyle.stroke
          ..strokeWidth = band * (0.6 + 0.4 * eased)
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_MealPainter old) => old.progress != progress;
}
