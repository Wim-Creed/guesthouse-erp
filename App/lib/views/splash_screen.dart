import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api_service.dart';
import '../widgets/champagne_backdrop.dart';
import 'lock_screen.dart';
import 'login_screen.dart';

/// The brand gold used for accents and buttons throughout the app.
const Color kBrandGold = Color(0xffd4af37);

/// How long the screen can sit untouched before the splash screen covers it
/// as an idle screen. One number, so it is easy to change.
const Duration kIdleSplashDelay = Duration(minutes: 5);

/// How long the device can sit untouched before the person logged in is
/// signed out. Every touch or key press starts the count again, so the
/// sign-out can only ever happen to a device nobody is using.
const Duration kIdleLogoutDelay = Duration(hours: 1);

/// The one navigator of the app. The idle guard sits above the screens, so it
/// reaches the lock screen and the login screen through this key.
final GlobalKey<NavigatorState> kAppNavigatorKey = GlobalKey<NavigatorState>();

/// The splash screen: the full Graceland Guesthouse badge, large and
/// centred on the champagne-gold field, fading gently in and then breathing
/// slowly. It has two uses:
///
///   - At launch it is the first screen. It keeps breathing until it is
///     tapped, and the tap dissolves into the login screen.
///   - As the idle screen it is laid over whatever is open once the app has
///     been untouched for [kIdleSplashDelay] (see [IdleSplashGuard]). A tap
///     removes it and the app is exactly where it was left.
///
/// The field behind the badge is built from the badge's own measured gold
/// (see champagne_backdrop.dart), deepest and exactly matching at the
/// badge's rim and growing lighter toward the corners, so the badge's disc
/// cannot be told apart from the background. The badge has no glow or
/// shadow around it for that reason: any halo would draw its edge back in.
class SplashScreen extends StatefulWidget {
  /// Called when the screen is tapped. Left empty, a tap moves on to the
  /// login screen (the launch behaviour); the idle screen passes its own
  /// function to uncover the app instead.
  final VoidCallback? onTapped;

  const SplashScreen({super.key, this.onTapped});

  /// True while the launch splash is the screen being shown, so the idle
  /// screen is not laid over it.
  static final ValueNotifier<bool> launchSplashVisible = ValueNotifier<bool>(false);

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  /// The badge's diameter on this screen. The backdrop is told the same
  /// number so the two agree exactly.
  static const double _badgeDiameter = 300;

  late final AnimationController _breathingController;
  late final Animation<double> _breathingScale;
  bool _isLeaving = false;

  @override
  void initState() {
    super.initState();

    if (widget.onTapped == null) {
      // Marked after the first frame so the notifier is never changed while
      // the widget tree is still being built.
      WidgetsBinding.instance.addPostFrameCallback((_) => SplashScreen.launchSplashVisible.value = true);
    }

    _breathingController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1250),
    )..repeat(reverse: true);

    _breathingScale = Tween<double>(begin: 0.96, end: 1.0).animate(
      CurvedAnimation(parent: _breathingController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    if (widget.onTapped == null) SplashScreen.launchSplashVisible.value = false;
    _breathingController.dispose();
    super.dispose();
  }

  void _handleTap() {
    if (widget.onTapped != null) {
      widget.onTapped!();
      return;
    }
    if (_isLeaving) return;
    _isLeaving = true;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        // A slow dissolve into the login screen, whose own background is
        // this same field, so the two read as one continuous scene.
        transitionDuration: const Duration(milliseconds: 700),
        pageBuilder: (context, animation, secondaryAnimation) => const LoginScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kChampagne,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _handleTap,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final double shortSide = constraints.biggest.shortestSide;
            // Never wider than the screen allows, but otherwise the same
            // size the backdrop is built around.
            final double diameter = _badgeDiameter < shortSide * 0.8 ? _badgeDiameter : shortSide * 0.8;
            return ChampagneBackdrop(
              // The backdrop sizes its disc from the screen's shorter side;
              // handing it the matching share keeps it equal to the badge.
              badgeShare: diameter / shortSide,
              maxBadgeDiameter: diameter,
              child: Stack(
                children: [
                  Center(
                    // The first 700ms is a fade-in, so the badge appears
                    // rather than snapping onto the screen.
                    child: TweenAnimationBuilder<double>(
                      tween: Tween<double>(begin: 0.0, end: 1.0),
                      duration: const Duration(milliseconds: 700),
                      curve: Curves.easeOut,
                      builder: (context, opacity, child) => Opacity(opacity: opacity, child: child),
                      child: ScaleTransition(
                        scale: _breathingScale,
                        child: Image.asset(
                          'lib/branding/graceland_logo_full.png',
                          width: diameter,
                          height: diameter,
                          filterQuality: FilterQuality.high,
                          isAntiAlias: true,
                        ),
                      ),
                    ),
                  ),
                  // The word WELCOME sits just under the badge, with a
                  // quiet line below it saying how to carry on.
                  Positioned(
                    left: 0,
                    right: 0,
                    top: constraints.maxHeight / 2 + diameter / 2 + 28,
                    child: Column(
                      children: [
                        const Text(
                          "WELCOME",
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 6,
                            color: kDeepNavy,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          "TAP TO CONTINUE",
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w500,
                            letterSpacing: 3,
                            color: kDeepNavy.withValues(alpha: 0.55),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Wraps the whole app (placed once, in the MaterialApp builder). It does
/// three jobs:
///
///   - After [kIdleSplashDelay] with no touch and no key press, the splash
///     screen covers whatever is open.
///   - A tap on the cover removes it. If a person is logged in, the lock
///     screen then asks for their password before anything can be used; the
///     app is exactly where it was left once the password is right.
///   - After [kIdleLogoutDelay] with no touch and no key press, the person
///     logged in is signed out and the login screen is shown.
///
/// Nothing is closed or saved by the cover or the lock.
///
/// Anything that needs the person's attention at once (a room's Time's Up
/// warning, for example) calls [IdleSplashGuard.uncover] first and sets
/// [IdleSplashGuard.alertOnScreen] while it is showing, so the cover can
/// never hide it. The password lock stays in place beneath such a prompt.
class IdleSplashGuard extends StatefulWidget {
  final Widget child;

  const IdleSplashGuard({super.key, required this.child});

  /// Removes the idle cover if it is showing and starts the idle count
  /// again. If a person is logged in, the lock screen takes the cover's
  /// place, so the app stays locked. Safe to call at any time.
  static void uncover() => _activeState?._uncover();

  /// True while a prompt that must not be hidden is on screen. The idle
  /// cover waits until it is gone.
  static bool alertOnScreen = false;

  static _IdleSplashGuardState? _activeState;

  @override
  State<IdleSplashGuard> createState() => _IdleSplashGuardState();
}

class _IdleSplashGuardState extends State<IdleSplashGuard> {
  Timer? _idleTimer;
  Timer? _logoutTimer;
  bool _isCovered = false;
  bool _lockIsOpen = false;

  @override
  void initState() {
    super.initState();
    IdleSplashGuard._activeState = this;
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
    _restartTimers();
  }

  @override
  void dispose() {
    if (IdleSplashGuard._activeState == this) IdleSplashGuard._activeState = null;
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    _idleTimer?.cancel();
    _logoutTimer?.cancel();
    super.dispose();
  }

  bool _onKeyEvent(KeyEvent event) {
    _onActivity();
    return false;
  }

  /// Any touch or key press: the device is in use.
  void _onActivity() {
    ApiService.current?.markTouched();
    _restartLogoutTimer();
    if (!_isCovered) _restartIdleTimer();
  }

  void _restartTimers() {
    _restartIdleTimer();
    _restartLogoutTimer();
  }

  void _restartIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(kIdleSplashDelay, _cover);
  }

  void _restartLogoutTimer() {
    _logoutTimer?.cancel();
    _logoutTimer = Timer(kIdleLogoutDelay, _signOutForInactivity);
  }

  void _cover() {
    // The launch splash is itself the splash screen, so nothing is laid
    // over it, and a prompt that needs attention is never covered.
    if (!mounted || SplashScreen.launchSplashVisible.value || IdleSplashGuard.alertOnScreen) {
      _restartIdleTimer();
      return;
    }
    setState(() => _isCovered = true);
  }

  /// Removes the cover. A person who is logged in gets the lock screen next.
  void _uncover() {
    if (!mounted) return;
    final bool wasCovered = _isCovered;
    if (_isCovered) setState(() => _isCovered = false);
    _restartTimers();
    if (wasCovered) _openLockIfLoggedIn();
  }

  void _openLockIfLoggedIn() {
    final ApiService? service = ApiService.current;
    final NavigatorState? navigator = kAppNavigatorKey.currentState;
    if (service == null || navigator == null || _lockIsOpen) return;

    _lockIsOpen = true;
    navigator
        .push(PageRouteBuilder<void>(
          opaque: true,
          transitionDuration: const Duration(milliseconds: 350),
          pageBuilder: (context, animation, secondaryAnimation) => LockScreen(apiService: service),
          transitionsBuilder: (context, animation, secondaryAnimation, child) =>
              FadeTransition(opacity: animation, child: child),
        ))
        .then((_) => _lockIsOpen = false);
  }

  /// One hour with the device untouched: the person is signed out and the
  /// login screen is shown. Anything still waiting to be sent stays saved on
  /// the device and is sent after the next login.
  void _signOutForInactivity() {
    final ApiService? service = ApiService.current;
    if (service == null) {
      _restartLogoutTimer();
      return;
    }
    service.logOut();
    if (mounted && _isCovered) setState(() => _isCovered = false);
    _lockIsOpen = false;
    kAppNavigatorKey.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(builder: (context) => const LoginScreen()),
      (route) => false,
    );
    _restartTimers();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _onActivity(),
      onPointerMove: (_) => _onActivity(),
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (_isCovered) Positioned.fill(child: SplashScreen(onTapped: _uncover)),
        ],
      ),
    );
  }
}
