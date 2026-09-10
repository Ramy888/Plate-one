import 'models.dart';

/// Turns the names a vision model produces into catalogue foods.
///
/// The model says "roast chicken thigh"; the catalogue has "Chicken". Matching
/// happens here, on the device, because the catalogue is already here — putting
/// it in the Worker would mean maintaining the same food list twice and having
/// them drift.
///
/// Anything that cannot be matched is kept, not discarded: an unrecognised
/// label still shows on the confirm screen so the user can see what the model
/// thought it saw and remove it. Silently dropping it would look like the app
/// missed something.
class RecognizedFood {
  const RecognizedFood({
    required this.label,
    required this.confidence,
    this.food,
  });

  /// What the model called it.
  final String label;
  final double confidence;

  /// The catalogue item it maps to, or null when nothing fits.
  final FoodItem? food;

  bool get isMatched => food != null;

  /// What the user sees on the confirm screen.
  String get displayName => food?.name ?? _titleCase(label);

  String get emoji => food?.emoji ?? '🍽️';

  /// Lucide icon name. An unmatched item gets the question glyph, which is the
  /// honest answer: something was read, and the app does not know it.
  String get icon => food?.icon ?? 'circle-help';

  RecognizedFood withFood(FoodItem? item) =>
      RecognizedFood(label: label, confidence: confidence, food: item);

  static String _titleCase(String value) =>
      value.isEmpty ? value : value[0].toUpperCase() + value.substring(1);
}

class FoodMatcher {
  const FoodMatcher(this.foods);

  final List<FoodItem> foods;

  /// Words that carry no identifying weight, so "a bowl of white rice" and
  /// "white rice" match the same thing.
  static const _noise = {
    'a', 'an', 'and', 'of', 'the', 'with', 'some', 'side', 'plate', 'bowl',
    'dish', 'serving', 'portion', 'piece', 'pieces', 'slice', 'slices',
    'fresh', 'cooked', 'grilled', 'roast', 'roasted', 'fried', 'baked',
    'boiled', 'steamed', 'sauteed', 'mixed', 'plain', 'small', 'large',
  };

  /// Phrasings a model reaches for that the token rule alone would miss.
  /// Deliberately short — every entry here is a thing that has to be
  /// maintained, so the general rule does the work wherever it can.
  static const _aliases = <String, String>{
    'bread': 'white_bread',
    'toast': 'white_bread',
    'pita': 'white_bread',
    'flatbread': 'baladi_bread',
    'noodles': 'pasta',
    'spaghetti': 'pasta',
    'macaroni': 'pasta',
    'potato': 'potatoes',
    'chips': 'fries',
    'egg': 'eggs',
    'omelette': 'eggs',
    'omelet': 'eggs',
    'yoghurt': 'yogurt',
    'greens': 'salad',
    'lettuce': 'salad',
    'vegetables': 'cooked_veg',
    'veg': 'cooked_veg',
    'broccoli': 'cooked_veg',
    'carrots': 'cooked_veg',
    'peas': 'cooked_veg',
    'beef': 'red_meat',
    'lamb': 'red_meat',
    'steak': 'red_meat',
    'mince': 'red_meat',
    'salmon': 'fish',
    'tuna': 'fish',
    'sardines': 'fish',
    'apple': 'fruit',
    'orange': 'fruit',
    'berries': 'fruit',
    'grapes': 'fruit',
    'biscuit': 'biscuits',
    'cookie': 'biscuits',
    'cookies': 'biscuits',
    'crisps': 'crisps',
    'nut': 'nuts',
    'almonds': 'nuts',
    'walnuts': 'nuts',
    'peanuts': 'nuts',
    'lentil': 'lentils',
    'bean': 'beans',
    'chickpeas': 'beans',
    'falafel': 'taameya',
    'ful': 'fuul',
    'foul': 'fuul',
  };

  static List<String> _tokens(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9\s-]'), ' ')
      .replaceAll('-', ' ')
      .split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty)
      .toList();

  static Set<String> _significant(String value) =>
      _tokens(value).where((t) => !_noise.contains(t)).toSet();

  /// Matches one recognised name, or returns it unmatched.
  RecognizedFood match(String label, double confidence, {required MealSlot slot}) {
    final item = _find(label, slot);
    return RecognizedFood(label: label, confidence: confidence, food: item);
  }

  List<RecognizedFood> matchAll(
    Iterable<({String name, double confidence})> recognized, {
    required MealSlot slot,
  }) {
    final seen = <String>{};
    final out = <RecognizedFood>[];
    for (final entry in recognized) {
      final matched = match(entry.name, entry.confidence, slot: slot);
      // Two labels can land on the same catalogue food — "rice" and "white
      // rice" both mean Rice. Keep the first and drop the duplicate rather
      // than double-counting it in the engine.
      final key = matched.food?.id ?? 'label:${entry.name.toLowerCase()}';
      if (seen.add(key)) out.add(matched);
    }
    return out;
  }

  FoodItem? _find(String label, MealSlot slot) {
    final wanted = _significant(label);
    if (wanted.isEmpty) return null;

    FoodItem? best;
    var bestScore = 0;

    for (final food in foods) {
      final score = _score(food, wanted, slot);
      if (score > bestScore) {
        bestScore = score;
        best = food;
      }
    }
    return bestScore > 0 ? best : null;
  }

  /// Higher is a better match. Zero means no match at all.
  int _score(FoodItem food, Set<String> wanted, MealSlot slot) {
    var score = 0;

    // A catalogue name whose significant words all appear in the label.
    // "Rice" matches "white rice"; "Chicken" matches "roast chicken thigh".
    // Token comparison rather than substring, so "chicken" never matches
    // "chickpeas".
    for (final variant in _variants(food.name)) {
      if (variant.isNotEmpty && variant.every(wanted.contains)) {
        score = 60 + variant.length * 10;
        break;
      }
    }

    // Alias only when the general rule found nothing.
    if (score == 0) {
      for (final token in wanted) {
        if (_aliases[token] == food.id) {
          score = 40;
          break;
        }
      }
    }
    if (score == 0) return 0;

    // Prefer a food that belongs to the meal being built. A tie between two
    // plausible foods should go to the one that fits breakfast if it is
    // breakfast.
    if (food.slots.contains(slot)) score += 5;
    return score;
  }

  /// "Beef or lamb" is two names, not one. Splitting on " or " lets either
  /// half match on its own.
  static List<Set<String>> _variants(String name) =>
      name.toLowerCase().split(' or ').map(_significant).toList();
}
