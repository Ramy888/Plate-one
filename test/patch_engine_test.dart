import 'package:flutter_test/flutter_test.dart';
import 'package:plateone/domain/models.dart';
import 'package:plateone/domain/patch_engine.dart';

/// Small hand-built catalogue so each test controls exactly one variable.
Addition _add(
  String id, {
  int protein = 0,
  int fibre = 0,
  int fat = 0,
  int speed = 2,
  int cost = 2,
  Set<String> tags = const {},
  Set<MealSlot> slots = const {MealSlot.lunchDinner},
  String collection = 'common',
}) =>
    Addition(
      id: id,
      name: 'Add $id',
      emoji: '🥄',
      icon: 'utensils',
      provides: NutrientScores(protein: protein, fibre: fibre, fat: fat),
      speed: speed,
      cost: cost,
      tags: tags,
      slots: slots,
      how: 'how $id',
      collection: collection,
    );

FoodItem _food(
  String id, {
  int protein = 0,
  int fibre = 0,
  int fat = 0,
  Set<MealSlot> slots = const {MealSlot.lunchDinner},
}) =>
    FoodItem(
      id: id,
      name: id,
      emoji: '🍽️',
      icon: 'utensils',
      group: 'dishes',
      slots: slots,
      provides: NutrientScores(protein: protein, fibre: fibre, fat: fat),
      tags: const {},
    );

/// Covers every angle so picks are never starved in the general-purpose tests.
final _catalogue = <Addition>[
  _add('quick_protein', protein: 3, speed: 1, cost: 2, tags: {'dairy'}),
  _add('cheap_protein', protein: 3, speed: 3, cost: 1, tags: {'meat'}),
  _add('plant_protein', protein: 3, fibre: 3, speed: 2, cost: 2, tags: {'plant'}),
  _add('quick_fibre', fibre: 3, speed: 1, cost: 3, tags: {'plant'}),
  _add('cheap_fat', fat: 3, speed: 2, cost: 1, tags: {'plant'}),
  _add('fatty_fish', protein: 3, fat: 3, speed: 1, cost: 3, tags: {'fish'}),
];

final _engine = PatchEngine(additions: _catalogue);

PatchResult _run({
  List<FoodItem> foods = const [],
  Goal goal = Goal.feelSatisfied,
  Set<DietPref> prefs = const {},
  HistoryInsight insight = HistoryInsight.none,
  bool isPro = false,
  MealSlot slot = MealSlot.lunchDinner,
}) =>
    _engine.patch(
      slot: slot,
      foods: foods,
      goal: goal,
      prefs: prefs,
      insight: insight,
      isPro: isPro,
    );

void main() {
  group('gap detection', () {
    test('plain rice is short of all three nutrients', () {
      final r = _run(foods: [_food('rice')]);
      expect(r.gaps, containsAll(Nutrient.values));
      expect(r.isBalanced, isFalse);
    });

    test('a plate meeting every threshold has no gaps', () {
      final r = _run(foods: [_food('big_plate', protein: 3, fibre: 3, fat: 2)]);
      expect(r.gaps, isEmpty);
      expect(r.isBalanced, isTrue);
      expect(r.headline, contains('already covers'));
    });

    test('nutrients accumulate across several foods', () {
      final r = _run(foods: [
        _food('rice'),
        _food('chicken', protein: 3),
        _food('salad', fibre: 3),
      ]);
      expect(r.totals.protein, 3);
      expect(r.totals.fibre, 3);
      expect(r.gaps, [Nutrient.healthyFat]);
    });

    test('a nutrient exactly at its threshold is not a gap', () {
      final r = _run(foods: [_food('exact', protein: 3)]);
      expect(r.gaps, isNot(contains(Nutrient.protein)));
    });
  });

  group('goal changes which gap leads', () {
    // Protein and fibre are equally short here, so only the goal breaks the tie.
    final plate = [_food('rice')];

    test('feel satisfied puts protein first', () {
      expect(_run(foods: plate, goal: Goal.feelSatisfied).gaps.first, Nutrient.protein);
    });

    test('more energy puts fibre first', () {
      expect(_run(foods: plate, goal: Goal.moreEnergy).gaps.first, Nutrient.fibre);
    });

    test('build better meals falls back to raw severity order', () {
      final r = _run(foods: plate, goal: Goal.betterMeals);
      expect(r.gaps.first, Nutrient.protein); // equal severity, priority order wins
      expect(r.gaps.last, Nutrient.healthyFat); // smallest threshold, smallest gap
    });
  });

  group('preferences filter suggestions', () {
    test('vegetarian removes meat and fish', () {
      final r = _run(foods: [_food('rice')], prefs: {DietPref.vegetarian});
      final ids = r.patches.map((p) => p.addition.id);
      expect(ids, isNot(contains('cheap_protein')));
      expect(ids, isNot(contains('fatty_fish')));
    });

    test('dairy-free removes dairy', () {
      final r = _run(foods: [_food('rice')], prefs: {DietPref.dairyFree});
      expect(r.patches.map((p) => p.addition.id), isNot(contains('quick_protein')));
    });

    test('low cost removes the priciest tier', () {
      final r = _run(foods: [_food('rice')], prefs: {DietPref.lowCost});
      expect(r.patches.every((p) => p.addition.cost < 3), isTrue);
    });

    test('preferences stack', () {
      final r = _run(
        foods: [_food('rice')],
        prefs: {DietPref.vegetarian, DietPref.dairyFree, DietPref.lowCost},
      );
      for (final p in r.patches) {
        expect(p.addition.tags.intersection({'meat', 'fish', 'dairy'}), isEmpty);
        expect(p.addition.cost, lessThan(3));
      }
    });
  });

  group('the three picks', () {
    test('returns one card per angle, all different', () {
      final r = _run(foods: [_food('rice')]);
      expect(r.patches, hasLength(3));
      expect(r.patches.map((p) => p.angle), PickAngle.values);
      expect(r.patches.map((p) => p.addition.id).toSet(), hasLength(3));
    });

    test('the fastest card is the quickest of the picks', () {
      final r = _run(foods: [_food('rice')]);
      final fastest = r.patches.firstWhere((p) => p.angle == PickAngle.fastest);
      expect(fastest.addition.speed, 1);
    });

    test('the cheapest card is not beaten on price by the others', () {
      final r = _run(foods: [_food('rice')]);
      final cheapest = r.patches.firstWhere((p) => p.angle == PickAngle.cheapest);
      final others = r.patches.where((p) => p.angle != PickAngle.cheapest);
      expect(others.every((p) => p.addition.cost >= cheapest.addition.cost), isTrue);
    });

    test('the plant-based card is plant-based when one is available', () {
      final r = _run(foods: [_food('rice')]);
      final plant = r.patches.firstWhere((p) => p.angle == PickAngle.plantBased);
      expect(plant.addition.isPlantBased, isTrue);
    });

    test('an addition already on the plate is never suggested', () {
      final r = _run(foods: [_food('rice'), _food('plant_protein', protein: 3, fibre: 3)]);
      expect(r.patches.map((p) => p.addition.id), isNot(contains('plant_protein')));
    });

    test('a balanced plate gets no cards to push', () {
      final r = _run(foods: [_food('big_plate', protein: 3, fibre: 3, fat: 2)]);
      expect(r.patches, isEmpty);
    });

    test('suggestions never exceed what the gap actually needs', () {
      // Only fat is short. The fat-only option should out-rank protein bombs
      // on the plant angle, because surplus protein scores nothing.
      final r = _run(foods: [_food('plate', protein: 3, fibre: 3)]);
      final plant = r.patches.firstWhere((p) => p.angle == PickAngle.plantBased);
      expect(plant.addition.id, 'cheap_fat');
    });

    test('the same inputs always produce the same output', () {
      final a = _run(foods: [_food('rice')]);
      final b = _run(foods: [_food('rice')]);
      expect(
        a.patches.map((p) => p.addition.id).toList(),
        b.patches.map((p) => p.addition.id).toList(),
      );
    });
  });

  group('pro gating', () {
    final proEngine = PatchEngine(additions: [
      _add('free_one', protein: 3, speed: 2, cost: 2, tags: {'plant'}),
      _add('pro_one', protein: 3, speed: 1, cost: 1, tags: {'plant'}, collection: 'pro'),
    ]);

    test('free users never see pro additions', () {
      final r = proEngine.patch(
        slot: MealSlot.lunchDinner,
        foods: [_food('rice')],
        goal: Goal.feelSatisfied,
      );
      expect(r.patches.map((p) => p.addition.id), isNot(contains('pro_one')));
    });

    test('pro users do', () {
      final r = proEngine.patch(
        slot: MealSlot.lunchDinner,
        foods: [_food('rice')],
        goal: Goal.feelSatisfied,
        isPro: true,
      );
      expect(r.patches.map((p) => p.addition.id), contains('pro_one'));
    });
  });

  group('meal slot', () {
    test('breakfast-only additions do not show up at dinner', () {
      final engine = PatchEngine(additions: [
        _add('breakfast_only', protein: 3, slots: {MealSlot.breakfast}, tags: {'plant'}),
      ]);
      final r = engine.patch(
        slot: MealSlot.lunchDinner,
        foods: [_food('rice')],
        goal: Goal.feelSatisfied,
      );
      expect(r.patches, isEmpty);
    });
  });

  group('history insight', () {
    SavedPatch check(Satisfaction s) => SavedPatch(
          id: s.id,
          savedAt: DateTime(2026, 9, 1),
          slot: MealSlot.lunchDinner,
          foodIds: const [],
          additionId: 'x',
          additionName: 'x',
          additionEmoji: '🥄',
          gapIds: const [],
          satisfaction: s,
        );

    test('fewer than two checks is not enough to conclude anything', () {
      final insight = HistoryInsight.fromHistory([check(Satisfaction.stillHungry)]);
      expect(insight.leanProtein, isFalse);
    });

    test('mostly still-hungry leans on protein', () {
      final insight = HistoryInsight.fromHistory([
        check(Satisfaction.stillHungry),
        check(Satisfaction.stillHungry),
        check(Satisfaction.comfortable),
      ]);
      expect(insight.leanProtein, isTrue);
    });

    test('unanswered checks are ignored', () {
      final unanswered = SavedPatch(
        id: 'u',
        savedAt: DateTime(2026, 9, 1),
        slot: MealSlot.lunchDinner,
        foodIds: const [],
        additionId: 'x',
        additionName: 'x',
        additionEmoji: '🥄',
        gapIds: const [],
      );
      final insight = HistoryInsight.fromHistory([unanswered, unanswered]);
      expect(insight.leanProtein, isFalse);
      expect(insight.leanLighter, isFalse);
    });

    test('leaning on protein can overturn the goal ordering', () {
      final r = _run(
        foods: [_food('rice')],
        goal: Goal.moreEnergy, // normally puts fibre first
        insight: const HistoryInsight(leanProtein: true),
      );
      expect(r.gaps.first, Nutrient.protein);
      expect(r.headline, contains('ending up hungry'));
    });
  });

  group('headline copy', () {
    test('names a single gap', () {
      final r = _run(foods: [_food('plate', protein: 3, fibre: 3)]);
      expect(r.headline, 'This looks light on healthy fats.');
    });

    test('joins several gaps readably', () {
      final r = _run(foods: [_food('rice')]);
      expect(r.headline, contains(' and '));
      expect(r.headline, isNot(contains(',,')));
    });

    test('a card names the gaps it closes, without repeating the headline', () {
      final r = _run(foods: [_food('rice')]);
      final plant = r.patches.firstWhere((p) => p.angle == PickAngle.plantBased);
      expect(plant.reason, 'Covers protein and fibre.');
      // The "why it helps" sentence lives on the headline only.
      for (final p in r.patches) {
        expect(p.reason, isNot(contains(Nutrient.protein.benefit)));
      }
    });

    test('never mentions calories or weight', () {
      final r = _run(foods: [_food('rice')]);
      final text = [r.headline, ...r.patches.map((p) => p.reason)].join(' ').toLowerCase();
      for (final banned in ['calorie', 'gram', 'kcal', 'weigh', 'macro']) {
        expect(text, isNot(contains(banned)));
      }
    });
  });

  group('alternates', () {
    test('are what the same angles would have picked next', () {
      // Not an arbitrary tail of the catalogue: each round is the three angles
      // choosing again from what is left, so a second choice is a real one.
      final result = _run(foods: [_food('rice')], isPro: true);

      expect(result.patches, isNotEmpty);
      expect(result.alternates, isNotEmpty);

      final shown = result.patches.map((p) => p.addition.id).toSet();
      final extra = result.alternates.map((p) => p.addition.id).toList();
      expect(extra.toSet().intersection(shown), isEmpty,
          reason: 'an alternate that is already on screen is not an alternative');
      expect(extra.toSet(), hasLength(extra.length), reason: 'no repeats');
    });

    test('carry a reason, the same as the first three do', () {
      final result = _run(foods: [_food('rice')], isPro: true);
      for (final patch in result.alternates) {
        expect(patch.reason, isNotEmpty, reason: patch.addition.name);
      }
    });

    test('are empty when there is nothing to patch', () {
      final balanced = _run(
        foods: [_food('big_plate', protein: 3, fibre: 3, fat: 2)],
        isPro: true,
      );
      expect(balanced.patches, isEmpty);
      expect(balanced.alternates, isEmpty);
    });
  });
}
