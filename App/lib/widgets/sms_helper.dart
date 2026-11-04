import 'dart:async';

import 'package:another_telephony/telephony.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

// ====================================================================
// SENDING A TEXT TO A GUEST FROM THE RECEPTIONIST'S TABLET
// ====================================================================
// The tablet has a SIM card, so a text goes out as an ordinary SMS on the
// SIM's airtime: no mobile data and no outside service. The booking,
// extension, 30-minute and time's-up texts are sent automatically, in the
// background; the tablet's own messaging app is never opened, so a tablet
// locked to this app keeps working as it is.
//
// A message counts as sent only when the tablet itself reports that it left
// the SIM. An automatic text that fails is tried again quietly a few times;
// only if it keeps failing is the receptionist warned, and the "Send
// Message" button remains as a manual fallback that shows the reason and
// can be tried again as many times as needed.
//
// Android asks once, the first time, for permission to send texts.

/// The message sent after a booking: who, which room, and the check-in and
/// check-out times, labelled GMT as every time in this app is.
String buildBookingSms({
  required String guestName,
  required String roomName,
  required DateTime checkInUtc,
  required DateTime checkOutUtc,
}) {
  return "Dear ${_firstName(guestName)}, congratulations! You are booked into $roomName at Graceland Guest House. "
      "Check-in: ${_formatGmt(checkInUtc)}. Check-out: ${_formatGmt(checkOutUtc)}. "
      "Thank you for choosing us. Enjoy your stay.";
}

/// The message sent after a stay is extended: who, which room, how many
/// hours were added and the new check-out time, labelled GMT.
String buildExtensionSms({
  required String guestName,
  required String roomName,
  required int additionalHours,
  required DateTime newCheckOutUtc,
}) {
  final String hoursText = additionalHours == 1 ? "1 hour" : "$additionalHours hours";
  return "Dear ${_firstName(guestName)}, your stay in $roomName at Graceland Guest House has been extended by $hoursText. "
      "Your new check-out time is ${_formatGmt(newCheckOutUtc)}. "
      "Thank you for staying with us. Enjoy your stay.";
}

/// The reminder sent shortly before a room's time runs out. It states the
/// real number of minutes left at the moment it is built, so a reminder sent
/// late is still true.
String buildMinutesLeftSms({required String guestName, required String roomName, required int minutesLeft}) {
  return "Dear ${_firstName(guestName)}, your time in $roomName at Graceland Guest House ends in $minutesLeft minutes. "
      "To extend your stay, please see the front desk. Thank you.";
}

/// The message sent when a room's time has run out. It follows the room
/// matrix's own countdown (the room shows as Time's Up).
String buildTimeUpSms({required String guestName, required String roomName}) {
  return "Dear ${_firstName(guestName)}, your time in $roomName at Graceland Guest House is up. "
      "Please check out or extend your stay at the front desk. "
      "Thank you for staying with us. We hope to see you again.";
}

String _firstName(String fullName) {
  final String trimmed = fullName.trim();
  if (trimmed.isEmpty) return "Guest";
  return trimmed.split(RegExp(r'\s+')).first;
}

String _formatGmt(DateTime utc) {
  final String hour = utc.hour.toString().padLeft(2, '0');
  final String minute = utc.minute.toString().padLeft(2, '0');
  return "$hour:$minute GMT, ${utc.day}/${utc.month}/${utc.year}";
}

/// The result of one attempt to send a text: whether the tablet confirmed
/// it, and, when it did not, the reason in plain words.
class SmsOutcome {
  final bool sent;

  /// True when the tablet gave no answer in time. The text may or may not
  /// have left the SIM, so it must never be sent again automatically.
  final bool unconfirmed;
  final String reason;

  const SmsOutcome.sent() : sent = true, unconfirmed = false, reason = "";
  const SmsOutcome.failed(this.reason) : sent = false, unconfirmed = false;
  const SmsOutcome.unconfirmed(this.reason) : sent = false, unconfirmed = true;
}

/// How long the tablet is given to confirm that a text left the SIM.
const Duration _kSmsConfirmationWait = Duration(seconds: 25);

/// Sends [message] to [phoneNumber] directly from the tablet's SIM and
/// reports whether the tablet confirmed it. Never throws: a refused
/// permission, a tablet without a SIM or any other failure comes back as a
/// failed outcome with the reason.
Future<SmsOutcome> sendGuestMessage({required String phoneNumber, required String message}) async {
  final String number = phoneNumber.trim();
  if (number.isEmpty) return const SmsOutcome.failed("This booking has no phone number.");

  try {
    final PermissionStatus permission = await Permission.sms.request();
    if (!permission.isGranted) {
      return const SmsOutcome.failed("The tablet has not been allowed to send texts. Allow SMS for this app in the tablet's settings.");
    }

    final bool? isCapable = await Telephony.instance.isSmsCapable;
    if (isCapable == false) {
      return const SmsOutcome.failed("This tablet cannot send texts. Check that a SIM card is in it.");
    }

    // The tablet reports back when the text has left the SIM. Only that
    // report counts as sent.
    final Completer<SendStatus> confirmation = Completer<SendStatus>();
    await Telephony.instance.sendSms(
      to: number,
      message: message,
      isMultipart: true,
      statusListener: (SendStatus status) {
        if (!confirmation.isCompleted) confirmation.complete(status);
      },
    );

    await confirmation.future.timeout(_kSmsConfirmationWait);
    return const SmsOutcome.sent();
  } on TimeoutException {
    return const SmsOutcome.unconfirmed(
        "The tablet did not confirm that the text was sent. It may already have gone out, so check with the guest before trying again. Also check the SIM, the airtime and the signal.");
  } catch (_) {
    return const SmsOutcome.failed("The text could not be sent from this tablet.");
  }
}

/// How many times an automatic text is attempted, and how long the tablet
/// waits between attempts.
const int _kAutomaticAttempts = 3;
const Duration _kAutomaticRetryPause = Duration(seconds: 20);

/// Sends a text without any dialog, trying again quietly when an attempt
/// fails. [messageBuilder] is called before every attempt, so a text that
/// states a changing fact (minutes left) is always true when it goes out.
/// [shouldContinue] is checked before every attempt; when it says no, the
/// text is abandoned and null is returned.
///
/// Returns true when the tablet confirmed the text, false when every
/// attempt failed or the tablet gave no confirmation (not tried again),
/// and null when the text was abandoned.
Future<bool?> sendGuestMessageQuietly({
  required String phoneNumber,
  required String Function() messageBuilder,
  bool Function()? shouldContinue,
}) async {
  if (phoneNumber.trim().isEmpty) return false;

  for (int attempt = 1; attempt <= _kAutomaticAttempts; attempt++) {
    if (shouldContinue != null && !shouldContinue()) return null;
    final SmsOutcome outcome = await sendGuestMessage(phoneNumber: phoneNumber, message: messageBuilder());
    if (outcome.sent) return true;
    // An unconfirmed text may already have been delivered, so it is never
    // sent again on its own. The receptionist is told and decides.
    if (outcome.unconfirmed) return false;
    if (attempt < _kAutomaticAttempts) await Future<void>.delayed(_kAutomaticRetryPause);
  }
  return false;
}

/// Tells the receptionist that an automatic text could not be sent, with a
/// SEND MESSAGE button that opens the manual route (it shows the reason and
/// offers Try Again).
void showAutomaticSendFailedWarning({
  required NavigatorState navigator,
  required ScaffoldMessengerState messenger,
  required String what,
  required String phoneNumber,
  required String Function() messageBuilder,
}) {
  messenger.showSnackBar(
    SnackBar(
      duration: const Duration(seconds: 20),
      backgroundColor: const Color(0xffc9971f),
      content: Text("$what was not confirmed as sent."),
      action: SnackBarAction(
        label: "SEND MESSAGE",
        textColor: Colors.white,
        onPressed: () {
          sendGuestMessageWithRetry(
            navigator: navigator,
            messenger: messenger,
            phoneNumber: phoneNumber,
            message: messageBuilder(),
            successText: "Message sent.",
          );
        },
      ),
    ),
  );
}

/// Automatic texts being sent right now, by number and message, so a text
/// the receptionist sends by hand is not sent a second time on top of one
/// that is still on its way.
final Map<String, Future<bool?>> _automaticInFlight = <String, Future<bool?>>{};

/// Sends a text automatically in the background: quietly, with retries, and
/// with a warning only if it keeps failing. Does not wait for the result.
void sendGuestMessageInBackground({
  required NavigatorState navigator,
  required ScaffoldMessengerState messenger,
  required String phoneNumber,
  required String Function() messageBuilder,
  required String what,
}) {
  final String key = "${phoneNumber.trim()}|${messageBuilder()}";
  if (_automaticInFlight.containsKey(key)) return;
  () async {
    final Future<bool?> job = sendGuestMessageQuietly(phoneNumber: phoneNumber, messageBuilder: messageBuilder);
    _automaticInFlight[key] = job;
    final bool? sent = await job;
    _automaticInFlight.remove(key);
    if (sent == false) {
      showAutomaticSendFailedWarning(
        navigator: navigator,
        messenger: messenger,
        what: what,
        phoneNumber: phoneNumber,
        messageBuilder: messageBuilder,
      );
    }
  }();
}

/// Sends a text by hand and keeps the receptionist informed until it has either
/// been confirmed or they choose to stop. While it sends, a small "Sending"
/// box is shown. If it fails, the reason is shown with Try Again and Close.
/// Returns true when the message was confirmed.
///
/// [navigator] and [messenger] are taken from the screen that asked, before
/// that screen may close, so the result can still be shown afterwards.
Future<bool> sendGuestMessageWithRetry({
  required NavigatorState navigator,
  required ScaffoldMessengerState messenger,
  required String phoneNumber,
  required String message,
  required String successText,
}) async {
  // If the same text is already being sent automatically, wait for it
  // instead of sending a second copy.
  final Future<bool?>? automatic = _automaticInFlight["${phoneNumber.trim()}|$message"];
  if (automatic != null) {
    final BuildContext? waitContext = navigator.overlay?.context;
    if (waitContext != null) {
      showDialog<void>(
        context: waitContext,
        barrierDismissible: false,
        builder: (_) => const PopScope(
          canPop: false,
          child: AlertDialog(
            content: Row(
              children: [
                SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xffd4af37))),
                SizedBox(width: 16),
                Expanded(child: Text("This message is already being sent...")),
              ],
            ),
          ),
        ),
      );
      final bool? result = await automatic;
      navigator.pop();
      if (result == true) {
        messenger.showSnackBar(SnackBar(backgroundColor: const Color(0xff14703f), content: Text(successText)));
        return true;
      }
      // The automatic send did not confirm; the receptionist may now send it by hand.
    }
  }

  while (true) {
    final BuildContext? overlayContext = navigator.overlay?.context;
    if (overlayContext == null) return false;

    showDialog<void>(
      context: overlayContext,
      barrierDismissible: false,
      builder: (_) => const PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xffd4af37))),
              SizedBox(width: 16),
              Expanded(child: Text("Sending the message...")),
            ],
          ),
        ),
      ),
    );

    final SmsOutcome outcome = await sendGuestMessage(phoneNumber: phoneNumber, message: message);
    navigator.pop();

    if (outcome.sent) {
      messenger.showSnackBar(SnackBar(backgroundColor: const Color(0xff14703f), content: Text(successText)));
      return true;
    }

    final BuildContext? dialogContext = navigator.overlay?.context;
    if (dialogContext == null) return false;
    final bool? tryAgain = await showDialog<bool>(
      context: dialogContext,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text("Message not sent"),
        content: Text(outcome.reason),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("Close")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xffd4af37), foregroundColor: Colors.black),
            onPressed: () => Navigator.pop(context, true),
            child: const Text("Try Again", style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (tryAgain != true) return false;
  }
}
