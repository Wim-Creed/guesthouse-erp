import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Rounds a cedi change amount DOWN to a value that can actually be handed
/// back with real coins and notes: the pesewa part is always one of .00,
/// .20, .40, .50, .60, .70, .80 or .90. This is the one place this rule
/// lives — every screen that hands back change (booking, extension, shop
/// sale) goes through this same widget, so the rule can never drift
/// between screens.
///
/// Any change under a cedi that does not land on one of those exact
/// values is rounded down to the nearest one below it. The business
/// absorbs the small remainder rather than being unable to make exact
/// change — it is never rounded up, which would mean handing back more
/// than was actually owed.
double roundDownToHandableChange(double rawChangeInGhs) {
  if (rawChangeInGhs <= 0) return 0.0;

  // Working in whole pesewas (cents) avoids floating-point rounding
  // surprises that working directly in cedi decimals can produce.
  final int totalPesewas = (rawChangeInGhs * 100).round();
  final int wholeCedis = totalPesewas ~/ 100;
  final int leftoverPesewas = totalPesewas % 100;

  const List<int> handablePesewaEndings = [0, 10, 20, 40, 50, 60, 70, 80, 90];
  int chosenEnding = 0;
  for (final ending in handablePesewaEndings) {
    if (ending <= leftoverPesewas) chosenEnding = ending;
  }

  return wholeCedis + (chosenEnding / 100.0);
}

/// A universal widget that manages dual-currency payment input: whatever
/// currency the guest hands over, the total due is always tracked in
/// cedis underneath, and the change handed back is always in cedis too —
/// the business only ever holds cedis to give back, never dollars.
///
/// The amount tendered is capped at a generous but finite ceiling
/// (_maxReasonableTenderedGhs below). Without a cap, a long string of
/// digits typed or pasted into this field can produce a change figure so
/// large it stops behaving like a normal number on screen. No real sale
/// or booking comes anywhere close to this ceiling, so it never gets in
/// the way of a real transaction — it only stops a mistyped or pasted
/// wall of digits from being treated as valid input.
class CurrencyToggleTerminal extends StatefulWidget {
  /// The total cost of the transaction in the default base currency (GHS).
  final double totalCostInGhs;

  /// The active exchange conversion rate retrieved from the local backend service.
  final double exchangeRate;

  /// Called whenever the calculated values update.
  ///   cashTenderedInGhs   — what was handed over, always converted to cedis
  ///   changeReturnedInGhs — the change to hand back, always in cedis,
  ///                         already rounded to something that can really
  ///                         be handed over
  ///   usdReceived         — the raw dollar amount handed over, only set
  ///                         when the guest paid in dollars; kept purely
  ///                         as a small note alongside the cedi record
  ///   isSufficient        — false when the amount tendered does not cover
  ///                         the total due, so the calling screen can hold
  ///                         off on submitting
  final void Function(double cashTenderedInGhs, double changeReturnedInGhs, double? usdReceived, bool isSufficient)
      onValuesChanged;

  /// Whether to show the change-due block below the amount tendered field.
  /// The amount tendered is always needed for the record regardless of
  /// payment method, but "change due" has no real meaning for a MoMo
  /// transfer, so screens hide it for that payment mode.
  final bool showChangeDue;

  /// Whether the guest may pay in dollars. Turned off for MoMo, which only
  /// moves cedis; the screen then stays on cedis.
  final bool allowDollars;

  /// Only turned on by the one screen where this field is genuinely the
  /// first thing the receptionist should type into once it appears (the
  /// Shop POS cash field) — left off everywhere else, since intake and
  /// extend-stay forms already autofocus their own earlier fields (guest
  /// name, duration) and this would otherwise steal focus from those.
  final bool autofocus;

  /// Called when Enter (or the keyboard's Done key) is pressed in the Cash
  /// Received field. This is always the LAST field on a screen, so the
  /// screen passes the same function its Confirm button runs: Enter then
  /// confirms the booking, the extension or the shop sale, exactly like
  /// pressing the button.
  final VoidCallback? onSubmitted;

  const CurrencyToggleTerminal({
    super.key,
    required this.totalCostInGhs,
    required this.exchangeRate,
    required this.onValuesChanged,
    this.showChangeDue = true,
    this.allowDollars = true,
    this.autofocus = false,
    this.onSubmitted,
  });

  @override
  State<CurrencyToggleTerminal> createState() => _CurrencyToggleTerminalState();
}

class _CurrencyToggleTerminalState extends State<CurrencyToggleTerminal> {
  // No genuine sale or booking is anywhere near this size; this exists
  // purely to reject a mistyped or pasted wall of digits before it turns
  // into a nonsensical change figure.
  static const double _maxReasonableTenderedGhs = 100000.0;

  String _selectedCurrency = "GHS";
  final TextEditingController _tenderedController = TextEditingController();
  double _changeReturned = 0.0;

  @override
  void didUpdateWidget(covariant CurrencyToggleTerminal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.allowDollars && _selectedCurrency == "USD") {
      _selectedCurrency = "GHS";
      _tenderedController.clear();
      _changeReturned = 0.0;
      _calculateResults();
    } else if (oldWidget.totalCostInGhs != widget.totalCostInGhs) {
      _calculateResults();
    }
  }

  /// Calculates the cedi amount actually received and the change owed.
  /// The guest's own currency choice is only ever used to work out these
  /// two cedi figures — nothing downstream of this widget ever needs to
  /// know or care what currency was physically handed over, except for
  /// the small dollar note kept alongside a dollar payment.
  void _calculateResults() {
    final double enteredAmount = double.tryParse(_tenderedController.text) ?? 0.0;

    // What the guest actually handed over, converted to cedis regardless
    // of which currency they paid in, so it can be compared directly
    // against the room or sale's cost, which is always tracked in cedis.
    final double tenderedInGhs = _selectedCurrency == "USD" ? enteredAmount * widget.exchangeRate : enteredAmount;

    final bool coversTotal = _tenderedController.text.isEmpty || tenderedInGhs >= widget.totalCostInGhs;
    final bool isWithinReasonableLimit = tenderedInGhs <= _maxReasonableTenderedGhs;
    final bool isSufficient = coversTotal && isWithinReasonableLimit;

    setState(() {
      if (tenderedInGhs >= widget.totalCostInGhs && isWithinReasonableLimit) {
        final double rawChangeInGhs = tenderedInGhs - widget.totalCostInGhs;
        _changeReturned = roundDownToHandableChange(rawChangeInGhs);
      } else {
        _changeReturned = 0.0;
      }
    });

    widget.onValuesChanged(
      tenderedInGhs,
      _changeReturned,
      _selectedCurrency == "USD" ? enteredAmount : null,
      isSufficient,
    );
  }

  @override
  Widget build(BuildContext context) {
    // When showing the total in dollars, the converted figure is always
    // rounded UP to the nearest cent — the business is never quoted less
    // than what is really owed once converted. This is the deliberate
    // mirror image of the change-rounds-DOWN rule above: price up,
    // change down, kept as two separate roundings in the code so they can
    // never be confused with each other.
    final double displayedCost = _selectedCurrency == "USD"
        ? (widget.totalCostInGhs / widget.exchangeRate * 100).ceil() / 100.0
        : widget.totalCostInGhs;

    final String currencySymbol = _selectedCurrency == "USD" ? "\$" : "₵";
    final double parsedTendered = double.tryParse(_tenderedController.text) ?? 0.0;
    final double tenderedInGhsNow = _selectedCurrency == "USD" ? parsedTendered * widget.exchangeRate : parsedTendered;
    final bool hasTypedAnything = _tenderedController.text.isNotEmpty;
    final bool isAmountInsufficient = hasTypedAnything && tenderedInGhsNow < widget.totalCostInGhs;
    final bool isAmountTooHigh = tenderedInGhsNow > _maxReasonableTenderedGhs;

    String? tenderedFieldErrorText;
    if (isAmountInsufficient) {
      tenderedFieldErrorText = "Amount is less than the total due";
    } else if (isAmountTooHigh) {
      tenderedFieldErrorText = "Amount entered is unrealistically high";
    }

    // What the "Cash Given" block below shows: before anything is typed,
    // or while the typed amount does not yet form a valid payment (too
    // little, or unrealistically large), it stays at a neutral ₵0.00
    // rather than showing "No Change Due" or a nonsensical change figure.
    // "No Change Due" only appears once a valid amount has actually been
    // entered and it happens to exactly cover the cost.
    final bool isInAnInvalidState = isAmountInsufficient || isAmountTooHigh;
    final String cashGivenText = (!hasTypedAnything || isInAnInvalidState)
        ? "₵ 0.00"
        : (_changeReturned > 0 ? "₵ ${_changeReturned.toStringAsFixed(2)}" : "No Change Due");

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        /// Interactive selection switch to change the active working payment currency.
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              "Transaction Currency",
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
            ),
            if (widget.allowDollars)
            ToggleButtons(
              isSelected: [_selectedCurrency == "GHS", _selectedCurrency == "USD"],
              onPressed: (int index) {
                setState(() {
                  _selectedCurrency = index == 0 ? "GHS" : "USD";
                  _tenderedController.clear();
                  _changeReturned = 0.0;
                });
                _calculateResults();
              },
              borderRadius: BorderRadius.circular(8),
              selectedColor: const Color(0xff0a1426),
              fillColor: const Color(0xffd4af37),
              children: const [
                Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text("GHS (₵)")),
                Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text("USD (\$)")),
              ],
            ),
          ],
        ),
        const SizedBox(height: 16),

        /// Displays the converted grand total amount due for clarity.
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.black26,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xffd4af37), width: 0.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("TOTAL AMOUNT DUE", style: TextStyle(fontSize: 12, color: Colors.white70)),
              const SizedBox(height: 4),
              Text(
                "$currencySymbol ${displayedCost.toStringAsFixed(2)}",
                style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Color(0xffd4af37)),
              ),
              if (_selectedCurrency == "USD") ...[
                const SizedBox(height: 4),
                Text(
                  "Base Conversion Value: ₵ ${widget.totalCostInGhs.toStringAsFixed(2)}",
                  style: const TextStyle(fontSize: 12, color: Colors.white54, fontStyle: FontStyle.italic),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),

        /// Numerical input field for capturing the raw monetary amount handed over by the customer.
        /// Labeled "Cash Received" throughout the app, matching what a
        /// receptionist would say out loud to a guest.
        TextFormField(
          controller: _tenderedController,
          autofocus: widget.autofocus,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          // Last field on the screen: the keyboard's key says "Done", and
          // pressing it (or Enter on a hardware keyboard) confirms.
          textInputAction: TextInputAction.done,
          onFieldSubmitted: (_) => widget.onSubmitted?.call(),
          // A generous ceiling on raw digit count — comfortably enough for
          // any real amount in either currency, but enough to stop a long
          // pasted or mistyped string of digits from ever reaching the
          // calculation below.
          inputFormatters: [LengthLimitingTextInputFormatter(10)],
          decoration: InputDecoration(
            labelText: "Cash Received ($currencySymbol)",
            prefixText: "$currencySymbol ",
            border: const OutlineInputBorder(),
            counterText: "",
            errorText: tenderedFieldErrorText,
          ),
          onChanged: (value) => _calculateResults(),
        ),
        if (widget.showChangeDue) ...[
          const SizedBox(height: 16),

          /// High-contrast output block detailing the cash change to be
          /// returned. Always in cedis, and always labeled "Cash Given",
          /// matching what a receptionist would say out loud to a guest.
          /// When there is genuinely nothing to hand back, this says so
          /// in plain words instead of showing "₵ 0.00", which could look
          /// like a mistake rather than a deliberate exact payment.
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _changeReturned > 0 ? const Color(0xff14703f) : Colors.black12,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("CASH GIVEN:", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                Text(
                  cashGivenText,
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  @override
  void dispose() {
    _tenderedController.dispose();
    super.dispose();
  }
}
