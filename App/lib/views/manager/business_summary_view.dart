import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

// Links to the shared network service core tool
import '../../services/api_service.dart';

/// One income or deduction line (Rooms, Ancillary, Expendables, Utilities,
/// Payroll, or the final Net Profit line): its value for the selected
/// period, the equal-length period right before it, and which way it
/// moved. isUnusuallyHigh is only meaningful for deduction lines.
class SummaryLine {
  final double current;
  final double previous;
  final String trend; // "UP", "DOWN", "FLAT"
  final bool isUnusuallyHigh;

  SummaryLine({
    required this.current,
    required this.previous,
    required this.trend,
    this.isUnusuallyHigh = false,
  });

  factory SummaryLine.fromJson(Map<String, dynamic> json) {
    return SummaryLine(
      current: (json['current'] as num).toDouble(),
      previous: (json['previous'] as num).toDouble(),
      trend: json['trend'],
      isUnusuallyHigh: json['is_unusually_high'] ?? false,
    );
  }
}

/// One duration/package row under a room or an ancillary item — e.g. "3
/// hour package, 3 new bookings, ₵390" or "₵18 price point, 5 sold, ₵90".
class PackageRow {
  final int? durationHours; // Only present for room package rows
  final String? kind; // "new" or "extension", only present for room package rows
  final double? unitPrice; // Only present for ancillary price-point rows
  final int count;
  final double subtotal;

  PackageRow({this.durationHours, this.kind, this.unitPrice, required this.count, required this.subtotal});

  factory PackageRow.fromRoomJson(Map<String, dynamic> json) {
    return PackageRow(
      durationHours: json['duration_hours'],
      kind: json['kind'],
      count: json['count'],
      subtotal: (json['subtotal'] as num).toDouble(),
    );
  }

  factory PackageRow.fromAncillaryJson(Map<String, dynamic> json) {
    return PackageRow(
      unitPrice: (json['unit_price'] as num).toDouble(),
      count: json['quantity'],
      subtotal: (json['subtotal'] as num).toDouble(),
    );
  }
}

/// One room's drill-down entry: how many times it was booked, what it
/// earned in total, and the package-by-package breakdown behind that.
class RoomBreakdownEntry {
  final String roomName;
  final int timesBooked;
  final double totalRevenue;
  final bool isHighestEarner;
  final bool isMostBooked;
  final List<PackageRow> packages;

  RoomBreakdownEntry({
    required this.roomName,
    required this.timesBooked,
    required this.totalRevenue,
    required this.isHighestEarner,
    required this.isMostBooked,
    required this.packages,
  });

  factory RoomBreakdownEntry.fromJson(Map<String, dynamic> json) {
    return RoomBreakdownEntry(
      roomName: json['room_name'],
      timesBooked: json['times_booked'],
      totalRevenue: (json['total_revenue'] as num).toDouble(),
      isHighestEarner: json['is_highest_earner'] ?? false,
      isMostBooked: json['is_most_booked'] ?? false,
      packages: (json['packages'] as List).map((p) => PackageRow.fromRoomJson(p)).toList(),
    );
  }
}

/// One ancillary item's drill-down entry, matched without regard to
/// capitalization or stray spacing — "Beer", "beer", and "BEER " all
/// land in the one entry.
class AncillaryBreakdownEntry {
  final String itemName;
  final int totalQuantity;
  final double totalRevenue;
  final bool isHighestEarner;
  final bool isMostSold;
  final List<PackageRow> pricePoints;

  AncillaryBreakdownEntry({
    required this.itemName,
    required this.totalQuantity,
    required this.totalRevenue,
    required this.isHighestEarner,
    required this.isMostSold,
    required this.pricePoints,
  });

  factory AncillaryBreakdownEntry.fromJson(Map<String, dynamic> json) {
    return AncillaryBreakdownEntry(
      itemName: json['item_name'],
      totalQuantity: json['total_quantity'],
      totalRevenue: (json['total_revenue'] as num).toDouble(),
      isHighestEarner: json['is_highest_earner'] ?? false,
      isMostSold: json['is_most_sold'] ?? false,
      pricePoints: (json['price_points'] as List).map((p) => PackageRow.fromAncillaryJson(p)).toList(),
    );
  }
}

/// One employee's prorated share of the payroll line for the period.
class PayrollBreakdownEntry {
  final String employeeName;
  final double proratedAmount;

  PayrollBreakdownEntry({required this.employeeName, required this.proratedAmount});

  factory PayrollBreakdownEntry.fromJson(Map<String, dynamic> json) {
    return PayrollBreakdownEntry(
      employeeName: json['employee_name'],
      proratedAmount: (json['prorated_amount'] as num).toDouble(),
    );
  }
}

/// One grouped line under Utilities or Expendables — e.g. "Electricity
/// bill, 2 entries, ₵340" — matched without regard to capitalization or
/// stray spacing, the same rule Ancillary already uses.
class ExpenseBreakdownEntry {
  final String itemName;
  final double totalAmount;
  final int entryCount;

  ExpenseBreakdownEntry({required this.itemName, required this.totalAmount, required this.entryCount});

  factory ExpenseBreakdownEntry.fromJson(Map<String, dynamic> json) {
    return ExpenseBreakdownEntry(
      itemName: json['item_name'],
      totalAmount: (json['total_amount'] as num).toDouble(),
      entryCount: json['entry_count'],
    );
  }
}

/// One cancelled booking: which room, how long it was booked for, when it
/// was booked and when it was cancelled, and by whom.
class CancelledBookingEntry {
  final String roomNumber;
  final int durationHours;
  final DateTime bookedAt;
  final DateTime cancelledAt;
  final String? bookedBy;
  final String? cancelledBy;

  CancelledBookingEntry({
    required this.roomNumber,
    required this.durationHours,
    required this.bookedAt,
    required this.cancelledAt,
    this.bookedBy,
    this.cancelledBy,
  });

  factory CancelledBookingEntry.fromJson(Map<String, dynamic> json) {
    return CancelledBookingEntry(
      roomNumber: json['room_number'],
      durationHours: json['duration_hours'],
      bookedAt: DateTime.parse(json['booked_at']).toLocal(),
      cancelledAt: DateTime.parse(json['cancelled_at']).toLocal(),
      bookedBy: json['booked_by'],
      cancelledBy: json['cancelled_by'],
    );
  }

  /// Only worth showing separately from bookedBy when it is genuinely a
  /// different person — the same "only when they differ" rule the one-tap
  /// Cancel confirmation already follows elsewhere in the app.
  bool get cancelledByDiffersFromBookedBy => cancelledBy != null && cancelledBy != bookedBy;
}

/// The full Business Summary payload for one selected horizon.
class BusinessSummaryData {
  final bool insufficientHistory;
  final int cancelledCount;
  final SummaryLine roomsIncome;
  final SummaryLine ancillaryIncome;
  final SummaryLine expendables;
  final SummaryLine utilities;
  final SummaryLine payroll;
  final SummaryLine netProfit;
  final List<RoomBreakdownEntry> roomsBreakdown;
  final List<AncillaryBreakdownEntry> ancillaryBreakdown;
  final List<ExpenseBreakdownEntry> utilitiesBreakdown;
  final List<ExpenseBreakdownEntry> expendablesBreakdown;
  final List<PayrollBreakdownEntry> payrollBreakdown;
  final List<CancelledBookingEntry> cancelledBreakdown;

  BusinessSummaryData({
    required this.insufficientHistory,
    required this.cancelledCount,
    required this.roomsIncome,
    required this.ancillaryIncome,
    required this.expendables,
    required this.utilities,
    required this.payroll,
    required this.netProfit,
    required this.roomsBreakdown,
    required this.ancillaryBreakdown,
    required this.utilitiesBreakdown,
    required this.expendablesBreakdown,
    required this.payrollBreakdown,
    required this.cancelledBreakdown,
  });

  factory BusinessSummaryData.fromJson(Map<String, dynamic> json) {
    final income = json['income'];
    final deductions = json['deductions'];
    return BusinessSummaryData(
      insufficientHistory: json['insufficient_history'] ?? false,
      cancelledCount: json['cancelled_count'],
      roomsIncome: SummaryLine.fromJson(income['rooms']),
      ancillaryIncome: SummaryLine.fromJson(income['ancillary']),
      expendables: SummaryLine.fromJson(deductions['expendables']),
      utilities: SummaryLine.fromJson(deductions['utilities']),
      payroll: SummaryLine.fromJson(deductions['payroll']),
      netProfit: SummaryLine.fromJson(json['net_profit']),
      roomsBreakdown: (json['rooms_breakdown'] as List).map((r) => RoomBreakdownEntry.fromJson(r)).toList(),
      ancillaryBreakdown: (json['ancillary_breakdown'] as List).map((a) => AncillaryBreakdownEntry.fromJson(a)).toList(),
      utilitiesBreakdown: (json['utilities_breakdown'] as List? ?? []).map((e) => ExpenseBreakdownEntry.fromJson(e)).toList(),
      expendablesBreakdown: (json['expendables_breakdown'] as List? ?? []).map((e) => ExpenseBreakdownEntry.fromJson(e)).toList(),
      payrollBreakdown: (json['payroll_breakdown'] as List).map((p) => PayrollBreakdownEntry.fromJson(p)).toList(),
      cancelledBreakdown: (json['cancelled_breakdown'] as List? ?? []).map((c) => CancelledBookingEntry.fromJson(c)).toList(),
    );
  }
}

const Color _kGold = Color(0xffd4af37);
const Color _kProfitGreen = Color(0xff1e9e5a);
const Color _kLossRed = Color(0xffc0392b);
const Color _kCardBg = Color(0xff111f3a);

/// The manager's full financial picture for a selected period: two income
/// lines, three deduction lines each compared against the period before
/// it (each expandable into its own item-by-item breakdown, the same
/// tap-to-drill-down treatment Rooms and Sales use), a net profit figure,
/// and a cancelled-bookings drill-down.
class BusinessSummaryView extends StatefulWidget {
  final ApiService apiService;

  const BusinessSummaryView({super.key, required this.apiService});

  @override
  State<BusinessSummaryView> createState() => _BusinessSummaryViewState();
}

class _BusinessSummaryViewState extends State<BusinessSummaryView> {
  // Quarterly and Half-Year are deliberately NOT offered here — Custom
  // already covers any such range in one pick, and this screen is meant
  // to stay a fast, uncluttered glance (see the Guest Log for the fuller
  // period picker).
  final List<String> _horizons = ["DAILY", "WEEKLY", "MONTHLY", "YEARLY", "CUSTOM"];
  int _activeHorizonIndex = 0;
  DateTimeRange? _customRange;

  bool _isLoading = true;
  String? _errorMessage;
  BusinessSummaryData? _data;
  DateTime? _lastKnownGoodAt;
  bool _lastRefreshFailed = false;

  @override
  void initState() {
    super.initState();
    _fetchSummary();
  }

  String _formatLastUpdated(DateTime when) {
    final hour = when.hour.toString().padLeft(2, '0');
    final minute = when.minute.toString().padLeft(2, '0');
    return "Last updated $hour:$minute";
  }

  /// The fixed period tabs are real calendar periods, worked out by the
  /// server: Daily is today's date, Weekly runs Sunday to Saturday,
  /// Monthly is the calendar month and Yearly the calendar year.
  String? _periodForHorizon() {
    switch (_activeHorizonIndex) {
      case 0: return "daily";
      case 1: return "weekly";
      case 2: return "monthly";
      case 3: return "yearly";
      default: return null; // CUSTOM uses _customRange instead
    }
  }

  Future<void> _pickCustomRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 5),
      lastDate: now,
      initialDateRange: _customRange ?? DateTimeRange(start: now.subtract(const Duration(days: 7)), end: now),
    );
    if (picked != null) {
      setState(() {
        _activeHorizonIndex = 4;
        _customRange = picked;
      });
      _fetchSummary();
    }
  }

  Future<void> _fetchSummary() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final String? period = _periodForHorizon();
      final Uri uri;
      if (period != null) {
        uri = Uri.parse("${ApiService.baseUrl}/analytics/financials/?period=$period");
      } else if (_customRange != null) {
        final startDate = _customRange!.start.toIso8601String().split('T').first;
        final endDate = _customRange!.end.toIso8601String().split('T').first;
        uri = Uri.parse("${ApiService.baseUrl}/analytics/financials/?start_date=$startDate&end_date=$endDate");
      } else {
        setState(() => _isLoading = false);
        return; // CUSTOM chosen but no range picked yet — nothing to fetch.
      }

      final response = await http.get(
        uri,
        headers: {"Authorization": "Bearer ${widget.apiService.authToken}"},
      ).timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        setState(() {
          _data = BusinessSummaryData.fromJson(jsonDecode(response.body));
          _isLoading = false;
          _errorMessage = null;
          _lastKnownGoodAt = DateTime.now();
          _lastRefreshFailed = false;
        });
      } else {
        throw Exception("Could not load the business summary right now.");
      }
    } catch (error) {
      // The server could not be reached (or rejected the request) this
      // time. If figures were already showing, they are kept exactly as
      // they were, with a "Last updated" time, rather than being replaced
      // by a plain error — a manager glancing at this screen should
      // always see the most recent real numbers, not a blank failure.
      setState(() {
        _isLoading = false;
        _lastRefreshFailed = true;
        if (_data == null) {
          _errorMessage = error.toString().replaceAll("Exception: ", "");
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              "BUSINESS SUMMARY",
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: _kGold, letterSpacing: 1),
            ),
            if (_lastRefreshFailed && _lastKnownGoodAt != null)
              Text(_formatLastUpdated(_lastKnownGoodAt!), style: const TextStyle(fontSize: 11, color: Colors.white54)),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: _horizons.asMap().entries.map((entry) {
            final int idx = entry.key;
            final bool isCustom = idx == 4;
            final bool selected = _activeHorizonIndex == idx;
            return Padding(
              padding: const EdgeInsets.only(right: 8.0),
              child: ChoiceChip(
                label: Text(isCustom && _customRange != null
                    ? "${_customRange!.start.month}/${_customRange!.start.day} – ${_customRange!.end.month}/${_customRange!.end.day}"
                    : entry.value),
                selected: selected,
                selectedColor: _kGold,
                labelStyle: TextStyle(color: selected ? Colors.black : Colors.white, fontWeight: FontWeight.bold),
                onSelected: (val) {
                  if (!val) return;
                  if (isCustom) {
                    _pickCustomRange();
                  } else {
                    setState(() => _activeHorizonIndex = idx);
                    _fetchSummary();
                  }
                },
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 20),
        Expanded(child: _buildBody()),
      ],
    );
  }

  Widget _buildBody() {
    if (_isLoading && _data == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2, color: _kGold));
    }
    if (_data == null && _errorMessage != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text("Could not load: $_errorMessage", style: const TextStyle(color: Color(0xffe0584a))),
            const SizedBox(height: 12),
            TextButton(onPressed: _fetchSummary, child: const Text("Try Again")),
          ],
        ),
      );
    }
    if (_data == null) {
      return const Center(child: Text("Pick a date range to view.", style: TextStyle(color: Colors.white54)));
    }

    final data = _data!;

    // The period reaches back further than the business itself has
    // existed — a plain message, rather than a technically-correct but
    // misleading small or "loss" figure for a stretch that could not
    // possibly have any real data in it.
    if (data.insufficientHistory) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24.0),
          child: Text(
            "Not enough time has passed yet for this period.",
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54, fontStyle: FontStyle.italic, fontSize: 15),
          ),
        ),
      );
    }

    final bool periodHasNoActivity = data.roomsBreakdown.isEmpty && data.ancillaryBreakdown.isEmpty;
    final String horizonLabel = _activeHorizonIndex == 4 ? "period" : _horizons[_activeHorizonIndex].toLowerCase();

    return RefreshIndicator(
      onRefresh: _fetchSummary,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          _buildNetProfitBanner(data.netProfit),
          const SizedBox(height: 16),
          _buildIncomeDeductionsCard(data),
          const SizedBox(height: 20),
          if (periodHasNoActivity)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(
                  "Nothing booked this $horizonLabel.",
                  style: const TextStyle(color: Colors.white54, fontStyle: FontStyle.italic),
                ),
              ),
            )
          else ...[
            _buildRoomsSection(data),
            const SizedBox(height: 20),
            _buildAncillarySection(data),
          ],
          if (data.cancelledBreakdown.isNotEmpty) ...[
            const SizedBox(height: 20),
            _buildCancelledSection(data),
          ],
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildNetProfitBanner(SummaryLine netProfit) {
    final bool isProfit = netProfit.current >= 0;
    final Color bannerColor = isProfit ? _kProfitGreen : _kLossRed;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [bannerColor.withAlpha(230), bannerColor.withAlpha(140)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(10),
        boxShadow: [BoxShadow(color: bannerColor.withAlpha(70), blurRadius: 16, offset: const Offset(0, 6))],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isProfit ? "NET PROFIT" : "NET LOSS",
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, letterSpacing: 1.2, color: Colors.white70),
              ),
              const SizedBox(height: 6),
              Text(
                "₵ ${netProfit.current.abs().toStringAsFixed(2)}",
                style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ],
          ),
          _buildTrendArrow(netProfit.trend, large: true),
        ],
      ),
    );
  }

  Widget _buildIncomeDeductionsCard(BusinessSummaryData data) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: _kCardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _kGold.withAlpha(60), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text("INCOME", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white54, letterSpacing: 1)),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _buildFinancialLine(Icons.hotel, "Rooms", data.roomsIncome, isDeduction: false),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _buildFinancialLine(Icons.storefront, "Sales", data.ancillaryIncome, isDeduction: false),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 14, horizontal: 16),
            child: Divider(color: Colors.white12, height: 1),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text("DEDUCTIONS", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white54, letterSpacing: 1)),
          ),
          const SizedBox(height: 4),
          _buildExpandableDeductionRow(
            icon: Icons.receipt_long,
            label: "Expendables",
            line: data.expendables,
            breakdown: data.expendablesBreakdown,
          ),
          _buildExpandableDeductionRow(
            icon: Icons.bolt,
            label: "Utilities",
            line: data.utilities,
            breakdown: data.utilitiesBreakdown,
          ),
          _buildExpandableDeductionRow(
            icon: Icons.groups,
            label: "Payroll",
            line: data.payroll,
            payrollBreakdown: data.payrollBreakdown,
          ),
        ],
      ),
    );
  }

  Widget _buildFinancialLine(IconData icon, String label, SummaryLine line, {required bool isDeduction}) {
    // A deduction line that jumped unusually compared to the period
    // before it is tinted so the cause of a bad period is visible at a
    // glance, not just the final total.
    final Color valueColor = line.isUnusuallyHigh ? const Color(0xffe67e22) : Colors.white;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 16, color: _kGold),
          const SizedBox(width: 10),
          Expanded(child: Text(label, style: const TextStyle(fontSize: 14, color: Colors.white70))),
          if (line.isUnusuallyHigh)
            const Padding(
              padding: EdgeInsets.only(right: 6),
              child: Icon(Icons.warning_amber_rounded, size: 15, color: Color(0xffe67e22)),
            ),
          Text(
            "${isDeduction ? '-' : ''}₵ ${line.current.toStringAsFixed(2)}",
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: valueColor),
          ),
          const SizedBox(width: 6),
          _buildTrendArrow(line.trend),
        ],
      ),
    );
  }

  /// A deduction line (Expendables, Utilities, or Payroll) that expands in
  /// place to show what actually makes it up — the same tap-to-drill-down
  /// treatment Rooms and Sales already have. Exactly one of `breakdown` or
  /// `payrollBreakdown` is passed, depending on which deduction this is.
  Widget _buildExpandableDeductionRow({
    required IconData icon,
    required String label,
    required SummaryLine line,
    List<ExpenseBreakdownEntry>? breakdown,
    List<PayrollBreakdownEntry>? payrollBreakdown,
  }) {
    final Color valueColor = line.isUnusuallyHigh ? const Color(0xffe67e22) : Colors.white;
    final bool isEmpty = (breakdown?.isEmpty ?? false) && (payrollBreakdown?.isEmpty ?? true);

    // A transparent Material sits directly behind the tile. An expanding
    // row is built on a ListTile, and Flutter prints "ListTile background
    // color or ink splashes may be invisible" whenever a coloured box sits
    // between a ListTile and the nearest Material. This gives the tile its
    // own Material, so the warning cannot appear; nothing looks different.
    return Material(
      type: MaterialType.transparency,
      child: Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
        childrenPadding: const EdgeInsets.fromLTRB(28, 0, 20, 10),
        title: Row(
          children: [
            Icon(icon, size: 16, color: _kGold),
            const SizedBox(width: 10),
            Expanded(child: Text(label, style: const TextStyle(fontSize: 14, color: Colors.white70))),
            if (line.isUnusuallyHigh)
              const Padding(
                padding: EdgeInsets.only(right: 6),
                child: Icon(Icons.warning_amber_rounded, size: 15, color: Color(0xffe67e22)),
              ),
            Text(
              "-₵ ${line.current.toStringAsFixed(2)}",
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: valueColor),
            ),
          ],
        ),
        children: isEmpty
            ? [const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text("Nothing logged this period.", style: TextStyle(fontSize: 12, color: Colors.white38, fontStyle: FontStyle.italic)),
              )]
            : payrollBreakdown != null
                ? payrollBreakdown.map((entry) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(entry.employeeName, style: const TextStyle(fontSize: 13, color: Colors.white70)),
                          Text("₵ ${entry.proratedAmount.toStringAsFixed(2)}", style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white)),
                        ],
                      ),
                    );
                  }).toList()
                : breakdown!.map((entry) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(child: Text(entry.itemName, style: const TextStyle(fontSize: 13, color: Colors.white70))),
                          Text("${entry.entryCount}× · ₵ ${entry.totalAmount.toStringAsFixed(2)}", style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white)),
                        ],
                      ),
                    );
                  }).toList(),
      ),
      ),
    );
  }

  /// Just an arrow and a color — no percentage, no sentence — comparing a
  /// line to the equal-length period right before it.
  Widget _buildTrendArrow(String trend, {bool large = false}) {
    final double size = large ? 22 : 15;
    switch (trend) {
      case "UP":
        return Icon(Icons.arrow_upward, size: size, color: const Color(0xff22b06a));
      case "DOWN":
        return Icon(Icons.arrow_downward, size: size, color: const Color(0xffd6473a));
      default:
        return Icon(Icons.remove, size: size, color: Colors.white38);
    }
  }

  Widget _buildRoomsSection(BusinessSummaryData data) {
    return _buildDrillDownCard(
      title: "Rooms",
      icon: Icons.hotel,
      children: data.roomsBreakdown.map((room) {
        return _buildExpandableRow(
          leading: room.roomName,
          badge1: room.isHighestEarner ? "Highest Earner" : null,
          badge2: room.isMostBooked ? "Most Booked" : null,
          subtitle: "${room.timesBooked} booked",
          total: room.totalRevenue,
          children: room.packages.map((pkg) {
            // Each line says which kind it is, so a count that includes
            // extensions can be traced back to its bookings and extensions.
            final String kindLabel = pkg.kind == "extension" ? "Extension" : "Booking";
            return _buildPackageDetailRow(
              "${pkg.durationHours} hours — $kindLabel",
              "${pkg.count} × ₵ ${(pkg.subtotal / pkg.count).toStringAsFixed(2)} = ₵ ${pkg.subtotal.toStringAsFixed(2)}",
            );
          }).toList(),
        );
      }).toList(),
    );
  }

  Widget _buildAncillarySection(BusinessSummaryData data) {
    return _buildDrillDownCard(
      title: "Sales",
      icon: Icons.storefront,
      children: data.ancillaryBreakdown.map((item) {
        return _buildExpandableRow(
          leading: item.itemName,
          badge1: item.isHighestEarner ? "Highest Earner" : null,
          badge2: item.isMostSold ? "Most Sold" : null,
          subtitle: "${item.totalQuantity} sold",
          total: item.totalRevenue,
          children: item.pricePoints.map((pp) {
            return _buildPackageDetailRow(
              "₵ ${pp.unitPrice!.toStringAsFixed(2)} each",
              "${pp.count} × ₵ ${pp.unitPrice!.toStringAsFixed(2)} = ₵ ${pp.subtotal.toStringAsFixed(2)}",
            );
          }).toList(),
        );
      }).toList(),
    );
  }

  /// Every cancelled booking this period: which room, how long it was for,
  /// when it was booked, when it was cancelled, and by whom — cancelled_by
  /// is only shown when it is a different person from who booked it.
  Widget _buildCancelledSection(BusinessSummaryData data) {
    String formatMoment(DateTime when) {
      final hour = when.hour.toString().padLeft(2, '0');
      final minute = when.minute.toString().padLeft(2, '0');
      return "$hour:$minute, ${when.day}/${when.month}/${when.year}";
    }

    return _buildDrillDownCard(
      title: "Cancelled (${data.cancelledCount})",
      icon: Icons.event_busy,
      children: data.cancelledBreakdown.map((entry) {
        final String byLine = entry.cancelledByDiffersFromBookedBy
            ? "Booked by ${entry.bookedBy ?? 'unknown'}, cancelled by ${entry.cancelledBy}"
            : "Booked and cancelled by ${entry.bookedBy ?? entry.cancelledBy ?? 'unknown'}";
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text("${entry.roomNumber} — ${entry.durationHours}h", style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white)),
                ],
              ),
              const SizedBox(height: 2),
              Text("Booked ${formatMoment(entry.bookedAt)}  ·  Cancelled ${formatMoment(entry.cancelledAt)}", style: const TextStyle(fontSize: 11, color: Colors.white54)),
              const SizedBox(height: 2),
              Text(byLine, style: const TextStyle(fontSize: 11, color: Colors.white38, fontStyle: FontStyle.italic)),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildDrillDownCard({required String title, required IconData icon, required List<Widget> children}) {
    if (children.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      decoration: BoxDecoration(
        color: _kCardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                Icon(icon, size: 16, color: _kGold),
                const SizedBox(width: 8),
                Text(title.toUpperCase(), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white54, letterSpacing: 1)),
              ],
            ),
          ),
          ...children,
        ],
      ),
    );
  }

  /// One tappable row that expands to reveal its own detailed breakdown —
  /// used for both a room and an ancillary item, since they share the
  /// same shape: a name, an optional badge or two, a short count, a
  /// total, and a hidden list of the numbers behind that total.
  Widget _buildExpandableRow({
    required String leading,
    String? badge1,
    String? badge2,
    required String subtitle,
    required double total,
    required List<Widget> children,
  }) {
    // Own Material behind the tile — see the note on the other expanding row above.
    return Material(
      type: MaterialType.transparency,
      child: Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        childrenPadding: const EdgeInsets.fromLTRB(28, 0, 16, 10),
        title: Row(
          children: [
            Flexible(child: Text(leading, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white))),
            if (badge1 != null) _buildBadge(badge1),
            if (badge2 != null) _buildBadge(badge2),
          ],
        ),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 11, color: Colors.white54)),
        trailing: Text(
          "₵ ${total.toStringAsFixed(2)}",
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: _kGold),
        ),
        children: children,
      ),
      ),
    );
  }

  Widget _buildBadge(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          border: Border.all(color: _kGold, width: 1),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(text, style: const TextStyle(fontSize: 9, color: _kGold, fontWeight: FontWeight.bold)),
      ),
    );
  }

  Widget _buildPackageDetailRow(String label, String calculation) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 12, color: Colors.white60)),
          Text(calculation, style: const TextStyle(fontSize: 12, color: Colors.white70)),
        ],
      ),
    );
  }
}
