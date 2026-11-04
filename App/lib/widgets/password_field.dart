import 'package:flutter/material.dart';

/// A password entry field with a show/hide "eye" toggle, used on every
/// password field in the app — login, Change Login, onboarding, and
/// anywhere else a password is typed — so staff can check what they
/// typed before submitting instead of guessing at a hidden field.
class PasswordField extends StatefulWidget {
  final TextEditingController controller;
  final String labelText;
  final String? Function(String?)? validator;
  final TextInputAction textInputAction;
  final void Function(String)? onFieldSubmitted;
  final bool autofocus;
  final FocusNode? focusNode;

  const PasswordField({
    super.key,
    required this.controller,
    this.labelText = "Password",
    this.validator,
    this.textInputAction = TextInputAction.done,
    this.onFieldSubmitted,
    this.autofocus = false,
    this.focusNode,
  });

  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  bool _isVisible = false;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: widget.controller,
      focusNode: widget.focusNode,
      obscureText: !_isVisible,
      autofocus: widget.autofocus,
      textInputAction: widget.textInputAction,
      onFieldSubmitted: widget.onFieldSubmitted,
      validator: widget.validator,
      decoration: InputDecoration(
        labelText: widget.labelText,
        prefixIcon: const Icon(Icons.lock_outline),
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(
          icon: Icon(_isVisible ? Icons.visibility_off : Icons.visibility),
          tooltip: _isVisible ? "Hide password" : "Show password",
          onPressed: () => setState(() => _isVisible = !_isVisible),
        ),
      ),
    );
  }
}
