import 'package:flutter/material.dart';

// Links to the shared network service core tool
import '../../services/api_service.dart';
import '../../widgets/currency_toggle_terminal.dart';
import '../../widgets/payment_method_selector.dart';
import '../../widgets/sms_helper.dart';
import 'intake_form_view.dart';

/// Adds extra time to an already-occupied or time-expired booking. The
/// guest and room are already known and cannot be changed here; the
/// receptionist only chooses an additional duration from this room's own
/// manager-approved price list and takes payment for that extension,
/// which is recorded as its own separate charge.
class ExtendStayView extends StatefulWidget {
  final ApiService apiService;
  // Null for a booking made while the server was down and not yet received
  // by it: it has no number, so it is extended by its room instead.
  final int? bookingId;
  final String roomName;
  final String guestName;
  // The phone number collected when the booking was made, used for the
  // confirmation text.
  final String guestPhone;
  // The room's checkout time as the tablet currently shows it. Used for the
  // confirmation text when the extension was saved offline and the server
  // has not yet reported the new checkout time.
  final DateTime? currentCheckout;

  const ExtendStayView({
    super.key,
    required this.apiService,
    required this.bookingId,
    required this.roomName,
    required this.guestName,
    required this.guestPhone,
    this.currentCheckout,
  });

  @override
  State<ExtendStayView> createState() => _ExtendStayViewState();
}

class _ExtendStayViewState extends State<ExtendStayView> {
  final TextEditingController _momoWalletController = TextEditingController();
  final TextEditingController _bankAccountController = TextEditingController();

  String _paymentMode = "CASH";
  double _cashTenderedGhs = 0.0;
  double _changeReturnedGhs = 0.0;
  double? _usdReceived;
  bool _isPaymentSufficient = true;
  bool _isSubmitting = false;

  bool _isLoadingPricing = true;
  String? _pricingErrorMessage;
  List<RoomPriceOption> _availableOptions = [];
  int? _selectedDurationHours;

  @override
  void initState() {
    super.initState();
    _loadPricingForThisRoom();
  }

  @override
  void dispose() {
    _momoWalletController.dispose();
    _bankAccountController.dispose();
    super.dispose();
  }

  /// Pulls this room's own manager-approved duration and price list, the
  /// same list the original booking form uses, so an extension can never
  /// be granted at a price nobody approved.
  Future<void> _loadPricingForThisRoom() async {
    try {
      // The price list saved on this tablet at login (never asked again mid-shift).
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

  double get _extensionCostInGhs {
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
      appBar: AppBar(title: Text("Extend Stay — ${widget.roomName}")),
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
                          "This room has no approved prices yet. A manager needs to set one before it can be extended.",
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white70),
                        ),
                      ),
                    )
                  : _buildForm(),
    );
  }

  Widget _buildForm() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Read-only summary of who and where this extension applies to.
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
              Text("Guest: ${widget.guestName}", style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text("Room: ${widget.roomName}", style: const TextStyle(color: Colors.white70)),
            ],
          ),
        ),
        const SizedBox(height: 24),

        // Only the durations this room actually has an approved price for
        // are offered, the same restriction a fresh booking follows.
        DropdownButtonFormField<int>(
          initialValue: _selectedDurationHours,
          autofocus: true,
          hint: const Text("Select a duration"),
          decoration: const InputDecoration(
            labelText: "Additional Duration",
            border: OutlineInputBorder(),
          ),
          items: _availableOptions
              .map((option) => DropdownMenuItem(
                    value: option.durationHours,
                    child: Text("${option.durationHours} hours — ₵ ${option.price.toStringAsFixed(2)}"),
                  ))
              .toList(),
          onChanged: (value) => setState(() => _selectedDurationHours = value),
        ),
        const SizedBox(height: 20),

        PaymentMethodSelector(
          paymentMode: _paymentMode,
          momoController: _momoWalletController,
          bankController: _bankAccountController,
          onChanged: (mode) => setState(() => _paymentMode = mode),
        ),

        const Divider(height: 32),

        CurrencyToggleTerminal(
          totalCostInGhs: _extensionCostInGhs,
          exchangeRate: widget.apiService.activeExchangeRate,
          // Transfers (MoMo or bank) have no meaningful "change due"; only cash does.
          showChangeDue: _paymentMode == "CASH",
            allowDollars: _paymentMode != "MOMO",
          // Enter on Cash Received is the last step: it confirms the extension.
          onSubmitted: _isSubmitting ? null : _handleExtendStay,
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
            onPressed: _isSubmitting ? null : _handleExtendStay,
            child: _isSubmitting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                  )
                : const Text("Confirm Extension", style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ),
      ],
    );
  }

  Future<void> _handleExtendStay() async {
    if (_selectedDurationHours == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Select an approved additional duration.")),
      );
      return;
    }

    if (!_isPaymentSufficient) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_paymentMode == "CASH" ? "Cash Received is less than the extension cost." : "Amount received is less than the extension cost.")),
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

    final String? transferProblem = PaymentMethodSelector.detailsProblem(
        _paymentMode, _momoWalletController.text, _bankAccountController.text);
    if (transferProblem != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(transferProblem)));
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      final result = await widget.apiService.extendStay(
        bookingId: widget.bookingId,
        roomName: widget.roomName,
        additionalHours: _selectedDurationHours!,
        paymentMode: _paymentMode,
        cashTendered: _cashTenderedGhs,
        changeReturned: _changeReturnedGhs,
        usdReceived: _usdReceived,
        momoNumber: _paymentMode == "MOMO" ? _momoWalletController.text.trim() : null,
        bankSenderAccount: _paymentMode == "BANK" ? _bankAccountController.text.trim() : null,
      );

      if (mounted) {
        final bool wasQueuedOffline = result['queued_offline'] == true;

        // The new checkout time as a UTC clock time. The server sends it
        // without a time-zone label (it is UTC, which is GMT in Ghana);
        // reading the clock fields as UTC is right for it. When the
        // extension was saved offline the time is worked out here: the
        // extra hours are added to the current checkout, or to now if that
        // moment has already passed.
        final int addedHours = _selectedDurationHours!;
        final DateTime nowUtc = DateTime.now().toUtc();
        DateTime newCheckOutUtc;
        if (result['new_checkout_deadline'] != null) {
          final parsed = DateTime.parse(result['new_checkout_deadline']);
          newCheckOutUtc = DateTime.utc(parsed.year, parsed.month, parsed.day, parsed.hour, parsed.minute);
        } else {
          final DateTime? current = widget.currentCheckout;
          final DateTime base = (current != null && current.isAfter(nowUtc)) ? current : nowUtc;
          newCheckOutUtc = base.add(Duration(hours: addedHours));
        }

        final String smsGuestName = widget.guestName;
        final String smsPhone = widget.guestPhone;
        final String smsRoom = widget.roomName;
        final messenger = ScaffoldMessenger.of(context);
        final NavigatorState rootNavigator = Navigator.of(context, rootNavigator: true);

        // The guest is texted the new checkout time automatically from the
        // tablet's SIM. The SEND MESSAGE button is offered for 15 seconds on
        // the next screen as a manual fallback.
        sendGuestMessageInBackground(
          navigator: rootNavigator,
          messenger: messenger,
          phoneNumber: smsPhone,
          what: "The extension text to $smsGuestName ($smsRoom)",
          messageBuilder: () => buildExtensionSms(
            guestName: smsGuestName,
            roomName: smsRoom,
            additionalHours: addedHours,
            newCheckOutUtc: newCheckOutUtc,
          ),
        );

        messenger.showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 15),
            backgroundColor: wasQueuedOffline ? const Color(0xffc9971f) : const Color(0xff14703f),
            content: Text(
              wasQueuedOffline ? "Saved. Pending, will be sent when the connection returns." : "Stay extended successfully.",
            ),
            action: SnackBarAction(
              label: "SEND MESSAGE",
              textColor: Colors.white,
              onPressed: () async {
                final String message = buildExtensionSms(
                  guestName: smsGuestName,
                  roomName: smsRoom,
                  additionalHours: addedHours,
                  newCheckOutUtc: newCheckOutUtc,
                );
                // The extension screen is closed by now, so the sending box
                // and the result are shown through the navigator and
                // messenger captured above. A failed text can be tried again.
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
            content: Text("Extension failed: ${e.toString().replaceAll("Exception: ", "")}"),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }
}
