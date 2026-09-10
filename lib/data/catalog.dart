import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../domain/models.dart';

/// The bundled food and addition catalogue. Loaded once at startup; there is
/// no network call anywhere in Plate One.
class Catalog {
  const Catalog({required this.foods, required this.additions});

  final List<FoodItem> foods;
  final List<Addition> additions;

  static Future<Catalog> load() async {
    final results = await Future.wait([
      rootBundle.loadString('assets/data/foods.json'),
      rootBundle.loadString('assets/data/additions.json'),
    ]);
    return Catalog(
      foods: _parse(results[0], FoodItem.fromJson),
      additions: _parse(results[1], Addition.fromJson),
    );
  }

  static List<T> _parse<T>(String source, T Function(Map<String, dynamic>) fromJson) =>
      (jsonDecode(source) as List<dynamic>)
          .map((j) => fromJson(j as Map<String, dynamic>))
          .toList(growable: false);

  /// Foods offered for a meal slot. Free users see the common collection only;
  /// the locked ones are still shown in the picker, with a lock, because a
  /// visible locked tile sells Pro far better than an absent one.
  List<FoodItem> foodsForSlot(MealSlot slot) =>
      foods.where((f) => f.slots.contains(slot)).toList();

  FoodItem? foodById(String id) {
    for (final f in foods) {
      if (f.id == id) return f;
    }
    return null;
  }

  List<FoodItem> foodsByIds(Iterable<String> ids) =>
      ids.map(foodById).whereType<FoodItem>().toList();
}
