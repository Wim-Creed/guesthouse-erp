import 'dart:async';
import 'package:flutter/material.dart';

// Links to the shared network service core tool
import '../../services/api_service.dart';
import '../../widgets/status_colors.dart';
import 'shift_bar.dart';

/// One room's current live state, as seen by the manager. This is a
/// simpler, read-only counterpart to the receptionist's room card: no
/// guest name, and no action buttons of any kind.
class ManagerRoomStatus {
  final String roomName;
  final String description;
  final String status;
  int? remainingSeconds;

  ManagerRoomStatus({
    required this.roomName,
    required this.description,
    required this.status,
    this.remainingSeconds,
  });

  factory ManagerRoomStatus.fromJson(Map<String, dynamic> json) {
    return ManagerRoomStatus(
      roomName: json['room_name'],
      description: json['description'] ?? "",
      status: json['status'],
      remainingSeconds: json['remaining_seconds'],
    );
  }
}

/// One cancelled booking, as shown in the live list on the manager's
/// screen: which room, which guest, who cancelled it and when.
class CancelledBookingRow {
  final String roomName;
  final String guestName;
  final String cancelledBy;
  final DateTime cancelledAtUtc;

  CancelledBookingRow({
    required this.roomName,
    required this.guestName,
    required this.cancelledBy,
    required this.cancelledAtUtc,
  });

  factory CancelledBookingRow.fromJson(Map<String, dynamic> json) {
    // The server sends naive UTC (the same as GMT in Ghana). Read it as UTC
    // explicitly so the time shown is the real GMT time, not shifted by
    // whatever zone the phone happens to be set to.
    final DateTime parsed = DateTime.parse(json['cancelled_at']);
    return CancelledBookingRow(
      roomName: json['room_name'] ?? "",
      guestName: json['guest_name'] ?? "Guest",
      cancelledBy: json['cancelled_by'] ?? "Unknown",
      cancelledAtUtc: DateTime.utc(parsed.year, parsed.month, parsed.day, parsed.hour, parsed.minute, parsed.second),
    );
  }
}

/// Compares two room names so that numbered rooms sort in true numeric
/// order (Room 1, Room 2, Room 10) instead of alphabetical order.
int _compareRoomNamesNaturally(String left, String right) {
  final leftNumber = RegExp(r'\d+').firstMatch(left);
  final rightNumber = RegExp(r'\d+').firstMatch(right);

  if (leftNumber != null && rightNumber != null) {
    final leftValue = int.parse(leftNumber.group(0)!);
    final rightValue = int.parse(rightNumber.group(0)!);
    if (leftValue != rightValue) return leftValue.compareTo(rightValue);
  }

  return left.compareTo(right);
}

/// The manager's Dashboard. The shift bar sits at the top, then a
/// simple, read-only overview of every room, grouped
/// by status, and grouped again within each status by matching room
/// descriptions. Includes a live summary strip of the day's operational
/// picture so far — bookings made, cancellations, and which specific
/// rooms are currently occupied — without waiting for the shift to close.
/// Detailed financial breakdowns stay in Business Summary; this is a
/// plain, at-a-glance operational view only.
class DashboardView extends StatefulWidget {
  final ApiService apiService;

  /// Passed on to the shift bar: called once a shift is confirmed closed.
  final VoidCallback? onShiftClosed;

  const DashboardView({super.key, required this.apiService, this.onShiftClosed});

  @override
  State<DashboardView> createState() => _DashboardViewState();
}

class _DashboardViewState extends State<DashboardView> {
  List<ManagerRoomStatus> _rooms = [];
  int _bookingsThisShift = 0;
  // Every booking cancelled since midnight today, whichever shift it fell
  // in. The server empties this list at midnight, so it needs no clearing here.
  List<CancelledBookingRow> _cancelledToday = [];
  bool _isLoading = true;
  String? _errorMessage;
  DateTime? _lastKnownGoodAt;
  bool _lastRefreshFailed = false;

  late Timer _serverSyncTimer;
  late Timer _localCountdownTimer;

  @override
  void initState() {
    super.initState();
    _fetchLiveOperationalSummary();
    _serverSyncTimer = Timer.periodic(const Duration(seconds: 15), (_) => _fetchLiveOperationalSummary());
    _localCountdownTimer = Timer.periodic(const Duration(seconds: 1), (_) => _tickCountdowns());
  }

  @override
  void dispose() {
    _serverSyncTimer.cancel();
    _localCountdownTimer.cancel();
    super.dispose();
  }

  Future<void> _fetchLiveOperationalSummary() async {
    try {
      final data = await widget.apiService.fetchLiveOperationalSummary();
      if (!mounted) return;
      final rawRooms = data['rooms'] as List<dynamic>;
      setState(() {
        _rooms = rawRooms.map((r) => ManagerRoomStatus.fromJson(r)).toList();
        _bookingsThisShift = data['bookings_this_shift'] ?? 0;
        _cancelledToday = ((data['cancelled_today'] as List<dynamic>?) ?? [])
            .map((row) => CancelledBookingRow.fromJson(Map<String, dynamic>.from(row)))
            .toList();
        _isLoading = false;
        _errorMessage = null;
        _lastKnownGoodAt = DateTime.now();
        _lastRefreshFailed = false;
      });
    } catch (e) {
      if (!mounted) return;
      // The server could not be reached this time. Keep showing whatever
      // was last known, with a "Last updated" time, instead of a plain
      // error — only show the error screen if nothing has loaded yet.
      setState(() {
        _isLoading = false;
        _lastRefreshFailed = true;
        if (_rooms.isEmpty) {
          _errorMessage = e.toString().replaceAll("Exception: ", "");
        }
      });
    }
  }

  String _formatLastUpdated(DateTime when) {
    final hour = when.hour.toString().padLeft(2, '0');
    final minute = when.minute.toString().padLeft(2, '0');
    return "Last updated $hour:$minute";
  }

  void _tickCountdowns() {
    if (!mounted) return;
    bool anyChanged = false;
    for (final room in _rooms) {
      if (room.status == "OCCUPIED" && room.remainingSeconds != null && room.remainingSeconds! > 0) {
        room.remainingSeconds = room.remainingSeconds! - 1;
        anyChanged = true;
      }
    }
    if (anyChanged) setState(() {});
  }

  String _formatCountdown(int totalSeconds) {
    final duration = Duration(seconds: totalSeconds);
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    if (hours > 0) return "${hours}h ${minutes}m left";
    return "${minutes}m left";
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading && _rooms.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xffd4af37)));
    }

    if (_rooms.isEmpty && _errorMessage != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              "Could not load room status: $_errorMessage",
              style: const TextStyle(color: Color(0xffe0584a), fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            TextButton(onPressed: _fetchLiveOperationalSummary, child: const Text("Try Again")),
          ],
        ),
      );
    }

    final available = _rooms.where((r) => r.status == "AVAILABLE").toList();
    final occupied = _rooms.where((r) => r.status == "OCCUPIED").toList()
      ..sort((a, b) => _compareRoomNamesNaturally(a.roomName, b.roomName));
    final timeUp = _rooms.where((r) => r.status == "TIME_UP").toList()
      ..sort((a, b) => _compareRoomNamesNaturally(a.roomName, b.roomName));
    final dirty = _rooms.where((r) => r.status == "DIRTY").toList();

    final Widget overview = RefreshIndicator(
      onRefresh: _fetchLiveOperationalSummary,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                "Dashboard",
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xffd4af37)),
              ),
              if (_lastRefreshFailed && _lastKnownGoodAt != null)
                Text(_formatLastUpdated(_lastKnownGoodAt!), style: const TextStyle(fontSize: 11, color: Colors.white54)),
            ],
          ),
          const SizedBox(height: 16),
          _buildOperationalSummaryCard(available.length, occupied, timeUp, dirty.length),
          const SizedBox(height: 24),
          _buildStatusGroup("Occupied", occupied, StatusColors.occupied, showCountdown: true),
          _buildStatusGroup("Time's Up", timeUp, StatusColors.timeUp, showCountdown: false),
          _buildStatusGroup("Available", available, StatusColors.available, showCountdown: false),
          _buildStatusGroup("Needs Cleaning", dirty, StatusColors.dirty, showCountdown: false),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ShiftBar(apiService: widget.apiService, onShiftClosed: widget.onShiftClosed),
        Expanded(child: overview),
      ],
    );
  }

  /// The main at-a-glance summary block: this shift's booking and
  /// cancellation counts, plus which specific rooms are occupied right
  /// now, all visible immediately without scrolling into the grouped
  /// lists below.
  Widget _buildOperationalSummaryCard(int availableCount, List<ManagerRoomStatus> occupied, List<ManagerRoomStatus> timeUp, int dirtyCount) {
    final timeUpRoomNames = timeUp.map((r) => r.roomName).join(", ");

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xff111f3a),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xffd4af37), width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Room-status counts, each colored to match the same status
          // colors used on the room grid itself, so amber always means
          // Time's Up, red always means Occupied, and so on — nothing
          // here borrows a color that means something else elsewhere.
          Row(
            children: [
              Expanded(child: _buildSummaryTile("Time's Up", timeUp.length, StatusColors.timeUp)),
              const SizedBox(width: 8),
              Expanded(child: _buildSummaryTile("Occupied", occupied.length, StatusColors.occupied)),
              const SizedBox(width: 8),
              Expanded(child: _buildSummaryTile("Available", availableCount, StatusColors.available)),
              const SizedBox(width: 8),
              Expanded(child: _buildSummaryTile("Dirty", dirtyCount, StatusColors.dirty)),
            ],
          ),
          const SizedBox(height: 12),
          // Shift totals, kept visually separate from the status tiles
          // above since these are running counts for the shift, not a
          // room's current state, so they never borrow the colors that
          // mean Occupied or Time's Up.
          Row(
            children: [
              Expanded(child: _buildShiftMetricTile("Booked This Shift", _bookingsThisShift)),
              const SizedBox(width: 8),
              Expanded(child: _buildShiftMetricTile("Cancelled Today", _cancelledToday.length)),
            ],
          ),
          // The cancellations themselves, as a list, so the manager sees
          // WHAT was cancelled and by whom, not just a count.
          if (_cancelledToday.isNotEmpty) ...[
            const SizedBox(height: 12),
            _buildCancelledList(),
          ],
          const SizedBox(height: 16),
          if (timeUp.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text(
              "Time's Up, Needs Checkout:",
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white70),
            ),
            const SizedBox(height: 4),
            Text(
              timeUpRoomNames,
              style: TextStyle(fontSize: 14, color: StatusColors.timeUp, fontWeight: FontWeight.w600),
            ),
          ],
        ],
      ),
    );
  }

  /// A room-status count, colored to match that status everywhere else in
  /// the app (Time's Up, Occupied, Available, Dirty).
  Widget _buildSummaryTile(String label, int count, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color, width: 1),
      ),
      child: Column(
        children: [
          Text("$count", style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: color)),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(fontSize: 13, color: Colors.white70), textAlign: TextAlign.center),
        ],
      ),
    );
  }

  /// A running total (not a room status). A soft black, so it sits in the
  /// navy and gold palette and can never be mistaken for one of the
  /// coloured status tiles above (grey is already the colour of a Dirty
  /// room, so it is not used here). Compact on purpose: it is a quiet
  /// figure, not a headline.
  Widget _buildShiftMetricTile(String label, int count) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
      decoration: BoxDecoration(
        color: StatusColors.softBlack,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white24, width: 0.8),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text("$count", style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
          const SizedBox(width: 8),
          Flexible(
            child: Text(label, style: const TextStyle(fontSize: 12, color: Colors.white70), overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }

  /// A short clock time with the GMT label, as every time shown to a
  /// person in this app is.
  String _formatGmtTime(DateTime utc) {
    final hour = utc.hour.toString().padLeft(2, '0');
    final minute = utc.minute.toString().padLeft(2, '0');
    return "$hour:$minute GMT";
  }

  /// Today's cancelled bookings, newest first: room, guest, who cancelled
  /// it, and when. It appears the moment a receptionist cancels (the
  /// screen refreshes itself every few seconds) and the server clears it
  /// at midnight. Drawn in the same coral red the Records tab uses for
  /// cancelled rows, so a cancellation looks the same everywhere.
  Widget _buildCancelledList() {
    const Color coral = Color(0xffe08a7a);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0x26c0392b),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xffc0392b), width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "CANCELLED TODAY (${_cancelledToday.length})",
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: coral, letterSpacing: 1),
          ),
          const SizedBox(height: 8),
          ..._cancelledToday.map(
            (row) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 72,
                    child: Text(row.roomName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                  ),
                  Expanded(
                    child: Text(
                      "${row.guestName}  ·  cancelled by ${row.cancelledBy}",
                      style: const TextStyle(fontSize: 13, color: Colors.white70),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(_formatGmtTime(row.cancelledAtUtc), style: const TextStyle(fontSize: 12, color: Colors.white54)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Builds one status section, further split into smaller groups of
  /// rooms that share the same description, so similar rooms sit
  /// together on screen. This is the detailed breakdown; the summary
  /// card above already surfaces the most operationally relevant parts
  /// of this at a glance.
  Widget _buildStatusGroup(String title, List<ManagerRoomStatus> rooms, Color color, {required bool showCountdown}) {
    if (rooms.isEmpty) return const SizedBox.shrink();

    final Map<String, List<ManagerRoomStatus>> groupedByDescription = {};
    for (final room in rooms) {
      final key = room.description.trim().isEmpty ? "Other Rooms" : room.description.trim();
      groupedByDescription.putIfAbsent(key, () => []).add(room);
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "${title.toUpperCase()} (${rooms.length})",
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: color, letterSpacing: 1),
          ),
          const SizedBox(height: 8),
          ...groupedByDescription.entries.map((entry) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.key, style: const TextStyle(fontSize: 12, color: Colors.white54, fontStyle: FontStyle.italic)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: entry.value.map((room) => _buildRoomChip(room, color, showCountdown)).toList(),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildRoomChip(ManagerRoomStatus room, Color color, bool showCountdown) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withAlpha(26),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(room.roomName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          if (showCountdown && room.remainingSeconds != null)
            Text(
              _formatCountdown(room.remainingSeconds!),
              style: const TextStyle(fontSize: 13, color: Colors.white70),
            ),
        ],
      ),
    );
  }
}
