import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../widgets/screen_scaler.dart' show activeScreenScale;

// Links to the shared network service core tool
import '../../services/api_service.dart';
import 'employee_management_view.dart' show EmployeeRecord;

const Color _kGold = Color(0xffd4af37);
const Color _kCardBg = Color(0xff111f3a);

/// The stand-in "person" for the shared Buffer login. The Buffer login is
/// deliberately not an employee (it never appears in Employee Management
/// or Payroll), so it has no real id; this made-up one is only ever used to
/// tell its chip apart from the receptionists' chips on this screen.
const int _kBufferChipId = -1;

// A faint reddish wash used for anything that was cancelled. Deliberately
// soft: a cancelled line is an audit record, not part of any total, so it
// should be easy to tell apart at a glance without shouting.
const Color _kCancelledTint = Color(0x26c0392b);
const Color _kCancelledText = Color(0xffe08a7a);

// A barely-there gold wash for extension lines, so they read as part of the
// booking above them but are still clearly not a booking of their own.
const Color _kExtensionTint = Color(0x12d4af37);

/// The period choices shared by every Records sub-view: real calendar
/// periods worked out by the server (Daily is today's date, Weekly runs
/// Sunday to Saturday, Monthly is the calendar month, Yearly the calendar
/// year). Quarterly and half-year views are simply a Custom range.
class _PeriodChoice {
  static const List<String> labels = ["Daily", "Weekly", "Monthly", "Yearly", "Custom"];
  static const List<String?> keys = ["daily", "weekly", "monthly", "yearly", null]; // null = Custom
  static const int customIndex = 4;
}

// ---------------------------------------------------------------------
// Shared formatting helpers
// ---------------------------------------------------------------------

/// "14:05, 30/9/2026", or a dash when there is no time to show.
String _formatMoment(DateTime? when) {
  if (when == null) return "—";
  final hour = when.hour.toString().padLeft(2, '0');
  final minute = when.minute.toString().padLeft(2, '0');
  return "$hour:$minute, ${when.day}/${when.month}/${when.year}";
}

String _cedis(num amount) => "₵ ${amount.toStringAsFixed(2)}";

/// How something was paid for, in one plain line, the same wording for
/// room bookings, extensions and shop sales:
///   - cash: the price
///   - dollars: that it was dollars, the dollar amount and its cedi equivalent
///   - MoMo: the cedis received, the extra over the price and the wallet number
///   - bank: the cedis received (or the dollars sent, their cedi value and the
///     rate), the extra over the price and the last four digits of the account
String _paymentText(Map<String, dynamic>? payment) {
  if (payment == null) return "—";
  switch (payment['method']) {
    case 'USD':
      final double dollars = (payment['usd_received'] as num?)?.toDouble() ?? 0.0;
      final double cedisEquivalent = (payment['cedi_equivalent'] as num?)?.toDouble() ?? 0.0;
      return "Paid in dollars · \$${dollars.toStringAsFixed(2)} (≈ ${_cedis(cedisEquivalent)})";
    case 'MOMO':
      final double received = (payment['amount_sent'] as num?)?.toDouble() ?? 0.0;
      final double extra = (payment['extra'] as num?)?.toDouble() ?? 0.0;
      final String number = (payment['momo_number'] as String?) ?? "unknown number";
      return "MoMo · received ${_cedis(received)} · extra ${_cedis(extra)} · $number";
    case 'BANK':
      final double received = (payment['amount_sent'] as num?)?.toDouble() ?? 0.0;
      final double extra = (payment['extra'] as num?)?.toDouble() ?? 0.0;
      final String digits = (payment['bank_sender_account'] as String?) ?? "";
      final String account = digits.isEmpty ? "unknown account" : "******$digits";
      final double? dollarsSent = (payment['usd_received'] as num?)?.toDouble();
      if (dollarsSent != null) {
        final double rate = (payment['rate'] as num?)?.toDouble() ?? 0.0;
        return "Bank · \$${dollarsSent.toStringAsFixed(2)} (≈ ${_cedis(received)} at ${rate.toStringAsFixed(2)}) · extra ${_cedis(extra)} · $account";
      }
      return "Bank · received ${_cedis(received)} · extra ${_cedis(extra)} · $account";
    default:
      return "Cash · ${_cedis((payment['price'] as num?)?.toDouble() ?? 0.0)}";
  }
}

/// True when every word typed appears somewhere in the haystack, in any
/// order and in any column — so "kofi room 3" finds that guest's line.
bool _matchesSearch(String haystack, String typed) {
  final terms = typed.toLowerCase().split(RegExp(r'\s+')).where((t) => t.isNotEmpty);
  final lowered = haystack.toLowerCase();
  return terms.every(lowered.contains);
}

// ---------------------------------------------------------------------
// Guest Log data
// ---------------------------------------------------------------------

/// One extension, shown as a short line under the booking it belongs to.
class GuestLogExtension {
  final int extensionId;
  final int additionalHours;
  final bool cancelled;
  final DateTime? startsAt;
  final DateTime? newScheduledCheckout;
  final DateTime madeAt;
  final String? madeBy;
  final bool cancelledByManager;
  final String? cancelledBy;
  final DateTime? cancelledAt;

  /// Only filled for an extension shown as its own row: the actual checkout
  /// of the booking it belongs to, and who checked the guest out.
  final DateTime? actualCheckout;
  final String? checkedOutBy;
  final Map<String, dynamic> payment;

  GuestLogExtension({
    required this.extensionId,
    required this.additionalHours,
    required this.cancelled,
    required this.startsAt,
    required this.newScheduledCheckout,
    required this.madeAt,
    required this.madeBy,
    this.cancelledByManager = false,
    this.cancelledBy,
    this.cancelledAt,
    this.actualCheckout,
    this.checkedOutBy,
    required this.payment,
  });

  factory GuestLogExtension.fromJson(Map<String, dynamic> json) {
    return GuestLogExtension(
      extensionId: json['extension_id'],
      additionalHours: json['additional_hours'],
      cancelled: json['cancelled'] ?? false,
      startsAt: json['starts_at'] != null ? DateTime.parse(json['starts_at']).toLocal() : null,
      newScheduledCheckout: json['new_scheduled_checkout'] != null ? DateTime.parse(json['new_scheduled_checkout']).toLocal() : null,
      madeAt: DateTime.parse(json['made_at']).toLocal(),
      madeBy: json['made_by'],
      cancelledByManager: json['cancelled_by_manager'] ?? false,
      cancelledBy: json['cancelled_by'],
      cancelledAt: json['cancelled_at'] != null ? DateTime.parse(json['cancelled_at']).toLocal() : null,
      actualCheckout: json['actual_checkout'] != null ? DateTime.parse(json['actual_checkout']).toLocal() : null,
      checkedOutBy: json['checked_out_by'],
      payment: Map<String, dynamic>.from(json['payment'] ?? {}),
    );
  }

  /// Everything this line shows, as one string, so a search matches
  /// anything visible on it.
  String get searchText => [
        "extension", "extended", if (cancelled) "cancelled extension cancelled",
        if (cancelledByManager) "cancelled by manager",
        cancelledBy ?? "", _formatMoment(cancelledAt), checkedOutBy ?? "", _formatMoment(actualCheckout),
        "+${additionalHours}h", "$additionalHours hours",
        _formatMoment(startsAt), _formatMoment(newScheduledCheckout),
        madeBy ?? "", _paymentText(payment),
      ].join(" ");
}

/// One booking in the Guest Log, with its extensions.
class GuestLogEntry {
  final int bookingId;
  final String guestName;
  final String guestPhone;
  final String roomNumber;
  final String roomDescription;
  final int durationHours;
  final bool extended;
  final bool cancelled;
  final DateTime checkedInAt;
  final DateTime scheduledCheckout;
  final DateTime? actualCheckout;
  final DateTime? cancelledAt;
  final String? checkedInBy;
  final String? checkedOutBy;
  final String? cancelledBy;
  final bool cancelledByManager;
  final bool restoredByManager;
  final Map<String, dynamic> payment;
  final List<GuestLogExtension> extensions;

  /// The shift this entry belongs to (see _ShiftInfo), when it has one.
  final int? sessionId;

  /// Set only for a row that is an extension on its own: an extension made
  /// in this period on a booking checked in before it. The row then shows
  /// the guest and room of that booking with this extension's details.
  final GuestLogExtension? standaloneExtension;

  GuestLogEntry({
    required this.bookingId,
    required this.guestName,
    required this.guestPhone,
    required this.roomNumber,
    required this.roomDescription,
    required this.durationHours,
    required this.extended,
    required this.cancelled,
    required this.checkedInAt,
    required this.scheduledCheckout,
    this.actualCheckout,
    this.cancelledAt,
    this.checkedInBy,
    this.checkedOutBy,
    this.cancelledBy,
    this.cancelledByManager = false,
    this.restoredByManager = false,
    required this.payment,
    required this.extensions,
    this.sessionId,
    this.standaloneExtension,
  });

  factory GuestLogEntry.fromJson(Map<String, dynamic> json) {
    if (json['kind'] == 'extension_only') {
      final GuestLogExtension extension = GuestLogExtension.fromJson(json);
      return GuestLogEntry(
        bookingId: json['booking_id'],
        guestName: json['guest_name'],
        guestPhone: json['guest_phone'],
        roomNumber: json['room_number'],
        roomDescription: json['room_description'] ?? "",
        durationHours: extension.additionalHours,
        extended: false,
        cancelled: false,
        checkedInAt: extension.madeAt,
        scheduledCheckout: extension.newScheduledCheckout ?? extension.madeAt,
        payment: extension.payment,
        extensions: const [],
        sessionId: json['session_id'],
        standaloneExtension: extension,
      );
    }
    return GuestLogEntry(
      bookingId: json['booking_id'],
      guestName: json['guest_name'],
      guestPhone: json['guest_phone'],
      roomNumber: json['room_number'],
      roomDescription: json['room_description'] ?? "",
      durationHours: json['duration_hours'],
      extended: json['extended'] ?? false,
      cancelled: json['cancelled'] ?? false,
      checkedInAt: DateTime.parse(json['checked_in_at']).toLocal(),
      scheduledCheckout: DateTime.parse(json['scheduled_checkout']).toLocal(),
      actualCheckout: json['actual_checkout'] != null ? DateTime.parse(json['actual_checkout']).toLocal() : null,
      cancelledAt: json['cancelled_at'] != null ? DateTime.parse(json['cancelled_at']).toLocal() : null,
      checkedInBy: json['checked_in_by'],
      checkedOutBy: json['checked_out_by'],
      cancelledBy: json['cancelled_by'],
      cancelledByManager: json['cancelled_by_manager'] ?? false,
      restoredByManager: json['restored_by_manager'] ?? false,
      payment: Map<String, dynamic>.from(json['payment'] ?? {}),
      extensions: (json['extensions'] as List<dynamic>? ?? [])
          .map((e) => GuestLogExtension.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      sessionId: json['session_id'],
    );
  }

  /// Everything the booking line shows, plus everything its extension
  /// lines show, so a search finds the whole group whichever line matched.
  String get searchText => [
        guestName, guestPhone, roomNumber, roomDescription, "${durationHours}h", "$durationHours hours",
        _paymentText(payment), _formatMoment(checkedInAt), _formatMoment(scheduledCheckout),
        if (!cancelled) _formatMoment(actualCheckout),
        if (cancelled) "cancelled cancel time ${_formatMoment(cancelledAt)}",
        if (cancelledByManager) "cancelled by manager",
        if (restoredByManager) "restored by manager",
        if (extended) "extended",
        checkedInBy ?? "", checkedOutBy ?? "", cancelledBy ?? "",
        ...extensions.map((e) => e.searchText),
        if (standaloneExtension != null) standaloneExtension!.searchText,
      ].join(" ");
}

/// One displayed line of the Guest Log table: a booking, one of its
/// extensions (which sits directly under its booking), or an extension that
/// stands on its own ([isStandalone]).
class _LogRow {
  final GuestLogEntry? entry;
  final GuestLogExtension? extension;
  final bool isStandalone;

  /// Set only for a shift heading, which is a single bar across the table.
  final String? heading;

  _LogRow(GuestLogEntry this.entry, [this.extension, this.isStandalone = false]) : heading = null;
  _LogRow.heading(String this.heading)
      : entry = null,
        extension = null,
        isStandalone = false;
}

// ---------------------------------------------------------------------
// The Records tab
// ---------------------------------------------------------------------

/// The Records tab: Guest Log, Shop Sales, Money Brought In and Login Record, picked with
/// chips at the top rather than as separate tabs, since the manager wanted
/// this kept to one tab overall.
class RecordsView extends StatefulWidget {
  final ApiService apiService;

  const RecordsView({super.key, required this.apiService});

  @override
  State<RecordsView> createState() => _RecordsViewState();
}

class _RecordsViewState extends State<RecordsView> {
  static const List<String> _sections = ["Guest Log", "Shop Sales", "Money Brought In", "Login Record"];
  int _activeSection = 0;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          "RECORDS",
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: _kGold, letterSpacing: 1),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: List.generate(_sections.length, (index) {
            final bool selected = _activeSection == index;
            return ChoiceChip(
              label: Text(_sections[index]),
              selected: selected,
              selectedColor: _kGold,
              labelStyle: TextStyle(color: selected ? Colors.black : Colors.white, fontWeight: FontWeight.bold),
              onSelected: (val) { if (val) setState(() => _activeSection = index); },
            );
          }),
        ),
        const SizedBox(height: 20),
        Expanded(
          child: switch (_activeSection) {
            0 => _GuestLogSubView(apiService: widget.apiService),
            1 => _ShopSalesSubView(apiService: widget.apiService),
            2 => _MoneyBroughtInSubView(apiService: widget.apiService),
            _ => _LoginRecordSubView(apiService: widget.apiService),
          },
        ),
      ],
    );
  }
}

/// A row of period chips shared by every sub-view. Selecting "Custom"
/// opens a date range picker; every other choice fetches immediately.
class _PeriodPicker extends StatelessWidget {
  final int activeIndex;
  final DateTimeRange? customRange;
  final void Function(int index, DateTimeRange? range) onChanged;

  const _PeriodPicker({required this.activeIndex, required this.customRange, required this.onChanged});

  Future<void> _pickCustomRange(BuildContext context) async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 5),
      lastDate: now,
      initialDateRange: customRange ?? DateTimeRange(start: now.subtract(const Duration(days: 7)), end: now),
    );
    if (picked != null) onChanged(_PeriodChoice.customIndex, picked);
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: _PeriodChoice.labels.asMap().entries.map((entry) {
        final int idx = entry.key;
        final bool isCustom = idx == _PeriodChoice.customIndex;
        final bool selected = activeIndex == idx;
        return ChoiceChip(
          label: Text(isCustom && customRange != null
              ? "${customRange!.start.day}/${customRange!.start.month} – ${customRange!.end.day}/${customRange!.end.month}"
              : entry.value),
          selected: selected,
          selectedColor: _kGold,
          labelStyle: TextStyle(color: selected ? Colors.black : Colors.white, fontWeight: FontWeight.bold),
          onSelected: (val) {
            if (!val && !isCustom) return;
            if (isCustom) {
              _pickCustomRange(context);
            } else {
              onChanged(idx, null);
            }
          },
        );
      }).toList(),
    );
  }
}

/// The search box shared by every sub-view. It filters instantly as
/// something is typed, across everything the table shows.
class _SearchBox extends StatelessWidget {
  final TextEditingController controller;
  final String hint;

  const _SearchBox({required this.controller, required this.hint});

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: const Icon(Icons.search),
        border: const OutlineInputBorder(),
        isDense: true,
        suffixIcon: controller.text.isNotEmpty
            ? IconButton(icon: const Icon(Icons.clear), tooltip: "Clear search", onPressed: controller.clear)
            : null,
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Filters
// ---------------------------------------------------------------------

/// The filters the Guest Log and Shop Sales can be narrowed by. Filters of
/// different kinds combine (a room AND a payment type); within one kind,
/// every ticked choice counts (Cash OR MoMo). A kind with nothing ticked
/// does not narrow anything.
class _RecordFilters {
  /// null = both, "buffer" = Buffer Shift only, "official" = official shifts only.
  String? shiftKind;
  final Set<String> rooms = {};
  final Set<String> payments = {};
  final Set<String> statuses = {};

  static const Map<String, String> paymentLabels = {
    "CASH": "Cash",
    "USD": "Dollars",
    "MOMO": "MoMo",
    "BANK": "Bank",
  };
  static const List<String> statusOptions = ["Cancelled", "Extended", "Restored"];

  int get activeCount =>
      (shiftKind != null ? 1 : 0) + (rooms.isNotEmpty ? 1 : 0) + (payments.isNotEmpty ? 1 : 0) + (statuses.isNotEmpty ? 1 : 0);

  void clear() {
    shiftKind = null;
    rooms.clear();
    payments.clear();
    statuses.clear();
  }

  bool matchesShiftKind(bool isBufferEntry) {
    if (shiftKind == null) return true;
    return shiftKind == "buffer" ? isBufferEntry : !isBufferEntry;
  }

  /// True when any of [methods] (the payment types on the line or group) is ticked.
  bool matchesPayment(Iterable<String?> methods) {
    if (payments.isEmpty) return true;
    return methods.any((m) => m != null && payments.contains(m));
  }
}

/// Whether an entry belongs to the Buffer Shift, by the same rule the
/// headings use: its shift is a buffer shift, or it was made before the
/// shift's official start.
bool _isBufferEntry(Map<int, _ShiftInfo> shifts, int? sessionId, DateTime time) {
  final _ShiftInfo? shift = sessionId == null ? null : shifts[sessionId];
  return shift != null && (shift.isBufferShift || time.isBefore(shift.start));
}

/// A "Filters" button that opens a panel of choice chips. Used above the
/// table of the Guest Log and Shop Sales.
class _FilterPanel extends StatefulWidget {
  final _RecordFilters filters;

  /// The room numbers to offer; null leaves the Room filter out (Shop Sales).
  final List<String>? roomOptions;

  /// Whether to offer the Status filter (Guest Log only).
  final bool showStatus;

  /// Called after any change, so the table can be worked out again.
  final VoidCallback onChanged;

  const _FilterPanel({required this.filters, required this.roomOptions, required this.showStatus, required this.onChanged});

  @override
  State<_FilterPanel> createState() => _FilterPanelState();
}

class _FilterPanelState extends State<_FilterPanel> {
  bool _open = false;

  Widget _group(String title, List<Widget> chips) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white70)),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 6, children: chips),
        ],
      ),
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) {
    return FilterChip(
      label: Text(label),
      selected: selected,
      showCheckmark: false,
      selectedColor: _kGold,
      labelStyle: TextStyle(color: selected ? Colors.black : Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
      onSelected: (_) {
        setState(onTap);
        widget.onChanged();
      },
    );
  }

  Widget _toggleIn(Set<String> set, String value, String label) {
    return _chip(label, set.contains(value), () {
      if (!set.remove(value)) set.add(value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final _RecordFilters f = widget.filters;
    final int count = f.activeCount;
    final List<String> rooms = widget.roomOptions ?? const [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: () => setState(() => _open = !_open),
              icon: Icon(_open ? Icons.expand_less : Icons.filter_list, size: 18),
              label: Text(count == 0 ? "Filters" : "Filters ($count)"),
              style: OutlinedButton.styleFrom(
                foregroundColor: count == 0 ? Colors.white : _kGold,
                side: BorderSide(color: count == 0 ? Colors.white24 : _kGold),
              ),
            ),
            if (count > 0) ...[
              const SizedBox(width: 8),
              TextButton(
                onPressed: () {
                  setState(f.clear);
                  widget.onChanged();
                },
                child: const Text("Clear"),
              ),
            ],
          ],
        ),
        if (_open)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 2),
            decoration: BoxDecoration(
              color: _kCardBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _group("Buffer", [
                  _chip("Buffer Shift", f.shiftKind == "buffer", () => f.shiftKind = f.shiftKind == "buffer" ? null : "buffer"),
                  _chip("Official shifts", f.shiftKind == "official", () => f.shiftKind = f.shiftKind == "official" ? null : "official"),
                ]),
                if (widget.roomOptions != null && rooms.isNotEmpty)
                  _group("Room", [for (final room in rooms) _toggleIn(f.rooms, room, room)]),
                _group("Payment", [
                  for (final entry in _RecordFilters.paymentLabels.entries) _toggleIn(f.payments, entry.key, entry.value),
                ]),
                if (widget.showStatus)
                  _group("Status", [for (final status in _RecordFilters.statusOptions) _toggleIn(f.statuses, status, status)]),
              ],
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------
// A table that behaves like a normal one: columns can be dragged wider or
// narrower, it scrolls sideways when it is wider than the screen, and the
// arrow keys, Page Up/Down, Home and End move around it without a mouse.
// ---------------------------------------------------------------------

class _TableColumn {
  final String title;
  final double width;
  const _TableColumn(this.title, this.width);

  /// The narrowest a column can be dragged to.
  double get minWidth => 60;
}

class _ResizableTable<T> extends StatefulWidget {
  final List<_TableColumn> columns;
  final List<T> rows;
  final String emptyMessage;

  /// Called when the table is pulled down. Reads the records again without
  /// replacing the table with a loading spinner.
  final Future<void> Function()? onRefresh;

  /// Builds one row. It is handed the live column widths so its cells
  /// always line up with the header, even while a column is being dragged.
  final Widget Function(BuildContext context, T row, List<double> widths) rowBuilder;

  const _ResizableTable({
    required this.columns,
    required this.rows,
    required this.rowBuilder,
    required this.emptyMessage,
    this.onRefresh,
  });

  @override
  State<_ResizableTable<T>> createState() => _ResizableTableState<T>();
}

class _ResizableTableState<T> extends State<_ResizableTable<T>> {
  late final List<double> _widths = widget.columns.map((c) => c.width).toList();

  /// How much the whole table (column widths and lettering together) is
  /// enlarged or reduced. 1.0 is the normal size; the buttons above the
  /// table step it, and Fit sets it so every column is visible at once.
  double _zoom = 1.0;
  static const double _minZoom = 0.5;
  static const double _maxZoom = 1.6;
  static const double _zoomStep = 0.1;
  final ScrollController _horizontalController = ScrollController();
  final ScrollController _verticalController = ScrollController();
  final FocusNode _focusNode = FocusNode(debugLabel: "records table");

  @override
  void initState() {
    super.initState();
    // Redraw the gold focus outline as the table gains or loses focus.
    _focusNode.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _horizontalController.dispose();
    _verticalController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _scrollBy(ScrollController controller, double delta) {
    if (!controller.hasClients) return;
    final double target = (controller.offset + delta).clamp(0.0, controller.position.maxScrollExtent).toDouble();
    controller.jumpTo(target);
  }

  /// Arrow keys scroll the table once it has focus (click on it, or Tab to
  /// it); everywhere else the arrow keys keep doing their normal jobs.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final double page = _verticalController.hasClients ? _verticalController.position.viewportDimension * 0.9 : 300;

    if (key == LogicalKeyboardKey.arrowLeft) {
      _scrollBy(_horizontalController, -90);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _scrollBy(_horizontalController, 90);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      _scrollBy(_verticalController, -60);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      _scrollBy(_verticalController, 60);
    } else if (key == LogicalKeyboardKey.pageUp) {
      _scrollBy(_verticalController, -page);
    } else if (key == LogicalKeyboardKey.pageDown) {
      _scrollBy(_verticalController, page);
    } else if (key == LogicalKeyboardKey.home) {
      if (_verticalController.hasClients) _verticalController.jumpTo(0);
    } else if (key == LogicalKeyboardKey.end) {
      if (_verticalController.hasClients) _verticalController.jumpTo(_verticalController.position.maxScrollExtent);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  Widget _headerCell(int index) {
    final column = widget.columns[index];
    return SizedBox(
      width: _widths[index] * _zoom,
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 10, 16, 10),
            child: Text(
              column.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: _kGold, letterSpacing: 0.5),
            ),
          ),
          // The drag handle on the right edge of each header: drag to make
          // the column wider or narrower, double-tap to put it back.
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (details) => setState(() {
                  _widths[index] = (_widths[index] + details.delta.dx / _zoom).clamp(column.minWidth, 700.0).toDouble();
                }),
                onDoubleTap: () => setState(() => _widths[index] = column.width),
                child: Container(
                  width: 12,
                  alignment: Alignment.center,
                  child: Container(width: 1, color: Colors.white24),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.rows.isEmpty) {
      final Widget message = Center(child: Text(widget.emptyMessage, style: const TextStyle(color: Colors.white54)));
      if (widget.onRefresh == null) return message;
      // Even with nothing to list, the screen can be pulled down to refresh.
      return LayoutBuilder(
        builder: (context, constraints) => RefreshIndicator(
          onRefresh: widget.onRefresh!,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [SizedBox(height: constraints.maxHeight, child: message)],
          ),
        ),
      );
    }

    final double baseWidth = _widths.fold(0.0, (sum, w) => sum + w);
    final double totalWidth = baseWidth * _zoom;
    final List<double> shownWidths = _widths.map((w) => w * _zoom).toList();

    return LayoutBuilder(
      builder: (context, constraints) {
        // The zoom at which every column fits the width available.
        final double fitZoom = baseWidth <= 0
            ? 1.0
            : ((constraints.maxWidth - 2) / baseWidth).clamp(_minZoom, _maxZoom).toDouble();
        final MediaQueryData mediaQuery = MediaQuery.of(context);

        return Column(
          children: [
            _buildZoomBar(fitZoom),
            const SizedBox(height: 6),
            Expanded(
              // Everything inside the table, lettering included, is
              // enlarged or reduced together.
              child: MediaQuery(
                data: mediaQuery.copyWith(textScaler: TextScaler.linear(_zoom)),
                child: Focus(
                  focusNode: _focusNode,
                  onKeyEvent: _onKey,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: _focusNode.requestFocus,
                    child: _withPullToRefresh(Container(
                      decoration: BoxDecoration(
                        color: _kCardBg,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: _focusNode.hasFocus ? _kGold : Colors.white12, width: _focusNode.hasFocus ? 1 : 0.5),
                      ),
                      child: Scrollbar(
                        controller: _horizontalController,
                        thumbVisibility: true,
                        child: SingleChildScrollView(
                          controller: _horizontalController,
                          scrollDirection: Axis.horizontal,
                          child: SizedBox(
                            width: totalWidth,
                            child: Column(
                              children: [
                                Container(
                                  decoration: const BoxDecoration(
                                    color: Color(0xff0a1426),
                                    border: Border(bottom: BorderSide(color: Colors.white24)),
                                  ),
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: List.generate(widget.columns.length, _headerCell),
                                  ),
                                ),
                                Expanded(
                                  child: ListView.builder(
                                    controller: _verticalController,
                                    physics: const AlwaysScrollableScrollPhysics(),
                                    itemCount: widget.rows.length,
                                    itemBuilder: (context, index) => widget.rowBuilder(context, widget.rows[index], shownWidths),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    )),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Pulling the table down reads the records again. The horizontal
  /// scrolling of a wide table is ignored; only a downward pull counts.
  Widget _withPullToRefresh(Widget table) {
    if (widget.onRefresh == null) return table;
    return RefreshIndicator(
      onRefresh: widget.onRefresh!,
      notificationPredicate: (notification) => notification.metrics.axis == Axis.vertical,
      child: table,
    );
  }

  /// The small control strip above the table: smaller, larger, and Fit,
  /// which sets the size so every column is on screen at once.
  Widget _buildZoomBar(double fitZoom) {
    void setZoom(double value) => setState(() => _zoom = value.clamp(_minZoom, _maxZoom).toDouble());

    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        IconButton(
          tooltip: "Make the table smaller",
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.zoom_out, size: 20),
          onPressed: _zoom <= _minZoom ? null : () => setZoom(_zoom - _zoomStep),
        ),
        SizedBox(
          width: 44,
          child: Text("${(_zoom * 100).round()}%", textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, color: Colors.white70)),
        ),
        IconButton(
          tooltip: "Make the table larger",
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.zoom_in, size: 20),
          onPressed: _zoom >= _maxZoom ? null : () => setZoom(_zoom + _zoomStep),
        ),
        TextButton(
          onPressed: () => setZoom(fitZoom),
          child: const Text("Fit", style: TextStyle(color: _kGold, fontWeight: FontWeight.bold)),
        ),
        TextButton(
          onPressed: () => setZoom(1.0),
          child: const Text("Reset", style: TextStyle(color: Colors.white70)),
        ),
      ],
    );
  }
}

/// One table cell of a set width, with the same padding everywhere.
Widget _cell(double width, Widget child) {
  return SizedBox(
    width: width,
    child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8), child: child),
  );
}

Widget _textCell(double width, String text, {Color color = Colors.white, double size = 12.5, FontWeight? weight, FontStyle? style}) {
  return _cell(width, Text(text, style: TextStyle(fontSize: size, color: color, fontWeight: weight, fontStyle: style)));
}

/// The row shell: background tint and a thin divider underneath.
Widget _rowShell({required List<Widget> cells, Color? tint}) {
  return Container(
    decoration: BoxDecoration(
      color: tint,
      border: const Border(bottom: BorderSide(color: Colors.white10)),
    ),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: cells),
  );
}

// ---------------------------------------------------------------------
// Shift headings
// ---------------------------------------------------------------------
// The Guest Log and the Shop Sales tables show a single bar above each
// shift's entries, saying when that shift was and how long it ran. Newest
// first, like everything else in Records:
//
//   Daily           Opened 08:12 GMT · Closed 16:40 GMT · 8h 28m
//                   (a shift still running says Open; when more than one
//                   shift ran that day, each bar also says how many)
//   Weekly and up   7 Oct 2026 · 8h 28m   (shifts on the same date are
//                   added together)
//   Buffer shift Buffer Shift (with the date from Weekly upward);
//                   it has no length

/// One shift, as the server describes it.
class _ShiftInfo {
  final int id;
  final DateTime start;
  final DateTime? end;
  final bool isOpen;
  final bool isBufferShift;

  _ShiftInfo({required this.id, required this.start, required this.end, required this.isOpen, required this.isBufferShift});

  factory _ShiftInfo.fromJson(Map<String, dynamic> json) {
    return _ShiftInfo(
      id: json['id'],
      start: DateTime.parse(json['start']).toLocal(),
      end: json['end'] != null ? DateTime.parse(json['end']).toLocal() : null,
      isOpen: json['is_open'] ?? false,
      isBufferShift: json['is_buffer_shift'] ?? false,
    );
  }

  /// How long the shift ran, or has run so far if it is still open.
  Duration get length => (end ?? DateTime.now()).difference(start);
}

Map<int, _ShiftInfo> _parseShifts(dynamic raw) {
  final Map<int, _ShiftInfo> shifts = {};
  for (final entry in (raw as List<dynamic>? ?? const [])) {
    final info = _ShiftInfo.fromJson(Map<String, dynamic>.from(entry));
    shifts[info.id] = info;
  }
  return shifts;
}

const List<String> _kMonthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

String _formatDay(DateTime when) => "${when.day} ${_kMonthNames[when.month - 1]} ${when.year}";

String _formatClock(DateTime when) {
  final hour = when.hour.toString().padLeft(2, '0');
  final minute = when.minute.toString().padLeft(2, '0');
  return "$hour:$minute GMT";
}

String _formatLength(Duration length) {
  final int totalMinutes = length.inMinutes < 0 ? 0 : length.inMinutes;
  final int hours = totalMinutes ~/ 60;
  final int minutes = totalMinutes % 60;
  return hours == 0 ? "${minutes}m" : "${hours}h ${minutes}m";
}

/// One piece of a grouped table: either a shift heading or an entry.
class _Grouped<T> {
  final String? heading;
  final T? item;
  _Grouped.heading(String this.heading) : item = null;
  _Grouped.item(T this.item) : heading = null;
}

class _ShiftGroup<T> {
  final bool isBufferShift;
  final bool hasShift;
  final DateTime? bufferDay;
  final List<_ShiftInfo> shifts = [];
  final List<T> items = [];
  _ShiftGroup({required this.isBufferShift, required this.hasShift, this.bufferDay});
}

/// Puts a shift heading above each shift's entries. [items] must already be
/// newest first; the groups keep the order in which they first appear, so
/// the newest shift is on top. An entry with no known shift is listed
/// without a heading. An entry made before its shift's official start
/// (during the buffer period) is listed under the Buffer Shift heading.
List<_Grouped<T>> _groupByShift<T>(
  List<T> items,
  int? Function(T) sessionIdOf,
  Map<int, _ShiftInfo> shifts, {
  required DateTime Function(T) timeOf,
  required bool isDaily,
}) {
  final Map<String, _ShiftGroup<T>> groups = {};

  for (final item in items) {
    final int? sessionId = sessionIdOf(item);
    final _ShiftInfo? shift = sessionId == null ? null : shifts[sessionId];

    final DateTime itemTime = timeOf(item);
    final bool isBufferEntry = shift != null && (shift.isBufferShift || itemTime.isBefore(shift.start));
    final DateTime? dayBasis = shift == null ? null : (isBufferEntry ? itemTime : shift.start);

    final String key;
    if (shift == null) {
      key = "none";
    } else {
      final String dayKey = "${dayBasis!.year}-${dayBasis.month}-${dayBasis.day}";
      key = isBufferEntry
          ? (isDaily ? "buffer-shift" : "buffer-shift-$dayKey")
          : (isDaily ? "shift-${shift.id}" : "day-$dayKey");
    }

    final group = groups.putIfAbsent(
      key,
      () => _ShiftGroup<T>(isBufferShift: isBufferEntry, hasShift: shift != null, bufferDay: isBufferEntry ? itemTime : null),
    );
    if (shift != null && !group.shifts.any((s) => s.id == shift.id)) group.shifts.add(shift);
    group.items.add(item);
  }

  final int officialShiftCount = groups.values.where((g) => g.hasShift && !g.isBufferShift).length;

  final List<_Grouped<T>> result = [];
  for (final group in groups.values) {
    if (group.hasShift) {
      result.add(_Grouped<T>.heading(_headingText(group, isDaily: isDaily, officialShiftCount: officialShiftCount)));
    }
    for (final item in group.items) {
      result.add(_Grouped<T>.item(item));
    }
  }
  return result;
}

String _headingText<T>(_ShiftGroup<T> group, {required bool isDaily, required int officialShiftCount}) {
  final _ShiftInfo first = group.shifts.first;

  if (group.isBufferShift) {
    return isDaily ? "Buffer Shift" : "${_formatDay(group.bufferDay ?? first.start)} · Buffer Shift";
  }

  if (isDaily) {
    final String times = first.isOpen || first.end == null
        ? "Opened ${_formatClock(first.start)} · Open"
        : "Opened ${_formatClock(first.start)} · Closed ${_formatClock(first.end!)} · ${_formatLength(first.length)}";
    return officialShiftCount > 1 ? "$officialShiftCount shifts today · $times" : times;
  }

  Duration total = Duration.zero;
  bool anyOpen = false;
  for (final shift in group.shifts) {
    total += shift.length;
    if (shift.isOpen) anyOpen = true;
  }
  return "${_formatDay(first.start)} · ${_formatLength(total)}${anyOpen ? ' (open)' : ''}";
}

/// The heading bar: one cell as wide as the whole table, so it reads as a
/// single line across every column.
Widget _shiftHeadingRow(String text, List<double> widths) {
  final double fullWidth = widths.fold(0.0, (sum, w) => sum + w);
  return Container(
    width: fullWidth,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
    decoration: const BoxDecoration(
      color: Color(0xff0a1426),
      border: Border(top: BorderSide(color: _kGold, width: 0.6), bottom: BorderSide(color: Colors.white12)),
    ),
    child: Text(
      text,
      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 0.6, color: _kGold),
    ),
  );
}

// ---------------------------------------------------------------------
// Guest Log
// ---------------------------------------------------------------------

class _GuestLogSubView extends StatefulWidget {
  final ApiService apiService;
  const _GuestLogSubView({required this.apiService});

  @override
  State<_GuestLogSubView> createState() => _GuestLogSubViewState();
}

class _GuestLogSubViewState extends State<_GuestLogSubView> {
  int _activePeriodIndex = 0;
  DateTimeRange? _customRange;
  final TextEditingController _searchController = TextEditingController();
  final _RecordFilters _filters = _RecordFilters();

  bool _isLoading = true;
  String? _errorMessage;
  List<GuestLogEntry> _entries = [];
  Map<int, _ShiftInfo> _shifts = {};

  // The columns, in the order the manager asked for. The two checkout
  // columns and the "by" column double as the cancel columns: for a
  // cancelled booking there is no checkout at all, so those cells say
  // "Cancelled", the cancel time, and who cancelled it instead.
  static const List<_TableColumn> _columns = [
    _TableColumn("GUEST NAME", 170),
    _TableColumn("PHONE", 115),
    _TableColumn("ROOM", 85),
    _TableColumn("DESCRIPTION", 150),
    _TableColumn("HOURS", 70),
    _TableColumn("PAYMENT", 260),
    _TableColumn("CHECKED IN", 135),
    _TableColumn("CHECKED IN BY", 130),
    _TableColumn("SCHEDULED CHECKOUT", 150),
    _TableColumn("ACTUAL CHECKOUT / CANCEL TIME", 175),
    _TableColumn("CHECKED OUT BY / CANCELLED BY", 160),
  ];

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() => setState(() {}));
    _fetch();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _fetch({bool quietly = false}) async {
    // A pull to refresh keeps the table on screen while it reads again.
    if (!quietly) setState(() { _isLoading = true; _errorMessage = null; });
    try {
      final raw = await widget.apiService.fetchGuestLog(
        period: _PeriodChoice.keys[_activePeriodIndex],
        startDate: _customRange != null ? _customRange!.start.toIso8601String().split('T').first : null,
        endDate: _customRange != null ? _customRange!.end.toIso8601String().split('T').first : null,
      );
      if (!mounted) return;
      setState(() {
        _entries = (raw['guests'] as List<dynamic>).map((e) => GuestLogEntry.fromJson(Map<String, dynamic>.from(e))).toList();
        _shifts = _parseShifts(raw['shifts']);
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      if (quietly) {
        // The records already on screen stay; only a short note is shown.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Could not refresh: ${e.toString().replaceAll("Exception: ", "")}")),
        );
        return;
      }
      setState(() {
        _isLoading = false;
        _errorMessage = e.toString().replaceAll("Exception: ", "");
      });
    }
  }

  /// The distinct room numbers in this period, in natural order, for the Room filter.
  List<String> get _roomOptions {
    final Set<String> rooms = _entries.map((e) => e.roomNumber).toSet();
    final List<String> sorted = rooms.toList();
    sorted.sort((a, b) {
      final int? na = int.tryParse(a);
      final int? nb = int.tryParse(b);
      if (na != null && nb != null) return na.compareTo(nb);
      return a.toLowerCase().compareTo(b.toLowerCase());
    });
    return sorted;
  }

  /// Whether a booking (with its extensions) passes every ticked filter.
  bool _passesFilters(GuestLogEntry entry) {
    final _RecordFilters f = _filters;
    if (f.activeCount == 0) return true;

    if (!f.matchesShiftKind(_isBufferEntry(_shifts, entry.sessionId, entry.checkedInAt))) return false;
    if (f.rooms.isNotEmpty && !f.rooms.contains(entry.roomNumber)) return false;

    final bool isExtensionOnly = entry.standaloneExtension != null;
    if (!f.matchesPayment([
      entry.payment['method'] as String?,
      ...entry.extensions.map((e) => e.payment['method'] as String?),
    ])) {
      return false;
    }

    if (f.statuses.isNotEmpty) {
      final bool cancelled = entry.cancelled || entry.extensions.any((e) => e.cancelled) || (entry.standaloneExtension?.cancelled ?? false);
      final bool extended = entry.extended || isExtensionOnly || entry.extensions.isNotEmpty;
      final bool restored = entry.restoredByManager;
      final bool any = (f.statuses.contains("Cancelled") && cancelled) ||
          (f.statuses.contains("Extended") && extended) ||
          (f.statuses.contains("Restored") && restored);
      if (!any) return false;
    }
    return true;
  }

  /// Flattens the matching bookings into table lines, newest first and
  /// grouped under a heading for their shift: each booking, then its
  /// extensions directly underneath.
  List<_LogRow> _visibleRows() {
    final String typed = _searchController.text;
    final List<GuestLogEntry> matching = _entries
        .where((entry) => _passesFilters(entry) && (typed.trim().isEmpty || _matchesSearch(entry.searchText, typed)))
        .toList();

    final List<_LogRow> rows = [];
    for (final piece in _groupByShift<GuestLogEntry>(matching, (e) => e.sessionId, _shifts, timeOf: (e) => e.checkedInAt, isDaily: _activePeriodIndex == 0)) {
      if (piece.heading != null) {
        rows.add(_LogRow.heading(piece.heading!));
        continue;
      }
      final GuestLogEntry entry = piece.item as GuestLogEntry;
      if (entry.standaloneExtension != null) {
        rows.add(_LogRow(entry, entry.standaloneExtension, true));
        continue;
      }
      rows.add(_LogRow(entry));
      for (final extension in entry.extensions) {
        rows.add(_LogRow(entry, extension));
      }
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _PeriodPicker(
          activeIndex: _activePeriodIndex,
          customRange: _customRange,
          onChanged: (index, range) {
            setState(() {
              _activePeriodIndex = index;
              _customRange = range;
            });
            _fetch();
          },
        ),
        const SizedBox(height: 12),
        _SearchBox(controller: _searchController, hint: "Search anything in the log: name, phone, room, date, person..."),
        const SizedBox(height: 10),
        _FilterPanel(filters: _filters, roomOptions: _roomOptions, showStatus: true, onChanged: () => setState(() {})),
        const SizedBox(height: 16),
        Expanded(child: _buildBody()),
      ],
    );
  }

  Widget _buildBody() {
    if (_isLoading) return const Center(child: CircularProgressIndicator(strokeWidth: 2, color: _kGold));
    if (_errorMessage != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text("Could not load: $_errorMessage", style: const TextStyle(color: Color(0xffe0584a))),
            const SizedBox(height: 12),
            TextButton(onPressed: _fetch, child: const Text("Try Again")),
          ],
        ),
      );
    }

    final rows = _visibleRows();
    final Widget table = _ResizableTable<_LogRow>(
      onRefresh: () => _fetch(quietly: true),
      columns: _columns,
      rows: rows,
      emptyMessage: _entries.isEmpty ? "No bookings in this period." : "Nothing matches that search or these filters.",
      rowBuilder: (context, row, widths) {
        if (row.heading != null) return _shiftHeadingRow(row.heading!, widths);
        final GuestLogEntry entry = row.entry!;
        if (row.extension == null) return _bookingRow(entry, widths);
        // A long press (phone) or a right click (laptop) on an extension
        // opens the manager's menu, exactly as it does on a booking.
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPressStart: (details) => _openExtensionMenu(entry, row.extension!, details.globalPosition),
          onSecondaryTapUp: (details) => _openExtensionMenu(entry, row.extension!, details.globalPosition),
          child: row.isStandalone
              ? _standaloneExtensionRow(entry, row.extension!, widths)
              : _extensionRow(entry, row.extension!, widths),
        );
      },
    );

    // Daily has no total: the live room screens and the shift chips already
    // say how many bookings the day has. From Weekly upward the total sits
    // above the table.
    if (_activePeriodIndex == 0) return table;
    return Column(
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 6, left: 2),
            child: Text(
              "Total bookings: $_totalBookings",
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: _kGold),
            ),
          ),
        ),
        Expanded(child: table),
      ],
    );
  }

  /// How many bookings were made in the chosen period. An extension counts
  /// as a booking, exactly as it does in Business Summary; cancelled ones
  /// are left out. It counts the whole period, whatever is typed in search.
  int get _totalBookings {
    int total = 0;
    for (final entry in _entries) {
      if (entry.standaloneExtension != null) {
        if (!entry.standaloneExtension!.cancelled) total++;
        continue;
      }
      if (entry.cancelled) continue;
      total++;
      total += entry.extensions.where((e) => !e.cancelled).length;
    }
    return total;
  }

  Widget _bookingRow(GuestLogEntry entry, List<double> w) {
    final bool cancelled = entry.cancelled;
    final Color textColor = cancelled ? _kCancelledText : Colors.white;
    final Color softColor = cancelled ? _kCancelledText : Colors.white70;

    // A cancelled booking has no checkout, so its two checkout cells and
    // the "by" cell are replaced rather than left blank or misleading.
    final Widget scheduledCell = cancelled
        ? _textCell(w[8], "CANCELLED", color: _kCancelledText, size: 11, weight: FontWeight.bold)
        : _textCell(w[8], _formatMoment(entry.scheduledCheckout), color: softColor);
    final Widget actualCell = cancelled
        ? _textCell(w[9], "Cancel time: ${_formatMoment(entry.cancelledAt)}", color: _kCancelledText)
        : _textCell(w[9], _formatMoment(entry.actualCheckout), color: softColor);
    final Widget byCell = cancelled
        ? _textCell(
            w[10],
            entry.cancelledByManager ? "Cancelled by Manager" : "Cancelled by ${entry.cancelledBy ?? 'unknown'}",
            color: _kCancelledText,
          )
        : _textCell(w[10], entry.checkedOutBy ?? "—", color: softColor);

    // A long press (phone) or a right click (laptop) on a booking opens the
    // manager's menu: Cancel Booking, or Restore Booking after a manager
    // cancel. A booking cancelled by a receptionist shows a note instead.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPressStart: (details) => _openBookingMenu(entry, details.globalPosition),
      onSecondaryTapUp: (details) => _openBookingMenu(entry, details.globalPosition),
      child: _rowShell(
      tint: cancelled ? _kCancelledTint : null,
      cells: [
        _cell(
          w[0],
          Row(
            children: [
              Flexible(child: Text(entry.guestName, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: textColor))),
              if (entry.restoredByManager) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(border: Border.all(color: Colors.white54, width: 0.7), borderRadius: BorderRadius.circular(3)),
                  child: const Text("RESTORED", style: TextStyle(fontSize: 8, color: Colors.white70, fontWeight: FontWeight.bold)),
                ),
              ],
            ],
          ),
        ),
        _textCell(w[1], entry.guestPhone, color: softColor),
        _textCell(w[2], entry.roomNumber, color: textColor),
        _textCell(w[3], entry.roomDescription.isEmpty ? "—" : entry.roomDescription, color: softColor),
        _textCell(w[4], "${entry.durationHours}h", color: softColor),
        _textCell(w[5], _paymentText(entry.payment), color: softColor),
        _textCell(w[6], _formatMoment(entry.checkedInAt), color: softColor),
        _textCell(w[7], entry.checkedInBy ?? "—", color: softColor),
        scheduledCell,
        actualCell,
        byCell,
      ],
    ),
    );
  }

  /// The manager's menu for one booking, opened where the press happened.
  Future<void> _openBookingMenu(GuestLogEntry entry, Offset position) async {
    final bool canCancel = !entry.cancelled;
    final bool canRestore = entry.cancelled && entry.cancelledByManager;

    final String? choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx / activeScreenScale, position.dy / activeScreenScale, position.dx / activeScreenScale, position.dy / activeScreenScale),
      items: [
        if (canCancel)
          const PopupMenuItem(value: "cancel", child: Text("Cancel Booking")),
        if (canRestore)
          const PopupMenuItem(value: "restore", child: Text("Restore Booking")),
        if (!canCancel && !canRestore)
          PopupMenuItem(
            enabled: false,
            child: Text("Cancelled by ${entry.cancelledBy ?? 'a receptionist'}; it cannot be restored here."),
          ),
      ],
    );
    if (choice == null || !mounted) return;
    await _confirmAndRunOverride(entry, restore: choice == "restore");
  }

  /// Asks the manager to confirm, then cancels or restores the booking on
  /// the server and reloads the log.
  Future<void> _confirmAndRunOverride(GuestLogEntry entry, {required bool restore}) async {
    final String who = "${entry.guestName}, ${entry.roomNumber}";
    // Extensions still standing on this booking are cancelled with it.
    final int standingExtensions = entry.extensions.where((extension) => !extension.cancelled).length;
    final String extensionNote = standingExtensions == 0
        ? ""
        : "\n\nThis booking has $standingExtensions ${standingExtensions == 1 ? "extension" : "extensions"}. "
            "${standingExtensions == 1 ? "It" : "They"} will be cancelled as well.";
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(restore ? "Restore this booking?" : "Cancel this booking?"),
        content: Text(
          restore
              ? "$who will count again in the totals, exactly as before it was cancelled."
              : "$who stays in the log marked as cancelled by the Manager, and its money "
                  "(extensions included) leaves the totals. It can be restored afterwards.$extensionNote",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(restore ? "Keep Cancelled" : "Keep Booking")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: restore ? _kGold : const Color(0xffc0392b),
              foregroundColor: restore ? Colors.black : Colors.white,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(restore ? "Restore Booking" : "Cancel Booking"),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      if (restore) {
        await widget.apiService.managerRestoreBooking(entry.bookingId);
      } else {
        await widget.apiService.managerCancelBooking(entry.bookingId);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xff14703f),
          content: Text(restore ? "Booking restored." : "Booking cancelled by the Manager."),
        ),
      );
      await _fetch();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xffc0392b),
          content: Text(e.toString().replaceAll("Exception: ", "")),
        ),
      );
    }
  }

  /// An extension: a smaller, slightly indented line directly under its
  /// booking. It never repeats the guest's name or phone. It shows when
  /// the extension started (the checkout time it carried on from), the new
  /// scheduled checkout it created, how it was paid and who made it. A
  /// cancelled extension gets the same faint reddish wash as a cancelled
  /// booking and is marked, because it stays in the log as an audit line
  /// but is never part of any total.
  /// The three cells at the end of an extension row, which hold what a
  /// booking's own end-of-row cells hold. A cancelled extension reads
  /// "CANCELLED", the cancel time and who cancelled it, like a cancelled
  /// booking. Otherwise the first cell is the new scheduled checkout; the
  /// other two are the actual checkout and who checked the guest out when
  /// the row stands on its own, and are blank under its booking, where the
  /// one actual checkout of the stay is shown.
  List<Widget> _extensionEndCells(GuestLogExtension extension, List<double> w, {required bool showCheckout}) {
    if (extension.cancelled) {
      return [
        _textCell(w[8], "CANCELLED", color: _kCancelledText, size: 11, weight: FontWeight.bold),
        _textCell(w[9], "Cancel time: ${_formatMoment(extension.cancelledAt)}", color: _kCancelledText, size: 11),
        _textCell(
          w[10],
          extension.cancelledByManager ? "Cancelled by Manager" : "Cancelled by ${extension.cancelledBy ?? 'unknown'}",
          color: _kCancelledText,
          size: 11,
        ),
      ];
    }
    return [
      _textCell(w[8], _formatMoment(extension.newScheduledCheckout), color: Colors.white60, size: 11),
      _textCell(w[9], showCheckout ? _formatMoment(extension.actualCheckout) : "", color: Colors.white60, size: 11),
      _textCell(w[10], showCheckout ? (extension.checkedOutBy ?? "—") : "", color: Colors.white60, size: 11),
    ];
  }

  Widget _extensionRow(GuestLogEntry entry, GuestLogExtension extension, List<double> w) {
    final bool cancelled = extension.cancelled;
    final Color soft = cancelled ? _kCancelledText : Colors.white60;

    return _rowShell(
      tint: cancelled ? _kCancelledTint : _kExtensionTint,
      cells: [
        _cell(
          w[0],
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Text(
              "↳ Extension",
              style: TextStyle(fontSize: 11, color: cancelled ? _kCancelledText : _kGold, fontWeight: FontWeight.w600),
            ),
          ),
        ),
        _textCell(w[1], "", size: 11),
        _textCell(w[2], "", size: 11),
        _textCell(w[3], "", size: 11),
        _textCell(w[4], "+${extension.additionalHours}h", color: soft, size: 11),
        _textCell(w[5], _paymentText(extension.payment), color: soft, size: 11),
        _textCell(w[6], "Starts ${_formatMoment(extension.startsAt)}", color: soft, size: 11),
        _textCell(w[7], "Extended by ${extension.madeBy ?? 'unknown'}", color: soft, size: 11),
        ..._extensionEndCells(extension, w, showCheckout: false),
      ],
    );
  }

  /// The manager's menu for one extension, opened where the press happened:
  /// Cancel Extension, or Restore Extension after a manager cancel. An
  /// extension a receptionist cancelled shows a note instead.
  Future<void> _openExtensionMenu(GuestLogEntry entry, GuestLogExtension extension, Offset position) async {
    final bool canCancel = !extension.cancelled && !entry.cancelled;
    final bool canRestore = extension.cancelled && extension.cancelledByManager && !entry.cancelled;

    final String? choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx / activeScreenScale, position.dy / activeScreenScale, position.dx / activeScreenScale, position.dy / activeScreenScale),
      items: [
        if (canCancel) const PopupMenuItem(value: "cancel", child: Text("Cancel Extension")),
        if (canRestore) const PopupMenuItem(value: "restore", child: Text("Restore Extension")),
        if (!canCancel && !canRestore)
          const PopupMenuItem(enabled: false, child: Text("This extension is cancelled; it cannot be restored here.")),
      ],
    );
    if (choice == null || !mounted) return;
    await _confirmAndRunExtensionOverride(entry, extension, restore: choice == "restore");
  }

  /// Asks the manager to confirm, then cancels or restores the extension on
  /// the server and reloads the log.
  Future<void> _confirmAndRunExtensionOverride(GuestLogEntry entry, GuestLogExtension extension, {required bool restore}) async {
    final String who = "${entry.guestName}, ${entry.roomNumber}";
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(restore ? "Restore this extension?" : "Cancel this extension?"),
        content: Text(
          restore
              ? "The extension for $who will count again in the totals."
              : "The extension for $who stays in the log marked as cancelled by the Manager, "
                  "and its money leaves the totals. It can be restored afterwards.",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(restore ? "Keep Cancelled" : "Keep Extension")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: restore ? _kGold : const Color(0xffc0392b),
              foregroundColor: restore ? Colors.black : Colors.white,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(restore ? "Restore Extension" : "Cancel Extension"),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      if (restore) {
        await widget.apiService.managerRestoreExtension(extension.extensionId);
      } else {
        await widget.apiService.managerCancelExtension(extension.extensionId);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xff14703f),
          content: Text(restore ? "Extension restored." : "Extension cancelled by the Manager."),
        ),
      );
      await _fetch();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xffc0392b),
          content: Text(e.toString().replaceAll("Exception: ", "")),
        ),
      );
    }
  }

  /// An extension that stands on its own: made in this period on a booking
  /// checked in earlier. It reads "Extension, room, guest name": the guest,
  /// phone, room and description of the booking it belongs to, the hours
  /// added, how it was paid, when it was made and by whom, and the new
  /// scheduled checkout it created.
  Widget _standaloneExtensionRow(GuestLogEntry entry, GuestLogExtension extension, List<double> w) {
    final bool cancelled = extension.cancelled;
    final Color textColor = cancelled ? _kCancelledText : Colors.white;
    final Color soft = cancelled ? _kCancelledText : Colors.white70;

    return _rowShell(
      tint: cancelled ? _kCancelledTint : _kExtensionTint,
      cells: [
        _cell(
          w[0],
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(entry.guestName, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: textColor)),
              Text(
                "Extension",
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: cancelled ? _kCancelledText : _kGold),
              ),
            ],
          ),
        ),
        _textCell(w[1], entry.guestPhone, color: soft),
        _textCell(w[2], entry.roomNumber, color: textColor),
        _textCell(w[3], entry.roomDescription.isEmpty ? "—" : entry.roomDescription, color: soft),
        _textCell(w[4], "+${extension.additionalHours}h", color: soft),
        _textCell(w[5], _paymentText(extension.payment), color: soft),
        _textCell(w[6], "Made ${_formatMoment(extension.madeAt)}", color: soft),
        _textCell(w[7], "Extended by ${extension.madeBy ?? 'unknown'}", color: soft),
        ..._extensionEndCells(extension, w, showCheckout: true),
      ],
    );
  }
}

// ---------------------------------------------------------------------
// Shop Sales
// ---------------------------------------------------------------------

class _ShopSaleEntry {
  final String itemName;
  final int quantity;
  final double unitPrice;
  final double totalCost;
  final DateTime timestamp;
  final String? soldBy;
  final Map<String, dynamic> payment;
  final int? sessionId;

  _ShopSaleEntry({
    required this.itemName,
    required this.quantity,
    required this.unitPrice,
    required this.totalCost,
    required this.timestamp,
    required this.soldBy,
    required this.payment,
    this.sessionId,
  });

  factory _ShopSaleEntry.fromJson(Map<String, dynamic> json) {
    return _ShopSaleEntry(
      itemName: json['item_name'],
      quantity: json['quantity'],
      unitPrice: (json['unit_price'] as num).toDouble(),
      totalCost: (json['total_cost'] as num).toDouble(),
      timestamp: DateTime.parse(json['timestamp']).toLocal(),
      soldBy: json['sold_by'],
      payment: Map<String, dynamic>.from(json['payment'] ?? {}),
      sessionId: json['session_id'],
    );
  }

  String get searchText => [
        itemName, "$quantity", _cedis(unitPrice), _cedis(totalCost),
        _formatMoment(timestamp), soldBy ?? "", _paymentText(payment),
      ].join(" ");
}

/// One line of the Shop Sales table: a sale, or a shift heading.
class _ShopLine {
  final _ShopSaleEntry? sale;
  final String? heading;
  _ShopLine.sale(_ShopSaleEntry this.sale) : heading = null;
  _ShopLine.heading(String this.heading) : sale = null;
}

class _ShopSalesSubView extends StatefulWidget {
  final ApiService apiService;
  const _ShopSalesSubView({required this.apiService});

  @override
  State<_ShopSalesSubView> createState() => _ShopSalesSubViewState();
}

class _ShopSalesSubViewState extends State<_ShopSalesSubView> {
  int _activePeriodIndex = 0;
  DateTimeRange? _customRange;
  final TextEditingController _searchController = TextEditingController();
  final _RecordFilters _filters = _RecordFilters();

  bool _isLoading = true;
  String? _errorMessage;
  List<_ShopSaleEntry> _entries = [];
  Map<int, _ShiftInfo> _shifts = {};

  static const List<_TableColumn> _columns = [
    _TableColumn("TIME", 140),
    _TableColumn("ITEM", 200),
    _TableColumn("QTY", 60),
    _TableColumn("UNIT PRICE", 100),
    _TableColumn("TOTAL", 100),
    _TableColumn("PAYMENT", 280),
    _TableColumn("SOLD BY", 150),
  ];

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() => setState(() {}));
    _fetch();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _fetch({bool quietly = false}) async {
    // A pull to refresh keeps the table on screen while it reads again.
    if (!quietly) setState(() { _isLoading = true; _errorMessage = null; });
    try {
      final raw = await widget.apiService.fetchShopSalesRecord(
        period: _PeriodChoice.keys[_activePeriodIndex],
        startDate: _customRange != null ? _customRange!.start.toIso8601String().split('T').first : null,
        endDate: _customRange != null ? _customRange!.end.toIso8601String().split('T').first : null,
      );
      if (!mounted) return;
      setState(() {
        _entries = (raw['sales'] as List<dynamic>).map((e) => _ShopSaleEntry.fromJson(Map<String, dynamic>.from(e))).toList();
        _shifts = _parseShifts(raw['shifts']);
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      if (quietly) {
        // The records already on screen stay; only a short note is shown.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Could not refresh: ${e.toString().replaceAll("Exception: ", "")}")),
        );
        return;
      }
      setState(() {
        _isLoading = false;
        _errorMessage = e.toString().replaceAll("Exception: ", "");
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _PeriodPicker(
          activeIndex: _activePeriodIndex,
          customRange: _customRange,
          onChanged: (index, range) {
            setState(() {
              _activePeriodIndex = index;
              _customRange = range;
            });
            _fetch();
          },
        ),
        const SizedBox(height: 12),
        _SearchBox(controller: _searchController, hint: "Search anything: item, person, date, MoMo number..."),
        const SizedBox(height: 10),
        _FilterPanel(filters: _filters, roomOptions: null, showStatus: false, onChanged: () => setState(() {})),
        const SizedBox(height: 16),
        Expanded(child: _buildBody()),
      ],
    );
  }

  Widget _buildBody() {
    if (_isLoading) return const Center(child: CircularProgressIndicator(strokeWidth: 2, color: _kGold));
    if (_errorMessage != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text("Could not load: $_errorMessage", style: const TextStyle(color: Color(0xffe0584a))),
            const SizedBox(height: 12),
            TextButton(onPressed: _fetch, child: const Text("Try Again")),
          ],
        ),
      );
    }

    final String typed = _searchController.text;
    final List<_ShopSaleEntry> matching = _entries
        .where((e) =>
            _filters.matchesShiftKind(_isBufferEntry(_shifts, e.sessionId, e.timestamp)) &&
            _filters.matchesPayment([e.payment['method'] as String?]) &&
            (typed.trim().isEmpty || _matchesSearch(e.searchText, typed)))
        .toList();

    // Newest first, each shift's sales under a heading for that shift.
    final List<_ShopLine> rows = _groupByShift<_ShopSaleEntry>(matching, (s) => s.sessionId, _shifts, timeOf: (s) => s.timestamp, isDaily: _activePeriodIndex == 0)
        .map((piece) => piece.heading != null ? _ShopLine.heading(piece.heading!) : _ShopLine.sale(piece.item as _ShopSaleEntry))
        .toList();

    return _ResizableTable<_ShopLine>(
      onRefresh: () => _fetch(quietly: true),
      columns: _columns,
      rows: rows,
      emptyMessage: _entries.isEmpty ? "No shop sales in this period." : "Nothing matches that search or these filters.",
      rowBuilder: (context, line, w) {
        if (line.heading != null) return _shiftHeadingRow(line.heading!, w);
        final sale = line.sale!;
        return _rowShell(
          cells: [
            _textCell(w[0], _formatMoment(sale.timestamp), color: Colors.white70),
            _textCell(w[1], sale.itemName, weight: FontWeight.bold),
            _textCell(w[2], "${sale.quantity}", color: Colors.white70),
            _textCell(w[3], _cedis(sale.unitPrice), color: Colors.white70),
            _textCell(w[4], _cedis(sale.totalCost)),
            _textCell(w[5], _paymentText(sale.payment), color: Colors.white70),
            _textCell(w[6], sale.soldBy ?? "—", color: Colors.white70),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------
// Money Brought In
// ---------------------------------------------------------------------

class _MoneyBroughtInSubView extends StatefulWidget {
  final ApiService apiService;
  const _MoneyBroughtInSubView({required this.apiService});

  @override
  State<_MoneyBroughtInSubView> createState() => _MoneyBroughtInSubViewState();
}

class _MoneyBroughtInSubViewState extends State<_MoneyBroughtInSubView> {
  int _activePeriodIndex = 0;
  DateTimeRange? _customRange;
  final TextEditingController _searchController = TextEditingController();

  bool _isLoadingStaff = true;
  String? _staffLoadError;
  List<EmployeeRecord> _receptionists = [];
  EmployeeRecord? _selectedStaff;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() => setState(() {}));
    _loadReceptionists();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadReceptionists() async {
    try {
      final raw = await widget.apiService.fetchAllEmployees();
      final all = raw.map((e) => EmployeeRecord.fromJson(e)).toList();
      final receptionistsOnly = all.where((e) => e.role == "Receptionist").toList()
        ..sort((a, b) => a.fullName.toLowerCase().compareTo(b.fullName.toLowerCase()));
      // The Buffer chip always comes last, after every receptionist, even
      // when there are no receptionists yet: anything booked or sold under
      // the shared Buffer login must always be findable here.
      receptionistsOnly.add(EmployeeRecord(id: _kBufferChipId, fullName: "Buffer", role: "Buffer", monthlySalary: 0));
      if (!mounted) return;
      setState(() {
        _receptionists = receptionistsOnly;
        _selectedStaff = receptionistsOnly.first;
        _isLoadingStaff = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _staffLoadError = e.toString().replaceAll("Exception: ", "");
        _isLoadingStaff = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoadingStaff) return const Center(child: CircularProgressIndicator(strokeWidth: 2, color: _kGold));
    if (_staffLoadError != null) {
      return Center(child: Text("Could not load staff: $_staffLoadError", style: const TextStyle(color: Color(0xffe0584a))));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // One chip per receptionist, plus a Buffer chip for the shared
        // Buffer login.
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _receptionists.map((staff) {
            final bool selected = _selectedStaff?.id == staff.id;
            return ChoiceChip(
              avatar: Icon(staff.id == _kBufferChipId ? Icons.swap_horiz : Icons.person, size: 16, color: selected ? Colors.black : Colors.white54),
              label: Text(staff.fullName),
              selected: selected,
              selectedColor: _kGold,
              labelStyle: TextStyle(color: selected ? Colors.black : Colors.white, fontWeight: FontWeight.bold),
              onSelected: (val) { if (val) setState(() => _selectedStaff = staff); },
            );
          }).toList(),
        ),
        const SizedBox(height: 12),
        _PeriodPicker(
          activeIndex: _activePeriodIndex,
          customRange: _customRange,
          onChanged: (index, range) => setState(() {
            _activePeriodIndex = index;
            _customRange = range;
          }),
        ),
        const SizedBox(height: 12),
        _SearchBox(controller: _searchController, hint: "Search anything: room, item, date, MoMo number..."),
        const SizedBox(height: 16),
        Expanded(child: _selectedStaff == null ? const SizedBox.shrink() : _buildEarningsBody()),
      ],
    );
  }

  /// One line under Bookings, Extensions or Shop Sales: what it was, how it
  /// was paid, and when.
  Widget _line({required String title, required double amount, required Map<String, dynamic> payment, required String timestamp}) {
    // Own transparent Material behind the row, so Flutter never prints the
    // "ListTile background color or ink splashes may be invisible" warning.
    return Material(
      type: MaterialType.transparency,
      child: ListTile(
        dense: true,
        title: Text(title),
        subtitle: Text(
          "${_paymentText(payment)}  ·  ${_formatMoment(DateTime.parse(timestamp).toLocal())}",
          style: const TextStyle(fontSize: 11, color: Colors.white54),
        ),
        trailing: Text(_cedis(amount)),
      ),
    );
  }

  bool _lineMatches(String title, Map<String, dynamic> payment, String timestamp) {
    final String typed = _searchController.text;
    if (typed.trim().isEmpty) return true;
    return _matchesSearch("$title ${_paymentText(payment)} ${_formatMoment(DateTime.parse(timestamp).toLocal())}", typed);
  }

  Widget _buildEarningsBody() {
    return FutureBuilder<Map<String, dynamic>>(
      key: ValueKey("${_selectedStaff!.id}-$_activePeriodIndex-${_customRange?.start}-${_customRange?.end}"),
      future: widget.apiService.fetchMoneyBroughtIn(
        // No employee id means the Buffer chip.
        employeeId: _selectedStaff!.id == _kBufferChipId ? null : _selectedStaff!.id,
        period: _PeriodChoice.keys[_activePeriodIndex],
        startDate: _customRange != null ? _customRange!.start.toIso8601String().split('T').first : null,
        endDate: _customRange != null ? _customRange!.end.toIso8601String().split('T').first : null,
      ),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 2, color: _kGold));
        }
        if (snapshot.hasError) {
          return Text("Could not load: ${snapshot.error.toString().replaceAll("Exception: ", "")}", style: const TextStyle(color: Color(0xffe0584a)));
        }

        final data = snapshot.data!;
        final bookings = List<Map<String, dynamic>>.from(data['bookings'] ?? []);
        final extensions = List<Map<String, dynamic>>.from(data['extensions'] ?? []);
        final shopSales = List<Map<String, dynamic>>.from(data['shop_sales'] ?? []);
        final double total = (data['total'] as num?)?.toDouble() ?? 0.0;

        // An extension is a booking: it is listed with the bookings, showing
        // the room that was extended and the hours added with a plus sign
        // (+6h), newest first. The guest's name is deliberately left off
        // these lines.
        final List<Map<String, dynamic>> bookingLines = [
          ...bookings.map((b) => {'room': b['room_number'], 'hours': '${b['duration_hours']}', 'amount': b['amount'], 'payment': b['payment'], 'timestamp': b['timestamp']}),
          ...extensions.map((e) => {'room': e['room_number'], 'hours': '+${e['additional_hours']}', 'amount': e['amount'], 'payment': e['payment'], 'timestamp': e['timestamp']}),
        ]..sort((a, b) => (b['timestamp'] as String).compareTo(a['timestamp'] as String));

        final shownBookings = bookingLines.where((b) => _lineMatches("${b['room']} ${b['hours']}h", Map<String, dynamic>.from(b['payment'] ?? {}), b['timestamp'])).toList();
        final shownSales = shopSales.where((s) => _lineMatches("${s['quantity']} x ${s['item_name']}", Map<String, dynamic>.from(s['payment'] ?? {}), s['timestamp'])).toList();

        return ListView(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: const Color(0xff14703f), borderRadius: BorderRadius.circular(6)),
              child: Text("Total: ${_cedis(total)}", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.white)),
            ),
            const SizedBox(height: 12),
            if (bookingLines.isEmpty && shopSales.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text("Nothing recorded this period.", style: TextStyle(color: Colors.white54, fontStyle: FontStyle.italic)),
              )
            else if (shownBookings.isEmpty && shownSales.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text("Nothing matches that search.", style: TextStyle(color: Colors.white54, fontStyle: FontStyle.italic)),
              ),
            if (shownBookings.isNotEmpty) ...[
              const Text("Bookings", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white70)),
              ...shownBookings.map((b) => _line(
                    title: "${b['room']} — ${b['hours']}h",
                    amount: (b['amount'] as num).toDouble(),
                    payment: Map<String, dynamic>.from(b['payment'] ?? {}),
                    timestamp: b['timestamp'],
                  )),
            ],
            if (shownSales.isNotEmpty) ...[
              const Text("Shop Sales", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white70)),
              ...shownSales.map((s) => _line(
                    title: "${s['quantity']} x ${s['item_name']}",
                    amount: (s['amount'] as num).toDouble(),
                    payment: Map<String, dynamic>.from(s['payment'] ?? {}),
                    timestamp: s['timestamp'],
                  )),
            ],
          ],
        );
      },
    );
  }
}


// ---------------------------------------------------------------------
// Login Record
// ---------------------------------------------------------------------

class _LoginRecordEntry {
  final String name;
  final String usernameTried;
  final String outcome; // SUCCESS, FAILED or BLOCKED
  final String? role;
  final String? clientIp;
  final String? flagNote;
  final DateTime attemptedAt;
  final bool firstToday;

  _LoginRecordEntry({
    required this.name,
    required this.usernameTried,
    required this.outcome,
    required this.role,
    required this.clientIp,
    required this.flagNote,
    required this.attemptedAt,
    required this.firstToday,
  });

  factory _LoginRecordEntry.fromJson(Map<String, dynamic> json) {
    return _LoginRecordEntry(
      name: json['name'] ?? "",
      usernameTried: json['username_tried'] ?? "",
      outcome: json['outcome'] ?? "",
      role: json['role'],
      clientIp: json['client_ip'],
      flagNote: json['flag_note'],
      attemptedAt: DateTime.parse(json['attempted_at']).toLocal(),
      firstToday: json['first_today'] ?? false,
    );
  }

  bool get isFlagged => outcome != "SUCCESS" || (flagNote ?? "").isNotEmpty;

  String get outcomeText {
    switch (outcome) {
      case "SUCCESS":
        return "Logged in";
      case "FAILED":
        return "Failed";
      default:
        return "Refused";
    }
  }

  String get searchText => [
        name, usernameTried, outcomeText, role ?? "", clientIp ?? "", flagNote ?? "",
        _formatMoment(attemptedAt), if (firstToday) "first login of the day started work",
      ].join(" ");
}

/// Who logged in, when, and from which device, plus every failed attempt
/// and every login from an unexpected kind of device. These are only
/// flagged for the manager to read; nothing here blocks anyone.
class _LoginRecordSubView extends StatefulWidget {
  final ApiService apiService;
  const _LoginRecordSubView({required this.apiService});

  @override
  State<_LoginRecordSubView> createState() => _LoginRecordSubViewState();
}

class _LoginRecordSubViewState extends State<_LoginRecordSubView> {
  int _activePeriodIndex = 0;
  DateTimeRange? _customRange;
  final TextEditingController _searchController = TextEditingController();

  bool _isLoading = true;
  String? _errorMessage;
  List<_LoginRecordEntry> _entries = [];

  static const List<_TableColumn> _columns = [
    _TableColumn("TIME", 135),
    _TableColumn("NAME", 170),
    _TableColumn("RESULT", 90),
    _TableColumn("ROLE", 100),
    _TableColumn("DEVICE ADDRESS", 140),
    _TableColumn("NOTE", 380),
  ];

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() => setState(() {}));
    _fetch();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _fetch({bool quietly = false}) async {
    // A pull to refresh keeps the table on screen while it reads again.
    if (!quietly) setState(() { _isLoading = true; _errorMessage = null; });
    try {
      final raw = await widget.apiService.fetchLoginRecords(
        period: _PeriodChoice.keys[_activePeriodIndex],
        startDate: _customRange != null ? _customRange!.start.toIso8601String().split('T').first : null,
        endDate: _customRange != null ? _customRange!.end.toIso8601String().split('T').first : null,
      );
      if (!mounted) return;
      setState(() {
        _entries = raw.map((e) => _LoginRecordEntry.fromJson(Map<String, dynamic>.from(e))).toList();
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      if (quietly) {
        // The records already on screen stay; only a short note is shown.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Could not refresh: ${e.toString().replaceAll("Exception: ", "")}")),
        );
        return;
      }
      setState(() {
        _isLoading = false;
        _errorMessage = e.toString().replaceAll("Exception: ", "");
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _PeriodPicker(
          activeIndex: _activePeriodIndex,
          customRange: _customRange,
          onChanged: (index, range) {
            setState(() {
              _activePeriodIndex = index;
              _customRange = range;
            });
            _fetch();
          },
        ),
        const SizedBox(height: 12),
        _SearchBox(controller: _searchController, hint: "Search the login record: name, result, device, date..."),
        const SizedBox(height: 16),
        Expanded(child: _buildBody()),
      ],
    );
  }

  Widget _buildBody() {
    if (_isLoading) return const Center(child: CircularProgressIndicator(strokeWidth: 2, color: _kGold));
    if (_errorMessage != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text("Could not load: $_errorMessage", style: const TextStyle(color: Color(0xffe0584a))),
            const SizedBox(height: 12),
            TextButton(onPressed: _fetch, child: const Text("Try Again")),
          ],
        ),
      );
    }

    final typed = _searchController.text;
    final rows = _entries.where((e) => typed.trim().isEmpty || _matchesSearch(e.searchText, typed)).toList();

    return _ResizableTable<_LoginRecordEntry>(
      onRefresh: () => _fetch(quietly: true),
      columns: _columns,
      rows: rows,
      emptyMessage: _entries.isEmpty ? "No logins in this period." : "Nothing matches that search.",
      rowBuilder: (context, entry, w) {
        final bool failed = entry.outcome != "SUCCESS";
        final Color textColor = failed ? _kCancelledText : Colors.white;
        final Color softColor = failed ? _kCancelledText : Colors.white70;
        return _rowShell(
          tint: failed ? _kCancelledTint : null,
          cells: [
            _textCell(w[0], _formatMoment(entry.attemptedAt), color: softColor),
            _cell(
              w[1],
              Row(
                children: [
                  Flexible(child: Text(entry.name, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: textColor))),
                  if (entry.firstToday) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(border: Border.all(color: _kGold, width: 0.7), borderRadius: BorderRadius.circular(3)),
                      child: const Text("FIRST OF DAY", style: TextStyle(fontSize: 8, color: _kGold, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ],
              ),
            ),
            _textCell(w[2], entry.outcomeText, color: textColor, weight: FontWeight.bold),
            _textCell(w[3], entry.role ?? "—", color: softColor),
            _textCell(w[4], entry.clientIp ?? "—", color: softColor),
            _textCell(
              w[5],
              (entry.flagNote ?? "").isEmpty ? "—" : entry.flagNote!,
              color: (entry.flagNote ?? "").isEmpty ? softColor : const Color(0xffc9971f),
            ),
          ],
        );
      },
    );
  }
}
