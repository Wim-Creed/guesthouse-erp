import 'package:flutter/material.dart';

/// The screen size the app is designed for, as the length of the screen's
/// shorter side in logical pixels. A screen at least this size shows the app
/// at its natural size, exactly as designed. A smaller screen (a phone) has
/// everything reduced together so it fits.
const double kReferenceShortSide = 480;

/// The smallest the whole app is ever reduced to, so a very small phone stays
/// readable. The app is never enlarged: a tablet or a laptop shows it at its
/// natural size.
const double kMinScreenScale = 0.7;

/// The factor the whole app is being reduced by right now (1.0 means no
/// reduction). Screens that position something from a raw screen coordinate
/// (a pop-up menu opened where a press happened) divide that coordinate by
/// this number, because the app itself is laid out at the reduced size.
double activeScreenScale = 1.0;

/// The scale for a screen of the given size: 1.0 on any screen whose shorter
/// side is at least [kReferenceShortSide], smaller below it.
double screenScaleFor(Size size) {
  final double scale = size.shortestSide / kReferenceShortSide;
  return scale >= 1.0 ? 1.0 : scale.clamp(kMinScreenScale, 1.0).toDouble();
}

/// Makes the whole app fit a screen smaller than the one it is designed for.
/// It is placed once, around everything (in the MaterialApp builder).
///
/// On a screen at least as large as the design, it does nothing at all. On a
/// smaller screen the app is laid out as if the screen were larger, by the
/// scale factor, and the result is drawn shrunk to the real screen. Every
/// button, icon, space and letter is reduced together, and the layout sees a
/// screen of the matching size.
class ScreenScaler extends StatelessWidget {
  final Widget child;

  const ScreenScaler({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final MediaQueryData mediaQuery = MediaQuery.of(context);
    final double scale = screenScaleFor(mediaQuery.size);
    activeScreenScale = scale;

    if (scale >= 1.0) return child;

    final Size laidOutSize = Size(mediaQuery.size.width / scale, mediaQuery.size.height / scale);

    return SizedBox(
      width: mediaQuery.size.width,
      height: mediaQuery.size.height,
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: laidOutSize.width,
          maxWidth: laidOutSize.width,
          minHeight: laidOutSize.height,
          maxHeight: laidOutSize.height,
          child: Transform.scale(
            scale: scale,
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: laidOutSize.width,
              height: laidOutSize.height,
              child: MediaQuery(
                data: mediaQuery.copyWith(
                  size: laidOutSize,
                  padding: mediaQuery.padding / scale,
                  viewPadding: mediaQuery.viewPadding / scale,
                  viewInsets: mediaQuery.viewInsets / scale,
                  systemGestureInsets: mediaQuery.systemGestureInsets / scale,
                ),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
