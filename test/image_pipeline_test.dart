import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plateone/data/image_pipeline.dart';

/// Real photographs, not synthetic gradients — the thresholds only mean
/// anything if they were measured against the kind of image a phone produces.
Uint8List fixture([String name = 'meal_rice_chicken']) =>
    File('test/fixtures/$name.jpg').readAsBytesSync();

img.Image decodedFixture() => img.decodeImage(fixture())!;

Uint8List encode(img.Image image, {int quality = 90}) => img.encodeJpg(image, quality: quality);

void main() {
  const pipeline = ImagePipeline();

  group('a good photo', () {
    late PhotoAccepted result;

    setUpAll(() {
      final r = pipeline.process(fixture());
      expect(r, isA<PhotoAccepted>(), reason: 'the reference photo must be accepted');
      result = r as PhotoAccepted;
    });

    test('comes back as a JPEG', () {
      // SOI marker: every JPEG starts FF D8.
      expect(result.jpeg.sublist(0, 2), [0xFF, 0xD8]);
    });

    test('fits the upload budget', () {
      expect(result.bytes, lessThanOrEqualTo(300 * 1024));
    });

    test('is square, because the camera guide is', () {
      expect(result.width, result.height);
    });

    test('is no larger than the target edge', () {
      expect(result.width, lessThanOrEqualTo(1024));
    });

    test('reports the measurements it judged on', () {
      expect(result.brightness, greaterThan(80));
      expect(result.sharpness, greaterThan(200));
    });

    test('is deterministic', () {
      final again = pipeline.process(fixture()) as PhotoAccepted;
      expect(again.jpeg, result.jpeg);
    });
  });

  group('metadata', () {
    /// A copy of the fixture carrying identifiable device EXIF, which is what
    /// a phone camera writes alongside GPS.
    Uint8List fixtureWithExif() {
      final image = decodedFixture();
      image.exif.imageIfd['Make'] = 'Plate One Phone';
      image.exif.imageIfd['Model'] = 'Test Device';
      return encode(image);
    }

    test('the reference photo carries EXIF to begin with', () {
      // Guards every assertion below: if the fixture were already clean, they
      // would all pass for the wrong reason.
      expect(decodedFixture().exif.isEmpty, isFalse);
    });

    test('the encoder really does write EXIF back', () {
      // The reason an explicit strip is needed at all. If this ever stops
      // being true the strip becomes redundant, not wrong — but the test
      // below would stop proving anything.
      final planted = img.decodeImage(fixtureWithExif())!;
      expect(planted.exif.imageIfd['Make'].toString(), contains('Plate One Phone'));
    });

    test('no EXIF survives the pipeline', () {
      final result = pipeline.process(fixtureWithExif()) as PhotoAccepted;
      final out = img.decodeImage(result.jpeg)!;
      expect(out.exif.isEmpty, isTrue, reason: 'metadata left the device');
    });

    test("the untouched fixture's own EXIF is stripped too", () {
      final result = pipeline.process(fixture()) as PhotoAccepted;
      expect(img.decodeImage(result.jpeg)!.exif.isEmpty, isTrue);
    });

    test('no location string appears anywhere in the bytes', () {
      final result = pipeline.process(fixtureWithExif()) as PhotoAccepted;
      final text = String.fromCharCodes(result.jpeg.where((b) => b >= 32 && b < 127));
      expect(text, isNot(contains('Plate One Phone')));
      expect(text, isNot(contains('Test Device')));
    });

    test('orientation is applied to the pixels before EXIF is dropped', () {
      // A portrait photo tagged "rotate 90" must come out upright. Without
      // baking, stripping the tag would silently leave it sideways.
      final tall = img.copyResize(decodedFixture(), width: 400, height: 800);
      tall.exif.imageIfd.orientation = 6; // 90° clockwise
      final result = pipeline.process(encode(tall), cropToGuide: false) as PhotoAccepted;
      // Baking a 90° rotation turns 400x800 into 800x400.
      expect(result.width, greaterThan(result.height));
    });
  });

  group('rejections', () {
    test('bytes that are not an image', () {
      final result = pipeline.process(Uint8List.fromList([1, 2, 3, 4, 5]));
      expect(result, isA<PhotoRejected>());
      expect((result as PhotoRejected).reason, PhotoRejection.unreadable);
    });

    test('an empty file', () {
      expect(pipeline.process(Uint8List(0)), isA<PhotoRejected>());
    });

    test('a photo too small to read', () {
      final tiny = img.copyResize(decodedFixture(), width: 120);
      final result = pipeline.process(encode(tiny)) as PhotoRejected;
      expect(result.reason, PhotoRejection.tooSmall);
    });

    test('a photo too dark', () {
      final dark = img.adjustColor(decodedFixture(), brightness: 0.25);
      final result = pipeline.process(encode(dark)) as PhotoRejected;
      expect(result.reason, PhotoRejection.tooDark);
      expect(result.brightness, lessThan(40));
    });

    test('a photo too blurry', () {
      final blurred = img.gaussianBlur(decodedFixture(), radius: 3);
      final result = pipeline.process(encode(blurred)) as PhotoRejected;
      expect(result.reason, PhotoRejection.tooBlurry);
    });

    test('a merely soft photo is still accepted', () {
      // The gate must not reject usable photos. Radius 1 is a slightly soft
      // hand-held shot, which a model reads perfectly well.
      final soft = img.gaussianBlur(decodedFixture(), radius: 1);
      expect(pipeline.process(encode(soft)), isA<PhotoAccepted>());
    });

    test('darkness is reported before blur', () {
      // A dark photo is usually also low-contrast. Telling someone to hold
      // still when the real problem is the lighting sends them in circles.
      final dark = img.adjustColor(decodedFixture(), brightness: 0.15);
      expect((pipeline.process(encode(dark)) as PhotoRejected).reason, PhotoRejection.tooDark);
    });

    test('every rejection says what to do next', () {
      for (final reason in PhotoRejection.values) {
        expect(reason.message, isNotEmpty);
        expect(reason.message.endsWith('.'), isTrue);
        // Never blames the user for the photo.
        expect(reason.message.toLowerCase(), isNot(contains('you failed')));
        expect(reason.message.toLowerCase(), isNot(contains('invalid')));
      }
    });
  });

  group('sizing', () {
    test('a huge photo is brought down to the target edge', () {
      final huge = img.copyResize(decodedFixture(), width: 3000);
      final result = pipeline.process(huge.let(encode)) as PhotoAccepted;
      expect(result.width, 1024);
      expect(result.bytes, lessThanOrEqualTo(300 * 1024));
    });

    test('a small photo is not enlarged', () {
      final small = img.copyResize(decodedFixture(), width: 400);
      final result = pipeline.process(encode(small)) as PhotoAccepted;
      expect(result.width, lessThan(400));
    });

    test('quality steps down rather than exceeding the budget', () {
      const tight = ImagePipeline(maxBytes: 20 * 1024);
      final result = tight.process(fixture()) as PhotoAccepted;
      expect(result.bytes, lessThanOrEqualTo(20 * 1024));
    });

    test('the guide crop takes the middle of the frame', () {
      final full = pipeline.process(fixture(), cropToGuide: false) as PhotoAccepted;
      final cropped = pipeline.process(fixture()) as PhotoAccepted;
      expect(cropped.width, lessThan(full.width));
    });
  });

  group('measurements', () {
    test('blur lowers sharpness sharply', () {
      final sharp = ImagePipeline.sharpnessOf(decodedFixture());
      final blurred = ImagePipeline.sharpnessOf(
        img.gaussianBlur(decodedFixture(), radius: 3),
      );
      expect(sharp, greaterThan(500));
      expect(blurred, lessThan(50));
    });

    test('brightness tracks exposure', () {
      final normal = ImagePipeline.meanBrightness(decodedFixture());
      final dim = ImagePipeline.meanBrightness(
        img.adjustColor(decodedFixture(), brightness: 0.5),
      );
      expect(dim, lessThan(normal));
      expect(normal, inInclusiveRange(0, 255));
    });
  });
}

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
