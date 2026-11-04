import 'dart:async';
import 'package:flutter/material.dart';
import '../app_edition.dart';
import '../services/api_service.dart';
import '../main.dart';
import '../widgets/password_field.dart';
import '../widgets/champagne_backdrop.dart';

/// The entry screen that forces people to log in before using the app.
///
/// There are two separate apps, and this screen adapts to whichever one it
/// is part of (see app_edition.dart):
///   - Receptionist app: "Staff Login" with a username and a password.
///     Receptionists and the shared Buffer login use it.
///   - Manager app: "Manager Login" with the PASSWORD ONLY. There is just
///     one manager, so there is no username to type; the screen signs in
///     to the manager's own account by itself.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

/// The pane the login form sits on: plain light-blue tinted glass. It is
/// see-through (no blur and no logo inside it), with a thin pale edge, so
/// the big badge behind it shows clearly through the glass.
class _LightGlassPanel extends StatelessWidget {
  final Widget child;

  const _LightGlassPanel({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xffcfe3f7).withValues(alpha: 0.40),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.80), width: 1.0),
      ),
      child: child,
    );
  }
}

class _LoginScreenState extends State<LoginScreen> {
  // Input tracking tools and network connectivity state variables
  final ApiService _apiService = ApiService();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final FocusNode _passwordFocusNode = FocusNode();
  bool _isLoading = false;
  String? _errorMessage;

  // After too many wrong passwords the server makes the person wait, a
  // little longer each time. These count that wait down on screen and keep
  // the Log In button off until it is over.
  int _lockSecondsLeft = 0;
  Timer? _lockTimer;

  final AppEdition _edition = activeEdition;
  bool get _isManagerApp => _edition == AppEdition.manager;

  @override
  void dispose() {
    // Clean up input fields from device memory when switching screens
    _usernameController.dispose();
    _passwordController.dispose();
    _passwordFocusNode.dispose();
    _lockTimer?.cancel();
    super.dispose();
  }

  /// The writing on the glass is dark navy on pale glass, so it stays easy
  /// to read whatever part of the badge happens to be behind it. The rest
  /// of the app is dark; this local theme only covers the glass card.
  ThemeData _glassTheme(BuildContext context) {
    return ThemeData(
      brightness: Brightness.light,
      colorScheme: ColorScheme.fromSeed(seedColor: kDeepNavy, brightness: Brightness.light).copyWith(primary: kDeepNavy),
      textSelectionTheme: const TextSelectionThemeData(cursorColor: kDeepNavy, selectionHandleColor: kDeepNavy),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.62),
        labelStyle: const TextStyle(color: kDeepNavy),
        floatingLabelStyle: const TextStyle(color: kDeepNavy, fontWeight: FontWeight.w600),
        prefixIconColor: kDeepNavy,
        suffixIconColor: kDeepNavy,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: kDeepNavy.withValues(alpha: 0.35)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: kDeepNavy, width: 1.6),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final double screenWidth = MediaQuery.of(context).size.width;
    final double cardWidth = screenWidth - 32 < 420 ? screenWidth - 32 : 420;

    return Scaffold(
      // The background continues from the splash screen: the same
      // champagne field whose centre matches the badge's own gold, with
      // the badge large behind the glass and only a small blur on the
      // field, so the badge reads clearly through the glass.
      body: ChampagneBackdrop(
        blurSigma: 2.5,
        showBadge: true,
        child: Center(
          // Scrollable view prevents screen errors when soft keyboards slide up
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16.0),
            child: SizedBox(
              width: cardWidth,
              child: _LightGlassPanel(
                child: Theme(
                  data: _glassTheme(context),
                  child: Builder(
                    builder: (context) => Padding(
                      padding: const EdgeInsets.all(28.0),
                      child: _buildFormColumn(),
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

  Widget _buildFormColumn() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // No logo inside the glass: the big badge behind it is the only one.
        const Text(
          "GRACELAND GUEST HOUSE",
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold, letterSpacing: 1.4, color: kDeepNavy),
        ),
        const SizedBox(height: 6),
        Text(
          _edition.loginTitle,
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: kDeepNavy.withValues(alpha: 0.75), letterSpacing: 1.0),
        ),
        const SizedBox(height: 26),

        // Staff app only: the username. Enter moves straight to the
        // password field, matching every other form in the app. The manager
        // app has no username field at all.
        if (!_isManagerApp) ...[
          TextField(
            controller: _usernameController,
            autofocus: true,
            style: const TextStyle(color: kDeepNavy),
            textInputAction: TextInputAction.next,
            onSubmitted: (_) => _passwordFocusNode.requestFocus(),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.account_circle_outlined, size: 20),
              labelText: 'Username',
            ),
          ),
          const SizedBox(height: 14),
        ],

        // Password entry field. Enter here presses the same button
        // "Log In" would. In the manager app this is the only field, so it
        // takes the cursor (and the keyboard) as soon as the screen opens.
        PasswordField(
          controller: _passwordController,
          focusNode: _passwordFocusNode,
          labelText: 'Password',
          autofocus: _isManagerApp,
          textInputAction: TextInputAction.done,
          onFieldSubmitted: (_) => _handleLoginAttempt(),
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            style: TextButton.styleFrom(foregroundColor: kDeepNavy),
            onPressed: _isLoading ? null : _showForgotPassword,
            child: const Text("Forgot password?", style: TextStyle(fontSize: 12)),
          ),
        ),

        // Dynamic error message display that appears when validation fails
        if (_errorMessage != null || _lockSecondsLeft > 0) ...[
          Text(
            _lockSecondsLeft > 0 ? "Too many wrong tries. Wait ${_formatWait(_lockSecondsLeft)}." : _errorMessage!,
            style: const TextStyle(color: Color(0xffa3231a), fontSize: 13, fontWeight: FontWeight.w600),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 14),
        ],

        // Full-width login action button with integrated loading spinner indicator
        SizedBox(
          width: double.infinity,
          height: 48,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xffd4af37), // The brand gold
              foregroundColor: kDeepNavy, // Deep navy lettering, from the badge itself
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            ),
            // Triggers a loading wheel or blocks interaction while processing
            onPressed: (_isLoading || _lockSecondsLeft > 0) ? null : _handleLoginAttempt,
            child: _isLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: kDeepNavy),
                  )
                : const Text("Log In", style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.0)),
          ),
        ),
      ],
    );
  }

  /// "Forgot password?" means different things in the two apps. In the
  /// manager app it goes straight to the one-time recovery code from first
  /// setup (it works entirely offline). In the staff app there is no
  /// self-service recovery on purpose: the manager resets it from the
  /// Change Login screen.
  void _showForgotPassword() {
    if (_isManagerApp) {
      _showAdministratorRecoveryDialog();
      return;
    }
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Forgot Password?"),
        content: const Text("Please ask the manager to reset your password from the Change Login screen."),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text("OK"))],
      ),
    );
  }

  void _showAdministratorRecoveryDialog() {
    final recoveryCodeController = TextEditingController();
    final newPasswordController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    bool isSubmitting = false;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            // One place that does the reset, so pressing Enter on the last
            // field and pressing the button behave exactly the same.
            Future<void> submitReset() async {
              if (isSubmitting) return;
              if (!formKey.currentState!.validate()) return;
              setDialogState(() => isSubmitting = true);
              try {
                await _apiService.recoverAdministratorPassword(
                  recoveryCode: recoveryCodeController.text.trim(),
                  newPassword: newPasswordController.text,
                );
                if (mounted) {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Password changed. You can now log in.")),
                  );
                }
              } catch (e) {
                setDialogState(() => isSubmitting = false);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(e.toString().replaceAll("Exception: ", ""))),
                  );
                }
              }
            }

            return AlertDialog(
              title: const Text("Manager Recovery"),
              content: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFormField(
                      controller: recoveryCodeController,
                      autofocus: true,
                      textCapitalization: TextCapitalization.characters,
                      textInputAction: TextInputAction.next,
                      onFieldSubmitted: (_) => FocusScope.of(context).nextFocus(),
                      decoration: const InputDecoration(labelText: "Recovery Code", border: OutlineInputBorder()),
                      validator: (val) => val == null || val.trim().isEmpty ? "Enter the recovery code" : null,
                    ),
                    const SizedBox(height: 12),
                    PasswordField(
                      controller: newPasswordController,
                      labelText: "New Password",
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => submitReset(),
                      validator: (val) => val == null || val.length < 8 ? "At least 8 characters" : null,
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
                ElevatedButton(
                  onPressed: isSubmitting ? null : submitReset,
                  child: isSubmitting
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text("Reset Password"),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// Sends credential entries out to the network service core to request clearance.
  /// "45 seconds" under a minute, otherwise "1:05".
  String _formatWait(int seconds) {
    if (seconds < 60) return "$seconds second${seconds == 1 ? '' : 's'}";
    return "${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}";
  }

  /// Starts the on-screen countdown of a wait the server asked for.
  void _startLockCountdown(int seconds) {
    _lockTimer?.cancel();
    setState(() {
      _lockSecondsLeft = seconds;
      _errorMessage = null;
    });
    _lockTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _lockSecondsLeft = _lockSecondsLeft - 1);
      if (_lockSecondsLeft <= 0) {
        timer.cancel();
        setState(() => _lockSecondsLeft = 0);
      }
    });
  }

  Future<void> _handleLoginAttempt() async {
    if (_lockSecondsLeft > 0) return;
    // The manager app never asks for a name: the one manager account is
    // signed in to automatically.
    final String username = _isManagerApp ? AppEditionRules.managerAccountUsername : _usernameController.text.trim();

    // Clear out any previous error logs from earlier attempts
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Stream user credentials out to the database via form-urlencoded mapping rules
      final loginPayload = await _apiService.loginUser(username, _passwordController.text);

      // Verify a valid network token payload exists before advancing
      if (loginPayload.containsKey('access_token')) {
        if (!mounted) return;

        final String role = loginPayload['role'] ?? '';

        // Each app only lets in the accounts built for it. Someone who
        // somehow has the right password for the OTHER app is turned away
        // here, and the login that was just made is cancelled.
        if (!_edition.allowsRole(role)) {
          _apiService.logOut();
          throw Exception(
            _isManagerApp
                ? "This password does not belong to the manager."
                : "This account cannot be used in the staff app.",
          );
        }

        final bool mustChangePassword = loginPayload['must_change_password'] == true;

        // An account that was handed a temporary password must choose its
        // own before doing anything else in the app.
        if (mustChangePassword) {
          final bool changed = await _promptForcedPasswordChange();
          if (!changed) {
            setState(() => _isLoading = false);
            return;
          }
        }

        // Only the manager's own app has internet, so this is the one
        // place a fresh exchange rate is looked up — nothing checks in
        // the background, and receptionist tablets never attempt this.
        if (_isManagerApp) {
          await _apiService.lookUpAndSaveLiveExchangeRate();
        }
        await _apiService.syncSharedExchangeRate();

        // The receptionist's tablet reads the approved price list ONCE, here
        // at login, and keeps it for the whole session. Bookings and
        // extensions use that saved copy, so they keep working if the
        // server goes down, and prices never change in the middle of a
        // shift; a new shift's login picks up any new prices.
        if (!_isManagerApp) {
          await _apiService.loadAndSaveRoomPricing();
        }

        if (!mounted) return;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => _isManagerApp
                ? MainNavigationShell(apiService: _apiService)
                : ReceptionistNavigationShell(apiService: _apiService),
          ),
        );
      } else {
        throw Exception("Login did not return a valid access token.");
      }
    } catch (error) {
      // Catch connection errors, bad routing configurations, or invalid credentials
      final String message = error.toString().replaceAll("Exception: ", "");
      // "Too many wrong tries. Wait 30 seconds." (or "1 minute"): count it down.
      final RegExpMatch? wait = RegExp(r'Wait (\d+) (second|minute)').firstMatch(message);
      if (wait != null) {
        final int amount = int.parse(wait.group(1)!);
        _startLockCountdown(wait.group(2) == "minute" ? amount * 60 : amount);
      } else {
        setState(() {
          _errorMessage = message;
        });
      }
    } finally {
      // Release the thread lock and hide the processing animation spinner wheel
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  /// Blocks progress into the app until a temporary password has been
  /// replaced. Returns true once a new password has been set.
  Future<bool> _promptForcedPasswordChange() async {
    final currentPasswordController = TextEditingController(text: _passwordController.text);
    final newPasswordController = TextEditingController();
    final confirmController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    bool isSubmitting = false;

    final bool? result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            // Shared by the Save button and by Enter on the last field.
            Future<void> submitNewPassword() async {
              if (isSubmitting) return;
              if (!formKey.currentState!.validate()) return;
              setDialogState(() => isSubmitting = true);
              try {
                await _apiService.changeOwnPassword(
                  currentPassword: currentPasswordController.text,
                  newPassword: newPasswordController.text,
                );
                if (context.mounted) Navigator.pop(context, true);
              } catch (e) {
                setDialogState(() => isSubmitting = false);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(e.toString().replaceAll("Exception: ", ""))),
                  );
                }
              }
            }

            return AlertDialog(
              title: const Text("Choose a New Password"),
              content: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      "A temporary password was set for this account. Please choose your own before continuing.",
                      style: TextStyle(fontSize: 13, color: Colors.white70),
                    ),
                    const SizedBox(height: 16),
                    PasswordField(
                      controller: newPasswordController,
                      labelText: "New Password",
                      autofocus: true,
                      textInputAction: TextInputAction.next,
                      validator: (val) => val == null || val.length < 8 ? "At least 8 characters" : null,
                    ),
                    const SizedBox(height: 12),
                    PasswordField(
                      controller: confirmController,
                      labelText: "Confirm New Password",
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => submitNewPassword(),
                      validator: (val) => val != newPasswordController.text ? "Passwords do not match" : null,
                    ),
                  ],
                ),
              ),
              actions: [
                ElevatedButton(
                  onPressed: isSubmitting ? null : submitNewPassword,
                  child: isSubmitting
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text("Save"),
                ),
              ],
            );
          },
        );
      },
    );
    return result ?? false;
  }
}
