import 'package:flutter/material.dart';

// Links to the shared network service core tool
import '../../services/api_service.dart';
import '../../widgets/password_field.dart';

/// Lets a manager change another employee's username, password, or both.
/// The manager's own password confirms the action, so a phone left
/// unlocked cannot be used to take over an account. Restricted to
/// manager hardware, same as every other manager-only action.
class ChangeLoginView extends StatefulWidget {
  final ApiService apiService;

  const ChangeLoginView({super.key, required this.apiService});

  @override
  State<ChangeLoginView> createState() => _ChangeLoginViewState();
}

class _ChangeLoginViewState extends State<ChangeLoginView> {
  final _formKey = GlobalKey<FormState>();

  final TextEditingController _targetUsernameController = TextEditingController();
  final TextEditingController _newUsernameController = TextEditingController();
  final TextEditingController _newPasswordController = TextEditingController();
  final TextEditingController _confirmPasswordController = TextEditingController();
  final TextEditingController _managerPasswordController = TextEditingController();

  // Lets Enter on "Confirm New Password" jump straight to "Your Password",
  // stepping over the "temporary password" tick box in between (that is
  // ticked by tapping, not typed).
  final FocusNode _managerPasswordFocus = FocusNode();

  bool _isTemporaryPassword = false;
  bool _isProcessing = false;

  @override
  void dispose() {
    _targetUsernameController.dispose();
    _newUsernameController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    _managerPasswordController.dispose();
    _managerPasswordFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "Change Login",
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xffd4af37)),
              ),
              const SizedBox(height: 20),
              Card(
                color: const Color(0xff111f3a),
                elevation: 4,
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextFormField(
                        controller: _targetUsernameController,
                        autofocus: true,
                        textInputAction: TextInputAction.next,
                        onFieldSubmitted: (_) => FocusScope.of(context).nextFocus(),
                        decoration: const InputDecoration(
                          labelText: "Employee Username",
                          prefixIcon: Icon(Icons.person_outline),
                          border: OutlineInputBorder(),
                        ),
                        validator: (val) => val == null || val.trim().isEmpty ? "Enter the employee's username" : null,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _newUsernameController,
                        textInputAction: TextInputAction.next,
                        onFieldSubmitted: (_) => FocusScope.of(context).nextFocus(),
                        decoration: const InputDecoration(
                          labelText: "New Username (leave blank to keep it)",
                          prefixIcon: Icon(Icons.badge_outlined),
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 16),
                      PasswordField(
                        controller: _newPasswordController,
                        labelText: "New Password (leave blank to keep it)",
                        textInputAction: TextInputAction.next,
                        validator: (val) {
                          if (val == null || val.isEmpty) return null;
                          if (val.length < 8) return "Password must be at least 8 characters";
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      PasswordField(
                        controller: _confirmPasswordController,
                        labelText: "Confirm New Password",
                        textInputAction: TextInputAction.next,
                        onFieldSubmitted: (_) => _managerPasswordFocus.requestFocus(),
                        validator: (val) {
                          if (_newPasswordController.text.isEmpty) return null;
                          if (val != _newPasswordController.text) return "Passwords do not match";
                          return null;
                        },
                      ),
                      CheckboxListTile(
                        value: _isTemporaryPassword,
                        onChanged: (val) => setState(() => _isTemporaryPassword = val ?? false),
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: const Text(
                          "This is a temporary password",
                          style: TextStyle(fontSize: 14),
                        ),
                        subtitle: const Text(
                          "The employee must choose their own password the next time they log in.",
                          style: TextStyle(fontSize: 12, color: Colors.white54),
                        ),
                      ),
                      const Divider(height: 32),
                      PasswordField(
                        controller: _managerPasswordController,
                        focusNode: _managerPasswordFocus,
                        labelText: "Your Password (to confirm)",
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) => _handleChangeLogin(),
                        validator: (val) => val == null || val.isEmpty ? "Enter your own password to confirm" : null,
                      ),
                      const SizedBox(height: 32),
                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xffd4af37),
                            foregroundColor: Colors.black,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                          ),
                          icon: const Icon(Icons.lock_reset),
                          onPressed: _isProcessing ? null : _handleChangeLogin,
                          label: _isProcessing
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                                )
                              : const Text("Save Changes", style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _handleChangeLogin() async {
    if (!_formKey.currentState!.validate()) return;

    if (_newUsernameController.text.trim().isEmpty && _newPasswordController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Enter a new username, a new password, or both.")),
      );
      return;
    }

    setState(() => _isProcessing = true);

    try {
      final result = await widget.apiService.changeLogin(
        targetUsername: _targetUsernameController.text.trim(),
        newUsername: _newUsernameController.text.trim().isEmpty ? null : _newUsernameController.text.trim(),
        newPassword: _newPasswordController.text.isEmpty ? null : _newPasswordController.text,
        isTemporaryPassword: _isTemporaryPassword,
        managerPassword: _managerPasswordController.text,
      );

      final bool wasQueuedOffline = result['queued_offline'] == true;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: wasQueuedOffline ? const Color(0xffc9971f) : const Color(0xff14703f),
            content: Text(
              wasQueuedOffline ? "Saved. Pending, will be sent when the connection returns." : "Login updated.",
            ),
          ),
        );
        _targetUsernameController.clear();
        _newUsernameController.clear();
        _newPasswordController.clear();
        _confirmPasswordController.clear();
        _managerPasswordController.clear();
        setState(() => _isTemporaryPassword = false);
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xffc0392b),
            content: Text("Could not update the login: ${error.toString().replaceAll("Exception: ", "")}"),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }
}
