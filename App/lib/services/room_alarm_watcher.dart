import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../widgets/sms_helper.dart';
import 'alarm_player.dart';
import 'api_service.dart';

/// A record, kept on the device, of the automatic guest texts already sent
/// (or given up on), so each text goes out once whether the tablet was
/// logged in or logged out at the time.
class GuestTextLog {
  GuestTextLog._();
  static const String _storageKey = "guest_texts_sent";

  static Future<Set<String>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return (prefs.getStringList(_storageKey) ?? const <String>[]).toSet();
    } catch (_) {
      return <String>{};
    }
  }

  static Future<void> add(String entry) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final Set<String> entries = (prefs.getStringList(_storageKey) ?? const <String>[]).toSet();
      entries.add(entry);
      // Only the newest entries are worth keeping; older ones belong to
      // stays that ended long ago.
      final List<String> kept = entries.toList();
      final List<String> trimmed = kept.length > 400 ? kept.sublist(kept.length - 400) : kept;
      await prefs.setStringList(_storageKey, trimmed);
    } catch (_) {}
  }
}

/// Keeps the Time's Up alarm and the automatic guest texts working while
/// nobody is logged in on the receptionist tablet.
///
/// While someone is logged in, the room grid raises the Time's Up screen
/// and sends the texts itself. When the tablet is logged out (a receptionist
/// signed out, or the hour of inactivity ended the session), the grid is
/// gone, so this watcher takes over the jobs that cannot wait: it rings the
/// alarm as soon as any occupied room's time has run out, and it sends the
/// 30-minute and Time's Up texts to the guests. It works from the last room
/// list the grid saw (rooms, check-out times, guest names and phone numbers),
/// which is kept on the device, and from the clock, so it needs neither the
/// server nor a login.
///
/// The alarm stops the moment anyone logs in. The room grid then takes
/// over; a text already sent here is never sent again.
class RoomAlarmWatcher {
  RoomAlarmWatcher._();
  static final RoomAlarmWatcher instance = RoomAlarmWatcher._();

  static const String _storageKey = "graceland_alarm_watch_rooms";

  /// Room name -> the moment its paid time runs out (UTC).
  final Map<String, DateTime> _checkoutByRoom = {};

  /// Room name -> the guest staying there, for the automatic texts.
  final Map<String, ({String name, String phone})> _guestByRoom = {};

  /// Texts being sent right now, by key, so the same text is never started twice.
  final Map<String, Future<bool?>> _textsInFlight = {};
  Timer? _checkTimer;
  bool _started = false;

  /// True only for the receptionist app; the manager's phone never rings.
  bool enabled = false;

  /// Starts watching. Safe to call more than once.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    await _load();
    _checkTimer = Timer.periodic(const Duration(seconds: 3), (_) => _check());
  }

  /// Called by the room grid every time it has a fresh room list. Only the
  /// rooms that are Occupied or Time's Up matter here.
  void rememberRooms(
    Iterable<({String roomName, DateTime? checkout, bool isOccupied, String guestName, String guestPhone})> rooms,
  ) {
    _checkoutByRoom.clear();
    _guestByRoom.clear();
    for (final room in rooms) {
      if (room.isOccupied && room.checkout != null) {
        _checkoutByRoom[room.roomName] = room.checkout!.toUtc();
        _guestByRoom[room.roomName] = (name: room.guestName, phone: room.guestPhone);
      }
    }
    _save();
  }

  /// The key that identifies one automatic text: the room, the check-out
  /// time it belongs to (an extension starts a fresh pair) and the kind.
  static String textKey(String roomName, DateTime checkout, String kind) =>
      "$roomName|${checkout.toUtc().toIso8601String()}|$kind";

  /// Sends the automatic text of [kind] ("thirtyMinutes" or "timeUp") for a
  /// room, once. Quiet, with retries. Returns true when it was sent (now or
  /// earlier), false when it could not be sent, and null when it was
  /// abandoned because it no longer applies. Used by both this watcher and
  /// the room grid, so a text is never sent twice.
  Future<bool?> sendRoomTextOnce({
    required String roomName,
    required DateTime checkout,
    required String kind,
    required String guestName,
    required String guestPhone,
  }) async {
    final String key = textKey(roomName, checkout, kind);

    final Future<bool?>? alreadyRunning = _textsInFlight[key];
    if (alreadyRunning != null) return alreadyRunning;

    String build() {
      if (kind == "timeUp") return buildTimeUpSms(guestName: guestName, roomName: roomName);
      final int seconds = checkout.toUtc().difference(DateTime.now().toUtc()).inSeconds;
      final int minutesLeft = seconds <= 0 ? 0 : (seconds / 60).ceil();
      return buildMinutesLeftSms(guestName: guestName, roomName: roomName, minutesLeft: minutesLeft);
    }

    bool stillApplies() {
      if (kind == "timeUp") return true;
      // With under five minutes left the Time's Up text follows at once.
      return checkout.toUtc().difference(DateTime.now().toUtc()).inSeconds >= 5 * 60;
    }

    // Registered before anything is awaited, so two callers arriving at the
    // same moment share one job instead of each starting a text.
    final Future<bool?> job = () async {
      final Set<String> log = await GuestTextLog.load();
      if (log.contains("$key|sent")) return true;
      if (log.contains("$key|failed")) return false;

      final bool? result = await sendGuestMessageQuietly(
        phoneNumber: guestPhone,
        messageBuilder: build,
        shouldContinue: stillApplies,
      );
      if (result == true) await GuestTextLog.add("$key|sent");
      if (result == false) await GuestTextLog.add("$key|failed");
      return result;
    }();
    _textsInFlight[key] = job;
    try {
      return await job;
    } finally {
      _textsInFlight.remove(key);
    }
  }

  /// Sends the 30-minute and Time's Up texts that are due, for the rooms
  /// remembered from the last room list. Only runs while nobody is logged in.
  void _sendDueTexts() {
    final DateTime now = DateTime.now().toUtc();
    for (final entry in _checkoutByRoom.entries) {
      final guest = _guestByRoom[entry.key];
      if (guest == null || guest.phone.trim().isEmpty) continue;

      final int secondsLeft = entry.value.difference(now).inSeconds;
      final String? kind = secondsLeft <= 0
          ? "timeUp"
          : (secondsLeft <= 30 * 60 && secondsLeft >= 5 * 60 ? "thirtyMinutes" : null);
      if (kind == null) continue;

      sendRoomTextOnce(
        roomName: entry.key,
        checkout: entry.value,
        kind: kind,
        guestName: guest.name,
        guestPhone: guest.phone,
      );
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _storageKey,
        jsonEncode(_checkoutByRoom.map((room, when) {
          final guest = _guestByRoom[room];
          return MapEntry(room, {
            "checkout": when.toIso8601String(),
            "name": guest?.name ?? "Guest",
            "phone": guest?.phone ?? "",
          });
        })),
      );
    } catch (_) {}
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);
      if (raw == null) return;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      decoded.forEach((room, value) {
        final Map<String, dynamic> details = Map<String, dynamic>.from(value as Map);
        _checkoutByRoom[room] = DateTime.parse(details["checkout"] as String).toUtc();
        _guestByRoom[room] = (name: (details["name"] as String?) ?? "Guest", phone: (details["phone"] as String?) ?? "");
      });
    } catch (_) {}
  }

  Future<void> _check() async {
    if (!enabled) return;

    // Someone is logged in: the room grid is in charge, so stay quiet.
    if (ApiService.current != null) {
      if (AlarmPlayer.instance.isRinging && !_gridOwnsTheSound) AlarmPlayer.instance.stop();
      return;
    }

    // A room whose Time's Up prompt was already raised and answered earlier
    // does not ring again just because the tablet was logged out.
    final Set<String> handled = await _handledPromptKeys();
    final DateTime now = DateTime.now().toUtc();
    final bool anyRoomTimeUp = _checkoutByRoom.entries.any((entry) {
      final bool timeIsUp = !entry.value.isAfter(now);
      final String key = "${entry.key}|${entry.value.toIso8601String()}|timeUp";
      return timeIsUp && !handled.contains(key);
    });

    if (ApiService.current != null) return;
    if (anyRoomTimeUp) {
      AlarmPlayer.instance.startLoopingAlarm();
    } else if (AlarmPlayer.instance.isRinging) {
      AlarmPlayer.instance.stop();
    }

    // The guest texts go out whether or not anyone is logged in.
    _sendDueTexts();
  }

  /// The prompts the room grid has already raised, saved on the device.
  Future<Set<String>> _handledPromptKeys() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return (prefs.getStringList("room_alerts_handled") ?? const <String>[]).toSet();
    } catch (_) {
      return <String>{};
    }
  }

  /// Set by the room grid while one of its own prompts is on screen, so the
  /// watcher never silences a sound the grid is playing.
  bool _gridOwnsTheSound = false;
  void gridIsPlaying(bool value) => _gridOwnsTheSound = value;
}
