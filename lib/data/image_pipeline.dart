import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Everything that happens to a meal photo before a byte of it leaves the phone.
///
/// Three jobs, in order of importance:
///
/// 1. **Privacy** — the file that gets uploaded carries no EXIF, so no GPS
///    coordinates, no device model, no capture timestamp.
/// 2. **Cost** — a 300 KB image costs a fraction of a 4 MB one to send and to
///    have a model read, and a photo rejected here is a model call not made.
/// 3. **Quality** — a dark or blurry photo produces a confidently wrong answer,
///    which is worse than no answer.
///
/// Pure Dart with no platform channels, so all of it is testable against real
/// photographs.

/// Why a photo was not good enough to send.
enum PhotoRejection {
  unreadable,
  tooSmall,
  tooDark,
  tooBlurry;

  /// Shown to the user. Says what to do, never what they did wrong.
  String get message => switch (this) {
        PhotoRejection.unreadable => "That photo could not be read. Try taking it again.",
        PhotoRejection.tooSmall => 'That photo is too small to read. Move a little closer.',
        PhotoRejection.tooDark => 'It is a bit dark to make out. Try somewhere brighter.',
        PhotoRejection.tooBlurry => 'That came out blurry. Hold still and try again.',
      };
}

sealed class PhotoResult {
  const PhotoResult();
}

class PhotoAccepted extends PhotoResult {
  const PhotoAccepted({
    required this.jpeg,
    required this.width,
    required this.height,
    required this.brightness,
    required this.sharpness,
  });

  final Uint8List jpeg;
  final int width;
  final int height;

  /// Mean luma, 0–255.
  final double brightness;

  /// Variance of the Laplacian. Higher is sharper.
  final double sharpness;

  int get bytes => jpeg.length;
}

class PhotoRejected extends PhotoResult {
  const PhotoRejected(this.reason, {this.brightness, this.sharpness});

  final PhotoRejection reason;
  final double? brightness;
  final double? sharpness;

  String get message => reason.message;
}

class ImagePipeline {
  const ImagePipeline({
    this.targetEdge = 1024,
    this.maxBytes = 300 * 1024,
    this.guideFraction = 0.78,
    this.minBrightness = 40,
    this.minSharpness = 80,
  });

  /// Longest edge of the uploaded image.
  final int targetEdge;

  /// Upload ceiling. Quality steps down until the result fits.
  final int maxBytes;

  /// The camera's circular guide, as a fraction of the shorter edge. The crop
  /// is that circle's bounding box — a guide the user aims with is far more
  /// reliable, and far less work, than a segmentation model.
  final double guideFraction;

  /// Mean luma below which a photo is too dark to read.
  final double minBrightness;

  /// Variance-of-Laplacian below which a photo is too blurry.
  ///
  /// Measured on real meal photographs: a sharp one scores ~1090, a slightly
  /// soft one ~230, and one blurred past usefulness ~37. 80 sits in the gap,
  /// with headroom for legitimately low-texture food like soup or porridge.
  /// Re-measure with `dart run tool/calibrate_photo_gate.dart`.
  final double minSharpness;

  /// 80 is the normal case; the rest are only reached when a photo refuses to
  /// fit, and are preferred over shrinking because resolution matters more to
  /// the model than compression artefacts.
  static const _qualitySteps = [80, 70, 60, 50, 40];

  /// How many times the image may be scaled down chasing [maxBytes].
  static const _maxShrinkAttempts = 4;

  /// Never shrink below this, or the model has nothing to read.
  static const _minEdge = 320;

  /// Runs the whole pipeline. Returns either bytes ready to upload, or the
  /// reason the user should take another photo.
  PhotoResult process(Uint8List raw, {bool cropToGuide = true}) {
    // decodeImage throws on some malformed input rather than returning null,
    // and a corrupt file must be a polite retry prompt, never a crash.
    final img.Image? decoded;
    try {
      decoded = img.decodeImage(raw);
    } catch (_) {
      return const PhotoRejected(PhotoRejection.unreadable);
    }
    if (decoded == null) return const PhotoRejected(PhotoRejection.unreadable);

    // Applies any EXIF rotation to the pixels. Without this, stripping EXIF
    // would silently turn portrait photos sideways.
    var image = img.bakeOrientation(decoded);

    if (math.min(image.width, image.height) < 200) {
      return const PhotoRejected(PhotoRejection.tooSmall);
    }

    if (cropToGuide) image = _cropToGuide(image);
    image = _fit(image);

    final brightness = meanBrightness(image);
    if (brightness < minBrightness) {
      return PhotoRejected(PhotoRejection.tooDark, brightness: brightness);
    }

    final sharpness = sharpnessOf(image);
    if (sharpness < minSharpness) {
      return PhotoRejected(
        PhotoRejection.tooBlurry,
        brightness: brightness,
        sharpness: sharpness,
      );
    }

    return PhotoAccepted(
      jpeg: _encodeWithinBudget(image),
      width: image.width,
      height: image.height,
      brightness: brightness,
      sharpness: sharpness,
    );
  }

  /// The centred square the camera guide sits in.
  img.Image _cropToGuide(img.Image image) {
    final side = (math.min(image.width, image.height) * guideFraction).round();
    return img.copyCrop(
      image,
      x: ((image.width - side) / 2).round(),
      y: ((image.height - side) / 2).round(),
      width: side,
      height: side,
    );
  }

  /// Scales the longest edge down to [targetEdge]. Never scales up — enlarging
  /// a small photo adds no detail for the model to read.
  img.Image _fit(img.Image image) {
    final longest = math.max(image.width, image.height);
    if (longest <= targetEdge) return image;
    return img.copyResize(
      image,
      width: image.width >= image.height ? targetEdge : null,
      height: image.height > image.width ? targetEdge : null,
      interpolation: img.Interpolation.cubic,
    );
  }

  /// Encodes to JPEG under [maxBytes]: quality first, then dimensions.
  ///
  /// The EXIF block is emptied first. `encodeJpg` writes back whatever the
  /// decoder found — verified in the tests — so re-encoding alone does **not**
  /// strip metadata.
  Uint8List _encodeWithinBudget(img.Image image) {
    var current = image;
    Uint8List encoded = Uint8List(0);

    for (var attempt = 0; attempt < _maxShrinkAttempts; attempt++) {
      current.exif = img.ExifData();
      for (final quality in _qualitySteps) {
        encoded = img.encodeJpg(current, quality: quality);
        if (encoded.length <= maxBytes) return encoded;
      }
      // Lowest quality still over budget: give up detail rather than the cap,
      // since the cap is what keeps uploads and model costs predictable.
      final nextWidth = (current.width * 0.75).round();
      if (nextWidth < _minEdge) break;
      current = img.copyResize(
        current,
        width: nextWidth,
        interpolation: img.Interpolation.average,
      );
    }
    return encoded;
  }

  /// Mean luma, 0–255.
  static double meanBrightness(img.Image image) {
    var total = 0.0;
    var count = 0;
    // Every fourth pixel: the mean is stable long before every pixel is read.
    for (var y = 0; y < image.height; y += 2) {
      for (var x = 0; x < image.width; x += 2) {
        total += image.getPixel(x, y).luminance;
        count++;
      }
    }
    return count == 0 ? 0 : total / count;
  }

  /// Variance of the Laplacian — the standard cheap sharpness measure. A blurred
  /// image has little high-frequency content, so the second derivative is flat.
  static double sharpnessOf(img.Image image) {
    final w = image.width;
    final h = image.height;
    if (w < 3 || h < 3) return 0;

    final luma = Float32List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        luma[y * w + x] = image.getPixel(x, y).luminance.toDouble();
      }
    }

    var sum = 0.0;
    var sumSquares = 0.0;
    var count = 0;
    for (var y = 1; y < h - 1; y++) {
      for (var x = 1; x < w - 1; x++) {
        final i = y * w + x;
        final value = luma[i - w] + luma[i + w] + luma[i - 1] + luma[i + 1] - 4 * luma[i];
        sum += value;
        sumSquares += value * value;
        count++;
      }
    }
    if (count == 0) return 0;
    final mean = sum / count;
    return sumSquares / count - mean * mean;
  }
}
