import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Links to the shared network service core tool
import '../../services/alarm_player.dart';
import '../../services/api_service.dart';
import '../../services/room_alarm_watcher.dart';
import '../../widgets/status_colors.dart';
import '../../widgets/sms_helper.dart';
import '../splash_screen.dart' show IdleSplashGuard;
import 'intake_form_view.dart';
import 'extend_stay_view.dart';

/// How long after check-in a booking may still be cancelled, and also how
/// long after the newest extension that extension alone may be undone.
/// The server enforces the same 10 minutes as the final authority.
const Duration kCancellationWindow = Duration(minutes: 10);

/// How long before a room's time runs out the guest is automatically sent a
/// reminder text.
const Duration kWarningLeadTime = Duration(minutes: 30);

/// A reminder is only worth sending while at least this many minutes are
/// left. Below it the room is about to show Time's Up, and that message
/// follows straight away, so the reminder is skipped.
const int kMinimumReminderMinutes = 5;

/// The two automatic texts a room can raise. Only Time's Up also takes
/// over the screen and rings the alarm.
enum _RoomAlertKind { thirtyMinutes, timeUp }

/// Where an automatic text stands, as shown on the Time's Up screen.
enum _AutoSmsState { sending, sent, failed }

/// One alert: which room, which guest, and what kind. A reminder knows the
/// moment the room's time runs out, so the minutes left are worked out
/// afresh every time the text is built.
class _RoomAlert {
  final _RoomAlertKind kind;
  final String roomName;
  final String guestName;
  final String guestPhone;
  final DateTime? checkout;

  /// How the automatic text for this alert is getting on.
  final ValueNotifier<_AutoSmsState> smsState = ValueNotifier<_AutoSmsState>(_AutoSmsState.sending);

  _RoomAlert({
    required this.kind,
    required this.roomName,
    required this.guestName,
    required this.guestPhone,
    this.checkout,
  });

  /// Whole minutes left right now, counting any part of a minute as one,
  /// never below zero. Zero when the moment of checkout is not known.
  int get minutesLeftNow {
    if (checkout == null) return 0;
    final int seconds = checkout!.difference(DateTime.now().toUtc()).inSeconds;
    return seconds <= 0 ? 0 : (seconds / 60).ceil();
  }

  /// The text of the message as it would be sent at this moment.
  String get message => kind == _RoomAlertKind.timeUp
      ? buildTimeUpSms(guestName: guestName, roomName: roomName)
      : buildMinutesLeftSms(guestName: guestName, roomName: roomName, minutesLeft: minutesLeftNow);
}

/// Represents one room's current live state, as reported by the server.
///
/// The guest name, phone, booking ID, check-in time, and expected checkout
/// time are only meaningful while a room is Occupied or Time's Up.
/// status and remainingSeconds are both deliberately mutable: this lets
/// the screen reflect an action (checkout, mark clean) the instant it is
/// pressed, on this one local copy, rather than waiting on a round trip
/// to the server — the next periodic refresh then either confirms this
/// same value or corrects it, exactly as it already does for the
/// countdown.
class LiveRoomStatus {
  final String roomId;
  final String roomName;
  final String description;
  String status; // AVAILABLE, OCCUPIED, TIME_UP, DIRTY
  int? remainingSeconds; // Only meaningful while status is OCCUPIED
  final int? bookingId;
  final String? guestName;
  final String? guestPhone; // Shown under the guest's name for contacting them
  final DateTime? checkInTime;
  final DateTime? expectedCheckoutTime; // Displayed alongside the countdown while Occupied

  LiveRoomStatus({
    required this.roomId,
    required this.roomName,
    required this.description,
    required this.status,
    this.remainingSeconds,
    this.bookingId,
    this.guestName,
    this.guestPhone,
    this.checkInTime,
    this.expectedCheckoutTime,
  });

  factory LiveRoomStatus.fromJson(Map<String, dynamic> json) {
    return LiveRoomStatus(
      roomId: json['room_id'].toString(),
      roomName: json['room_name'],
      description: json['description'] ?? "",
      status: json['status'],
      remainingSeconds: json['remaining_seconds'],
      bookingId: json['booking_id'],
      guestName: json['guest_name'],
      guestPhone: json['guest_phone'],
      checkInTime: _parseServerUtcTimestamp(json['check_in_time']),
      expectedCheckoutTime: _parseServerUtcTimestamp(json['expected_checkout_time']),
    );
  }

  /// An independent copy of this room, so a list of rooms can be adjusted
  /// (see the replay of saved actions in the grid) without disturbing the
  /// untouched list the server last sent.
  LiveRoomStatus copy() => LiveRoomStatus(
        roomId: roomId,
        roomName: roomName,
        description: description,
        status: status,
        remainingSeconds: remainingSeconds,
        bookingId: bookingId,
        guestName: guestName,
        guestPhone: guestPhone,
        checkInTime: checkInTime,
        expectedCheckoutTime: expectedCheckoutTime,
      );

  /// The status actually shown on screen. A room ticks over to Time's Up
  /// the instant its own local countdown hits zero, rather than waiting
  /// for the next server refresh to say so — this is what lets the tablet
  /// run its own countdown correctly even while the server cannot be
  /// reached at all.
  String get effectiveStatus {
    if (status == "OCCUPIED" && remainingSeconds != null && remainingSeconds! <= 0) {
      return "TIME_UP";
    }
    return status;
  }

  /// Whether this booking still falls inside its own cancellation window.
  bool get isWithinCancellationWindow {
    if (checkInTime == null) return false;
    final elapsed = DateTime.now().toUtc().difference(checkInTime!);
    return elapsed <= kCancellationWindow;
  }

  /// How much time is left before the cancellation window closes.
  Duration get remainingCancellationTime {
    if (checkInTime == null) return Duration.zero;
    final elapsed = DateTime.now().toUtc().difference(checkInTime!);
    final remaining = kCancellationWindow - elapsed;
    return remaining.isNegative ? Duration.zero : remaining;
  }
}

/// The backend stores timestamps as naive UTC values, meaning the timezone
/// label is not included in what it sends. This reads the raw timestamp
/// text and treats it as UTC explicitly, rather than letting Dart assume
/// it is already in the device's local time.
DateTime? _parseServerUtcTimestamp(String? rawValue) {
  if (rawValue == null) return null;
  final parsed = DateTime.parse(rawValue);
  return DateTime.utc(
    parsed.year,
    parsed.month,
    parsed.day,
    parsed.hour,
    parsed.minute,
    parsed.second,
    parsed.millisecond,
  );
}

/// Shows every room grouped by its current state, and grouped again
/// within each state by matching room descriptions, with a live countdown
/// for occupied rooms. Tapping an available room starts a new booking for
/// that specific room.
///
/// Works fully on its own when the server cannot be reached: booking,
/// extending, cancelling, checking out and cleaning all update this
/// screen immediately, the room's own countdown keeps running locally,
/// and the underlying action is saved to sync automatically once the
/// connection returns. Checkout, Mark Available, and Cancel each lock
/// their own room's button the instant they are pressed, so repeated
/// tapping while waiting can never queue the same action twice.
class RoomMatrixGrid extends StatefulWidget {
  final ApiService apiService;

  const RoomMatrixGrid({super.key, required this.apiService});

  @override
  State<RoomMatrixGrid> createState() => _RoomMatrixGridState();
}

class _RoomMatrixGridState extends State<RoomMatrixGrid> {
  // What is shown on screen: the server's last list with every action this
  // tablet has taken but the server has not confirmed yet laid on top of it.
  List<LiveRoomStatus> _rooms = [];

  // The server's last list exactly as it arrived (or, if the app was
  // opened with the server down, the copy saved on this tablet). The saved
  // actions are always replayed on a fresh copy of THIS list, never on the
  // list already on screen, so repeating the replay every few seconds can
  // never apply the same action twice.
  List<LiveRoomStatus> _serverRooms = [];
  bool _isLoading = true;
  String? _errorMessage;
  DateTime? _lastKnownGoodAt;
  // Only true right after a refresh attempt has actually failed to reach
  // the server — "Last updated" is shown only then, never on a normal
  // successful load.
  bool _lastRefreshFailed = false;

  // A room name currently in this set has an action (Checkout, Mark
  // Available, or Cancel) waiting on the server; its button is disabled
  // and shows a small spinner instead of its label until that resolves,
  // so repeated tapping can never queue the same action twice.
  final Set<String> _pendingRooms = {};

  // Refreshes from the server periodically to stay accurate and catch
  // status changes (for example, another tablet checking a room out).
  late Timer _serverSyncTimer;

  // Ticks once a second so the on-screen countdown, and the cancellation
  // window, feel live between server refreshes, without needing to ask
  // the server every second.
  late Timer _localCountdownTimer;

  // Toggles on and off every half second to drive the flashing highlight
  // on rooms whose time has run out.
  bool _flashOn = false;
  late Timer _flashTimer;

  // The prompts already raised, as room + checkout time + kind. Saved on
  // the tablet so a prompt that was already shown is not shown again after
  // the app restarts, and an extension (which moves the checkout time)
  // starts a fresh pair of prompts.
  static const String _handledAlertsStorageKey = "room_alerts_handled";
  final Set<String> _handledAlertKeys = {};
  bool _handledAlertsLoaded = false;
  final List<_RoomAlert> _alertQueue = [];
  bool _isAlertShowing = false;

  @override
  void initState() {
    super.initState();
    _loadHandledAlerts();
    _fetchLiveRoomStatus();
    _serverSyncTimer = Timer.periodic(const Duration(seconds: 15), (_) => _fetchLiveRoomStatus());
    _localCountdownTimer = Timer.periodic(const Duration(seconds: 1), (_) => _tickCountdowns());
    _flashTimer = Timer.periodic(const Duration(milliseconds: 600), (_) {
      if (mounted) setState(() => _flashOn = !_flashOn);
    });
  }

  @override
  void dispose() {
    _serverSyncTimer.cancel();
    _localCountdownTimer.cancel();
    _flashTimer.cancel();
    RoomAlarmWatcher.instance.gridIsPlaying(false);
    AlarmPlayer.instance.stop();
    IdleSplashGuard.alertOnScreen = false;
    super.dispose();
  }

  // ---------------------------------------------------------------------
  // Automatic texts 30 minutes before time is up and at time's up; the
  // full-screen alarm comes only at time's up
  // ---------------------------------------------------------------------

  Future<void> _loadHandledAlerts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _handledAlertKeys.addAll(prefs.getStringList(_handledAlertsStorageKey) ?? const []);
    } catch (_) {}
    _handledAlertsLoaded = true;
  }

  Future<void> _saveHandledAlerts() async {
    try {
      // Only prompts for rooms still occupied are worth remembering; the
      // rest are dropped so the saved list never grows without limit.
      final Set<String> occupiedRoomNames = _rooms
          .where((r) => r.status == "OCCUPIED" || r.status == "TIME_UP")
          .map((r) => r.roomName)
          .toSet();
      _handledAlertKeys.removeWhere((key) => !occupiedRoomNames.contains(key.split('|').first));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_handledAlertsStorageKey, _handledAlertKeys.toList());
    } catch (_) {}
  }

  String _alertKey(LiveRoomStatus room, _RoomAlertKind kind) {
    final String checkout = room.expectedCheckoutTime?.toIso8601String() ?? "${room.bookingId ?? room.guestName}";
    return "${room.roomName}|$checkout|${kind.name}";
  }

  /// Looks at every occupied room and queues a prompt for each one that has
  /// just come within 30 minutes of its end, or has just run out of time.
  void _collectAlerts() {
    if (!_handledAlertsLoaded) return;
    bool anythingNew = false;

    for (final room in _rooms) {
      if (room.status != "OCCUPIED" && room.status != "TIME_UP") continue;
      if (room.remainingSeconds == null && room.status != "TIME_UP") continue;

      final bool isTimeUp = room.effectiveStatus == "TIME_UP";
      final bool isWithinWarning = !isTimeUp && room.remainingSeconds! <= kWarningLeadTime.inSeconds;
      if (!isTimeUp && !isWithinWarning) continue;

      // Under five minutes left the reminder is pointless: Time's Up
      // follows at once. It is marked as handled and never sent.
      final bool tooLateForReminder = !isTimeUp && room.remainingSeconds! < kMinimumReminderMinutes * 60;

      final String warningKey = _alertKey(room, _RoomAlertKind.thirtyMinutes);
      final String timeUpKey = _alertKey(room, _RoomAlertKind.timeUp);

      if (isTimeUp) {
        // A room found already past its time (the app was closed) skips the
        // 30-minute text, which would be out of date.
        if (_handledAlertKeys.add(warningKey)) anythingNew = true;
        if (_handledAlertKeys.add(timeUpKey)) {
          anythingNew = true;
          _queueTimeUpAlert(room);
        }
      } else if (_handledAlertKeys.add(warningKey)) {
        anythingNew = true;
        if (!tooLateForReminder) _sendReminderAutomatically(room);
      }
    }

    if (anythingNew) {
      _saveHandledAlerts();
      _showNextAlert();
    }
  }

  _RoomAlert _alertFor(LiveRoomStatus room, _RoomAlertKind kind) {
    return _RoomAlert(
      kind: kind,
      roomName: room.roomName,
      guestName: room.guestName ?? "Guest",
      guestPhone: room.guestPhone ?? "",
      checkout: room.expectedCheckoutTime,
    );
  }

  /// Sends the 30-minute reminder text by itself: quietly, with retries, and
  /// with a warning only if it keeps failing. No screen, no sound. A text the
  /// tablet already sent while it was logged out is not sent again.
  void _sendReminderAutomatically(LiveRoomStatus room) {
    final _RoomAlert alert = _alertFor(room, _RoomAlertKind.thirtyMinutes);
    if (alert.guestPhone.trim().isEmpty || alert.checkout == null) return;

    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final NavigatorState navigator = Navigator.of(context, rootNavigator: true);
    () async {
      final bool? sent = await RoomAlarmWatcher.instance.sendRoomTextOnce(
        roomName: alert.roomName,
        checkout: alert.checkout!,
        kind: "thirtyMinutes",
        guestName: alert.guestName,
        guestPhone: alert.guestPhone,
      );
      if (sent == false) {
        showAutomaticSendFailedWarning(
          navigator: navigator,
          messenger: messenger,
          what: "The reminder text to ${alert.guestName} (${alert.roomName})",
          phoneNumber: alert.guestPhone,
          messageBuilder: () => alert.message,
        );
      }
    }();
  }

  /// Queues the Time's Up screen and starts its text straight away, so a
  /// text is never held back behind another room's alarm that is still on
  /// screen. A text the tablet already sent while it was logged out is not
  /// sent again; the screen simply shows it as sent.
  void _queueTimeUpAlert(LiveRoomStatus room) {
    final _RoomAlert alert = _alertFor(room, _RoomAlertKind.timeUp);
    _alertQueue.add(alert);

    if (alert.guestPhone.trim().isEmpty || alert.checkout == null) {
      alert.smsState.value = _AutoSmsState.failed;
      return;
    }
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final NavigatorState navigator = Navigator.of(context, rootNavigator: true);
    () async {
      final bool? sent = await RoomAlarmWatcher.instance.sendRoomTextOnce(
        roomName: alert.roomName,
        checkout: alert.checkout!,
        kind: "timeUp",
        guestName: alert.guestName,
        guestPhone: alert.guestPhone,
      );
      alert.smsState.value = sent == true ? _AutoSmsState.sent : _AutoSmsState.failed;
      if (sent == false) {
        showAutomaticSendFailedWarning(
          navigator: navigator,
          messenger: messenger,
          what: "The Time's Up text to ${alert.guestName} (${alert.roomName})",
          phoneNumber: alert.guestPhone,
          messageBuilder: () => alert.message,
        );
      }
    }();
  }

  /// The Time's Up alarm rings until the screen is answered.
  void _playAlarm() {
    RoomAlarmWatcher.instance.gridIsPlaying(true);
    AlarmPlayer.instance.startLoopingAlarm();
  }

  void _stopAlarm() {
    RoomAlarmWatcher.instance.gridIsPlaying(false);
    AlarmPlayer.instance.stop();
  }

  /// Shows the next waiting Time's Up screen over everything on the tablet,
  /// one at a time. The idle screen is lifted first so it can never hide it.
  Future<void> _showNextAlert() async {
    if (_isAlertShowing || _alertQueue.isEmpty || !mounted) return;
    _isAlertShowing = true;
    final _RoomAlert alert = _alertQueue.removeAt(0);

    IdleSplashGuard.alertOnScreen = true;
    IdleSplashGuard.uncover();
    _playAlarm();

    final bool? wantsToSend = await showGeneralDialog<bool>(
      context: context,
      useRootNavigator: true,
      barrierDismissible: false,
      barrierLabel: "Room alert",
      barrierColor: Colors.black87,
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (dialogContext, _, __) => _RoomAlertScreen(alert: alert),
    );

    _stopAlarm();

    // Only reached when the automatic text failed and the receptionist chose
    // to send it by hand; the sending box shows the reason and Try Again.
    if (wantsToSend == true && mounted) {
      await sendGuestMessageWithRetry(
        navigator: Navigator.of(context, rootNavigator: true),
        messenger: ScaffoldMessenger.of(context),
        phoneNumber: alert.guestPhone,
        message: alert.message,
        successText: "Message sent to ${alert.guestName} (${alert.roomName}).",
      );
    }

    _isAlertShowing = false;
    if (_alertQueue.isEmpty) IdleSplashGuard.alertOnScreen = false;
    _showNextAlert();
  }

  /// Pulls the real, current state of every room from the server. If the
  /// server cannot be reached, the screen keeps showing whatever it last
  /// knew, with a "Last updated" time, instead of a plain error — the
  /// tablet's own countdown keeps the picture close to correct in the
  /// meantime.
  Future<void> _fetchLiveRoomStatus() async {
    try {
      final rawRooms = await widget.apiService.fetchLiveRoomStatus();
      if (!mounted) return;
      _serverRooms = rawRooms.map((r) => LiveRoomStatus.fromJson(r)).toList();
      final shown = await _replaySavedActions(_serverRooms);
      if (!mounted) return;
      _shareRoomsWithAlarmWatcher(shown);
      setState(() {
        _rooms = shown;
        _isLoading = false;
        _errorMessage = null;
        _lastKnownGoodAt = DateTime.now();
        _lastRefreshFailed = false;
      });
    } catch (e) {
      if (!mounted) return;

      // The server cannot be reached. Nothing on this screen depends on it:
      // the rooms are rebuilt from the last list the server sent (or, if
      // the app was only just opened, the copy saved on this tablet) with
      // every saved action laid on top, and the countdowns keep running.
      if (_serverRooms.isEmpty) {
        final cached = await widget.apiService.loadCachedRoomStatus();
        if (cached != null) _serverRooms = cached.map((r) => LiveRoomStatus.fromJson(r)).toList();
      }
      final shown = _serverRooms.isEmpty ? <LiveRoomStatus>[] : await _replaySavedActions(_serverRooms);
      if (!mounted) return;

      if (_serverRooms.isNotEmpty) _shareRoomsWithAlarmWatcher(shown);
      setState(() {
        if (_serverRooms.isNotEmpty) _rooms = shown;
        // Only treat this as a hard error if nothing has ever loaded yet.
        // Once the screen has real data, a failed refresh just means
        // "Last updated" appears alongside the room grid — it never
        // replaces the grid with an error message.
        if (_rooms.isEmpty) {
          _errorMessage = e.toString().replaceAll("Exception: ", "");
        }
        _isLoading = false;
        _lastRefreshFailed = true;
      });
    }
  }

  /// THE TABLET RUNS THE ROOMS BY ITSELF.
  /// Takes a list of rooms as the server last described them and lays on
  /// top of it, in the order they were made, every action this tablet has
  /// taken that the server has not confirmed yet:
  ///   booking   -> the room becomes Occupied, with the guest's name, phone
  ///                and a countdown worked out here;
  ///   extension -> the checkout time moves on (from the old checkout time,
  ///                or from the moment of the extension if the time was
  ///                already up — the same rule the server uses);
  ///   cancel    -> undoes the newest extension if there is one waiting,
  ///                otherwise the booking is cancelled and the room is
  ///                Dirty, as the server does;
  ///   checkout  -> Dirty;      clean -> Available.
  /// The result is what the receptionist sees, whether the server is down
  /// or just has not yet received the action. Returns a new list; the one
  /// passed in is left untouched. The server remains the final authority:
  /// when the saved actions reach it, its answer replaces all of this.
  Future<List<LiveRoomStatus>> _replaySavedActions(List<LiveRoomStatus> serverRooms) async {
    final DateTime now = DateTime.now().toUtc();
    final List<LiveRoomStatus> rooms = serverRooms.map((r) => r.copy()).toList();

    // A copy taken some time ago has countdowns that have since moved on:
    // work them out again from each room's own checkout time.
    for (final room in rooms) {
      if (room.status == "OCCUPIED" && room.expectedCheckoutTime != null) {
        final int left = room.expectedCheckoutTime!.difference(now).inSeconds;
        room.remainingSeconds = left < 0 ? 0 : left;
      }
    }

    final events = await widget.apiService.pendingRoomEvents();
    if (events.isEmpty) return rooms;

    // For each room, the checkout times from before each saved extension,
    // so that a saved cancel can undo the newest one.
    final Map<String, List<DateTime>> extensionHistory = {};

    for (final event in events) {
      final int index = rooms.indexWhere((r) => r.roomName == event.roomName);
      if (index == -1) continue;
      final LiveRoomStatus room = rooms[index];

      LiveRoomStatus withCheckout(DateTime checkout) {
        final int left = checkout.difference(now).inSeconds;
        return LiveRoomStatus(
          roomId: room.roomId,
          roomName: room.roomName,
          description: room.description,
          status: "OCCUPIED",
          remainingSeconds: left < 0 ? 0 : left,
          bookingId: room.bookingId,
          guestName: room.guestName,
          guestPhone: room.guestPhone,
          checkInTime: room.checkInTime,
          expectedCheckoutTime: checkout,
        );
      }

      LiveRoomStatus withStatus(String status) => LiveRoomStatus(
            roomId: room.roomId,
            roomName: room.roomName,
            description: room.description,
            status: status,
          );

      switch (event.kind) {
        case "BOOKING":
          if (room.status != "AVAILABLE") break; // the server already has it
          final DateTime checkout = event.atUtc.add(Duration(hours: event.hours ?? 0));
          final int left = checkout.difference(now).inSeconds;
          rooms[index] = LiveRoomStatus(
            roomId: room.roomId,
            roomName: room.roomName,
            description: room.description,
            status: "OCCUPIED",
            remainingSeconds: left < 0 ? 0 : left,
            // No booking number yet: the server gives it one on arrival.
            bookingId: null,
            guestName: event.guestName,
            guestPhone: event.guestPhone,
            checkInTime: event.atUtc,
            expectedCheckoutTime: checkout,
          );
          extensionHistory[room.roomName] = [];
          break;

        case "EXTEND":
          if (room.status != "OCCUPIED") break;
          final DateTime before = room.expectedCheckoutTime ?? now;
          final DateTime base = before.isAfter(event.atUtc) ? before : event.atUtc;
          extensionHistory.putIfAbsent(room.roomName, () => []).add(before);
          rooms[index] = withCheckout(base.add(Duration(hours: event.hours ?? 0)));
          break;

        case "CANCEL":
          final history = extensionHistory[room.roomName];
          if (history != null && history.isNotEmpty) {
            rooms[index] = withCheckout(history.removeLast());
          } else if (room.status == "OCCUPIED") {
            rooms[index] = withStatus("DIRTY");
          }
          break;

        case "CHECKOUT":
          if (room.status == "OCCUPIED") rooms[index] = withStatus("DIRTY");
          break;

        case "CLEAN":
          if (room.status == "DIRTY") rooms[index] = withStatus("AVAILABLE");
          break;
      }
    }
    return rooms;
  }

  /// Gives the alarm watcher the moment each occupied room runs out, so the
  /// Time's Up alarm still sounds if the tablet is logged out.
  void _shareRoomsWithAlarmWatcher(List<LiveRoomStatus> rooms) {
    RoomAlarmWatcher.instance.rememberRooms(
      rooms.map((r) => (
            roomName: r.roomName,
            checkout: r.expectedCheckoutTime,
            isOccupied: r.status == "OCCUPIED" || r.status == "TIME_UP",
            guestName: r.guestName ?? "Guest",
            guestPhone: r.guestPhone ?? "",
          )),
    );
  }

  void _tickCountdowns() {
    if (!mounted) return;
    for (final room in _rooms) {
      if (room.status == "OCCUPIED" && room.remainingSeconds != null && room.remainingSeconds! > 0) {
        room.remainingSeconds = room.remainingSeconds! - 1;
      }
    }
    setState(() {});
    _collectAlerts();
  }

  String _formatCountdown(int totalSeconds) {
    final duration = Duration(seconds: totalSeconds);
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return "${hours}h ${minutes}m";
    }
    return "${minutes}m ${seconds.toString().padLeft(2, '0')}s";
  }

  String _formatCancellationCountdown(Duration remaining) {
    final minutes = remaining.inMinutes;
    final seconds = remaining.inSeconds.remainder(60);
    return "${minutes}m ${seconds.toString().padLeft(2, '0')}s left";
  }

  /// A short clock time for the card — deliberately just "HH:MM" with no
  /// date. A booking's checkout deadline is always within the same day or
  /// the next morning, so the room's own status (Occupied vs Time's Up)
  /// already carries whichever context a date would otherwise add; adding
  /// one here would only make an already-compact card busier to read.
  /// The server sends this as naive UTC, which is the same as GMT/Ghana
  /// local time with no adjustment needed.
  String _formatCheckoutTime(DateTime expectedCheckoutTime) {
    final hour = expectedCheckoutTime.hour.toString().padLeft(2, '0');
    final minute = expectedCheckoutTime.minute.toString().padLeft(2, '0');
    return "$hour:$minute";
  }

  String _formatLastUpdated(DateTime when) {
    final hour = when.hour.toString().padLeft(2, '0');
    final minute = when.minute.toString().padLeft(2, '0');
    return "Last updated $hour:$minute";
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xffd4af37)));
    }

    if (_errorMessage != null) {
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
            TextButton(onPressed: _fetchLiveRoomStatus, child: const Text("Try Again")),
          ],
        ),
      );
    }

    final available = _rooms.where((r) => r.effectiveStatus == "AVAILABLE").toList();
    final timeUp = _rooms.where((r) => r.effectiveStatus == "TIME_UP").toList();
    final occupied = _rooms.where((r) => r.effectiveStatus == "OCCUPIED").toList();
    final dirty = _rooms.where((r) => r.effectiveStatus == "DIRTY").toList();

    return RefreshIndicator(
      onRefresh: _fetchLiveRoomStatus,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                "Rooms",
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xffd4af37)),
              ),
              Row(
                children: [
                  if (_lastRefreshFailed && _lastKnownGoodAt != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Text(
                        "${_formatLastUpdated(_lastKnownGoodAt!)} · pull down to refresh",
                        style: const TextStyle(fontSize: 11, color: Colors.white54),
                      ),
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Ordered by how urgently staff need to see it: rooms needing
          // checkout or cleaning first, since those need action; available
          // rooms next, since they're checked often for new guests;
          // occupied rooms last, since they need no attention right now.
          _buildSection("Time's Up", timeUp, StatusColors.timeUp),
          _buildSection("Needs Cleaning", dirty, StatusColors.dirty),
          _buildSection("Available", available, StatusColors.available),
          _buildSection("Occupied", occupied, StatusColors.occupied),
        ],
      ),
    );
  }

  Widget _buildSection(String title, List<LiveRoomStatus> rooms, Color color) {
    if (rooms.isEmpty) return const SizedBox.shrink();

    // Grouped again within the status by matching room descriptions, the
    // same as the manager's own read-only overview already does, so
    // similar rooms sit together on screen instead of being jumbled
    // together with no grouping.
    final Map<String, List<LiveRoomStatus>> groupedByDescription = {};
    for (final room in rooms) {
      final key = room.description.trim().isEmpty ? "Other Rooms" : room.description.trim();
      groupedByDescription.putIfAbsent(key, () => []).add(room);
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The state, a dash, and how many rooms are in it, so the
          // receptionist never has to count rooms: "OCCUPIED — 4 ROOMS".
          Text(
            "${title.toUpperCase()} — ${rooms.length} ${rooms.length == 1 ? 'ROOM' : 'ROOMS'}",
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: color, letterSpacing: 1),
          ),
          const SizedBox(height: 8),
          ...groupedByDescription.entries.map((entry) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.key, style: const TextStyle(fontSize: 12, color: Colors.white54, fontStyle: FontStyle.italic)),
                  const SizedBox(height: 6),
                  // COMPACT ROOM CARDS.
                  // Four cards sit to a row, never narrower than a width at
                  // which the text and buttons still fit.
                  LayoutBuilder(
                    builder: (context, constraints) {
                      const double gap = 10;
                      const double minimumCardWidth = 200; // below this the buttons would not fit
                      // A card is a quarter of the area of a two-to-a-row
                      // card: half its width and half its height.
                      final double twoPerRowWidth = (constraints.maxWidth - gap) / 2;
                      final double cardWidth = twoPerRowWidth / 2;
                      // How many cards fit in a row, rounded to the nearest
                      // whole number so each comes out at (very nearly)
                      // exactly that width.
                      int columns = ((constraints.maxWidth + gap) / (cardWidth + gap)).round().clamp(1, 12);
                      // On a narrow screen, drop a column rather than let a
                      // card get too small to hold its text and buttons.
                      while (columns > 1 && (constraints.maxWidth - gap * (columns - 1)) / columns < minimumCardWidth) {
                        columns--;
                      }
                      return GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          crossAxisSpacing: gap,
                          mainAxisSpacing: gap,
                          childAspectRatio: 1.2,
                        ),
                        itemCount: entry.value.length,
                        itemBuilder: (context, index) => _buildRoomCard(entry.value[index], color),
                      );
                    },
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildRoomCard(LiveRoomStatus room, Color outlineColor) {
    // Enforces bright text across both light and dark backgrounds for maximum contrast
    const Color baseTextColor = Colors.white;
    final String effectiveStatus = room.effectiveStatus;

    // Determines if the room requires an active visual alert based on its status
    final bool isFlashingAlert = effectiveStatus == "TIME_UP";
    final Color activeOutline = isFlashingAlert && _flashOn
        ? Color.lerp(outlineColor, Colors.white, 0.25)!
        : outlineColor;

    // The coloured accent stripe on the left edge is drawn as its own narrow
    // strip inside the card, rather than as a thicker left side on the card's
    // border. Flutter cannot paint a rounded card whose four border sides
    // differ in width or colour: in a debug run it throws an error part-way
    // through drawing the card, which left the card's background and shadow
    // visible but stopped every piece of text and every button inside it
    // from being drawn (they still reacted to hover and taps). The border is
    // now one uniform outline all the way round, which paints correctly.
    return Container(
      decoration: BoxDecoration(
        color: outlineColor.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: activeOutline.withAlpha(60), width: 1),
        boxShadow: [
          BoxShadow(color: activeOutline.withAlpha(35), blurRadius: 10, offset: const Offset(0, 3)),
        ],
      ),
      // Clips the accent stripe so it follows the card's rounded corners.
      child: ClipRRect(
        borderRadius: BorderRadius.circular(7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 4, color: activeOutline),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Header section displaying the room identity and its current status badge
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          room.roomName,
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: 0.3, color: baseTextColor),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            border: Border.all(color: activeOutline, width: 1),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            effectiveStatus.replaceAll("_", " "),
                            style: TextStyle(fontSize: 9, color: activeOutline, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),

                    // Primary guest information displayed for active or expired bookings
                    if ((effectiveStatus == "OCCUPIED" || effectiveStatus == "TIME_UP") && room.guestName != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          room.guestName!,
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: baseTextColor),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),

                    // Guest phone number, so the receptionist can contact
                    // them without having to look the booking up elsewhere.
                    if ((effectiveStatus == "OCCUPIED" || effectiveStatus == "TIME_UP") && room.guestPhone != null)
                      _buildIconLine(Icons.phone, room.guestPhone!, baseTextColor),

                    // Time tracking rows showing remaining duration and final checkout deadline
                    if (effectiveStatus == "OCCUPIED" && room.remainingSeconds != null)
                      _buildIconLine(Icons.schedule, _formatCountdown(room.remainingSeconds!), baseTextColor),
                    if ((effectiveStatus == "OCCUPIED" || effectiveStatus == "TIME_UP") && room.expectedCheckoutTime != null)
                      _buildIconLine(Icons.logout, "Out by ${_formatCheckoutTime(room.expectedCheckoutTime!)}", baseTextColor),

                    // Action tray providing standard operation options based on room availability
                    _buildActionsForRoom(room, baseTextColor),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Builds a standardized data line containing a leading icon and secondary descriptor text
  Widget _buildIconLine(IconData icon, String text, Color color) {
    return Padding(
      padding: const EdgeInsets.only(top: 1),
      child: Row(
        children: [
          Icon(icon, size: 11, color: color.withValues(alpha: 0.7)),
          const SizedBox(width: 4),
          Text(text, style: TextStyle(fontSize: 11, color: color.withValues(alpha: 0.85))),
        ],
      ),
    );
  }

  /// Evaluates room criteria to render context-aware interactive buttons.
  /// Every action button here is locked the instant it is pressed (see
  /// _pendingRooms) so repeated tapping while waiting on the server can
  /// never queue the same action twice.
  Widget _buildActionsForRoom(LiveRoomStatus room, Color buttonTextColor) {
    final bool isPending = _pendingRooms.contains(room.roomName);

    switch (room.effectiveStatus) {
      case "AVAILABLE":
        return TextButton.icon(
          onPressed: () => _openBookingFormForRoom(room.roomName),
          icon: Icon(Icons.add_circle, color: StatusColors.available, size: 18),
          label: Text("Assign Guest", style: TextStyle(color: StatusColors.available, fontSize: 12, fontWeight: FontWeight.w600)),
        );

      case "OCCUPIED":
        final bool canCancel = room.isWithinCancellationWindow;
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            if (canCancel)
              TextButton(
                onPressed: isPending ? null : () => _handleCancelBooking(room),
                child: isPending
                    ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(
                        "Cancel (${_formatCancellationCountdown(room.remainingCancellationTime)})",
                        style: TextStyle(color: buttonTextColor.withValues(alpha: 0.85), fontSize: 11, fontWeight: FontWeight.w600),
                      ),
              )
            else
              const SizedBox.shrink(),
            TextButton(
              onPressed: () => _openExtendStayForRoom(room),
              child: Text("Extend", style: TextStyle(color: buttonTextColor.withValues(alpha: 0.85), fontSize: 11, fontWeight: FontWeight.w600)),
            ),
          ],
        );

      case "TIME_UP":
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            ElevatedButton(
             style: ElevatedButton.styleFrom(
              backgroundColor: StatusColors.timeUp,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              minimumSize: Size.zero,
             ),
              onPressed: isPending ? null : () => _handleCheckout(room),
              child: isPending
                  ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text("Checkout", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
            ),
            TextButton(
              onPressed: () => _openExtendStayForRoom(room),
              child: Text("Extend", style: TextStyle(color: buttonTextColor.withValues(alpha: 0.85), fontSize: 11, fontWeight: FontWeight.w600)),
            ),
          ],
        );

      case "DIRTY":
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: StatusColors.dirty,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                minimumSize: Size.zero,
              ),
              icon: isPending
                  ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.cleaning_services, size: 15),
              label: const Text("Mark Available", style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
              onPressed: isPending ? null : () => _handleCleanRoom(room),
            ),
          ],
        );

      default:
        return const SizedBox.shrink();
    }
  }

  /// Opens the booking form already set to this specific room, so the
  /// receptionist never has to pick the room twice.
  Future<void> _openBookingFormForRoom(String roomName) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => IntakeFormView(apiService: widget.apiService, roomName: roomName),
      ),
    );
    // Refresh as soon as the receptionist returns, in case a booking was made.
    _fetchLiveRoomStatus();
  }

  /// Opens the extend-stay form, pre-filled with this booking's guest and
  /// room, so the receptionist only has to enter the additional time and
  /// payment for the extension itself.
  Future<void> _openExtendStayForRoom(LiveRoomStatus room) async {
    // A booking made while the server was down has no number yet
    // (room.bookingId is null). That is fine: it is extended by its room.
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ExtendStayView(
          apiService: widget.apiService,
          bookingId: room.bookingId,
          roomName: room.roomName,
          guestName: room.guestName ?? "Guest",
          guestPhone: room.guestPhone ?? "",
          currentCheckout: room.expectedCheckoutTime,
        ),
      ),
    );
    _fetchLiveRoomStatus();
  }

  /// Asks the receptionist to confirm before cancelling, since this is
  /// mostly a one-way action within a short time window. The dialog's own
  /// wording stays neutral ("Cancel") because only the server knows for
  /// certain, at the moment this is pressed, whether this will undo the
  /// booking's newest extension instead of the booking itself — the
  /// confirmation shown afterward always says which one actually happened.
  Future<void> _handleCancelBooking(LiveRoomStatus room) async {
    final bool confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text("Cancel"),
            content: Text(
              "Undo the most recent action on ${room.roomName} (${room.guestName ?? 'this guest'})? "
              "If an extension was just added, only the extension is undone and the booking stays. "
              "Otherwise the booking itself is cancelled. This will be kept on record.",
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("Go Back")),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: StatusColors.occupied),
                onPressed: () => Navigator.pop(context, true),
                child: const Text("Yes, Cancel"),
              ),
            ],
          ),
        ) ??
        false;

    if (!confirmed || _pendingRooms.contains(room.roomName)) return;
    setState(() => _pendingRooms.add(room.roomName));

    try {
      // A null booking number (a booking made while the server was down) is
      // fine: it is cancelled by its room.
      final result = await widget.apiService.cancelBooking(bookingId: room.bookingId, roomName: room.roomName);
      if (mounted) {
        final bool wasQueuedOffline = result['queued_offline'] == true;
        String message;
        if (wasQueuedOffline) {
          message = "Saved. Pending, will be sent when the connection returns.";
        } else if (result['action_taken'] == "EXTENSION_CANCELLED") {
          message = "Extension cancelled. Checkout time restored.";
        } else {
          message = "Booking cancelled. ${room.roomName} now needs cleaning.";
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: wasQueuedOffline ? const Color(0xffc9971f) : const Color(0xff14703f),
            content: Text(message),
          ),
        );
      }
      _fetchLiveRoomStatus();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Cancellation failed: ${e.toString().replaceAll("Exception: ", "")}")),
        );
      }
    } finally {
      if (mounted) setState(() => _pendingRooms.remove(room.roomName));
    }
  }

  Future<void> _handleCheckout(LiveRoomStatus room) async {
    if (_pendingRooms.contains(room.roomName)) return;

    // Reflected on screen the instant this is pressed — the room turns
    // Dirty right away on this device, regardless of whether the server
    // can be reached at this exact moment. A genuine rejection (not a
    // connectivity failure — those are queued and treated as success,
    // see ApiService) reverts this back below.
    final String previousStatus = room.status;
    setState(() {
      _pendingRooms.add(room.roomName);
      room.status = "DIRTY";
      room.remainingSeconds = null;
    });

    try {
      final result = await widget.apiService.checkoutRoom(room.roomName);
      if (mounted) {
        final bool wasQueuedOffline = result['queued_offline'] == true;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(wasQueuedOffline
                ? "Saved. Pending, will be sent when the connection returns."
                : "${room.roomName} checked out. Needs cleaning."),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => room.status = previousStatus);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Checkout failed: ${e.toString().replaceAll("Exception: ", "")}")),
        );
      }
    } finally {
      if (mounted) setState(() => _pendingRooms.remove(room.roomName));
      _fetchLiveRoomStatus();
    }
  }

  Future<void> _handleCleanRoom(LiveRoomStatus room) async {
    if (_pendingRooms.contains(room.roomName)) return;

    // Same immediate, optimistic reflection as Checkout above.
    final String previousStatus = room.status;
    setState(() {
      _pendingRooms.add(room.roomName);
      room.status = "AVAILABLE";
    });

    try {
      final result = await widget.apiService.cleanRoom(room.roomName);
      if (mounted) {
        final bool wasQueuedOffline = result['queued_offline'] == true;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(wasQueuedOffline
                ? "Saved. Pending, will be sent when the connection returns."
                : "${room.roomName} is now available."),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => room.status = previousStatus);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Could not mark room clean: ${e.toString().replaceAll("Exception: ", "")}")),
        );
      }
    } finally {
      if (mounted) setState(() => _pendingRooms.remove(room.roomName));
      _fetchLiveRoomStatus();
    }
  }
}


/// The full-screen Time's Up screen: it takes the place of whatever is on
/// screen and rings the alarm. The guest's text goes out by itself; the
/// screen shows how it is getting on. Pops true when the receptionist asks
/// to send the text by hand (offered only when the automatic text failed),
/// false when it is dismissed.
class _RoomAlertScreen extends StatefulWidget {
  final _RoomAlert alert;

  const _RoomAlertScreen({required this.alert});

  @override
  State<_RoomAlertScreen> createState() => _RoomAlertScreenState();
}

class _RoomAlertScreenState extends State<_RoomAlertScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 700))..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final alert = widget.alert;
    final Color accent = StatusColors.timeUp;
    final bool hasPhone = alert.guestPhone.trim().isNotEmpty;

    return PopScope(
      canPop: false,
      child: Material(
        color: const Color(0xff0a1426),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(28),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: ValueListenableBuilder<_AutoSmsState>(
                  valueListenable: alert.smsState,
                  builder: (context, smsState, _) {
                    final String statusText = !hasPhone
                        ? "This booking has no phone number, so no message can be sent."
                        : switch (smsState) {
                            _AutoSmsState.sending => "Sending the message to the guest...",
                            _AutoSmsState.sent => "The guest has been sent this message:",
                            _AutoSmsState.failed => "The message was not confirmed as sent.",
                          };
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        FadeTransition(
                          opacity: Tween<double>(begin: 0.45, end: 1.0).animate(_pulse),
                          child: Icon(Icons.alarm_on, size: 84, color: accent),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          "TIME'S UP",
                          style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold, letterSpacing: 3, color: accent),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          alert.roomName,
                          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          alert.guestName,
                          style: const TextStyle(fontSize: 16, color: Colors.white70),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          statusText,
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 15, color: Colors.white),
                        ),
                        if (hasPhone) ...[
                          const SizedBox(height: 16),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: const Color(0xff111f3a),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: accent.withValues(alpha: 0.5), width: 0.7),
                            ),
                            child: Text(
                              alert.message,
                              style: const TextStyle(fontSize: 13, color: Colors.white70, height: 1.35),
                            ),
                          ),
                        ],
                        const SizedBox(height: 24),
                        if (hasPhone && smsState == _AutoSmsState.failed)
                          SizedBox(
                            width: double.infinity,
                            height: 54,
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: accent,
                                foregroundColor: const Color(0xff0a1426),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                              ),
                              icon: const Icon(Icons.send),
                              label: const Text("Send Message", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                              onPressed: () => Navigator.of(context, rootNavigator: true).pop(true),
                            ),
                          ),
                        const SizedBox(height: 10),
                        TextButton(
                          onPressed: () => Navigator.of(context, rootNavigator: true).pop(false),
                          child: const Text(
                            "Dismiss",
                            style: TextStyle(color: Colors.white70, fontSize: 14),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
