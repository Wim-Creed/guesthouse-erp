import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A reusable text entry form field that enforces a strict 10-character restriction pattern for mobile money wallets.
class MomoMaskField extends StatefulWidget {
  final TextEditingController controller;
  final String labelText;
  final FormFieldValidator<String>? validator;

  const MomoMaskField({
    super.key,
    required this.controller,
    this.labelText = "Mobile Money Wallet Number",
    this.validator,
  });

  @override
  State<MomoMaskField> createState() => _MomoMaskFieldState();
}

class _MomoMaskFieldState extends State<MomoMaskField> {
  // The "must be exactly 10 digits" hint only appears once there is
  // actually something typed that falls short of that — not sitting
  // there permanently as noise on an empty or already-correct field.
  bool _showLengthHint = false;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: widget.controller,
      keyboardType: TextInputType.phone,
      // Enter carries on to the next field (the amount received) rather
      // than just closing the keyboard.
      textInputAction: TextInputAction.next,
      validator: widget.validator,

      /// Restricts keyboard entry to numeric patterns and strictly limits length boundaries to ten slots.
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(10),
      ],
      onChanged: (value) {
        final bool shouldShow = value.isNotEmpty && value.length != 10;
        if (shouldShow != _showLengthHint) setState(() => _showLengthHint = shouldShow);
      },
      decoration: InputDecoration(
        labelText: widget.labelText,
        prefixIcon: const Icon(Icons.phone_android),
        border: const OutlineInputBorder(),
        hintText: "0XX XXX XXXX",
        helperText: _showLengthHint ? "Must be exactly 10 digits." : null,
      ),
    );
  }
}
