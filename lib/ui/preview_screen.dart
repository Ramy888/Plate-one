import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/models.dart';
import '../state/scan_providers.dart';
import 'theme.dart';
import 'widgets/common.dart';
import 'widgets/report_sheet.dart';

/// The before-and-after slider.
///
/// The point is not the picture. It is that someone who cannot picture "add a
/// side salad" can now see it on their own plate, in their own kitchen light.
///
/// The label under it is not decoration and not dismissible: a generated
/// photograph of food that reads as real is exactly what Play's AI policy is
/// watching for, and what an honest product owes the person looking at it.
class PreviewScreen extends ConsumerStatefulWidget {
  const PreviewScreen({super.key, required this.patch});

  final Patch patch;

  @override
  ConsumerState<PreviewScreen> createState() => _PreviewScreenState();
}

class _PreviewScreenState extends ConsumerState<PreviewScreen> {
  double _split = 0.5;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(scanControllerProvider.notifier).generatePreview(widget.patch.addition.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scan = ref.watch(scanControllerProvider);
    final before = scan.photo;
    final after = scan.preview;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Preview'),
        actions: [
          IconButton(
            tooltip: 'Report this result',
            icon: const Icon(LucideIcons.flag),
            onPressed: () => ReportSheet.show(context),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, Space.xl),
          children: [
            Text(
              widget.patch.addition.name,
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: Space.xs),
            Text(widget.patch.addition.how, style: Theme.of(context).textTheme.bodyLarge),
            const SizedBox(height: Space.lg),
            if (before == null)
              const _NoPhoto()
            else if (scan.previewFailure != null)
              _PreviewProblem(message: scan.previewFailure!.message)
            else if (after == null)
              const _Generating()
            else ...[
              _BeforeAfter(before: before, after: after, split: _split),
              const SizedBox(height: Space.sm),
              Slider(
                value: _split,
                onChanged: (v) => setState(() => _split = v),
                activeColor: PlateColors.green,
                inactiveColor: PlateColors.line,
              ),
              const _Disclaimer(),
            ],
            const SizedBox(height: Space.lg),
            OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Back to my patch'),
            ),
          ],
        ),
      ),
    );
  }
}

class _BeforeAfter extends StatelessWidget {
  const _BeforeAfter({required this.before, required this.after, required this.split});

  final Uint8List before;
  final Uint8List after;
  final double split;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(kRadius),
      child: AspectRatio(
        aspectRatio: 1,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.memory(after, fit: BoxFit.cover),
            // The original, revealed from the left as the slider moves.
            ClipRect(
              clipper: _LeftClipper(split),
              child: Image.memory(before, fit: BoxFit.cover),
            ),
            Align(
              alignment: Alignment(split * 2 - 1, 0),
              child: Container(width: 2, color: PlateColors.neutral100),
            ),
            Positioned(
              left: Space.sm,
              top: Space.sm,
              child: Pill(
                label: 'Now',
                background: Colors.black54,
                foreground: PlateColors.neutral100,
              ),
            ),
            const Positioned(
              right: Space.sm,
              top: Space.sm,
              child: Pill(
                label: 'Patched',
                background: Colors.black54,
                foreground: PlateColors.neutral100,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LeftClipper extends CustomClipper<Rect> {
  const _LeftClipper(this.split);

  final double split;

  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, size.width * split, size.height);

  @override
  bool shouldReclip(covariant _LeftClipper oldClipper) => oldClipper.split != split;
}

class _Disclaimer extends StatelessWidget {
  const _Disclaimer();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: Space.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(LucideIcons.sparkles, size: 14, color: PlateColors.green),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Text(
              'AI visual preview — appearance and serving size are illustrative.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _Generating extends StatelessWidget {
  const _Generating();

  @override
  Widget build(BuildContext context) {
    return PlateCard(
      padding: const EdgeInsets.symmetric(vertical: Space.xxl, horizontal: Space.lg),
      child: Column(
        children: [
          const CircularProgressIndicator(color: PlateColors.green),
          const SizedBox(height: Space.md),
          Text('Drawing your patched plate…',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: Space.xs),
          Text(
            'This takes a few seconds.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}

class _PreviewProblem extends StatelessWidget {
  const _PreviewProblem({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return PlateCard(
      padding: const EdgeInsets.all(Space.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(LucideIcons.palette, size: 26, color: PlateColors.green),
          const SizedBox(height: Space.sm),
          Text('No preview this time', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: Space.xs),
          Text(message, style: Theme.of(context).textTheme.bodyLarge),
        ],
      ),
    );
  }
}

/// Shown when the patch came from the tile picker rather than a scan, so there
/// is no photograph to edit.
class _NoPhoto extends StatelessWidget {
  const _NoPhoto();

  @override
  Widget build(BuildContext context) {
    return PlateCard(
      padding: const EdgeInsets.all(Space.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(LucideIcons.camera, size: 26, color: PlateColors.green),
          const SizedBox(height: Space.sm),
          Text('Scan a meal to see a preview',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: Space.xs),
          Text(
            'A preview is drawn from your own photo, so it needs one to start from.',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ],
      ),
    );
  }
}
