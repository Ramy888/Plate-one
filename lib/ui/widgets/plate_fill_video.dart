import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'plate_fill.dart';

/// The onboarding film: a plate filling with a meal.
///
/// Four seconds, silent, looping. The audio track is stripped rather than
/// muted — a browser will refuse to autoplay anything that carries sound, and
/// there was nothing on it to hear.
///
/// Falls back to the drawn [PlateFill] whenever the film cannot play: a codec
/// the browser will not take, a blocked autoplay, a file that failed to load.
/// The first screen of the app is the wrong place to find out that a video
/// asset is the one thing standing between somebody and the product.
class PlateFillVideo extends StatefulWidget {
  const PlateFillVideo({super.key, this.size = 240});

  final double size;

  @override
  State<PlateFillVideo> createState() => _PlateFillVideoState();
}

class _PlateFillVideoState extends State<PlateFillVideo> {
  VideoPlayerController? _controller;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final controller =
        VideoPlayerController.asset('assets/onboarding/plate_fill.mp4');
    try {
      await controller.initialize();
      await controller.setLooping(true);
      await controller.setVolume(0);
      await controller.play();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
    } catch (error) {
      // Said out loud. A silent fallback is indistinguishable from the film
      // simply not being there, and that is a bad thing to debug in a browser.
      // ignore: avoid_print
      print('plate_fill video failed: $error');
      await controller.dispose();
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;

    // Somebody who asked their system for less motion gets the plate drawn and
    // still, not four seconds of food on a loop.
    if (_failed ||
        controller == null ||
        MediaQuery.disableAnimationsOf(context)) {
      return PlateFill(size: widget.size);
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: SizedBox(
        width: widget.size * 1.6,
        height: widget.size,
        // The film is 16:9 and the plate sits in the middle of it, so it is
        // cropped to fill rather than letterboxed into a band of grey.
        child: FittedBox(
          fit: BoxFit.cover,
          clipBehavior: Clip.hardEdge,
          child: SizedBox(
            width: controller.value.size.width,
            height: controller.value.size.height,
            child: VideoPlayer(controller),
          ),
        ),
      ),
    );
  }
}
