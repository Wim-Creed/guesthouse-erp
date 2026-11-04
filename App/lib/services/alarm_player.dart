import 'dart:async';

import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';

/// Plays the receptionist tablet's Time's Up alarm.
///
/// Each call is awaited inside its own try block, so a sound that cannot be
/// played can never reach the rest of the app.
class AlarmPlayer {
  AlarmPlayer._();
  static final AlarmPlayer instance = AlarmPlayer._();

  bool _alarmRinging = false;

  /// Whether the alarm is ringing right now.
  bool get isRinging => _alarmRinging;

  /// The Time's Up alarm: rings until [stop] is called.
  Future<void> startLoopingAlarm() async {
    if (_alarmRinging) return;
    _alarmRinging = true;
    try {
      await FlutterRingtonePlayer().playAlarm(looping: true, volume: 1.0, asAlarm: true);
    } catch (_) {
      _alarmRinging = false;
    }
  }

  /// Silences the alarm.
  Future<void> stop() async {
    _alarmRinging = false;
    try {
      await FlutterRingtonePlayer().stop();
    } catch (_) {}
  }
}
