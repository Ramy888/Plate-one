import 'package:flutter/material.dart';

/// A page that rises from the bottom.
///
/// Used for the two screens the hub opens — the food picker and the chat. Both
/// are a continuation of a tap made near the bottom of the screen, so coming up
/// from there keeps the gesture and the movement pointing the same way.
Route<T> slideUpRoute<T>(Widget page) {
  return PageRouteBuilder<T>(
    transitionDuration: const Duration(milliseconds: 320),
    reverseTransitionDuration: const Duration(milliseconds: 260),
    pageBuilder: (_, _, _) => page,
    transitionsBuilder: (_, animation, _, child) {
      // Eased rather than linear: it should feel like the sheet is settling,
      // not sliding on rails.
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 1),
          end: Offset.zero,
        ).animate(curved),
        child: FadeTransition(
          opacity: Tween<double>(begin: 0.4, end: 1).animate(curved),
          child: child,
        ),
      );
    },
  );
}
