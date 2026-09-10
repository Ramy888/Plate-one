import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plateone/domain/models.dart';
import 'package:plateone/domain/patch_engine.dart';

/// These run against the JSON that actually ships in the bundle. If the
/// catalogue is edited into a state where some real combination of meal,
/// goal and preferences produces no suggestion, that is a broken app for that
/// user — so it has to fail here, not in the store.
List<dynamic> _load(String name) =>
    jsonDecode(File('assets/data/$name.json').readAsStringSync()) as List<dynamic>;

void main() {
  final foods = _load('foods').map((j) => FoodItem.fromJson(j as Map<String, dynamic>)).toList();
  final additions =
      _load('additions').map((j) => Addition.fromJson(j as Map<String, dynamic>)).toList();
  final engine = PatchEngine(additions: additions);

  group('catalogue integrity', () {
    test('ids are unique', () {
      expect(foods.map((f) => f.id).toSet(), hasLength(foods.length));
      expect(additions.map((a) => a.id).toSet(), hasLength(additions.length));
    });

    test('every food belongs to at least one meal slot', () {
      for (final f in foods) {
        expect(f.slots, isNotEmpty, reason: '${f.id} has no slots');
      }
    });

    test('every addition belongs to at least one meal slot', () {
      for (final a in additions) {
        expect(a.slots, isNotEmpty, reason: '${a.id} has no slots');
      }
    });

    test('nutrient scores stay on the 0-3 scale', () {
      for (final f in foods) {
        for (final n in Nutrient.values) {
          expect(f.provides[n], inInclusiveRange(0, 3), reason: '${f.id} ${n.id}');
        }
      }
      for (final a in additions) {
        for (final n in Nutrient.values) {
          expect(a.provides[n], inInclusiveRange(0, 3), reason: '${a.id} ${n.id}');
        }
      }
    });

    test('speed and cost stay on the 1-3 scale', () {
      for (final a in additions) {
        expect(a.speed, inInclusiveRange(1, 3), reason: '${a.id} speed');
        expect(a.cost, inInclusiveRange(1, 3), reason: '${a.id} cost');
      }
    });

    test('every addition carries usable portion guidance', () {
      for (final a in additions) {
        expect(a.how, isNotEmpty, reason: '${a.id} has no "how"');
        expect(a.name.toLowerCase(), anyOf(startsWith('add'), startsWith('swap'),
            startsWith('stir'), startsWith('drizzle'), startsWith('sprinkle')),
            reason: '${a.id} should read as an instruction');
      }
    });

    test('collections are ones the app knows how to gate', () {
      const knownFood = {'common', 'mena', 'world'};
      const knownAddition = {'common', 'pro'};
      for (final f in foods) {
        expect(knownFood, contains(f.collection), reason: f.id);
      }
      for (final a in additions) {
        expect(knownAddition, contains(a.collection), reason: a.id);
      }
    });

    test('no copy mentions calories, weighing or macros', () {
      final copy = [
        ...foods.map((f) => f.name),
        ...additions.map((a) => '${a.name} ${a.how}'),
      ].join(' ').toLowerCase();
      for (final banned in ['calorie', 'kcal', 'macro', 'weigh ', 'grams']) {
        expect(copy, isNot(contains(banned)));
      }
    });
  });

  group('every free user gets a usable answer', () {
    // The free tier is what most judges and most users will actually see, so
    // it is the tier that must never dead-end.
    for (final slot in MealSlot.values) {
      final slotFoods = foods.where((f) => f.isFree && f.slots.contains(slot)).toList();

      test('${slot.id}: free catalogue offers foods to pick', () {
        expect(slotFoods.length, greaterThanOrEqualTo(6));
      });

      for (final goal in Goal.values) {
        test('${slot.id} + ${goal.id}: a bare carb plate still gets three cards', () {
          // Worst realistic case: the emptiest food in the slot.
          final bare = slotFoods.reduce((a, b) =>
              (a.provides.protein + a.provides.fibre + a.provides.fat) <=
                      (b.provides.protein + b.provides.fibre + b.provides.fat)
                  ? a
                  : b);
          final r = engine.patch(slot: slot, foods: [bare], goal: goal);
          expect(r.patches, hasLength(3), reason: '${slot.id}/${goal.id}/${bare.id}');
          expect(r.patches.map((p) => p.addition.id).toSet(), hasLength(3));
        });
      }
    }
  });

  group('every preference combination still gets an answer', () {
    // Powerset of the four preferences: 16 combinations, checked on the
    // hardest slot for each. A free vegetarian, dairy-free, low-cost,
    // gluten-free user must still be told something useful.
    final combos = <Set<DietPref>>[];
    for (var mask = 0; mask < 1 << DietPref.values.length; mask++) {
      combos.add({
        for (var i = 0; i < DietPref.values.length; i++)
          if (mask & (1 << i) != 0) DietPref.values[i],
      });
    }

    for (final slot in MealSlot.values) {
      for (final combo in combos) {
        final label = combo.isEmpty ? 'no prefs' : combo.map((p) => p.id).join('+');
        test('${slot.id} / $label yields at least one suggestion', () {
          final bare = foods.firstWhere((f) => f.isFree && f.slots.contains(slot));
          final r = engine.patch(
            slot: slot,
            foods: [bare],
            goal: Goal.feelSatisfied,
            prefs: combo,
          );
          expect(r.patches, isNotEmpty, reason: '$label on ${slot.id} dead-ends');
          for (final p in r.patches) {
            expect(PatchEngine.blockedByPrefs(p.addition, combo), isFalse,
                reason: '${p.addition.id} violates $label');
          }
        });
      }
    }
  });

  group('pro tier adds real value', () {
    test('pro unlocks meaningfully more additions', () {
      final free = additions.where((a) => a.isFree).length;
      final pro = additions.length;
      expect(pro, greaterThan(free));
      expect(free, greaterThanOrEqualTo(12), reason: 'free tier must not feel crippled');
    });

    test('pro unlocks extra food collections', () {
      expect(foods.where((f) => !f.isFree).length, greaterThanOrEqualTo(10));
    });
  });
}
