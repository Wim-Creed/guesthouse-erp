import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Links to the shared network service core tool
import '../../services/api_service.dart';
import '../../widgets/currency_toggle_terminal.dart';
import '../../widgets/payment_method_selector.dart';
import '../../widgets/capitalize_words_formatter.dart';
import '../../widgets/sms_helper.dart';

/// One approved duration and price combination for the room being booked.
class RoomPriceOption {
  final int durationHours;
  final double price;

  RoomPriceOption({required this.durationHours, required this.price});
}

/// Formats a raw server timestamp into a readable time labeled "GMT",
/// since the server stores time as UTC, which is identical to GMT for
/// Ghana with no daylight saving to account for. Any screen displaying a
/// timestamp to a person should read "GMT", even though the underlying
/// stored value stays UTC throughout the rest of the system.
String formatCheckoutDeadline(String isoTimestamp) {
  final parsed = DateTime.parse(isoTimestamp);
  final utcTime = DateTime.utc(parsed.year, parsed.month, parsed.day, parsed.hour, parsed.minute);
  final hour = utcTime.hour.toString().padLeft(2, '0');
  final minute = utcTime.minute.toString().padLeft(2, '0');
  return "$hour:$minute GMT, ${utcTime.day}/${utcTime.month}/${utcTime.year}";
}

/// Collects a guest's details and books them into a specific, already
/// chosen room. The room itself is fixed for this screen; the receptionist
/// only picks from that room's manager-approved durations and prices.
///
/// Works fully on its own when the server cannot be reached: the booking
/// is saved on the tablet immediately, the room turns Occupied straight
/// away, and the confirmation shows the checkout time worked out locally
/// — never "Booking failed" just because the connection is briefly down.
class IntakeFormView extends StatefulWidget {
  final ApiService apiService;
  final String roomName;

  const IntakeFormView({super.key, required this.apiService, required this.roomName});

  @override
  State<IntakeFormView> createState() => _IntakeFormViewState();
}

class _IntakeFormViewState extends State<IntakeFormView> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _momoWalletController = TextEditingController();
  final TextEditingController _bankAccountController = TextEditingController();

  String _paymentMode = "CASH";
  int? _selectedDurationHours;

  double _cashTenderedGhs = 0.0;
  double _changeReturnedGhs = 0.0;
  double? _usdReceived;
  bool _isPaymentSufficient = true;
  bool _isBookingProcessing = false;
  bool _showPhoneLengthHint = false;

  bool _isLoadingPricing = true;
  String? _pricingErrorMessage;
  List<RoomPriceOption> _availableOptions = [];

  @override
  void initState() {
    super.initState();
    _loadPricingForThisRoom();
  }

  /// Pulls every room's approved pricing from the server, then keeps only
  /// the entries that belong to this specific room.
  Future<void> _loadPricingForThisRoom() async {
    try {
      // The price list saved on this tablet at login (never asked again mid-shift),
      // which is also what lets a booking be made while the server is down.
      final allPricing = await widget.apiService.fetchRoomPricingForBooking();
      final matchingOptions = allPricing
          .where((entry) => entry['room_id'] == widget.roomName)
          .map((entry) => RoomPriceOption(
                durationHours: entry['duration_hours'],
                price: (entry['price'] as num).toDouble(),
              ))
          .toList();
      matchingOptions.sort((a, b) => a.durationHours.compareTo(b.durationHours));

      if (mounted) {
        setState(() {
          _availableOptions = matchingOptions;
          // Starts unselected on purpose: a distracted tap
          // should never silently book the wrong duration just because it
          // happened to be whatever came first in the list.
          _selectedDurationHours = null;
          _isLoadingPricing = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _pricingErrorMessage = e.toString().replaceAll("Exception: ", "");
          _isLoadingPricing = false;
        });
      }
    }
  }

  double get _selectedPrice {
    if (_selectedDurationHours == null) return 0.0;
    final match = _availableOptions.firstWhere(
      (option) => option.durationHours == _selectedDurationHours,
      orElse: () => RoomPriceOption(durationHours: 0, price: 0.0),
    );
    return match.price;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("New Booking — ${widget.roomName}")),
      body: _isLoadingPricing
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xffd4af37)))
          : _pricingErrorMessage != null
              ? Center(
                  child: Text(
                    "Could not load pricing: $_pricingErrorMessage",
                    style: const TextStyle(color: Color(0xffe0584a)),
                    textAlign: TextAlign.center,
                  ),
                )
              : _availableOptions.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24.0),
                        child: Text(
                          "This room has no approved prices yet. A manager needs to set one before it can be booked.",
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white70),
                        ),
                      ),
                    )
                  : _buildForm(),
    );
  }

  Widget _buildForm() {
    final double roomCostInGhs = _selectedPrice;

    return Form(
      key: _formKey,
      // Enter moves through the form field by field: name, phone, (MoMo
      // number when paying by MoMo), then Cash Received, where Enter
      // confirms the booking. Choosing a duration and a payment method is
      // done by tapping, so the keyboard flow simply steps over them.
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextFormField(
            controller: _nameController,
            autofocus: true,
            textInputAction: TextInputAction.next,
            // A person's name: each word capitalised, and a name typed in
            // capitals (KOFI) becomes Kofi — see capitalize_words_formatter.dart.
            inputFormatters: [CapitalizeWordsFormatter(keepAbbreviations: false)],
            decoration: const InputDecoration(
              labelText: "Guest Name",
              prefixIcon: Icon(Icons.person),
              border: OutlineInputBorder(),
            ),
            validator: (value) => value == null || value.isEmpty ? "Guest name is required" : null,
          ),
          const SizedBox(height: 16),

          TextFormField(
            controller: _phoneController,
            keyboardType: TextInputType.phone,
            textInputAction: TextInputAction.next,
            onFieldSubmitted: (_) => FocusScope.of(context).nextFocus(),
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(10),
            ],
            onChanged: (value) {
              final bool shouldShow = value.isNotEmpty && value.length != 10;
              if (shouldShow != _showPhoneLengthHint) setState(() => _showPhoneLengthHint = shouldShow);
            },
            decoration: InputDecoration(
              labelText: "Guest Phone Number",
              prefixIcon: const Icon(Icons.phone),
              border: const OutlineInputBorder(),
              helperText: _showPhoneLengthHint ? "Must be exactly 10 digits." : null,
            ),
            validator: (value) {
              if (value == null || value.isEmpty) return "Guest phone number is required";
              if (value.length != 10) return "Must be exactly 10 digits.";
              return null;
            },
          ),
          const SizedBox(height: 16),

          // Only the durations this room actually has an approved price for are offered.
          DropdownButtonFormField<int>(
            initialValue: _selectedDurationHours,
            hint: const Text("Select a duration"),
            decoration: const InputDecoration(
              labelText: "Stay Duration",
              border: OutlineInputBorder(),
            ),
            items: _availableOptions
                .map((option) => DropdownMenuItem(
                      value: option.durationHours,
                      child: Text("${option.durationHours} hours — ₵ ${option.price.toStringAsFixed(2)}"),
                    ))
                .toList(),
            onChanged: (value) => setState(() => _selectedDurationHours = value),
            validator: (value) => value == null ? "Select a duration" : null,
          ),
          const SizedBox(height: 16),

          PaymentMethodSelector(
            paymentMode: _paymentMode,
            momoController: _momoWalletController,
            bankController: _bankAccountController,
            onChanged: (mode) => setState(() => _paymentMode = mode),
          ),

          const Divider(height: 32),

          CurrencyToggleTerminal(
            totalCostInGhs: roomCostInGhs,
            exchangeRate: widget.apiService.activeExchangeRate,
            // Transfers (MoMo or bank) have no meaningful "change due"; only cash does.
            showChangeDue: _paymentMode == "CASH",
            allowDollars: _paymentMode != "MOMO",
            // Enter on Cash Received is the last step: it confirms the booking.
            onSubmitted: _isBookingProcessing ? null : _processGuestIntake,
            onValuesChanged: (cashTenderedGhs, changeReturnedGhs, usdReceived, isSufficient) {
              _cashTenderedGhs = cashTenderedGhs;
              _changeReturnedGhs = changeReturnedGhs;
              _usdReceived = usdReceived;
              _isPaymentSufficient = isSufficient;
            },
          ),
          const SizedBox(height: 24),

          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xffd4af37),
                foregroundColor: const Color(0xff0a1426),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
              ),
              onPressed: _isBookingProcessing ? null : _processGuestIntake,
              child: _isBookingProcessing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                    )
                  : const Text("Confirm Booking", style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _processGuestIntake() async {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedDurationHours == null) return;

    if (!_isPaymentSufficient) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_paymentMode == "CASH" ? "Cash Received is less than the room cost." : "Amount received is less than the room cost.")),
      );
      return;
    }

    // A transfer is recorded with what actually arrived, so it must be typed in.
    if (_paymentMode != "CASH" && _cashTenderedGhs <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Enter the amount received.")),
      );
      return;
    }

    setState(() => _isBookingProcessing = true);

    try {
      final receipt = await widget.apiService.createBooking(
        roomNumber: widget.roomName,
        // The final, tidy form of the name (the one name rule), so it is right even
        // for a booking saved on the tablet while the server is down.
        guestName: canonicalName(_nameController.text, keepAbbreviations: false),
        guestPhone: _phoneController.text.trim(),
        durationHours: _selectedDurationHours!,
        paymentMode: _paymentMode,
        cashTendered: _cashTenderedGhs,
        changeReturned: _changeReturnedGhs,
        usdReceived: _usdReceived,
        momoNumber: _paymentMode == "MOMO" ? _momoWalletController.text.trim() : null,
        bankSenderAccount: _paymentMode == "BANK" ? _bankAccountController.text.trim() : null,
      );

      if (mounted) {
        // Whether this was confirmed by the server just now, or saved on
        // the tablet to be sent once the connection returns, the
        // checkout time shown is always the one worked out at the moment
        // of booking — never "Booking failed" just because the network
        // happened to be down.
        final bool wasQueuedOffline = receipt['queued_offline'] == true;
        final String checkoutMessage = receipt['checkout_deadline'] != null
            ? "Checkout by: ${formatCheckoutDeadline(receipt['checkout_deadline'])}"
            : "";
        // One tap to text the guest: the confirmation (room, check-in,
        // check-out) is sent straight from the tablet's SIM. The button is
        // offered for 15 seconds on the next screen.
        final DateTime checkInUtc = DateTime.now().toUtc();
        // The checkout time as a UTC clock time. The server sends it without a
        // time-zone label (it is UTC, which is GMT in Ghana), and a time saved
        // on the tablet carries a "Z"; reading the clock fields as UTC is
        // right for both.
        DateTime checkOutUtc = checkInUtc.add(Duration(hours: _selectedDurationHours ?? 0));
        if (receipt['checkout_deadline'] != null) {
          final parsed = DateTime.parse(receipt['checkout_deadline']);
          checkOutUtc = DateTime.utc(parsed.year, parsed.month, parsed.day, parsed.hour, parsed.minute);
        }
        final String smsGuestName = canonicalName(_nameController.text, keepAbbreviations: false);
        final String smsPhone = _phoneController.text.trim();
        final String smsRoom = widget.roomName;
        final messenger = ScaffoldMessenger.of(context);
        final NavigatorState rootNavigator = Navigator.of(context, rootNavigator: true);

        // The guest is texted the booking details automatically from the
        // tablet's SIM. The SEND MESSAGE button below is a manual fallback.
        sendGuestMessageInBackground(
          navigator: rootNavigator,
          messenger: messenger,
          phoneNumber: smsPhone,
          what: "The booking text to $smsGuestName ($smsRoom)",
          messageBuilder: () => buildBookingSms(
            guestName: smsGuestName,
            roomName: smsRoom,
            checkInUtc: checkInUtc,
            checkOutUtc: checkOutUtc,
          ),
        );

        messenger.showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 15),
            backgroundColor: wasQueuedOffline ? const Color(0xffc9971f) : const Color(0xff14703f),
            content: Text(
              wasQueuedOffline
                  ? "Saved. Pending, will be sent when the connection returns."
                  : "Booking confirmed. $checkoutMessage",
            ),
            action: SnackBarAction(
              label: "SEND MESSAGE",
              textColor: Colors.white,
              onPressed: () async {
                final String message = buildBookingSms(
                  guestName: smsGuestName,
                  roomName: smsRoom,
                  checkInUtc: checkInUtc,
                  checkOutUtc: checkOutUtc,
                );
                // The booking screen is closed by now, so the sending box and
                // the result are shown through the navigator and messenger
                // captured above. A failed text can be tried again.
                await sendGuestMessageWithRetry(
                  navigator: rootNavigator,
                  messenger: messenger,
                  phoneNumber: smsPhone,
                  message: message,
                  successText: "Message sent to the guest.",
                );
              },
            ),
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xffc0392b),
            content: Text("Booking failed: ${e.toString().replaceAll("Exception: ", "")}"),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isBookingProcessing = false);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _momoWalletController.dispose();
    _bankAccountController.dispose();
    super.dispose();
  }
}
