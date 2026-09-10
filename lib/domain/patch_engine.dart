import 'models.dart';

/// Light personalisation derived from the user's after-meal checks.
/// Nothing clever: if someone keeps ending up hungry, lean harder on protein.
class HistoryInsight {
  const HistoryInsight({this.leanProtein = false, this.leanLighter = false});

  /// The user reported "still hungry" more often than not recently.
  final bool leanProtein;

  /// The user reported "too full" more often than not recently.
  final bool leanLighter;

  static const none = HistoryInsight();

  /// Looks at the most recent [window] checks only — a month-old meal should
  /// not steer today's suggestion.
  factory HistoryInsight.fromHistory(List<SavedPatch> history, {int window = 5}) {
    final checked = history.where((h) => h.satisfaction != null).take(window).toList();
    if (checked.length < 2) return none;
    final hungry = checked.where((h) => h.satisfaction == Satisfaction.stillHungry).length;
    final full = checked.where((h) => h.satisfaction == Satisfaction.tooFull).length;
    return HistoryInsight(
      leanProtein: hungry * 2 >= checked.length,
      leanLighter: full * 2 >= checked.length,
    );
  }
}

/// Turns "here is what I am eating" into "here is one thing to add".
///
/// Pure and deterministic: same inputs always produce the same patches, which
/// is what makes it testable and what keeps the demo predictable.
class PatchEngine {
  const PatchEngine({required this.additions});

  final List<Addition> additions;

  /// A plate is considered short of a nutrient below these totals.
  /// Scores are the coarse 0-3 scale from [NutrientScores].
  static const _thresholds = {
    Nutrient.protein: 3,
    Nutrient.fibre: 3,
    Nutrient.healthyFat: 2,
  };

  /// Fixed tie-break order when two gaps score identically.
  static const _priority = [Nutrient.protein, Nutrient.fibre, Nutrient.healthyFat];

  /// How much each successive gap counts when scoring a candidate.
  static const _gapRankWeights = [1.0, 0.6, 0.3];

  PatchResult patch({
    required MealSlot slot,
    required List<FoodItem> foods,
    required Goal goal,
    Set<DietPref> prefs = const {},
    HistoryInsight insight = HistoryInsight.none,
    bool isPro = false,
  }) {
    final totals = foods.fold(NutrientScores.zero, (sum, f) => sum + f.provides);
    final severity = _severity(totals);
    final gaps = _rankGaps(severity, goal, insight);

    final candidates = _candidates(slot: slot, foods: foods, prefs: prefs, isPro: isPro);
    final scored = <Addition, double>{};
    for (final a in candidates) {
      final score = _coverage(a, gaps, severity);
      if (score > 0) scored[a] = score;
    }

    return PatchResult(
      slot: slot,
      foods: foods,
      totals: totals,
      gaps: gaps,
      patches: _pick(scored, gaps, severity),
      headline: _headline(gaps, insight),
    );
  }

  Map<Nutrient, int> _severity(NutrientScores totals) => {
        for (final n in Nutrient.values)
          n: (_thresholds[n]! - totals[n]).clamp(0, _thresholds[n]!),
      };

  /// Gaps, worst first. The goal and the user's recent history tilt the order
  /// but never invent a gap that isn't there.
  List<Nutrient> _rankGaps(Map<Nutrient, int> severity, Goal goal, HistoryInsight insight) {
    final open = _priority.where((n) => severity[n]! > 0).toList();
    open.sort((a, b) {
      final byWeight = (severity[b]! * _goalWeight(b, goal, insight))
          .compareTo(severity[a]! * _goalWeight(a, goal, insight));
      if (byWeight != 0) return byWeight;
      return _priority.indexOf(a).compareTo(_priority.indexOf(b));
    });
    return open;
  }

  double _goalWeight(Nutrient n, Goal goal, HistoryInsight insight) {
    var w = switch (goal) {
      Goal.feelSatisfied => switch (n) {
          Nutrient.protein => 1.4,
          Nutrient.fibre => 1.1,
          Nutrient.healthyFat => 1.0,
        },
      Goal.moreEnergy => switch (n) {
          Nutrient.protein => 1.2,
          Nutrient.fibre => 1.4,
          Nutrient.healthyFat => 1.0,
        },
      Goal.betterMeals => 1.0,
    };
    if (insight.leanProtein && n == Nutrient.protein) w *= 1.3;
    return w;
  }

  List<Addition> _candidates({
    required MealSlot slot,
    required List<FoodItem> foods,
    required Set<DietPref> prefs,
    required bool isPro,
  }) {
    final onPlate = foods.map((f) => f.id).toSet();
    return additions.where((a) {
      if (!a.slots.contains(slot)) return false;
      if (onPlate.contains(a.id)) return false;
      if (!isPro && !a.isFree) return false;
      if (blockedByPrefs(a, prefs)) return false;
      return true;
    }).toList();
  }

  /// Preference filtering. Exposed for tests — the rules here are the ones a
  /// user will notice immediately if they break.
  static bool blockedByPrefs(Addition a, Set<DietPref> prefs) {
    if (prefs.contains(DietPref.vegetarian) &&
        (a.tags.contains('meat') || a.tags.contains('fish'))) {
      return true;
    }
    if (prefs.contains(DietPref.dairyFree) && a.tags.contains('dairy')) return true;
    if (prefs.contains(DietPref.glutenFree) && a.tags.contains('gluten')) return true;
    if (prefs.contains(DietPref.lowCost) && a.cost >= 3) return true;
    return false;
  }

  /// How well one addition fills the ranked gaps. Contribution beyond what the
  /// gap actually needs is ignored, so a protein bomb doesn't win a fibre gap.
  double _coverage(Addition a, List<Nutrient> gaps, Map<Nutrient, int> severity) {
    var score = 0.0;
    for (var i = 0; i < gaps.length; i++) {
      final n = gaps[i];
      final weight = i < _gapRankWeights.length ? _gapRankWeights[i] : 0.2;
      final useful = a.provides[n].clamp(0, severity[n]!);
      score += weight * useful;
    }
    return score;
  }

  /// Angles resolved most-constrained first. "Plant-based" can only be filled
  /// by a plant option, so it chooses before the angles that can take anything
  /// — otherwise a thin candidate list leaves the plant card empty.
  static const _resolveOrder = [PickAngle.plantBased, PickAngle.fastest, PickAngle.cheapest];

  /// Up to three distinct additions, one per angle, returned in display order.
  /// When the candidate list is too thin to fill every angle, fewer cards are
  /// returned rather than the same addition twice.
  List<Patch> _pick(Map<Addition, double> scored, List<Nutrient> gaps, Map<Nutrient, int> severity) {
    if (scored.isEmpty) return const [];

    final taken = <String>{};
    final patches = <Patch>[];

    for (final angle in _resolveOrder) {
      final pool = scored.keys.where((a) {
        if (taken.contains(a.id)) return false;
        // The plant card must actually be plant-based. Better to show two
        // honest cards than three where one is mislabelled.
        if (angle == PickAngle.plantBased && !a.isPlantBased) return false;
        return true;
      }).toList();

      final chosen = _best(pool, scored, angle);
      if (chosen == null) continue;

      taken.add(chosen.id);
      patches.add(Patch(
        angle: angle,
        addition: chosen,
        reason: _reason(chosen, gaps, severity),
      ));
    }

    patches.sort((a, b) =>
        PickAngle.values.indexOf(a.angle).compareTo(PickAngle.values.indexOf(b.angle)));
    return patches;
  }

  Addition? _best(List<Addition> pool, Map<Addition, double> scored, PickAngle angle) {
    if (pool.isEmpty) return null;
    final sorted = [...pool]..sort((a, b) {
        final primary = switch (angle) {
          PickAngle.fastest => a.speed.compareTo(b.speed),
          PickAngle.cheapest => a.cost.compareTo(b.cost),
          PickAngle.plantBased => 0,
        };
        if (primary != 0) return primary;
        final byScore = scored[b]!.compareTo(scored[a]!);
        if (byScore != 0) return byScore;
        return a.id.compareTo(b.id); // deterministic final tie-break
      });
    return sorted.first;
  }

  /// The one-line "why this" under each card. It names the gaps this addition
  /// actually closes — the *why does it help* sentence belongs to the headline,
  /// and repeating it on all three cards reads like filler.
  String _reason(Addition a, List<Nutrient> gaps, Map<Nutrient, int> severity) {
    final covered = [
      for (final n in gaps)
        if (a.provides[n].clamp(0, severity[n]!) > 0) n.label,
    ];
    if (covered.isEmpty) return 'Rounds the plate out a little more.';
    final joined = covered.length == 1
        ? covered.first
        : '${covered.take(covered.length - 1).join(', ')} and ${covered.last}';
    return 'Covers $joined.';
  }

  String _headline(List<Nutrient> gaps, HistoryInsight insight) {
    if (gaps.isEmpty) {
      return 'This plate already covers protein, fibre and healthy fats.';
    }
    final names = gaps.map((g) => g.label).toList();
    final joined = names.length == 1
        ? names.first
        : '${names.take(names.length - 1).join(', ')} and ${names.last}';
    final lead = insight.leanProtein && gaps.first == Nutrient.protein
        ? 'You have been ending up hungry, and this looks light on'
        : 'This looks light on';
    return '$lead $joined.';
  }
}
