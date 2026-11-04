import 'dart:async';

import 'package:flutter/material.dart';

import '../app_edition.dart';
import '../services/api_service.dart';
import '../widgets/capitalize_words_formatter.dart';
import '../widgets/champagne_backdrop.dart';
import '../widgets/password_field.dart';
import 'login_screen.dart';

/// The lock screen shown when someone touches the idle screen while a
/// person is logged in.
///
/// Nothing in the app can be reached until the logged-in person types their
/// own password again. The password is checked on this device against the
/// one typed at login, so the lock works with the server down as well. The
/// Log Out button (the same door icon as the top bar) lets a different
/// person sign in with their own username.
///
/// Five wrong passwords in a row make the lock wait thirty seconds before
/// it accepts another try.
class LockScreen extends StatefulWidget {
  final ApiService apiService;

  const LockScreen({super.key, required this.apiService});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  static const int _attemptsBeforeWait = 5;
  static const Duration _waitAfterTooManyAttempts = Duration(seconds: 30);

  final TextEditingController _passwordController = TextEditingController();
  final FocusNode _passwordFocus = FocusNode();

  String? _errorMessage;
  int _wrongAttempts = 0;
  DateTime? _lockedOutUntil;
  Timer? _waitTimer;

  @override
  void dispose() {
    _waitTimer?.cancel();
    _passwordController.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  String get _displayName {
    if (activeEdition == AppEdition.manager) return "Manager";
    return canonicalName(widget.apiService.currentUsername ?? "", keepAbbreviations: false);
  }

  bool get _isWaiting => _lockedOutUntil != null && DateTime.now().isBefore(_lockedOutUntil!);

  void _unlock() {
    if (_isWaiting) return;

    if (widget.apiService.passwordMatchesLogin(_passwordController.text)) {
      Navigator.of(context).pop();
      return;
    }

    _wrongAttempts++;
    _passwordController.clear();
    if (_wrongAttempts >= _attemptsBeforeWait) {
      _wrongAttempts = 0;
      _lockedOutUntil = DateTime.now().add(_waitAfterTooManyAttempts);
      _waitTimer?.cancel();
      _waitTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) return;
        if (!_isWaiting) timer.cancel();
        setState(() {});
      });
      setState(() => _errorMessage = "Too many wrong tries. Wait 30 seconds.");
    } else {
      setState(() => _errorMessage = "That is not the password. Try again.");
    }
    _passwordFocus.requestFocus();
  }

  void _logOut() {
    widget.apiService.logOut();
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (context) => const LoginScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final int secondsToWait = _isWaiting ? _lockedOutUntil!.difference(DateTime.now()).inSeconds + 1 : 0;

    return PopScope(
      canPop: false,
      child: Scaffold(
        body: ChampagneBackdrop(
          blurSigma: 2,
          showBadge: true,
          child: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 400),
                  child: Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: const Color(0xff0b1a33).withValues(alpha: 0.88),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xffd4af37), width: 0.8),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Icon(Icons.lock_outline, size: 40, color: Color(0xffd4af37)),
                        const SizedBox(height: 12),
                        const Text(
                          "LOCKED",
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, letterSpacing: 4, color: Color(0xffd4af37)),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          "Signed in as $_displayName",
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 14, color: Colors.white70),
                        ),
                        const SizedBox(height: 20),
                        PasswordField(
                          controller: _passwordController,
                          focusNode: _passwordFocus,
                          labelText: "Your Password",
                          autofocus: true,
                          onFieldSubmitted: (_) => _unlock(),
                        ),
                        if (_errorMessage != null) ...[
                          const SizedBox(height: 10),
                          Text(
                            _isWaiting ? "Too many wrong tries. Wait $secondsToWait seconds." : _errorMessage!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 13, color: Color(0xffe0584a)),
                          ),
                        ],
                        const SizedBox(height: 18),
                        SizedBox(
                          height: 48,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xffd4af37),
                              foregroundColor: const Color(0xff0a1426),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                            ),
                            onPressed: _isWaiting ? null : _unlock,
                            child: const Text("Unlock", style: TextStyle(fontWeight: FontWeight.bold)),
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextButton.icon(
                          onPressed: _logOut,
                          icon: const Icon(Icons.logout, size: 18),
                          label: const Text("Log Out"),
                          style: TextButton.styleFrom(foregroundColor: Colors.white70),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
