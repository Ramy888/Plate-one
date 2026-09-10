import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/models.dart';
import '../state/scan_providers.dart';
import 'scan_confirm_screen.dart';
import 'theme.dart';

/// The camera, with a circular plate guide.
///
/// The guide does the cropping. A segmentation model would be more impressive
/// and far more fragile; asking someone to fill a circle with their plate is
/// reliable, instant, and needs no model at all.
class ScanCameraScreen extends ConsumerStatefulWidget {
  const ScanCameraScreen({super.key, required this.slot});

  final MealSlot slot;

  @override
  ConsumerState<ScanCameraScreen> createState() => _ScanCameraScreenState();
}

class _ScanCameraScreenState extends ConsumerState<ScanCameraScreen> {
  CameraController? _controller;
  String? _cameraProblem;
  bool _capturing = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() => _cameraProblem = 'No camera on this phone.');
        return;
      }
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        back,
        ResolutionPreset.high,
        enableAudio: false,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
    } catch (_) {
      // Permission refused, camera in use, emulator without one — all end the
      // same way: say so, and offer the manual builder.
      setState(() => _cameraProblem = 'The camera is not available.');
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null || _capturing) return;

    // Out of allowance the server would refuse this anyway, so say so before
    // spending a photo on it rather than after.
    if (_outOfAllowance(ref.read(scanControllerProvider))) return;

    setState(() => _capturing = true);
    try {
      final file = await controller.takePicture();
      final bytes = await file.readAsBytes();
      if (!mounted) return;

      await ref.read(scanControllerProvider.notifier).scan(bytes, slot: widget.slot);
      if (!mounted) return;

      final scan = ref.read(scanControllerProvider);
      if (scan.stage == ScanStage.done) {
        await Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) => ScanConfirmScreen(slot: widget.slot),
          ),
        );
        return;
      }
      // Running out is said plainly in the footer, not raised as an error.
    } catch (_) {
      if (mounted) setState(() => _cameraProblem = 'That photo could not be taken.');
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  /// True once today's scan allowance is spent. The quota is null until the
  /// device registers, and an unknown allowance is not a spent one.
  static bool _outOfAllowance(ScanState scan) {
    final quota = scan.quota;
    return quota != null && !quota.hasScans;
  }

  @override
  Widget build(BuildContext context) {
    final scan = ref.watch(scanControllerProvider);
    final controller = _controller;

    return Scaffold(
      backgroundColor: PlateColors.camera,
      appBar: AppBar(
        backgroundColor: PlateColors.camera,
        foregroundColor: PlateColors.neutral100,
        title: const Text('Scan your meal', style: TextStyle(color: PlateColors.neutral100)),
        actions: [
          if (scan.quota != null)
            Padding(
              padding: const EdgeInsets.only(right: Space.md),
              child: Center(
                child: Text(
                  '${scan.quota!.scans} left',
                  style: const TextStyle(color: PlateColors.onCameraSoft, fontSize: 14),
                ),
              ),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              // BoxFit.cover deliberately overflows to fill the box, so
              // without this clip the preview paints over the footer.
              child: ClipRect(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (controller != null)
                      FittedBox(
                        fit: BoxFit.cover,
                        child: SizedBox(
                          width: controller.value.previewSize?.height ?? 1,
                          height: controller.value.previewSize?.width ?? 1,
                          child: CameraPreview(controller),
                        ),
                      )
                    else
                      Center(
                        child: _cameraProblem == null
                            ? const CircularProgressIndicator(color: PlateColors.neutral100)
                            : _CameraUnavailable(message: _cameraProblem!),
                      ),
                    if (controller != null) const _PlateGuide(),
                    if (scan.isBusy) const _Working(),
                  ],
                ),
              ),
            ),
            _Footer(
              problem: _outOfAllowance(scan)
                  ? 'Today\'s scans are used up. Tap the meal and pick the food instead.'
                  : scan.problem,
              canCapture: controller != null &&
                  !scan.isBusy &&
                  !_capturing &&
                  !_outOfAllowance(scan),
              onCapture: _capture,
              onManual: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }
}

/// A dimmed frame with a clear circle in the middle: aim the plate at it.
///
/// Painted rather than composed from blend-mode tricks — nesting ColorFiltered
/// over a live camera texture produced stray opaque rectangles on device.
class _PlateGuide extends StatelessWidget {
  const _PlateGuide();

  static const guideFraction = 0.78;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Stack(
        children: [
          Positioned.fill(child: CustomPaint(painter: _GuidePainter())),
          Positioned(
            left: 0,
            right: 0,
            bottom: 32,
            child: Text(
              'Fill the circle with your plate',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: PlateColors.neutral100.withValues(alpha: 0.95),
                fontSize: 15,
                fontWeight: FontWeight.w600,
                shadows: const [Shadow(blurRadius: 8, color: PlateColors.camera)],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GuidePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final radius = math.min(size.width, size.height) * _PlateGuide.guideFraction / 2;
    final centre = Offset(size.width / 2, size.height / 2);

    // Dim everything, then clear the circle back out. saveLayer is what makes
    // BlendMode.clear affect only this layer rather than the whole scene.
    canvas.saveLayer(Offset.zero & size, Paint());
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = PlateColors.camera.withValues(alpha: 0.45),
    );
    canvas.drawCircle(centre, radius, Paint()..blendMode = BlendMode.clear);
    canvas.restore();

    canvas.drawCircle(
      centre,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = PlateColors.onCameraSoft,
    );
  }

  @override
  bool shouldRepaint(covariant _GuidePainter oldDelegate) => false;
}

class _Working extends StatelessWidget {
  const _Working();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: PlateColors.camera.withValues(alpha: 0.6),
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: PlateColors.neutral100),
            SizedBox(height: Space.md),
            Text('Looking at your meal…', style: TextStyle(color: PlateColors.neutral100, fontSize: 16)),
          ],
        ),
      ),
    );
  }
}

class _CameraUnavailable extends StatelessWidget {
  const _CameraUnavailable({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(Space.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(LucideIcons.camera, size: 34, color: PlateColors.onCameraSoft),
          const SizedBox(height: Space.md),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: PlateColors.neutral100, fontSize: 17, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: Space.sm),
          const Text(
            'You can still build the meal by hand.',
            textAlign: TextAlign.center,
            style: TextStyle(color: PlateColors.onCameraSoft, fontSize: 14.5),
          ),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.problem,
    required this.canCapture,
    required this.onCapture,
    required this.onManual,
  });

  final String? problem;
  final bool canCapture;
  final VoidCallback onCapture;
  final VoidCallback onManual;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: PlateColors.camera,
      padding: const EdgeInsets.fromLTRB(Space.lg, Space.md, Space.lg, Space.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (problem != null) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(Space.md),
              decoration: BoxDecoration(
                color: PlateColors.warnSoft,
                borderRadius: BorderRadius.circular(kRadiusSmall),
              ),
              child: Text(
                problem!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: PlateColors.ink, fontSize: 14.5),
              ),
            ),
            const SizedBox(height: Space.md),
          ],
          GestureDetector(
            onTap: canCapture ? onCapture : null,
            child: Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: canCapture ? PlateColors.neutral100 : PlateColors.onCameraFaint,
                border: Border.all(color: PlateColors.onCameraSoft, width: 4),
              ),
            ),
          ),
          const SizedBox(height: Space.md),
          TextButton(
            onPressed: onManual,
            child: const Text(
              'Build the meal by hand instead',
              style: TextStyle(color: PlateColors.onCameraSoft),
            ),
          ),
        ],
      ),
    );
  }
}
