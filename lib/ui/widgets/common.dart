import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme.dart';

/// The app's one card shape. Everything raised off the page uses it.
///
/// The border is two pixels of *transparent* by default, so selecting a card
/// changes its colour without moving anything by a pixel.
class PlateCard extends StatelessWidget {
  const PlateCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(Space.md),
    this.color = PlateColors.card,
    this.border,
    this.onTap,
  });

  final Widget child;
  final EdgeInsets padding;
  final Color color;
  final Color? border;
  final VoidCallback? onTap;

  /// A card in the selected state: the stronger sage fill and a sage edge.
  factory PlateCard.selected({
    Key? key,
    required Widget child,
    EdgeInsets padding = const EdgeInsets.all(Space.md),
    VoidCallback? onTap,
  }) => PlateCard(
    key: key,
    padding: padding,
    onTap: onTap,
    color: PlateColors.greenSel,
    border: PlateColors.green,
    child: child,
  );

  /// A card that is about Pro, or about something worth a second look.
  factory PlateCard.pro({
    Key? key,
    required Widget child,
    EdgeInsets padding = const EdgeInsets.all(Space.md),
    VoidCallback? onTap,
  }) => PlateCard(
    key: key,
    padding: padding,
    onTap: onTap,
    color: PlateColors.proSoft,
    border: PlateColors.warn,
    child: child,
  );

  /// A card that recedes: a note rather than an object.
  factory PlateCard.quiet({
    Key? key,
    required Widget child,
    EdgeInsets padding = const EdgeInsets.all(Space.md),
  }) => PlateCard(
    key: key,
    padding: padding,
    color: PlateColors.neutral100,
    child: child,
  );

  @override
  Widget build(BuildContext context) {
    final shape = BorderRadius.circular(kRadius);
    return Material(
      color: color,
      borderRadius: shape,
      child: InkWell(
        onTap: onTap,
        borderRadius: shape,
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: shape,
            border: Border.all(color: border ?? Colors.transparent, width: 2),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// The small round glyph that leads a row. Always the same size, so rows line
/// up down a list whatever they are about.
class Lead extends StatelessWidget {
  const Lead(
    this.icon, {
    super.key,
    this.tone = PlateColors.green,
    this.background = PlateColors.neutral100,
    this.size = 19,
  });

  final IconData icon;
  final Color tone;

  /// The disc behind the glyph. Inverted — sage disc, pale glyph — where the
  /// badge carries the emphasis on its own rather than sitting on a fill.
  final Color background;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: background,
      ),
      child: Icon(icon, size: size, color: tone),
    );
  }
}

/// A picture well. The app ships no food photography, so what shows is the
/// glyph — which is exactly the design's own unfilled state, not a gap in it.
class PlateThumb extends StatelessWidget {
  const PlateThumb(this.icon, {super.key, this.small = false});

  final IconData icon;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final side = small ? 54.0 : 78.0;
    return Container(
      width: side,
      height: side,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: PlateColors.neutral100,
        borderRadius: BorderRadius.circular(kRadiusSmall),
      ),
      child: Icon(icon, size: small ? 19 : 23, color: PlateColors.neutral400),
    );
  }
}

/// A food as a picture: an 86px well with the name beneath, and a badge in the
/// corner once it is on the plate.
class FoodTile extends StatelessWidget {
  const FoodTile({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(kRadiusSmall),
        child: SizedBox(
            width: 86,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Stack(
                  children: [
                    Container(
                      width: 86,
                      height: 86,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: PlateColors.neutral100,
                        borderRadius: BorderRadius.circular(kRadius * 0.7),
                        border: Border.all(
                          color: selected
                              ? PlateColors.green
                              : Colors.transparent,
                          width: 2,
                        ),
                      ),
                      child: Icon(
                        icon,
                        size: 23,
                        color: PlateColors.neutral400,
                      ),
                    ),
                    if (selected)
                      const Positioned(
                        top: 6,
                        right: 6,
                        child: _Badge(
                          icon: LucideIcons.check,
                          background: PlateColors.green,
                          foreground: PlateColors.neutral100,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 7),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  // Two lines fits every name in the catalogue at this width;
                  // the cap stops a longer one from overflowing the rail.
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.3,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                    color: selected ? PlateColors.greenPress : PlateColors.ink,
                  ),
                ),
              ],
            ),
          ),
        ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({
    required this.icon,
    required this.background,
    required this.foreground,
  });

  final IconData icon;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      alignment: Alignment.center,
      decoration: BoxDecoration(shape: BoxShape.circle, color: background),
      child: Icon(icon, size: 13, color: foreground),
    );
  }
}

/// A large tappable row: glyph, title, blurb, and an indicator. Big targets,
/// because this is the first thing anyone touches.
class ChoiceRow extends StatelessWidget {
  const ChoiceRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    required this.selected,
    required this.onTap,
    this.showIndicator = true,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;

  /// Off where the tap is an immediate action rather than a selection — an
  /// empty checkbox there wrongly implies a confirm step is coming.
  final bool showIndicator;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: PlateCard(
        onTap: onTap,
        color: selected ? PlateColors.greenSel : PlateColors.card,
        border: selected ? PlateColors.green : null,
        child: Row(
          children: [
            Lead(icon),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleMedium),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: Space.sm),
            if (showIndicator)
              Tick(on: selected)
            else
              const Icon(
                LucideIcons.chevronRight,
                size: 20,
                color: PlateColors.inkSoft,
              ),
          ],
        ),
      ),
    );
  }
}

/// The round check that marks a selection.
class Tick extends StatelessWidget {
  const Tick({super.key, required this.on});

  final bool on;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: on ? PlateColors.green : Colors.transparent,
        border: Border.all(
          color: on ? PlateColors.green : PlateColors.neutral400,
          width: 2,
        ),
      ),
      child: on
          ? const Icon(
              LucideIcons.check,
              size: 15,
              color: PlateColors.neutral100,
            )
          : const SizedBox.shrink(),
    );
  }
}

/// Small pill used for "Pro", "Fastest", "Cheapest", "Plant-based".
class Pill extends StatelessWidget {
  const Pill({
    super.key,
    required this.label,
    this.icon,
    this.background = PlateColors.greenSoft,
    this.foreground = PlateColors.green,
  });

  final String label;
  final IconData? icon;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(kPill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: foreground),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.25,
              color: foreground,
            ),
          ),
        ],
      ),
    );
  }
}

/// A pill-shaped tappable label. Used wherever a list of foods has to stay
/// compact — the confirm screen's "add something it missed".
class PlateChip extends StatelessWidget {
  const PlateChip({
    super.key,
    required this.icon,
    required this.label,
    this.selected = false,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final shape = BorderRadius.circular(kPill);
    return Material(
      color: selected ? PlateColors.greenSel : PlateColors.card,
      borderRadius: shape,
      child: InkWell(
        onTap: onTap,
        borderRadius: shape,
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: shape,
            border: Border.all(
              color: selected ? PlateColors.green : Colors.transparent,
              width: 2,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 17, color: PlateColors.green),
              const SizedBox(width: Space.sm),
              Text(
                label,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                  color: PlateColors.ink,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A quiet block of text on a recessed ground — the reason under a suggestion,
/// or the hint that tells you what to do next.
class Inset extends StatelessWidget {
  const Inset({super.key, required this.child, this.icon});

  final Widget child;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
      decoration: BoxDecoration(
        color: PlateColors.neutral100,
        borderRadius: BorderRadius.circular(kRadiusSmall),
      ),
      child: icon == null
          ? child
          : Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(icon, size: 17, color: PlateColors.green),
                const SizedBox(width: Space.sm),
                Expanded(child: child),
              ],
            ),
    );
  }
}

/// Empty states and locked states share this shape so the app never shows a
/// blank rectangle with nothing to do next.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.lg,
          vertical: Space.xl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: PlateColors.card,
              ),
              child: Icon(icon, size: 26, color: PlateColors.green),
            ),
            const SizedBox(height: Space.md),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: Space.sm),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (action != null) ...[const SizedBox(height: Space.lg), action!],
          ],
        ),
      ),
    );
  }
}

/// The addition, said in words.
///
/// The whole app is one sentence long — "add this one thing" — and this is that
/// sentence. It appears wherever a patch does: the result page, a chat reply, a
/// spoken one. A picture alone was never enough; a generated plate shows the
/// addition mixed in with everything else on it.
///
/// Nothing sits behind it. It has worn a filled card, then a washed one with a
/// rule down the edge, and both made a sentence look like a slab. All the
/// emphasis is in the badge now — a sage disc with a pale glyph — and in the
/// weight of the line itself, which is as much as one sentence needs.
///
/// There is no "ADD" label above the name either: every addition in the
/// catalogue is already written as an instruction, and seven of them say Swap,
/// Drizzle, Sprinkle or Stir, so the label was redundant at best and
/// contradicted the line beneath it at worst.
class PatchHighlight extends StatelessWidget {
  const PatchHighlight({
    super.key,
    required this.icon,
    required this.name,
    this.how,
    this.compact = false,
  });

  final IconData icon;
  final String name;

  /// The portion guidance. Omitted where space is tight.
  final String? how;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Lead(
          icon,
          size: compact ? 17 : 19,
          tone: PlateColors.neutral100,
          background: PlateColors.green,
        ),
        const SizedBox(width: Space.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Nudged down so the first line sits against the badge's middle
              // rather than its top edge.
              const SizedBox(height: 5),
              Text(name, style: text.titleMedium),
              if (how != null && !compact) ...[
                const SizedBox(height: 3),
                Text(how!, style: text.bodyMedium),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Keeps a page readable on a wide window.
///
/// A browser is not a phone. Left alone, every row on these screens stretches
/// to whatever the window happens to be, so a line of text and a thumbnail sit
/// at opposite ends of two thousand pixels with nothing in between. This holds
/// the content to a column and centres it, which is what the phone layout
/// already was.
class Readable extends StatelessWidget {
  const Readable({super.key, required this.child, this.maxWidth = 720});

  final Widget child;

  /// Roughly a tablet in portrait. Wide enough for a card and a picture, not
  /// so wide that a sentence runs off the edge of what the eye follows.
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
