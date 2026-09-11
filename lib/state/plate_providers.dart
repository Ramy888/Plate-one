import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api.dart';
import 'api_providers.dart';

/// The written-up, drawn version of one patch.
///
/// The rules engine has already decided *what* to add — that is where the
/// dietary preferences, the Pro gating and the no-numbers rule live, and it
/// works with no network at all. This asks for the words and the picture of
/// that decision, and everything it adds is optional: with no network, or after
/// the trial, the page still shows the whole answer, just without the polish.
class PlateVisual {
  const PlateVisual({
    this.messageId = '',
    this.caption = '',
    this.image,
    this.loading = false,
    this.unavailable = false,
    this.blocked = false,
    this.granted,
  });

  /// What a rating or a report is filed against. Empty until one arrives.
  final String messageId;

  /// A sentence about this plate. Empty falls back to the engine's own reason.
  final String caption;
  final Uint8List? image;

  final bool loading;

  /// The picture could not be drawn. Not an error worth a dialog.
  final bool unavailable;

  /// Today's free try is used, so there is nothing to draw with. Kept apart
  /// from [unavailable] because it is not a failure: it has a way out, and the
  /// plate says what it is.
  final bool blocked;

  /// How many plates a redeemed code just opened. The plate says so until the
  /// next conversation starts — a toast is gone in three seconds, and the
  /// number is the thing somebody wants to check.
  final int? granted;

  /// The allowance is spent, which is a reason to sell rather than apologise.
}

class PlateVisualController extends Notifier<PlateVisual> {
  @override
  PlateVisual build() => const PlateVisual();

  /// Identifies the plate currently being drawn, so a slow answer for a patch
  /// the user has already moved on from is dropped rather than shown.
  String _wanted = '';

  /// The plate we would draw next, and whether one is already being drawn.
  ///
  /// A conversation moves faster than a picture: someone naming three foods
  /// produces three plates in a few seconds, and a draw takes a few seconds
  /// each. Firing them all meant paying for pictures nobody ever saw and
  /// leaving the plate permanently a draw behind.
  ({List<String> foodIds, String additionId})? _pending;
  bool _drawing = false;
  Timer? _settle;

  /// How long the meal has to stop changing before it is worth drawing.
  /// "Rice" then "and chicken" then "and a salad" is one plate, not three.
  static const _settleDelay = Duration(milliseconds: 800);

  /// Asks for a plate.
  ///
  /// Never blocks and never queues more than one: the latest request wins, and
  /// it waits for whatever is already in flight rather than racing it.
  void request({
    required List<String> foodIds,
    String additionId = '',
    bool now = false,
  }) {
    _pending = (foodIds: [...foodIds], additionId: additionId);
    _settle?.cancel();
    // A tap is a person waiting. A meal changing mid-sentence is not.
    if (now) {
      unawaited(_drain());
    } else {
      _settle = Timer(_settleDelay, () => unawaited(_drain()));
    }
  }

  Future<void> _drain() async {
    // Already drawing: the running draw picks up whatever is pending when it
    // finishes, so the plate ends up at the latest state having drawn once.
    if (_drawing) return;
    final next = _pending;
    if (next == null) return;

    _pending = null;
    _drawing = true;
    try {
      await load(foodIds: next.foodIds, additionId: next.additionId);
    } finally {
      _drawing = false;
      if (_pending != null) unawaited(_drain());
    }
  }

  /// Draws a plate.
  ///
  /// An empty [additionId] means the meal on its own, which is what the plate
  /// shows while the conversation is still filling it in. The Worker caches by
  /// content, so redrawing a plate somebody has already seen is instant.
  Future<void> load({
    required List<String> foodIds,
    String additionId = '',
  }) async {
    if (foodIds.isEmpty && additionId.isEmpty) return;
    final key = '${foodIds.join(',')}|$additionId';
    if (key == _wanted && (state.image != null || state.loading)) return;

    _wanted = key;
    // The picture already on screen stays while the new one is drawn: a plate
    // that blanks out on every word is worse than one that lags.
    state = PlateVisual(image: state.image, caption: state.caption, loading: true);

    try {
      final token = await ref.read(deviceProvider.notifier).token();
      final reply = await ref.read(apiProvider).plate(
            deviceToken: token,
            foodIds: foodIds,
            additionId: additionId,
          );
      if (_stale(key)) return;

      Uint8List? image;
      if (reply.imageUrl != null) {
        try {
          image = await ref
              .read(apiProvider)
              .previewImage(deviceToken: token, url: reply.imageUrl!);
        } catch (_) {
          // The words still stand.
        }
      }
      if (_stale(key)) return;

      state = PlateVisual(
        messageId: reply.messageId,
        caption: reply.reply,
        image: image,
        unavailable: image == null,
      );
      ref.read(deviceProvider.notifier).noteQuota(reply.quota);
    } on ApiFailure catch (failure) {
      if (_stale(key)) return;
      // A spent try is not a failed drawing. The screen says so differently,
      // and offers the way back in rather than an apology.
      state = failure.error == ApiError.tryUsed
          ? const PlateVisual(blocked: true)
          : const PlateVisual(unavailable: true);
    } catch (_) {
      if (_stale(key)) return;
      state = const PlateVisual(unavailable: true);
    }
  }

  /// Whether this answer is still wanted.
  ///
  /// Two ways it stops being: the plate moved on while it was being drawn, or
  /// the screen it was for is gone. The second one matters as much as the
  /// first — a draw that lands after the conversation ended would put the old
  /// meal back on a plate somebody has already cleared, and writing to a
  /// disposed provider throws where nobody is catching.
  bool _stale(String key) => _wanted != key || !ref.mounted;

  /// Says how many plates a code just opened.
  void showGranted(int plates) {
    _settle?.cancel();
    _settle = null;
    _pending = null;
    _wanted = '';
    state = PlateVisual(granted: plates);
  }

  /// Says the day's try is used, without asking the server again.
  ///
  /// The microphone is refused at the same door the drawing is, so the answer
  /// is already known by the time somebody taps it.
  void showTryUsed() {
    _settle?.cancel();
    _settle = null;
    _pending = null;
    _wanted = '';
    state = const PlateVisual(blocked: true);
  }

  void clear() {
    _settle?.cancel();
    _settle = null;
    _pending = null;
    _wanted = '';
    state = const PlateVisual();
  }
}

final plateVisualProvider =
    NotifierProvider<PlateVisualController, PlateVisual>(PlateVisualController.new);
