import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../widgets/capitalize_words_formatter.dart' show canonicalName;
import 'offline_outbox.dart';

/// This service manages all network communication between the user interface
/// on the front desk tablets and the central database server.
///
/// Every write action (creating, changing, or deleting something) goes
/// through _resilientRequest below. If the server cannot be reached at
/// all, the action is saved to the offline outbox and treated as
/// successful immediately — business does not stop because the router is
/// down. The outbox then retries it automatically in the background,
/// oldest action first, until the server actually confirms it, using the
/// same one-time action tag the backend already checks for, so a retried
/// action can never be saved twice. A real rejection from a server that
/// IS reachable (wrong password, room already occupied, insufficient
/// cash) is never queued this way — it is shown immediately as a real
/// failure, since retrying a genuine rejection forever would be wrong.
/// One thing this tablet did to a room that the server has not confirmed
/// yet (see ApiService.pendingRoomEvents). [kind] is BOOKING, EXTEND,
/// CANCEL, CHECKOUT or CLEAN.
class PendingRoomEvent {
  final String kind;
  final String? roomName;
  final DateTime atUtc;
  final String? guestName;
  final String? guestPhone;
  final int? hours;

  PendingRoomEvent({
    required this.kind,
    required this.roomName,
    required this.atUtc,
    this.guestName,
    this.guestPhone,
    this.hours,
  });
}

/// One booking or one extension made during the current shift, as listed
/// for the receptionist: the room, the hours and the price. It never says
/// who made it.
class ShiftBookingLine {
  final bool isExtension;
  final String room;
  final int hours;
  final double price;
  final DateTime at;

  ShiftBookingLine({required this.isExtension, required this.room, required this.hours, required this.price, required this.at});
}

/// One shop sale line made during the current shift: the item, the number
/// sold and the total price for that line. It never says who sold it.
class ShiftSaleLine {
  final String item;
  final int quantity;
  final double total;
  final DateTime at;

  ShiftSaleLine({required this.item, required this.quantity, required this.total, required this.at});
}

/// The "what has happened this shift" lists shown to the receptionist (see
/// ApiService.refreshShiftActivity). An extension counts as a booking.
class ShiftActivity {
  final List<ShiftBookingLine> bookings;
  final List<ShiftSaleLine> sales;

  ShiftActivity({required this.bookings, required this.sales});

  int get bookingsTotal => bookings.length;
  int get salesTotal => sales.length;
  double get salesAmount => sales.fold(0.0, (sum, line) => sum + line.total);
}

class ApiService {
  /// The service that currently has someone logged in, or null when nobody
  /// is logged in on this device. The idle lock and the alarm watcher read
  /// it, because they live outside any one screen.
  static ApiService? current;

  ApiService() {
    // Lets the offline outbox always send a queued action with whatever
    // login is CURRENT on this device, rather than the one that was
    // active back when the action was first queued — see
    // OfflineOutbox.authHeaderProvider for why this matters.
    OfflineOutbox.instance.authHeaderProvider =
        () => _authToken != null ? {"Authorization": "Bearer $_authToken"} : null;
  }

  /// Where the last good copy of the price list and the room list are kept
  /// on this device. These are what let the booking form open, and the
  /// room grid load, while the server is down: the guesthouse never has to
  /// stop taking guests because the router is off.
  static const String _pricingCacheKey = "graceland_cached_room_pricing";
  static const String _roomsCacheKey = "graceland_cached_room_status";

  /// This shift's running totals for the receptionist's screen (null until
  /// the first answer). The activity boxes listen to this.
  final ValueNotifier<ShiftActivity?> shiftActivity = ValueNotifier<ShiftActivity?>(null);

  /// Whether an official shift is open right now, as last reported by the
  /// server (null until the first answer). The receptionist's screen shows
  /// a plain "Buffer period" banner while this is false.
  final ValueNotifier<bool?> officialShiftActive = ValueNotifier<bool?>(null);

  // -------------------------------------------------------------------
  // FINDING THE SERVER
  // -------------------------------------------------------------------
  // The addresses the server can be reached on are listed in the file
  // lib/config/server_addresses.json, which is packed inside the app. At
  // login the app tries each address in the order listed and uses the
  // first one that answers. Changing where the server lives means editing
  // that file; no code has to be opened.

  /// Where the list of server addresses is kept inside the app.
  static const String _serverAddressesAsset = "lib/config/server_addresses.json";

  /// The address used when the list cannot be read. It points at the
  /// device itself, so it only works when the server runs on that device.
  static const String _unconfiguredAddress = "http://127.0.0.1:8000";

  /// The address that most recently answered, tried first at the next login.
  static String? _lastWorkingAddress;

  /// The local network address and port of the backend server. It holds
  /// the address found by findServer, and is read by every request below
  /// and by the screens that build their own web addresses.
  static String baseUrl = _unconfiguredAddress;

  /// Reads the list of server addresses from the file packed inside the
  /// app. A missing or unreadable file gives a list holding only
  /// [_unconfiguredAddress].
  static Future<List<String>> _readConfiguredAddresses() async {
    try {
      final String raw = await rootBundle.loadString(_serverAddressesAsset);
      final dynamic decoded = jsonDecode(raw);
      final dynamic list = decoded is Map ? decoded['server_addresses'] : null;
      if (list is List) {
        final List<String> cleaned = list
            .whereType<String>()
            .map((address) => address.trim().replaceAll(RegExp(r'/+$'), ''))
            .where((address) => address.isNotEmpty)
            .toList();
        if (cleaned.isNotEmpty) return cleaned;
      }
    } catch (e) {
      debugPrint("Could not read the server address list: $e");
    }
    return [_unconfiguredAddress];
  }

  /// True when something answers at [address]. Any reply counts, including
  /// a refusal, because a refusal still proves the server is there.
  static Future<bool> _serverAnswers(String address) async {
    try {
      await http.get(Uri.parse(address)).timeout(const Duration(seconds: 2));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Tries the configured server addresses one by one, the address that
  /// answered last time first, and keeps the first one that answers in
  /// [baseUrl]. When none answers, [baseUrl] holds the last working
  /// address (or the first one listed), so the usual "could not reach the
  /// server" message is what the person sees. Never throws.
  static Future<void> findServer() async {
    final List<String> configured = await _readConfiguredAddresses();
    final List<String> candidates = [
      if (_lastWorkingAddress != null) _lastWorkingAddress!,
      ...configured,
    ];

    final Set<String> alreadyTried = <String>{};
    for (final String address in candidates) {
      if (!alreadyTried.add(address)) continue;
      if (await _serverAnswers(address)) {
        baseUrl = address;
        _lastWorkingAddress = address;
        debugPrint("Server found at $address");
        return;
      }
    }

    baseUrl = _lastWorkingAddress ?? configured.first;
    debugPrint("No server answered. Using $baseUrl");
  }

  /// Stores the active exchange rate between US Dollars and Ghanaian Cedis.
  /// This is only ever set from what the server reports — see
  /// syncSharedExchangeRate below — never from a hardcoded guess.
  double _cachedExchangeRate = 15.60;

  /// Tracks if the system can successfully connect to the outside internet.
  bool _isSystemOnline = true;

  /// Holds the active security login token returned by the server.
  String? _authToken;

  /// The username of whoever is currently logged in on this device. Sent
  /// along with every action a receptionist takes, so an action saved
  /// while offline and sent later still gets credited to the right
  /// person, even if someone else has since logged in on this same
  /// tablet — see resolve_acting_user on the server.
  String? _currentUsername;

  /// Called once, from outside this service, whenever the server reports
  /// that the current login is no longer valid (expired, or the account
  /// was removed). The app uses this to send the person back to the
  /// login screen with the right message. Never called just because the
  /// server could not be reached — only for a real "no longer logged in".
  void Function(String message)? onSessionEnded;

  /// Public accessors to view the current exchange rate and internet status.
  double get activeExchangeRate => _cachedExchangeRate;
  bool get isSystemOnline => _isSystemOnline;
  String? get authToken => _authToken;
  String? get currentUsername => _currentUsername;

  /// Reads the single, authoritative USD-to-GHS rate the manager's phone
  /// most recently looked up and saved on the server (see
  /// lookUpAndSaveLiveExchangeRate below). The server itself has no
  /// internet, so it never looks this rate up on its own; it only ever
  /// reports whatever was last sent to it, or simply holds its last known
  /// value if this device cannot reach the server right now. Reading it
  /// this way means a receptionist tablet with no internet access of its
  /// own still always shows the same, correct rate as the manager's
  /// device, since both are only ever talking to the guesthouse's own
  /// local server.
  Future<void> syncSharedExchangeRate() async {
    if (_authToken == null) return;
    try {
      final response = await http.get(
        Uri.parse("$baseUrl/sessions/current-rate/"),
        headers: {"Authorization": "Bearer $_authToken"},
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        _cachedExchangeRate = (data['usd_to_ghs_rate'] as num).toDouble();
        _isSystemOnline = true;
        debugPrint("Exchange rate synced from server: $_cachedExchangeRate");
      } else {
        _isSystemOnline = false;
      }
    } catch (e) {
      // Server unreachable right now (for example, the tablet just isn't on
      // the local network yet). Keep showing the last known rate rather
      // than falling back to any hardcoded number.
      _isSystemOnline = false;
      debugPrint("Could not reach the server for the exchange rate. Keeping last known rate: $_cachedExchangeRate");
    }
  }

  /// Called only from the manager's app, which is the only device with its
  /// own internet connection. Looks the live USD-to-GHS rate up from a
  /// public exchange-rate source, then saves it on the server so every
  /// tablet reads the same figure. Nothing checks in the background: this
  /// only ever runs when the manager explicitly triggers it (at login).
  /// If the lookup or the save fails, the server simply keeps whatever
  /// rate it already had — this never throws in a way that blocks login.
  Future<void> lookUpAndSaveLiveExchangeRate() async {
    try {
      final lookupResponse = await http
          .get(Uri.parse("https://open.er-api.com/v6/latest/USD"))
          .timeout(const Duration(seconds: 8));
      if (lookupResponse.statusCode != 200) return;

      final lookupData = jsonDecode(lookupResponse.body);
      final double? liveRate = (lookupData['rates']?['GHS'] as num?)?.toDouble();
      if (liveRate == null || liveRate <= 0) return;

      await setExchangeRate(liveRate);
      _cachedExchangeRate = liveRate;
    } catch (e) {
      // No internet on this phone right now, or the lookup source is
      // unreachable. The server's last saved rate is left exactly as it
      // was — there is nothing more useful to do here.
      debugPrint("Could not look up a live exchange rate right now: $e");
    }
  }

  /// Converts a US Dollar cost into Ghanaian Cedis using the active exchange rate.
  double convertUsdToGhs(double usdAmount) {
    return usdAmount * _cachedExchangeRate;
  }

  /// Generates a fresh, effectively unique tag for one write action, used
  /// by the server to recognize a retried action and never save it twice.
  String _generateActionId() {
    final randomSuffix = Random().nextInt(999999).toString().padLeft(6, '0');
    return "${DateTime.now().microsecondsSinceEpoch}-$randomSuffix";
  }

  /// True if this failure means the server could not be reached at all
  /// (router down, no signal, request timed out) rather than the server
  /// being reached and returning a real rejection.
  bool _isConnectivityFailure(Object error) {
    if (error is TimeoutException) return true;
    final text = error.toString();
    return text.contains("SocketException") ||
        text.contains("Failed host lookup") ||
        text.contains("Connection refused") ||
        text.contains("Connection closed") ||
        text.contains("ClientException") ||
        text.contains("Network is unreachable") ||
        text.contains("No route to host") ||
        text.contains("Connection reset") ||
        text.contains("Connection timed out") ||
        text.contains("Connection failed") ||
        text.contains("Software caused connection abort");
  }

  Future<http.Response> _dispatchHttp(String method, String url, Map<String, String> headers, String body) {
    switch (method) {
      case "POST":
        return http.post(Uri.parse(url), headers: headers, body: body.isEmpty ? null : body);
      case "PATCH":
        return http.patch(Uri.parse(url), headers: headers, body: body.isEmpty ? null : body);
      case "DELETE":
        return http.delete(Uri.parse(url), headers: headers, body: body.isEmpty ? null : body);
      default:
        throw Exception("Unsupported method: $method");
    }
  }

  /// Reads the message out of a 401 response and, unless the server was
  /// simply unreachable, tells the rest of the app the login is no longer
  /// valid so it can show the login screen again. This only ever fires
  /// for a real "not logged in any more" answer from a server that WAS
  /// reached — never for a connectivity failure, which is handled
  /// entirely separately by the offline outbox above.
  void _handleUnauthorized(http.Response response) {
    String message = "Your session has ended. Please log in again.";
    try {
      final errorLog = jsonDecode(response.body);
      if (errorLog['detail'] is String) message = errorLog['detail'];
    } catch (_) {}
    _authToken = null;
    _currentUsername = null;
    onSessionEnded?.call(message);
  }

  /// Sends one write action, resiliently. Use jsonBodyFields for an
  /// endpoint that expects a JSON body (most POST/PATCH endpoints); use
  /// queryParams for an endpoint that takes its arguments as plain query
  /// parameters instead (most DELETE endpoints, checkout/clean, and shift
  /// open/close). The two are mutually exclusive per call, matching how
  /// each real backend endpoint is actually built.
  ///
  /// Every JSON-body action automatically carries client_time (the exact
  /// moment this was pressed, in UTC) and acted_by_username (whoever is
  /// logged in right now) — this is what lets an action saved while
  /// offline keep its real moment and its real author even if it is only
  /// actually sent to the server much later, by a different login.
  Future<Map<String, dynamic>> _resilientRequest({
    required String method,
    required String path,
    Map<String, dynamic>? jsonBodyFields,
    Map<String, String>? queryParams,
    required String description,
  }) async {
    if (_authToken == null) throw Exception("Session unauthorized. Access token invalid.");

    final clientActionId = _generateActionId();
    final Map<String, String> headers = {"Authorization": "Bearer $_authToken"};
    String finalUrl = "$baseUrl$path";
    String bodyString = "";

    if (jsonBodyFields != null) {
      headers["Content-Type"] = "application/json";
      bodyString = jsonEncode({
        ...jsonBodyFields,
        "client_action_id": clientActionId,
        "client_time": DateTime.now().toUtc().toIso8601String(),
        "acted_by_username": _currentUsername,
      });
    } else {
      final allParams = {
        ...?queryParams,
        "client_action_id": clientActionId,
        "client_time": DateTime.now().toUtc().toIso8601String(),
        if (_currentUsername != null) "acted_by_username": _currentUsername!,
      };
      final queryString = allParams.entries
          .map((entry) => "${Uri.encodeQueryComponent(entry.key)}=${Uri.encodeQueryComponent(entry.value)}")
          .join("&");
      finalUrl = "$finalUrl${finalUrl.contains('?') ? '&' : '?'}$queryString";
    }

    try {
      final response = await _dispatchHttp(method, finalUrl, headers, bodyString).timeout(const Duration(seconds: 6));

      if (response.statusCode >= 200 && response.statusCode < 300) {
        refreshShiftActivity(); // the totals on the receptionist's screen move at once
        return response.body.isNotEmpty ? jsonDecode(response.body) : {};
      } else if (response.statusCode == 401) {
        _handleUnauthorized(response);
        throw Exception("Your session has ended. Please log in again.");
      } else {
        Map<String, dynamic> errorLog = {};
        try {
          errorLog = jsonDecode(response.body);
        } catch (_) {}
        throw Exception(errorLog['detail'] ?? "Save failed. Try again.");
      }
    } catch (e) {
      if (_isConnectivityFailure(e)) {
        await OfflineOutbox.instance.enqueuePending(PendingAction(
          clientActionId: clientActionId,
          method: method,
          url: finalUrl,
          headers: headers,
          body: bodyString,
          queuedAt: DateTime.now(),
          description: description,
        ));
        // Business does not stop because the router is down: this is
        // treated as a success right away, and the outbox will keep
        // retrying it in the background until the server confirms it.
        refreshShiftActivity(); // counts what is waiting on this tablet too
        return {
          "status": "Saved. Pending, will be sent when the connection returns.",
          "queued_offline": true,
          "client_action_id": clientActionId,
        };
      }
      rethrow;
    }
  }

  /// A small helper for the plain GET calls below: raises the same
  /// session-ended handling as every write action, so a GET made with an
  /// expired login also sends the person back to the login screen rather
  /// than showing a confusing generic error.
  void _checkForSessionEnded(http.Response response) {
    if (response.statusCode == 401) {
      _handleUnauthorized(response);
      throw Exception("Your session has ended. Please log in again.");
    }
  }

  /// Verifies employee credentials with the server to log them into the system.
  Future<Map<String, dynamic>> loginUser(String username, String password) async {
    // The server is looked for before every login, so a change of network
    // (a different router, a phone hotspot) is picked up without
    // restarting the app.
    await findServer();

    try {
      final response = await http.post(
        Uri.parse("$baseUrl/auth/login/"),
        headers: {"Content-Type": "application/x-www-form-urlencoded"},
        body: {"username": username, "password": password},
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final userData = jsonDecode(response.body);
        _authToken = userData['access_token'];
        _currentUsername = userData['username'] ?? username;
        // Kept in this device's memory only, never written to disk, so the
        // idle lock can check the password again without the server. It is
        // cleared on log out.
        _unlockPassword = password;
        current = this;
        startTokenRenewal();

        // Start the background retry loop now that the app has a valid
        // session, and immediately try to clear anything left over from
        // an earlier session that never finished syncing.
        OfflineOutbox.instance.startAutoFlush();
        unawaited(OfflineOutbox.instance.flushQueue());

        return userData;
      } else {
        Map<String, dynamic> errorLog = {};
        try {
          errorLog = jsonDecode(response.body);
        } catch (_) {}
        throw Exception(errorLog['detail'] ?? "Wrong username or password.");
      }
    } on TimeoutException {
      throw Exception("Could not reach the server. Check the local connection and try again.");
    } catch (e) {
      if (_isConnectivityFailure(e)) {
        throw Exception("Could not reach the server. Check the local connection and try again.");
      }
      rethrow;
    }
  }

  /// Logs this device out. The offline outbox keeps running and keeps
  /// retrying whatever it already has queued: each attempt asks for the
  /// current login's header rather than using one saved at queue time, so
  /// a queue built up under one login still sends cleanly under whoever
  /// is logged in next — logging out
  /// here never loses or permanently blocks anything still waiting to be
  /// sent, though it will simply wait for a login to exist again if
  /// nobody is signed in on this device right now.
  void logOut() {
    _authToken = null;
    _currentUsername = null;
    _unlockPassword = null;
    _renewalTimer?.cancel();
    _renewalTimer = null;
    if (identical(current, this)) current = null;
  }

  /// The password typed at login, held in memory only (see loginUser).
  String? _unlockPassword;

  /// Whether [typed] is the password of the person logged in right now. A
  /// comparison that takes the same time whatever the text, so the answer
  /// cannot be guessed from how long it takes.
  bool passwordMatchesLogin(String typed) {
    final String? expected = _unlockPassword;
    if (expected == null) return false;
    final List<int> a = utf8.encode(typed);
    final List<int> b = utf8.encode(expected);
    int difference = a.length ^ b.length;
    for (int i = 0; i < (a.length < b.length ? a.length : b.length); i++) {
      difference |= a[i] ^ b[i];
    }
    return difference == 0;
  }

  // -------------------------------------------------------------------
  // KEEPING A LOGIN ALIVE WHILE THE DEVICE IS IN USE
  // -------------------------------------------------------------------

  Timer? _renewalTimer;

  /// The last moment anyone touched this device (see IdleSplashGuard).
  DateTime _lastTouchedAt = DateTime.now();

  /// Records that the device was just touched.
  void markTouched() => _lastTouchedAt = DateTime.now();

  /// While the device is being used, the login is renewed every ten minutes
  /// so it never runs out in the middle of a booking. A device left
  /// untouched stops renewing, and the hour of inactivity ends the session.
  void startTokenRenewal() {
    _renewalTimer?.cancel();
    _renewalTimer = Timer.periodic(const Duration(minutes: 10), (_) => _renewTokenIfInUse());
  }

  Future<void> _renewTokenIfInUse() async {
    if (_authToken == null) return;
    if (DateTime.now().difference(_lastTouchedAt) > const Duration(minutes: 15)) return;
    try {
      final response = await http.post(
        Uri.parse("$baseUrl/auth/renew/"),
        headers: {"Authorization": "Bearer $_authToken"},
      ).timeout(const Duration(seconds: 6));
      if (response.statusCode == 200) {
        final String? fresh = jsonDecode(response.body)['access_token'];
        if (fresh != null && _authToken != null) _authToken = fresh;
      }
    } catch (_) {
      // Server unreachable: the current login simply carries on.
    }
  }

  /// Lets the currently logged-in person choose a new password for
  /// themselves. Used after a manager has handed out a temporary one.
  Future<Map<String, dynamic>> changeOwnPassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    if (_authToken == null) throw Exception("Session unauthorized. Access token invalid.");
    final response = await http.post(
      Uri.parse("$baseUrl/auth/change-own-password/"),
      headers: {"Content-Type": "application/json", "Authorization": "Bearer $_authToken"},
      body: jsonEncode({"current_password": currentPassword, "new_password": newPassword}),
    ).timeout(const Duration(seconds: 8));

    if (response.statusCode == 200) return jsonDecode(response.body);
    Map<String, dynamic> errorLog = {};
    try {
      errorLog = jsonDecode(response.body);
    } catch (_) {}
    throw Exception(errorLog['detail'] ?? "Could not change the password right now.");
  }

  /// "Forgot password?" for the administrator only. Works with no
  /// internet, and with nobody logged in yet, using the one-time recovery
  /// code shown at first setup.
  Future<Map<String, dynamic>> recoverAdministratorPassword({
    required String recoveryCode,
    required String newPassword,
  }) async {
    // Nobody is logged in here, so the server is looked for first.
    await findServer();

    final response = await http.post(
      Uri.parse("$baseUrl/auth/admin-recover/"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({"recovery_code": recoveryCode, "new_password": newPassword}),
    ).timeout(const Duration(seconds: 8));

    if (response.statusCode == 200) return jsonDecode(response.body);
    Map<String, dynamic> errorLog = {};
    try {
      errorLog = jsonDecode(response.body);
    } catch (_) {}
    throw Exception(errorLog['detail'] ?? "The recovery code is not correct.");
  }

  /// Records a new room reservation directly into the live server database.
  /// cashTendered and changeReturned are always in cedis: when the guest
  /// pays in dollars, the calling screen has already converted the dollar
  /// amount before it ever reaches this method. usdReceived is passed
  /// through only as a small note for the receipt when that happened.
  Future<Map<String, dynamic>> createBooking({
    required String roomNumber,
    required String guestName,
    required String guestPhone,
    required int durationHours,
    required String paymentMode,
    required double cashTendered,
    required double changeReturned,
    double? usdReceived,
    String? momoNumber,
    String? bankSenderAccount,
  }) async {
    final DateTime pressedAt = DateTime.now().toUtc();
    final result = await _resilientRequest(
      method: "POST",
      path: "/bookings/",
      jsonBodyFields: {
        "room_number": roomNumber,
        "guest_name": guestName,
        "guest_phone": guestPhone,
        "duration_hours": durationHours,
        "payment_mode": paymentMode,
        "currency_used": "GHS",
        "cash_tendered": cashTendered,
        "change_returned": changeReturned,
        if (usdReceived != null) "usd_received": usdReceived,
        if (paymentMode == "MOMO") "momo_number": momoNumber,
        if (paymentMode == "BANK") "bank_sender_account": bankSenderAccount,
      },
      description: "New booking for $roomNumber ($guestName)",
    );

    // Saved on the tablet because the server could not be reached: the
    // server will work out the official checkout time when the booking
    // arrives, but the receptionist must be able to tell the guest NOW. So
    // the same sum (the moment of pressing confirm plus the paid hours) is
    // done here, and the room grid shows the room as Occupied meanwhile.
    if (result['queued_offline'] == true && result['checkout_deadline'] == null) {
      result['checkout_deadline'] = pressedAt.add(Duration(hours: durationHours)).toIso8601String();
    }
    return result;
  }

  /// Reads this shift's bookings, extensions and shop sales from the server
  /// (the whole shift, whoever made them) and adds whatever this tablet has
  /// saved but the server has not yet received, so the receptionist sees an
  /// accurate picture even with the server down. If the server cannot be
  /// reached, the last lists are kept and only the waiting items are added
  /// on top. No name is ever kept or shown. Never throws.
  Future<void> refreshShiftActivity() async {
    if (_authToken == null) return;

    // 1. The server's lists (or the last ones we had).
    try {
      final response = await http.get(
        Uri.parse("$baseUrl/shift/activity-summary/"),
        headers: {"Authorization": "Bearer $_authToken"},
      ).timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) {
        _lastServerActivity = jsonDecode(response.body) as Map<String, dynamic>;
      }
    } catch (_) {
      // Server not reachable: fall through and use the last lists.
    }

    final List<ShiftBookingLine> bookings = [];
    final List<ShiftSaleLine> sales = [];

    final data = _lastServerActivity;
    if (data != null) {
      for (final row in (data['bookings'] as List<dynamic>? ?? const [])) {
        bookings.add(ShiftBookingLine(
          isExtension: row['kind'] == 'extension',
          room: row['room'],
          hours: (row['hours'] as num).toInt(),
          price: (row['price'] as num).toDouble(),
          at: _parseUtc(row['at']),
        ));
      }
      for (final row in (data['sales'] as List<dynamic>? ?? const [])) {
        sales.add(ShiftSaleLine(
          item: row['item'],
          quantity: (row['quantity'] as num).toInt(),
          total: (row['total'] as num).toDouble(),
          at: _parseUtc(row['at']),
        ));
      }
    }

    // 2. Add what is saved on this tablet and not yet on the server. A
    // saved booking or extension takes its price from the price list kept
    // on this tablet.
    try {
      final waiting = await OfflineOutbox.instance.pendingActions();
      for (final action in waiting) {
        if (action.method != "POST") continue;
        final String path = Uri.parse(action.url).path;
        if (path.endsWith("/bookings/")) {
          final body = jsonDecode(action.body) as Map<String, dynamic>;
          final String room = body["room_number"];
          final int hours = (body["duration_hours"] as num).toInt();
          bookings.add(ShiftBookingLine(
            isExtension: false, room: room, hours: hours,
            price: await _savedPriceFor(room, hours),
            at: DateTime.tryParse(body["client_time"] ?? "") ?? action.queuedAt,
          ));
        } else if (path.endsWith("/extend/") || path.endsWith("/extend-room-booking/")) {
          final body = jsonDecode(action.body) as Map<String, dynamic>;
          final String room = body["room_number"];
          final int hours = (body["additional_hours"] as num).toInt();
          bookings.add(ShiftBookingLine(
            isExtension: true, room: room, hours: hours,
            price: await _savedPriceFor(room, hours),
            at: DateTime.tryParse(body["client_time"] ?? "") ?? action.queuedAt,
          ));
        } else if (path.endsWith("/shop/sale/")) {
          final body = jsonDecode(action.body) as Map<String, dynamic>;
          final int quantity = (body["quantity"] as num).toInt();
          sales.add(ShiftSaleLine(
            item: canonicalName(body["item_name"] ?? ""),
            quantity: quantity,
            total: (body["unit_price"] as num).toDouble() * quantity,
            at: DateTime.tryParse(body["client_time"] ?? "") ?? action.queuedAt,
          ));
        }
      }
    } catch (_) {}

    bookings.sort((a, b) => b.at.compareTo(a.at));
    sales.sort((a, b) => b.at.compareTo(a.at));
    shiftActivity.value = ShiftActivity(bookings: bookings, sales: sales);
  }

  Map<String, dynamic>? _lastServerActivity;

  /// Reads a server timestamp (UTC, sent without a zone label) as UTC.
  DateTime _parseUtc(String raw) {
    final bool hasZone = raw.endsWith('Z') || RegExp(r'[+-]\d\d:\d\d$').hasMatch(raw);
    return DateTime.parse(hasZone ? raw : "${raw}Z");
  }

  /// The approved price for a room and duration, read from the price list
  /// saved on this tablet at login. 0 when it cannot be found.
  Future<double> _savedPriceFor(String room, int hours) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_pricingCacheKey);
      if (saved == null) return 0.0;
      for (final entry in (jsonDecode(saved) as List<dynamic>)) {
        if (entry['room_id'] == room && entry['duration_hours'] == hours) {
          return (entry['price'] as num).toDouble();
        }
      }
    } catch (_) {}
    return 0.0;
  }

  /// Everything this tablet has done to a room that the server has not
  /// confirmed yet, oldest first, as plain events the room grid can replay
  /// on top of the server's last list. This is what lets the tablet show
  /// the true state of every room by itself while the server is down (or
  /// simply has not caught up yet): a new booking turns a room Occupied, an
  /// extension moves its checkout time, a cancel makes it Dirty again, and
  /// so on. Read straight from the offline outbox, which is saved on the
  /// device, so it survives the app being closed.
  Future<List<PendingRoomEvent>> pendingRoomEvents() async {
    final pending = await OfflineOutbox.instance.pendingActions();
    final List<PendingRoomEvent> events = [];

    for (final action in pending) {
      try {
        if (action.method != "POST") continue;
        final Uri uri = Uri.parse(action.url);
        final String path = uri.path;

        if (path.endsWith("/bookings/")) {
          final body = jsonDecode(action.body) as Map<String, dynamic>;
          events.add(PendingRoomEvent(
            kind: "BOOKING",
            roomName: body["room_number"],
            atUtc: DateTime.parse(body["client_time"]).toUtc(),
            guestName: body["guest_name"] ?? "Guest",
            guestPhone: body["guest_phone"] ?? "",
            hours: body["duration_hours"] as int,
          ));
        } else if (path.endsWith("/extend/") || path.endsWith("/extend-room-booking/")) {
          final body = jsonDecode(action.body) as Map<String, dynamic>;
          events.add(PendingRoomEvent(
            kind: "EXTEND",
            roomName: body["room_number"],
            atUtc: DateTime.parse(body["client_time"]).toUtc(),
            hours: body["additional_hours"] as int,
          ));
        } else if (path.endsWith("/cancel/") || path.endsWith("/cancel-room-booking/")) {
          events.add(PendingRoomEvent(
            kind: "CANCEL",
            roomName: uri.queryParameters["room_number"],
            atUtc: DateTime.parse(uri.queryParameters["client_time"] ?? DateTime.now().toUtc().toIso8601String()).toUtc(),
          ));
        } else if (path.endsWith("/counter/checkout-room/")) {
          events.add(PendingRoomEvent(kind: "CHECKOUT", roomName: uri.queryParameters["room_number"], atUtc: DateTime.now().toUtc()));
        } else if (path.endsWith("/counter/clean-room/")) {
          events.add(PendingRoomEvent(kind: "CLEAN", roomName: uri.queryParameters["room_number"], atUtc: DateTime.now().toUtc()));
        }
      } catch (_) {
        // A saved action that cannot be read is simply not shown locally;
        // it is still sent to the server as usual.
      }
    }
    return events.where((e) => e.roomName != null).toList();
  }

  /// Fetches the current status of every room, plus a live countdown of
  /// time remaining for any occupied room.
  Future<List<dynamic>> fetchLiveRoomStatus() async {
    if (_authToken == null) throw Exception("Session unauthorized. Access token invalid.");
    final response = await http.get(
      Uri.parse("$baseUrl/rooms/live-status/"),
      headers: {"Authorization": "Bearer $_authToken"},
    ).timeout(const Duration(seconds: 5));
    _checkForSessionEnded(response);
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      if (data['official_shift_active'] is bool) officialShiftActive.value = data['official_shift_active'];
      final rooms = data['rooms'] as List<dynamic>;
      _rememberRoomsForOffline(rooms);
      return rooms;
    }
    throw Exception("Could not load room status.");
  }

  /// Keeps the last good room list on the device (with the time it was
  /// taken), so the room grid can still open if the app is started while
  /// the server is down. Never throws.
  Future<void> _rememberRoomsForOffline(List<dynamic> rooms) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_roomsCacheKey, jsonEncode({"saved_at": DateTime.now().toUtc().toIso8601String(), "rooms": rooms}));
    } catch (_) {}
  }

  /// The last good room list saved on this device, with each countdown
  /// moved on by the time that has passed since it was saved. Null if
  /// nothing has ever been saved. Used by the room grid only when it has
  /// nothing on screen and the server cannot be reached.
  Future<List<dynamic>?> loadCachedRoomStatus() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_roomsCacheKey);
      if (raw == null) return null;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final DateTime savedAt = DateTime.parse(decoded["saved_at"]).toUtc();
      final int secondsPassed = DateTime.now().toUtc().difference(savedAt).inSeconds;
      final rooms = (decoded["rooms"] as List<dynamic>).map((r) => Map<String, dynamic>.from(r)).toList();
      for (final room in rooms) {
        if (room["remaining_seconds"] is int) {
          final int left = (room["remaining_seconds"] as int) - secondsPassed;
          room["remaining_seconds"] = left < 0 ? 0 : left;
        }
      }
      return rooms;
    } catch (_) {
      return null;
    }
  }

  /// Fetches the full live status payload, including the running count of
  /// bookings and cancellations made so far during the current shift.
  Future<Map<String, dynamic>> fetchLiveOperationalSummary() async {
    if (_authToken == null) throw Exception("Session unauthorized. Access token invalid.");
    final response = await http.get(
      Uri.parse("$baseUrl/rooms/live-status/"),
      headers: {"Authorization": "Bearer $_authToken"},
    ).timeout(const Duration(seconds: 5));
    _checkForSessionEnded(response);
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (data['official_shift_active'] is bool) officialShiftActive.value = data['official_shift_active'];
      return data;
    }
    throw Exception("Could not load the live operational summary.");
  }

  /// Fetches every room's manager-approved list of duration and price
  /// combinations.
  /// The live price list, straight from the server. Used by the manager's
  /// Room Management screen, which must always show the real current prices.
  /// The booking and extension forms do NOT use this directly; they use
  /// fetchRoomPricingForBooking below.
  Future<List<dynamic>> fetchRoomPricing() async {
    if (_authToken == null) throw Exception("Session unauthorized. Access token invalid.");
    final response = await http.get(
      Uri.parse("$baseUrl/rooms/pricing/"),
      headers: {"Authorization": "Bearer $_authToken"},
    ).timeout(const Duration(seconds: 5));
    _checkForSessionEnded(response);
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data['pricing'] as List<dynamic>;
    }
    throw Exception("Could not load room pricing.");
  }

  /// PRICES ARE READ ONCE, AT LOGIN, AND THEN JUST USED.
  /// Called right after a successful login. It fetches the approved price
  /// list from the server and saves it on this tablet. From then on the
  /// booking and extension forms use that saved copy and never ask the
  /// server again, whether the server is up or down: prices do not change
  /// in the middle of a shift (a manager changes them when a shift has
  /// closed, and the next shift's login picks them up). It is also what
  /// lets a booking be made while the server is down, since the prices are
  /// already on the tablet. Never throws: if the server cannot be reached
  /// right at this moment, the forms fall back to asking for them when
  /// first opened (see below).
  Future<void> loadAndSaveRoomPricing() async {
    try {
      final pricing = await fetchRoomPricing();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_pricingCacheKey, jsonEncode(pricing));
    } catch (e) {
      debugPrint("Could not save the price list at login: $e");
    }
  }

  /// The price list the booking and extension forms use: the copy saved at
  /// login. Only if no copy exists at all (the save at login did not
  /// manage to run) is the server asked, once, and the answer saved.
  Future<List<dynamic>> fetchRoomPricingForBooking() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_pricingCacheKey);
      if (saved != null) return jsonDecode(saved) as List<dynamic>;
    } catch (_) {}

    try {
      final pricing = await fetchRoomPricing();
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_pricingCacheKey, jsonEncode(pricing));
      } catch (_) {}
      return pricing;
    } catch (e) {
      if (_isConnectivityFailure(e)) {
        throw Exception("The price list is not on this tablet yet and the server cannot be reached. Log out and log in again once the server is up.");
      }
      rethrow;
    }
  }

  /// Marks an occupied room as checked out and ready for cleaning.
  Future<Map<String, dynamic>> checkoutRoom(String roomName) async {
    return _resilientRequest(
      method: "POST",
      path: "/counter/checkout-room/",
      queryParams: {"room_number": roomName},
      description: "Checkout for $roomName",
    );
  }

  /// Marks a dirty room as clean and available again.
  Future<Map<String, dynamic>> cleanRoom(String roomName) async {
    return _resilientRequest(
      method: "POST",
      path: "/counter/clean-room/",
      queryParams: {"room_number": roomName},
      description: "Mark $roomName clean",
    );
  }

  /// The single Cancel action for a booking. The server itself decides
  /// whether this undoes the newest extension or the booking as a whole —
  /// see execute_one_tap_cancellation on the server — so this method has
  /// no separate "which one" argument to get wrong.
  ///
  /// [bookingId] is null for a booking that was made while the server was
  /// down and has not reached the server yet: it has no number, so it is
  /// cancelled by its room instead (the server finds that room's active
  /// booking and runs the very same cancel). The room name is always sent
  /// along as well, so the tablet can tell which room a saved cancel
  /// belongs to and show that room correctly straight away.
  Future<Map<String, dynamic>> cancelBooking({int? bookingId, required String roomName}) async {
    if (bookingId == null) {
      return _resilientRequest(
        method: "POST",
        path: "/counter/cancel-room-booking/",
        queryParams: {"room_number": roomName},
        description: "Cancel for $roomName",
      );
    }
    return _resilientRequest(
      method: "POST",
      path: "/bookings/$bookingId/cancel/",
      queryParams: {"room_number": roomName},
      description: "Cancel for booking #$bookingId ($roomName)",
    );
  }

  /// Adds extra time onto an already-occupied or time-expired booking.
  ///
  /// As with cancelBooking, a null [bookingId] means a booking the server
  /// has not received yet, so it is extended by its room instead.
  Future<Map<String, dynamic>> extendStay({
    int? bookingId,
    required String roomName,
    required int additionalHours,
    required String paymentMode,
    required double cashTendered,
    required double changeReturned,
    double? usdReceived,
    String? momoNumber,
    String? bankSenderAccount,
  }) async {
    return _resilientRequest(
      method: "POST",
      path: bookingId == null ? "/counter/extend-room-booking/" : "/bookings/$bookingId/extend/",
      jsonBodyFields: {
        // Always sent: names the room for the by-room route, and lets the
        // tablet recognise which room a saved extension belongs to.
        "room_number": roomName,
        "additional_hours": additionalHours,
        "payment_mode": paymentMode,
        "cash_tendered": cashTendered,
        "change_returned": changeReturned,
        if (usdReceived != null) "usd_received": usdReceived,
        if (paymentMode == "MOMO") "momo_number": momoNumber,
        if (paymentMode == "BANK") "bank_sender_account": bankSenderAccount,
      },
      description: "Extend $roomName by $additionalHours hours",
    );
  }

  /// Records a single counter shop item sale.
  Future<Map<String, dynamic>> submitShopSaleItem({
    required String itemName,
    required int quantity,
    required double unitPrice,
    required String paymentMode,
    required double cashTendered,
    required double changeReturned,
    double? usdReceived,
    String? momoNumber,
    String? bankSenderAccount,
  }) async {
    return _resilientRequest(
      method: "POST",
      path: "/shop/sale/",
      jsonBodyFields: {
        "item_name": itemName,
        "quantity": quantity,
        "unit_price": unitPrice,
        "payment_mode": paymentMode,
        "cash_tendered": cashTendered,
        "change_returned": changeReturned,
        if (usdReceived != null) "usd_received": usdReceived,
        if (paymentMode == "MOMO") "momo_number": momoNumber,
        if (paymentMode == "BANK") "bank_sender_account": bankSenderAccount,
      },
      description: "Shop sale: $quantity x $itemName",
    );
  }

  /// Fetches every item sold during the currently active shift.
  Future<List<dynamic>> fetchTodaysShopSales() async {
    if (_authToken == null) throw Exception("Session unauthorized. Access token invalid.");
    final response = await http.get(
      Uri.parse("$baseUrl/shop/sales/today/"),
      headers: {"Authorization": "Bearer $_authToken"},
    ).timeout(const Duration(seconds: 5));
    _checkForSessionEnded(response);
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data['sales'] as List<dynamic>;
    }
    throw Exception("Could not load today's sales.");
  }

  // ------------------------------------------------------------------
  // MANAGER ACTIONS
  // Every manager action lives here, so each one shares the same
  // offline-resilient path as every receptionist action — the manager's
  // work is just as important to keep running when the router is down.
  // ------------------------------------------------------------------

  /// Fetches the real, current list of rooms.
  Future<List<dynamic>> fetchAllRooms() async {
    if (_authToken == null) throw Exception("Session unauthorized. Access token invalid.");
    final response = await http.get(
      Uri.parse("$baseUrl/management/rooms/"),
      headers: {"Authorization": "Bearer $_authToken"},
    ).timeout(const Duration(seconds: 5));
    _checkForSessionEnded(response);
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data['rooms'] as List<dynamic>;
    }
    throw Exception("Could not load the room list.");
  }

  Future<Map<String, dynamic>> addRoom({required String roomName, required String description}) async {
    return _resilientRequest(
      method: "POST",
      path: "/management/rooms/",
      jsonBodyFields: {"room_name": roomName, "description": description},
      description: "Add room $roomName",
    );
  }

  Future<Map<String, dynamic>> editRoom({required String roomId, required String description}) async {
    return _resilientRequest(
      method: "PATCH",
      path: "/management/rooms/$roomId",
      jsonBodyFields: {"description": description},
      description: "Edit room $roomId",
    );
  }

  Future<Map<String, dynamic>> deleteRoom({required String roomId}) async {
    return _resilientRequest(
      method: "DELETE",
      path: "/management/rooms/$roomId",
      description: "Delete room $roomId",
    );
  }

  Future<Map<String, dynamic>> setPricingForDescription({
    required String description,
    required int durationHours,
    required double price,
  }) async {
    return _resilientRequest(
      method: "POST",
      path: "/management/room-pricing/by-description/",
      jsonBodyFields: {"description": description, "duration_hours": durationHours, "price": price},
      description: "Set price for '$description' rooms: $durationHours hours",
    );
  }

  Future<Map<String, dynamic>> removePricingForDescription({
    required String description,
    required int durationHours,
  }) async {
    return _resilientRequest(
      method: "DELETE",
      path: "/management/room-pricing/by-description/",
      queryParams: {"description": description, "duration_hours": durationHours.toString()},
      description: "Remove price for '$description' rooms: $durationHours hours",
    );
  }

  /// Fetches the real, current list of active employees.
  Future<List<dynamic>> fetchAllEmployees() async {
    if (_authToken == null) throw Exception("Session unauthorized. Access token invalid.");
    final response = await http.get(
      Uri.parse("$baseUrl/management/employees/"),
      headers: {"Authorization": "Bearer $_authToken"},
    ).timeout(const Duration(seconds: 5));
    _checkForSessionEnded(response);
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data['employees'] as List<dynamic>;
    }
    throw Exception("Could not load the staff list.");
  }

  /// Onboards a new employee. username and password are only used, and
  /// only required, when role is "Receptionist" — this is what creates
  /// their login at the same time as their staff record.
  Future<Map<String, dynamic>> addEmployee({
    required String employeeName,
    required String role,
    required double monthlySalary,
    String? username,
    String? password,
  }) async {
    return _resilientRequest(
      method: "POST",
      path: "/management/employees/",
      jsonBodyFields: {
        "employee_name": employeeName,
        "role": role,
        "monthly_salary": monthlySalary,
        if (username != null) "username": username,
        if (password != null) "password": password,
      },
      description: "Onboard employee $employeeName",
    );
  }

  /// username and password are only used, and only required, when role is
  /// being changed TO "Receptionist" for someone who does not already have
  /// a working login — the server prompts for this the same way
  /// onboarding does, and reuses this person's own retired login instead
  /// of creating a new one if they had been a receptionist before.
  Future<Map<String, dynamic>> editEmployee({
    required int employeeId,
    required String role,
    required double monthlySalary,
    String? username,
    String? password,
  }) async {
    return _resilientRequest(
      method: "PATCH",
      path: "/management/employees/$employeeId",
      jsonBodyFields: {
        "role": role,
        "monthly_salary": monthlySalary,
        if (username != null) "username": username,
        if (password != null) "password": password,
      },
      description: "Edit employee #$employeeId",
    );
  }

  Future<Map<String, dynamic>> deleteEmployee({required int employeeId}) async {
    return _resilientRequest(
      method: "DELETE",
      path: "/management/employees/$employeeId",
      description: "Deactivate employee #$employeeId",
    );
  }

  /// Builds the period part of a Records/Summary request: a fixed calendar
  /// period ("daily", "weekly", "monthly" or "yearly" — Sunday to Saturday
  /// for weekly, the real calendar month and year for the others), or a
  /// Custom startDate/endDate pair (each "yyyy-MM-dd"). Quarterly and
  /// half-year views are simply Custom ranges.
  String _periodQuery({String? period, String? startDate, String? endDate}) {
    if (period != null) return "period=$period";
    return "start_date=$startDate&end_date=$endDate";
  }

  /// Money Brought In for one employee: their own bookings, extensions and
  /// shop sales over the chosen period, each with how it was paid (cash,
  /// dollars with the cedi equivalent, or MoMo with the amount and number).
  ///
  /// Leave [employeeId] out to get the Buffer chip: everything booked or
  /// sold under the shared Buffer login.
  Future<Map<String, dynamic>> fetchMoneyBroughtIn({
    int? employeeId,
    String? period,
    String? startDate,
    String? endDate,
  }) async {
    if (_authToken == null) throw Exception("Session unauthorized. Access token invalid.");
    final params = _periodQuery(period: period, startDate: startDate, endDate: endDate);
    final response = await http.get(
      Uri.parse(employeeId == null
          ? "$baseUrl/management/buffer/money-brought-in/?$params"
          : "$baseUrl/management/employees/$employeeId/money-brought-in/?$params"),
      headers: {"Authorization": "Bearer $_authToken"},
    ).timeout(const Duration(seconds: 8));
    _checkForSessionEnded(response);
    if (response.statusCode == 200) return jsonDecode(response.body);
    throw Exception("Could not load this employee's figures.");
  }

  /// The Guest Log half of the Records tab: every booking in the chosen
  /// period, each carrying its own extensions, with the list of shifts they
  /// belong to ("guests" and "shifts"). Searching is done on the screen over
  /// everything it shows, so nothing is sent for it here.
  Future<Map<String, dynamic>> fetchGuestLog({
    String? period,
    String? startDate,
    String? endDate,
  }) async {
    if (_authToken == null) throw Exception("Session unauthorized. Access token invalid.");
    final params = _periodQuery(period: period, startDate: startDate, endDate: endDate);
    final response = await http.get(
      Uri.parse("$baseUrl/records/guest-log/?$params"),
      headers: {"Authorization": "Bearer $_authToken"},
    ).timeout(const Duration(seconds: 8));
    _checkForSessionEnded(response);
    if (response.statusCode == 200) return Map<String, dynamic>.from(jsonDecode(response.body));
    throw Exception("Could not load the Guest Log right now.");
  }

  /// The Login Record half of the Records tab: every login attempt in the
  /// chosen period, newest first, with failed attempts and logins from an
  /// unexpected kind of device carrying a plain note.
  Future<List<dynamic>> fetchLoginRecords({
    String? period,
    String? startDate,
    String? endDate,
  }) async {
    if (_authToken == null) throw Exception("Session unauthorized. Access token invalid.");
    final params = _periodQuery(period: period, startDate: startDate, endDate: endDate);
    final response = await http.get(
      Uri.parse("$baseUrl/management/login-records/?$params"),
      headers: {"Authorization": "Bearer $_authToken"},
    ).timeout(const Duration(seconds: 8));
    _checkForSessionEnded(response);
    if (response.statusCode == 200) return jsonDecode(response.body)['records'] as List<dynamic>;
    throw Exception("Could not load the Login Record right now.");
  }

  /// The manager's cancel from the Records screen. It takes effect on the
  /// server straight away, so it is never saved for later: if the server
  /// cannot be reached the manager is told so and nothing has changed.
  Future<Map<String, dynamic>> managerCancelBooking(int bookingId) async {
    return _managerBookingAction(bookingId, "manager-cancel");
  }

  /// Reverses a manager cancel (see managerCancelBooking).
  Future<Map<String, dynamic>> managerRestoreBooking(int bookingId) async {
    return _managerBookingAction(bookingId, "manager-restore");
  }

  /// Cancels one extension from the Records screen, the same way a whole
  /// booking is cancelled (see managerCancelBooking).
  Future<Map<String, dynamic>> managerCancelExtension(int extensionId) async {
    return _managerBookingAction(extensionId, "manager-cancel", area: "extensions");
  }

  /// Reverses a manager cancel of one extension.
  Future<Map<String, dynamic>> managerRestoreExtension(int extensionId) async {
    return _managerBookingAction(extensionId, "manager-restore", area: "extensions");
  }

  Future<Map<String, dynamic>> _managerBookingAction(int bookingId, String action, {String area = "bookings"}) async {
    if (_authToken == null) throw Exception("Session unauthorized. Access token invalid.");
    http.Response response;
    try {
      response = await http.post(
        Uri.parse("$baseUrl/management/$area/$bookingId/$action/"),
        headers: {"Authorization": "Bearer $_authToken"},
      ).timeout(const Duration(seconds: 8));
    } catch (_) {
      throw Exception("The server cannot be reached right now. Nothing was changed.");
    }
    _checkForSessionEnded(response);
    final dynamic body = response.body.isEmpty ? <String, dynamic>{} : jsonDecode(response.body);
    if (response.statusCode == 200) return Map<String, dynamic>.from(body);
    throw Exception(body is Map && body['detail'] != null ? body['detail'].toString() : "The server refused this.");
  }

  /// The Shop Sales half of the Records tab: every counter sale in the
  /// chosen period, with who sold it and how it was paid, and the list of
  /// shifts they belong to ("sales" and "shifts").
  Future<Map<String, dynamic>> fetchShopSalesRecord({
    String? period,
    String? startDate,
    String? endDate,
  }) async {
    if (_authToken == null) throw Exception("Session unauthorized. Access token invalid.");
    final params = _periodQuery(period: period, startDate: startDate, endDate: endDate);
    final response = await http.get(
      Uri.parse("$baseUrl/records/shop-sales/?$params"),
      headers: {"Authorization": "Bearer $_authToken"},
    ).timeout(const Duration(seconds: 8));
    _checkForSessionEnded(response);
    if (response.statusCode == 200) return Map<String, dynamic>.from(jsonDecode(response.body));
    throw Exception("Could not load Shop Sales right now.");
  }

  /// Uploads an employee's passport photo. Takes the image as raw bytes,
  /// rather than a file path, since a path is not something Flutter Web
  /// can hand back at all — the browser only ever exposes the picked
  /// image's actual data, which is what this needs regardless of
  /// platform. File uploads are not queued offline like other actions —
  /// reliably queuing a binary file for background retry needs different
  /// handling than a small JSON action, so this one still fails
  /// immediately (with a clear error) if the server cannot be reached,
  /// rather than silently claiming success.
  Future<Map<String, dynamic>> uploadEmployeePhoto({
    required int employeeId,
    required Uint8List photoBytes,
    required String fileName,
  }) async {
    if (_authToken == null) throw Exception("Session unauthorized. Access token invalid.");
    final request = http.MultipartRequest(
      "POST",
      Uri.parse("$baseUrl/management/employees/$employeeId/photo/"),
    );
    request.headers["Authorization"] = "Bearer $_authToken";
    request.files.add(http.MultipartFile.fromBytes("photo", photoBytes, filename: fileName));

    final streamedResponse = await request.send().timeout(const Duration(seconds: 15));
    final response = await http.Response.fromStream(streamedResponse);
    _checkForSessionEnded(response);

    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      Map<String, dynamic> errorLog = {};
      try {
        errorLog = jsonDecode(response.body);
      } catch (_) {}
      throw Exception(errorLog['detail'] ?? "Could not upload the photo right now.");
    }
  }

  /// Fetches every logged Utilities and Expendables entry.
  Future<List<dynamic>> fetchDailyExpenses() async {
    if (_authToken == null) throw Exception("Session unauthorized. Access token invalid.");
    final response = await http.get(
      Uri.parse("$baseUrl/expenses/"),
      headers: {"Authorization": "Bearer $_authToken"},
    ).timeout(const Duration(seconds: 5));
    _checkForSessionEnded(response);
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data['expenses'] as List<dynamic>;
    }
    throw Exception("Could not load the expense list.");
  }

  Future<Map<String, dynamic>> addExpense({
    required String itemOrReason,
    required double amountSpent,
    required String category,
  }) async {
    return _resilientRequest(
      method: "POST",
      path: "/expenses/",
      jsonBodyFields: {"item_or_reason": itemOrReason, "amount_spent": amountSpent, "category": category},
      description: "Log expense: $itemOrReason",
    );
  }

  Future<Map<String, dynamic>> editExpense({
    required int expenseId,
    required String itemOrReason,
    required double amountSpent,
  }) async {
    return _resilientRequest(
      method: "PATCH",
      path: "/expenses/$expenseId",
      jsonBodyFields: {"item_or_reason": itemOrReason, "amount_spent": amountSpent},
      description: "Edit expense #$expenseId",
    );
  }

  Future<Map<String, dynamic>> deleteExpense({required int expenseId}) async {
    return _resilientRequest(
      method: "DELETE",
      path: "/expenses/$expenseId",
      description: "Delete expense #$expenseId",
    );
  }

  /// The Change Login screen: changes an employee's username, password,
  /// or both. managerPassword confirms the manager's own identity.
  /// isTemporaryPassword marks a handed-out password as one the
  /// receptionist must replace at their next login.
  Future<Map<String, dynamic>> changeLogin({
    required String targetUsername,
    String? newUsername,
    String? newPassword,
    bool isTemporaryPassword = false,
    required String managerPassword,
  }) async {
    return _resilientRequest(
      method: "POST",
      path: "/management/change-login/",
      jsonBodyFields: {
        "target_username": targetUsername,
        if (newUsername != null) "new_username": newUsername,
        if (newPassword != null) "new_password": newPassword,
        "is_temporary_password": isTemporaryPassword,
        "manager_password": managerPassword,
      },
      description: "Change login for $targetUsername",
    );
  }

  Future<Map<String, dynamic>> fetchCurrentShiftState() async {
    if (_authToken == null) throw Exception("Session unauthorized. Access token invalid.");
    final response = await http.get(
      Uri.parse("$baseUrl/sessions/current/"),
      headers: {"Authorization": "Bearer $_authToken"},
    ).timeout(const Duration(seconds: 5));
    _checkForSessionEnded(response);
    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    }
    throw Exception("The server did not return the current shift state.");
  }

  Future<Map<String, dynamic>> closeShift() async {
    return _resilientRequest(
      method: "POST",
      path: "/sessions/close/",
      description: "Close shift",
    );
  }

  Future<Map<String, dynamic>> openShift() async {
    return _resilientRequest(
      method: "POST",
      path: "/sessions/open-main/",
      description: "Open new shift",
    );
  }

  /// Saves a freshly looked-up exchange rate onto the server. Called only
  /// from the manager's app; see lookUpAndSaveLiveExchangeRate above.
  Future<Map<String, dynamic>> setExchangeRate(double usdToGhsRate) async {
    return _resilientRequest(
      method: "POST",
      path: "/sessions/exchange-rate/",
      jsonBodyFields: {"usd_to_ghs_rate": usdToGhsRate},
      description: "Save exchange rate",
    );
  }

  /// Reads and saves where the shift backup file, employee photos, and the
  /// dated database copy are written on the server's own computer.
  Future<String> fetchBackupFolder() async {
    if (_authToken == null) throw Exception("Session unauthorized. Access token invalid.");
    final response = await http.get(
      Uri.parse("$baseUrl/settings/backup-folder/"),
      headers: {"Authorization": "Bearer $_authToken"},
    ).timeout(const Duration(seconds: 5));
    _checkForSessionEnded(response);
    if (response.statusCode == 200) {
      return jsonDecode(response.body)['backup_folder'] ?? "backups";
    }
    throw Exception("Could not load the backup folder setting.");
  }

  Future<Map<String, dynamic>> setBackupFolder(String backupFolder) async {
    return _resilientRequest(
      method: "POST",
      path: "/settings/backup-folder/",
      jsonBodyFields: {"backup_folder": backupFolder},
      description: "Set backup folder",
    );
  }
}
