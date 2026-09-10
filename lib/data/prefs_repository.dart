import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/models.dart';

/// Everything Plate One remembers about your meals, kept on the device. None of
/// it is uploaded. There is no account and nothing to sync — the only thing the
/// server knows is an anonymous id with a call count against it.
class PrefsRepository {
  PrefsRepository(this._prefs);

  final SharedPreferences _prefs;

  static const _kOnboarded = 'onboarded';
  static const _kGoal = 'goal';
  static const _kDietPrefs = 'diet_prefs';
  static const _kHistory = 'history';
  static const _kDeviceToken = 'device_token';
  static const _kChat = 'chat';

  /// How many saved meals a free user keeps. Older ones are not deleted — they
  /// stay on the device and come back if the user upgrades.
  static const freeSavedLimit = 3;

  bool get onboarded => _prefs.getBool(_kOnboarded) ?? false;

  Future<void> setOnboarded(bool value) => _prefs.setBool(_kOnboarded, value);

  Goal get goal => GoalLabel.fromId(_prefs.getString(_kGoal) ?? Goal.feelSatisfied.id);

  Future<void> setGoal(Goal goal) => _prefs.setString(_kGoal, goal.id);

  Set<DietPref> get dietPrefs => (_prefs.getStringList(_kDietPrefs) ?? const [])
      .map(DietPrefLabel.fromId)
      .whereType<DietPref>()
      .toSet();

  Future<void> setDietPrefs(Set<DietPref> prefs) =>
      _prefs.setStringList(_kDietPrefs, prefs.map((p) => p.id).toList());

  /// Newest first. Corrupt entries are dropped rather than crashing the app —
  /// a bad row in local history must never make Plate One unlaunchable.
  List<SavedPatch> get history {
    final raw = _prefs.getStringList(_kHistory) ?? const [];
    final out = <SavedPatch>[];
    for (final row in raw) {
      try {
        out.add(SavedPatch.fromJson(jsonDecode(row) as Map<String, dynamic>));
      } on FormatException {
        continue;
      } on TypeError {
        continue;
      }
    }
    out.sort((a, b) => b.savedAt.compareTo(a.savedAt));
    return out;
  }

  /// The chat transcript, oldest first. Words only — a reply's picture lives
  /// in memory for the session and is deliberately not written to disk, since
  /// the server deletes its copy within a day anyway.
  List<String> get chatJson => _prefs.getStringList(_kChat) ?? const [];

  Future<void> setChatJson(List<String> rows) => _prefs.setStringList(_kChat, rows);

  Future<void> setHistory(List<SavedPatch> history) => _prefs.setStringList(
        _kHistory,
        history.map((h) => jsonEncode(h.toJson())).toList(),
      );

  /// The anonymous device token issued by the API. Not an account: there is
  /// nothing to sign into and it identifies an allowance, not a person.
  String? get deviceToken {
    final value = _prefs.getString(_kDeviceToken);
    return (value == null || value.isEmpty) ? null : value;
  }

  Future<void> setDeviceToken(String? token) => token == null
      ? _prefs.remove(_kDeviceToken)
      : _prefs.setString(_kDeviceToken, token);

  static Future<PrefsRepository> open() async =>
      PrefsRepository(await SharedPreferences.getInstance());
}
