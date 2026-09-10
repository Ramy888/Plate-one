import 'package:flutter/widgets.dart' show IconData;
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The three nutrients Plate One reasons about. Deliberately not calories:
/// the product promise is "add one thing", never "count something".
enum Nutrient { protein, fibre, healthyFat }

extension NutrientLabel on Nutrient {
  String get id => switch (this) {
        Nutrient.protein => 'protein',
        Nutrient.fibre => 'fibre',
        Nutrient.healthyFat => 'fat',
      };

  String get label => switch (this) {
        Nutrient.protein => 'protein',
        Nutrient.fibre => 'fibre',
        Nutrient.healthyFat => 'healthy fats',
      };

  /// Short, plain-language reason this nutrient helps satisfaction.
  String get benefit => switch (this) {
        Nutrient.protein => 'Protein is the biggest lever on feeling full.',
        Nutrient.fibre => 'Fibre slows a meal down so the energy lasts longer.',
        Nutrient.healthyFat => 'A little healthy fat makes a meal taste finished.',
      };

  static Nutrient fromId(String id) => switch (id) {
        'protein' => Nutrient.protein,
        'fibre' => Nutrient.fibre,
        _ => Nutrient.healthyFat,
      };
}

enum MealSlot { breakfast, lunchDinner, snack }

extension MealSlotLabel on MealSlot {
  String get id => switch (this) {
        MealSlot.breakfast => 'breakfast',
        MealSlot.lunchDinner => 'lunch_dinner',
        MealSlot.snack => 'snack',
      };

  String get label => switch (this) {
        MealSlot.breakfast => 'Breakfast',
        MealSlot.lunchDinner => 'Lunch or dinner',
        MealSlot.snack => 'Snack',
      };

  IconData get icon => switch (this) {
        MealSlot.breakfast => LucideIcons.sunrise,
        MealSlot.lunchDinner => LucideIcons.utensils,
        MealSlot.snack => LucideIcons.cookie,
      };

  /// The photograph on the meal card. Bundled, so the first screen of the app
  /// needs no network and looks the same offline.
  String get image => 'assets/meals/$id.jpg';

  static MealSlot fromId(String id) => MealSlot.values.firstWhere(
        (s) => s.id == id,
        orElse: () => MealSlot.lunchDinner,
      );
}

enum Goal { feelSatisfied, moreEnergy, betterMeals }

extension GoalLabel on Goal {
  String get id => switch (this) {
        Goal.feelSatisfied => 'feel_satisfied',
        Goal.moreEnergy => 'more_energy',
        Goal.betterMeals => 'better_meals',
      };

  String get label => switch (this) {
        Goal.feelSatisfied => 'Feel satisfied',
        Goal.moreEnergy => 'More energy',
        Goal.betterMeals => 'Build better meals',
      };

  String get blurb => switch (this) {
        Goal.feelSatisfied => 'Stop feeling hungry an hour after eating.',
        Goal.moreEnergy => 'Avoid the slump that follows a meal.',
        Goal.betterMeals => 'Round out whatever is already on the plate.',
      };

  IconData get icon => switch (this) {
        Goal.feelSatisfied => LucideIcons.smile,
        Goal.moreEnergy => LucideIcons.zap,
        Goal.betterMeals => LucideIcons.utensils,
      };

  static Goal fromId(String id) => Goal.values.firstWhere(
        (g) => g.id == id,
        orElse: () => Goal.feelSatisfied,
      );
}

/// Dietary and budget preferences. These *filter* suggestions; they never
/// filter what the user says they are eating.
enum DietPref { vegetarian, dairyFree, lowCost, glutenFree }

extension DietPrefLabel on DietPref {
  String get id => switch (this) {
        DietPref.vegetarian => 'vegetarian',
        DietPref.dairyFree => 'dairy_free',
        DietPref.lowCost => 'low_cost',
        DietPref.glutenFree => 'gluten_free',
      };

  String get label => switch (this) {
        DietPref.vegetarian => 'Vegetarian',
        DietPref.dairyFree => 'Dairy-free',
        DietPref.lowCost => 'Low cost',
        DietPref.glutenFree => 'Gluten-free',
      };

  String get blurb => switch (this) {
        DietPref.vegetarian => 'No meat or fish suggestions',
        DietPref.dairyFree => 'No milk, yogurt or cheese',
        DietPref.lowCost => 'Only budget-friendly additions',
        DietPref.glutenFree => 'No wheat, barley or rye',
      };

  IconData get icon => switch (this) {
        DietPref.vegetarian => LucideIcons.leaf,
        DietPref.dairyFree => LucideIcons.milkOff,
        DietPref.lowCost => LucideIcons.wallet,
        DietPref.glutenFree => LucideIcons.wheatOff,
      };

  static DietPref? fromId(String id) {
    for (final p in DietPref.values) {
      if (p.id == id) return p;
    }
    return null;
  }
}

/// How the after-meal check went. Drives light personalisation.
enum Satisfaction { stillHungry, comfortable, tooFull }

extension SatisfactionLabel on Satisfaction {
  String get id => switch (this) {
        Satisfaction.stillHungry => 'still_hungry',
        Satisfaction.comfortable => 'comfortable',
        Satisfaction.tooFull => 'too_full',
      };

  String get label => switch (this) {
        Satisfaction.stillHungry => 'Still hungry',
        Satisfaction.comfortable => 'Comfortably satisfied',
        Satisfaction.tooFull => 'Too full',
      };

  String get emoji => switch (this) {
        Satisfaction.stillHungry => '🤔',
        Satisfaction.comfortable => '😌',
        Satisfaction.tooFull => '😵',
      };

  IconData get icon => switch (this) {
        Satisfaction.stillHungry => LucideIcons.frown,
        Satisfaction.comfortable => LucideIcons.smile,
        Satisfaction.tooFull => LucideIcons.annoyed,
      };

  static Satisfaction fromId(String id) => Satisfaction.values.firstWhere(
        (s) => s.id == id,
        orElse: () => Satisfaction.comfortable,
      );
}

/// A nutrient score triple on a 0-3 scale (none / a little / some / lots).
/// Coarse on purpose: this is a rules app, not a nutrition database.
class NutrientScores {
  const NutrientScores({this.protein = 0, this.fibre = 0, this.fat = 0});

  final int protein;
  final int fibre;
  final int fat;

  int operator [](Nutrient n) => switch (n) {
        Nutrient.protein => protein,
        Nutrient.fibre => fibre,
        Nutrient.healthyFat => fat,
      };

  NutrientScores operator +(NutrientScores other) => NutrientScores(
        protein: protein + other.protein,
        fibre: fibre + other.fibre,
        fat: fat + other.fat,
      );

  static const zero = NutrientScores();

  factory NutrientScores.fromJson(Map<String, dynamic> json) => NutrientScores(
        protein: (json['protein'] as num?)?.toInt() ?? 0,
        fibre: (json['fibre'] as num?)?.toInt() ?? 0,
        fat: (json['fat'] as num?)?.toInt() ?? 0,
      );

  @override
  String toString() => 'NutrientScores(p:$protein, f:$fibre, fat:$fat)';
}

/// Something the user might already be eating.
class FoodItem {
  const FoodItem({
    required this.id,
    required this.name,
    required this.emoji,
    required this.icon,
    required this.group,
    required this.slots,
    required this.provides,
    required this.tags,
    this.collection = 'common',
  });

  final String id;
  final String name;

  /// Kept for saved rows written before the app used icons. Nothing draws it.
  final String emoji;

  /// Lucide icon name. Resolved through `catalogIcon` at the point of drawing.
  final String icon;

  /// Which rail this food sits in on the meal picker.
  final String group;
  final Set<MealSlot> slots;
  final NutrientScores provides;
  final Set<String> tags;

  /// `common` foods are free; other collections (e.g. `mena`) are Pro.
  final String collection;

  bool get isFree => collection == 'common';

  factory FoodItem.fromJson(Map<String, dynamic> json) => FoodItem(
        id: json['id'] as String,
        name: json['name'] as String,
        emoji: json['emoji'] as String? ?? '🍽️',
        icon: json['icon'] as String? ?? 'utensils',
        group: json['group'] as String? ?? 'dishes',
        slots: ((json['slots'] as List?) ?? const [])
            .map((s) => MealSlotLabel.fromId(s as String))
            .toSet(),
        provides:
            NutrientScores.fromJson((json['provides'] as Map?)?.cast<String, dynamic>() ?? const {}),
        tags: ((json['tags'] as List?) ?? const []).map((t) => t as String).toSet(),
        collection: json['collection'] as String? ?? 'common',
      );
}

/// Something Plate One can suggest adding to the plate.
class Addition {
  const Addition({
    required this.id,
    required this.name,
    required this.emoji,
    required this.icon,
    required this.provides,
    required this.speed,
    required this.cost,
    required this.tags,
    required this.slots,
    required this.how,
    this.collection = 'common',
  });

  final String id;

  /// Written as an instruction the user can act on: "Add a small bowl of yogurt".
  final String name;

  /// Kept for saved rows written before the app used icons. Nothing draws it.
  final String emoji;

  /// Lucide icon name.
  final String icon;
  final NutrientScores provides;

  /// 1 = grab it now, 2 = a minute of prep, 3 = needs cooking.
  final int speed;

  /// 1 = cheap, 2 = mid, 3 = pricier.
  final int cost;
  final Set<String> tags;
  final Set<MealSlot> slots;

  /// Concrete portion guidance. Never a weight, never a calorie count.
  final String how;
  final String collection;

  bool get isPlantBased => tags.contains('plant');

  bool get isFree => collection == 'common';

  factory Addition.fromJson(Map<String, dynamic> json) => Addition(
        id: json['id'] as String,
        name: json['name'] as String,
        emoji: json['emoji'] as String? ?? '🥄',
        icon: json['icon'] as String? ?? 'utensils',
        provides:
            NutrientScores.fromJson((json['provides'] as Map?)?.cast<String, dynamic>() ?? const {}),
        speed: (json['speed'] as num?)?.toInt() ?? 2,
        cost: (json['cost'] as num?)?.toInt() ?? 2,
        tags: ((json['tags'] as List?) ?? const []).map((t) => t as String).toSet(),
        slots: ((json['slots'] as List?) ?? const [])
            .map((s) => MealSlotLabel.fromId(s as String))
            .toSet(),
        how: json['how'] as String? ?? '',
        collection: json['collection'] as String? ?? 'common',
      );
}

/// Why a particular addition was chosen, and what angle it won on.
enum PickAngle { fastest, cheapest, plantBased }

extension PickAngleLabel on PickAngle {
  String get label => switch (this) {
        PickAngle.fastest => 'Fastest',
        PickAngle.cheapest => 'Cheapest',
        PickAngle.plantBased => 'Plant-based',
      };

  String get emoji => switch (this) {
        PickAngle.fastest => '⚡',
        PickAngle.cheapest => '💰',
        PickAngle.plantBased => '🌱',
      };

  IconData get icon => switch (this) {
        PickAngle.fastest => LucideIcons.zap,
        PickAngle.cheapest => LucideIcons.wallet,
        PickAngle.plantBased => LucideIcons.leaf,
      };
}

/// The rails the meal picker groups foods into. Order is the order they appear.
class FoodGroup {
  const FoodGroup(this.id, this.label, this.icon);

  final String id;
  final String label;
  final IconData icon;

  static const all = [
    FoodGroup('grains', 'Breads & grains', LucideIcons.wheat),
    FoodGroup('protein', 'Meat, fish & eggs', LucideIcons.drumstick),
    FoodGroup('dairy', 'Dairy', LucideIcons.milk),
    FoodGroup('veg', 'Vegetables & pulses', LucideIcons.carrot),
    FoodGroup('fruit', 'Fruit & nuts', LucideIcons.apple),
    FoodGroup('dishes', 'Made dishes', LucideIcons.pizza),
    FoodGroup('sweets', 'Sweet things & snacks', LucideIcons.cookie),
    FoodGroup('drinks', 'Drinks', LucideIcons.coffee),
  ];

  /// The single rail the Pro collections collapse into for a free user.
  static const locked =
      FoodGroup('pro', 'Egyptian, MENA & world', LucideIcons.globe);
}

class Patch {
  const Patch({required this.angle, required this.addition, required this.reason});

  final PickAngle angle;
  final Addition addition;

  /// One sentence tying this addition to the gap it fills.
  final String reason;
}

/// The full result of patching one meal.
class PatchResult {
  const PatchResult({
    required this.slot,
    required this.foods,
    required this.totals,
    required this.gaps,
    required this.patches,
    required this.headline,
  });

  final MealSlot slot;
  final List<FoodItem> foods;
  final NutrientScores totals;

  /// Missing nutrients, most important first. Empty when the plate is balanced.
  final List<Nutrient> gaps;
  final List<Patch> patches;

  /// The "what may be missing" line shown at the top of the result screen.
  final String headline;

  bool get isBalanced => gaps.isEmpty;
}

/// One saved meal plus its optional after-meal check.
class SavedPatch {
  const SavedPatch({
    required this.id,
    required this.savedAt,
    required this.slot,
    required this.foodIds,
    required this.additionId,
    required this.additionName,
    required this.additionEmoji,
    required this.gapIds,
    this.satisfaction,
    this.imagePath,
  });

  final String id;
  final DateTime savedAt;
  final MealSlot slot;
  final List<String> foodIds;
  final String additionId;
  final String additionName;
  final String additionEmoji;
  final List<String> gapIds;
  final Satisfaction? satisfaction;

  /// File name of the picture kept for this patch, or null where there was
  /// none. Resolved through [PatchImages]; the path itself is never stored, so
  /// the app's directory moving between OS versions cannot orphan it.
  final String? imagePath;

  SavedPatch withSatisfaction(Satisfaction s) => SavedPatch(
        id: id,
        savedAt: savedAt,
        slot: slot,
        foodIds: foodIds,
        additionId: additionId,
        additionName: additionName,
        additionEmoji: additionEmoji,
        gapIds: gapIds,
        satisfaction: s,
        imagePath: imagePath,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'savedAt': savedAt.toIso8601String(),
        'slot': slot.id,
        'foodIds': foodIds,
        'additionId': additionId,
        'additionName': additionName,
        'additionEmoji': additionEmoji,
        'gapIds': gapIds,
        if (satisfaction != null) 'satisfaction': satisfaction!.id,
        if (imagePath != null) 'imagePath': imagePath,
      };

  factory SavedPatch.fromJson(Map<String, dynamic> json) => SavedPatch(
        id: json['id'] as String,
        savedAt: DateTime.tryParse(json['savedAt'] as String? ?? '') ?? DateTime.now(),
        slot: MealSlotLabel.fromId(json['slot'] as String? ?? 'lunch_dinner'),
        foodIds: ((json['foodIds'] as List?) ?? const []).map((e) => e as String).toList(),
        additionId: json['additionId'] as String? ?? '',
        additionName: json['additionName'] as String? ?? '',
        additionEmoji: json['additionEmoji'] as String? ?? '🥄',
        gapIds: ((json['gapIds'] as List?) ?? const []).map((e) => e as String).toList(),
        satisfaction: json['satisfaction'] == null
            ? null
            : SatisfactionLabel.fromId(json['satisfaction'] as String),
        imagePath: json['imagePath'] as String?,
      );
}
