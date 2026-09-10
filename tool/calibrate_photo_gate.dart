// Prints brightness and sharpness for the test fixtures at varying blur and
// exposure, so the thresholds in ImagePipeline can be set from measurements
// rather than guessed.
//
//   dart run tool/calibrate_photo_gate.dart
// ignore_for_file: avoid_print

import 'dart:io';
import 'package:image/image.dart' as img;
import 'package:plateone/data/image_pipeline.dart';

void main() {
  for (final name in ['meal_rice_chicken', 'meal_rice_chicken_patched']) {
    final raw = File('test/fixtures/$name.jpg').readAsBytesSync();
    final base = img.bakeOrientation(img.decodeImage(raw)!);
    print('--- $name (${base.width}x${base.height}) ---');
    for (final r in [0, 1, 2, 3, 4]) {
      final im = r == 0 ? base : img.gaussianBlur(base.clone(), radius: r);
      print('  blur r$r  sharpness=${ImagePipeline.sharpnessOf(im).toStringAsFixed(1)}');
    }
    for (final b in [1.0, 0.5, 0.35, 0.25]) {
      final im = img.adjustColor(base.clone(), brightness: b);
      print('  bright x$b  luma=${ImagePipeline.meanBrightness(im).toStringAsFixed(1)}');
    }
  }
}
