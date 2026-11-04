import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// The Graceland colour set, kept in one place so the splash screen, the
/// login screen and the rest of the app all draw from the same palette:
/// champagne gold taken from the badge itself, and the deep navy of its
/// lettering.
const Color kChampagneLight = Color(0xfff1e5c4);
const Color kChampagne = Color(0xffdcc693);
const Color kChampagneDeep = Color(0xffbf9f66);
const Color kDeepNavy = Color(0xff0b1a33);

/// The deep champagne gold at the centre of the screen, taken from the
/// badge's own gold (measured from the logo image: rgb 216, 192, 144).
const Color kBadgeDiscCentre = Color(0xffd8c090);

/// The champagne field behind the splash and login screens.
///
/// The badge artwork is the navy lettering and rings on a transparent
/// background, as the monogram is. The field below is therefore the ONLY
/// gold the eye sees, so the badge is fused with it and there is no
/// circular edge to find, at any size.
///
/// The field is deepest in the middle, where the badge sits, and grows
/// lighter and lighter as it spreads toward the corners.
///
/// [badgeDiameter] and [badgeCenter] only say where the badge is, so the
/// light glow can start just outside it. With [showBadge] the backdrop draws
/// the badge itself at that size (the login screen); the splash draws its
/// own, animated, badge and leaves this off. With a [blurSigma] above zero
/// the whole field, badge included, is softened once (a small blur only, so
/// the badge stays clearly readable through the login glass).
class ChampagneBackdrop extends StatelessWidget {
  /// 0 leaves the field crisp. A small value (2 to 3) softens it a little.
  final double blurSigma;

  /// Whether the backdrop itself draws the large badge.
  final bool showBadge;

  /// The badge's diameter as a share of the screen's shorter side, capped
  /// at [maxBadgeDiameter] so it is never stretched past what the image
  /// can show sharply.
  final double badgeShare;
  final double maxBadgeDiameter;

  /// Where the badge's centre sits, as a fraction of the screen
  /// (0.5, 0.5 is the middle).
  final Offset badgeCenterFraction;

  /// Drawn on top of the field, unblurred.
  final Widget? child;

  const ChampagneBackdrop({
    super.key,
    this.blurSigma = 0,
    this.showBadge = false,
    this.badgeShare = 0.92,
    this.maxBadgeDiameter = 760,
    this.badgeCenterFraction = const Offset(0.5, 0.5),
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final Size size = constraints.biggest;
        final double diameter = math.min(size.shortestSide * badgeShare, maxBadgeDiameter);
        final Offset center = Offset(size.width * badgeCenterFraction.dx, size.height * badgeCenterFraction.dy);

        final Widget field = Stack(
          fit: StackFit.expand,
          children: [
            CustomPaint(painter: _BadgeBlendPainter(badgeDiameter: diameter, badgeCenter: center)),
            if (showBadge)
              Positioned(
                left: center.dx - diameter / 2,
                top: center.dy - diameter / 2,
                width: diameter,
                height: diameter,
                child: Image.asset(
                  'lib/branding/graceland_logo_full.png',
                  fit: BoxFit.contain,
                  // The best resampling Flutter offers, so the badge is
                  // smooth rather than pixelated at any size.
                  filterQuality: FilterQuality.high,
                  isAntiAlias: true,
                ),
              ),
          ],
        );

        return Stack(
          fit: StackFit.expand,
          children: [
            if (blurSigma > 0)
              // ImageFiltered blurs its own child (the field), once. The
              // clip keeps the soft blurred edge inside the screen.
              ClipRect(
                child: ImageFiltered(
                  imageFilter: ui.ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
                  child: field,
                ),
              )
            else
              field,
            if (child != null) child!,
          ],
        );
      },
    );
  }
}

/// Paints the field described above. Static: nothing in it ever animates.
class _BadgeBlendPainter extends CustomPainter {
  final double badgeDiameter;
  final Offset badgeCenter;

  const _BadgeBlendPainter({required this.badgeDiameter, required this.badgeCenter});

  @override
  void paint(Canvas canvas, Size size) {
    final Rect whole = Offset.zero & size;

    // --- 1. The deep champagne gold, everywhere. ---
    canvas.drawRect(whole, Paint()..color = kBadgeDiscCentre);

    // --- 2. Lighter and lighter toward the corners. ---
    // A pale champagne glow that is clear in the middle and thickens
    // smoothly toward the farthest corner. It starts a little inside the
    // badge's edge so the change of shade is gradual, not a visible ring.
    final double farthestCorner = [
      (badgeCenter - whole.topLeft).distance,
      (badgeCenter - whole.topRight).distance,
      (badgeCenter - whole.bottomLeft).distance,
      (badgeCenter - whole.bottomRight).distance,
    ].reduce(math.max);
    final double start = ((badgeDiameter / 2) * 0.55 / farthestCorner).clamp(0.0, 0.9).toDouble();
    canvas.drawRect(
      whole,
      Paint()
        ..shader = ui.Gradient.radial(
          badgeCenter,
          farthestCorner,
          [
            kChampagneLight.withValues(alpha: 0.0),
            kChampagneLight.withValues(alpha: 0.35),
            kChampagneLight.withValues(alpha: 0.80),
            kChampagneLight.withValues(alpha: 0.95),
          ],
          [start, start + (1 - start) * 0.35, start + (1 - start) * 0.75, 1.0],
        ),
    );
  }

  @override
  bool shouldRepaint(covariant _BadgeBlendPainter old) =>
      old.badgeDiameter != badgeDiameter || old.badgeCenter != badgeCenter;
}
