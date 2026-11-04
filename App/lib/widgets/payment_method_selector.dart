import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'momo_mask_field.dart';

/// The payment choice shared by the booking, extension and shop sale
/// screens. The first row offers Cash or Transfer; choosing Transfer
/// reveals a second row with MoMo or Bank, and the matching detail field
/// (the wallet number, or the last four digits of the sender's account).
///
/// The chosen payment type is one of "CASH", "MOMO" or "BANK". The screen
/// that uses this widget owns the value and both text controllers.
class PaymentMethodSelector extends StatelessWidget {
  final String paymentMode;
  final ValueChanged<String> onChanged;
  final TextEditingController momoController;
  final TextEditingController bankController;

  const PaymentMethodSelector({
    super.key,
    required this.paymentMode,
    required this.onChanged,
    required this.momoController,
    required this.bankController,
  });

  static const Color _navy = Color(0xff0a1426);
  static const Color _gold = Color(0xffd4af37);

  /// A plain message when the transfer details for [mode] are incomplete,
  /// or null when they are fine. For screens that submit without a Form.
  static String? detailsProblem(String mode, String momoNumber, String bankDigits) {
    if (mode == "MOMO" && momoNumber.trim().length != 10) return "Enter the 10-digit MoMo number.";
    if (mode == "BANK" && bankDigits.trim().length != 4) return "Enter the last 4 digits of the sender's account.";
    return null;
  }

  void _choose(String mode) {
    if (mode != "MOMO") momoController.clear();
    if (mode != "BANK") bankController.clear();
    onChanged(mode);
  }

  Widget _toggle({
    required List<String> labels,
    required int selectedIndex,
    required void Function(int) onPressed,
  }) {
    return ToggleButtons(
      isSelected: [for (int i = 0; i < labels.length; i++) i == selectedIndex],
      onPressed: onPressed,
      borderRadius: BorderRadius.circular(8),
      selectedColor: _navy,
      fillColor: _gold,
      children: [
        for (final label in labels)
          Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(label)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool isTransfer = paymentMode != "CASH";

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text("Payment Method:", style: TextStyle(fontWeight: FontWeight.bold)),
            _toggle(
              labels: const ["CASH", "TRANSFER"],
              selectedIndex: isTransfer ? 1 : 0,
              onPressed: (index) {
                if (index == 0) {
                  _choose("CASH");
                } else if (!isTransfer) {
                  // MoMo is the usual transfer, so it is picked first.
                  _choose("MOMO");
                }
              },
            ),
          ],
        ),
        if (isTransfer) ...[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: _toggle(
              labels: const ["MOMO", "BANK"],
              selectedIndex: paymentMode == "BANK" ? 1 : 0,
              onPressed: (index) => _choose(index == 0 ? "MOMO" : "BANK"),
            ),
          ),
        ],
        const SizedBox(height: 20),
        if (paymentMode == "MOMO") ...[
          MomoMaskField(
            controller: momoController,
            validator: (value) {
              if (value == null || value.length != 10) return "Must be exactly 10 digits.";
              return null;
            },
          ),
          const SizedBox(height: 20),
        ],
        if (paymentMode == "BANK") ...[
          BankSenderField(controller: bankController),
          const SizedBox(height: 20),
        ],
      ],
    );
  }
}

/// Entry field for the last four digits of the account a bank transfer was
/// sent from. Only these four digits are ever stored.
class BankSenderField extends StatelessWidget {
  final TextEditingController controller;

  const BankSenderField({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      keyboardType: TextInputType.number,
      textInputAction: TextInputAction.next,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(4),
      ],
      validator: (value) {
        if (value == null || value.length != 4) return "Enter the last 4 digits.";
        return null;
      },
      decoration: const InputDecoration(
        labelText: "Sender's account",
        prefixIcon: Icon(Icons.account_balance),
        border: OutlineInputBorder(),
        hintText: "Last 4 digits",
      ),
    );
  }
}
