import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/scan_api.dart';
import 'scan_providers.dart';

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
  });

  /// What a rating or a report is filed against. Empty until one arrives.
  final String messageId;

  /// A sentence about this plate. Empty falls back to the engine's own reason.
  final String caption;
  final Uint8List? image;

  final bool loading;

  /// The picture could not be drawn. Not an error worth a dialog.
  final bool unavailable;

  /// The allowance is spent, which is a reason to sell rather than apologise.
}

class PlateVisualController extends Notifier<PlateVisual> {
  @override
  PlateVisual build() => const PlateVisual();

  /// Identifies the plate currently being drawn, so a slow answer for a patch
  /// the user has already moved on from is dropped rather than shown.
  String _wanted = '';

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
      final token = await ref.read(scanControllerProvider.notifier).deviceToken();
      final reply = await ref.read(scanApiProvider).plate(
            deviceToken: token,
            foodIds: foodIds,
            additionId: additionId,
          );
      if (_wanted != key) return;

      Uint8List? image;
      if (reply.imageUrl != null) {
        try {
          image = await ref
              .read(scanApiProvider)
              .previewImage(deviceToken: token, url: reply.imageUrl!);
        } catch (_) {
          // The words still stand.
        }
      }
      if (_wanted != key) return;

      state = PlateVisual(
        messageId: reply.messageId,
        caption: reply.reply,
        image: image,
        unavailable: image == null,
      );
      ref.read(scanControllerProvider.notifier).noteQuota(reply.quota);
    } on ScanFailure {
      if (_wanted != key) return;
      state = const PlateVisual(unavailable: true);
    } catch (_) {
      if (_wanted != key) return;
      state = const PlateVisual(unavailable: true);
    }
  }

  void clear() {
    _wanted = '';
    state = const PlateVisual();
  }
}

final plateVisualProvider =
    NotifierProvider<PlateVisualController, PlateVisual>(PlateVisualController.new);
