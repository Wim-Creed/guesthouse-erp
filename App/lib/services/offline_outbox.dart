import 'dart:convert';
import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// One write action that could not be confirmed by the server yet,
/// either because it is still waiting for its first retry attempt, or
/// because the server was reachable but genuinely rejected it and a
/// person needs to look at it.
class PendingAction {
  final String clientActionId;
  final String method;
  final String url;
  final Map<String, String> headers;
  final String body;
  final DateTime queuedAt;
  final String description;

  PendingAction({
    required this.clientActionId,
    required this.method,
    required this.url,
    required this.headers,
    required this.body,
    required this.queuedAt,
    required this.description,
  });

  Map<String, dynamic> toJson() => {
        "clientActionId": clientActionId,
        "method": method,
        "url": url,
        "headers": headers,
        "body": body,
        "queuedAt": queuedAt.toIso8601String(),
        "description": description,
      };

  factory PendingAction.fromJson(Map<String, dynamic> json) {
    return PendingAction(
      clientActionId: json["clientActionId"],
      method: json["method"],
      url: json["url"],
      headers: Map<String, String>.from(json["headers"]),
      body: json["body"],
      queuedAt: DateTime.parse(json["queuedAt"]),
      description: json["description"],
    );
  }
}

/// Holds every write action taken anywhere in the app that the server
/// could not be reached to confirm at the moment it was attempted.
///
/// Business is never supposed to stop because the router is down: when an
/// action cannot reach the server, it is saved here immediately, the
/// screen is told to treat it as successful right away, and this outbox
/// quietly keeps retrying it in the background — oldest action first —
/// until the server actually confirms it. The server's own one-time
/// action tag (client_action_id) means a retried action can never be
/// saved twice, even if an earlier attempt actually did reach the server
/// but its confirmation never made it back to the tablet.
///
/// A genuine rejection from a server that IS reachable (wrong password,
/// room already occupied, insufficient cash) is a different situation
/// entirely and is never placed in this retry queue — see failedActions
/// below for those.
class OfflineOutbox {
  OfflineOutbox._internal();
  static final OfflineOutbox instance = OfflineOutbox._internal();

  static const String _pendingStorageKey = "offline_outbox_pending_actions";
  static const String _failedStorageKey = "offline_outbox_failed_actions";

  Timer? _autoFlushTimer;
  bool _isFlushingNow = false;

  /// Set once by ApiService at startup. Returns whatever Authorization
  /// header this device's CURRENT login should use right now, or null if
  /// nobody is logged in on this device at the moment.
  ///
  /// A queued action's own saved header is only ever a snapshot from the
  /// moment it was made — if the tablet is offline for longer than a
  /// login token's life, that saved header goes stale and every action
  /// queued during the outage would otherwise come back "not logged in"
  /// the moment the connection returns, even though nothing about the
  /// action itself was wrong. Asking for the freshest header at send
  /// time, right before each attempt, avoids that: as long as someone is
  /// currently logged in on this device (the original receptionist or
  /// whoever is on shift now), the queue sends successfully. Who actually
  /// gets credited for the action is decided separately, from
  /// acted_by_username already baked into the saved request body — this
  /// only affects whose login is used to authenticate the HTTP call.
  Map<String, String>? Function()? authHeaderProvider;

  /// Serializes every read-modify-write against the stored lists below,
  /// so a save started by flushQueue can never overwrite a save started
  /// by enqueuePending (or vice versa) that happened to land in the
  /// middle of it. Without this, a booking queued at the exact moment
  /// the background flush was already mid-flight could be silently lost
  /// — the flush would finish and write back a list that never included
  /// it.
  Future<void> _storageLock = Future.value();

  Future<T> _withStorageLock<T>(Future<T> Function() action) {
    final previousLock = _storageLock;
    final completer = Completer<void>();
    _storageLock = completer.future;
    return previousLock.then((_) async {
      try {
        return await action();
      } finally {
        completer.complete();
      }
    });
  }

  /// Starts the background retry loop. Safe to call more than once; only
  /// one loop ever runs at a time.
  void startAutoFlush({Duration interval = const Duration(seconds: 15)}) {
    _autoFlushTimer?.cancel();
    _autoFlushTimer = Timer.periodic(interval, (_) => flushQueue());
  }

  void stopAutoFlush() {
    _autoFlushTimer?.cancel();
    _autoFlushTimer = null;
  }

  Future<List<PendingAction>> _loadList(String storageKey) async {
    final prefs = await SharedPreferences.getInstance();
    final rawList = prefs.getString(storageKey);
    if (rawList == null) return [];
    final decoded = jsonDecode(rawList) as List<dynamic>;
    return decoded.map((entry) => PendingAction.fromJson(entry)).toList();
  }

  Future<void> _saveList(String storageKey, List<PendingAction> actions) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(storageKey, jsonEncode(actions.map((a) => a.toJson()).toList()));
  }

  Future<List<PendingAction>> pendingActions() => _loadList(_pendingStorageKey);
  Future<List<PendingAction>> failedActions() => _loadList(_failedStorageKey);

  Future<int> pendingCount() async => (await pendingActions()).length;
  Future<int> failedCount() async => (await failedActions()).length;

  /// Saves a new action that could not reach the server just now, so it
  /// can be retried automatically the next time the queue is flushed.
  Future<void> enqueuePending(PendingAction action) {
    return _withStorageLock(() async {
      final queue = await pendingActions();
      queue.add(action);
      await _saveList(_pendingStorageKey, queue);
    });
  }

  /// Moves an action out of the retry queue and into the failed list,
  /// because the server was reachable but genuinely rejected it. This
  /// stops it from being retried forever, and keeps it visible so a
  /// person can review and decide what to do about it, rather than the
  /// action silently vanishing. Only ever called from inside flushQueue's
  /// own lock, so it does not take the lock itself.
  Future<void> _moveToFailedLocked(PendingAction action, String reason) async {
    final failed = await failedActions();
    failed.add(action);
    await _saveList(_failedStorageKey, failed);
  }

  /// Removes a failed action once a person has reviewed it.
  Future<void> dismissFailedAction(String clientActionId) {
    return _withStorageLock(() async {
      final failed = await failedActions();
      failed.removeWhere((a) => a.clientActionId == clientActionId);
      await _saveList(_failedStorageKey, failed);
    });
  }

  /// Attempts to send every queued action to the server, oldest first.
  ///
  /// Three outcomes for a single action, each handled differently:
  ///   - The server confirms it (2xx): done, drop it from the queue.
  ///   - The server cannot be reached at all, OR is reached but cannot
  ///     currently process it (401 "not logged in right now" — which can
  ///     simply mean nobody has logged back in on this device yet after
  ///     an outage — or a 5xx server-side error): this is not a genuine
  ///     rejection of the action itself, so it stays queued and this pass
  ///     stops, the same as a plain connectivity failure. There is no
  ///     point hammering a server that just proved it cannot handle this
  ///     right now, and a 401/5xx here almost always clears up on its own
  ///     once someone is logged in again or the server catches up.
  ///   - The server is reached and genuinely refuses the action for a
  ///     real reason (bad data, room already occupied, insufficient
  ///     cash — any other 4xx): that is a real rejection, and it moves to
  ///     the failed list so a person can see and deal with it, rather
  ///     than being retried forever or silently dropped.
  Future<void> flushQueue() async {
    if (_isFlushingNow) return;
    _isFlushingNow = true;

    try {
      final queueSnapshot = await pendingActions();
      if (queueSnapshot.isEmpty) return;

      final Set<String> confirmedIds = {};
      bool stopThisPass = false;

      for (final action in queueSnapshot) {
        if (stopThisPass) break;

        try {
          final response = await _sendAction(action).timeout(const Duration(seconds: 8));

          if (response.statusCode >= 200 && response.statusCode < 300) {
            confirmedIds.add(action.clientActionId);
          } else if (response.statusCode == 401 || response.statusCode >= 500) {
            // Not a real rejection — either nobody is currently logged in
            // on this device to authenticate the retry, or the server
            // itself hit trouble. Leave this (and everything after it in
            // this pass) queued for the next attempt.
            stopThisPass = true;
          } else {
            // A real rejection from a server that IS working right now.
            await _moveToFailedLocked(action, response.body);
            confirmedIds.add(action.clientActionId);
          }
        } catch (e) {
          // Could not reach the server at all this time.
          stopThisPass = true;
        }
      }

      if (confirmedIds.isEmpty) return;

      // Re-read the list fresh rather than writing back the snapshot from
      // the top of this function: anything enqueued by another action
      // while this flush was in flight is only visible in a fresh read,
      // and removing just the IDs this pass actually confirmed leaves it
      // untouched instead of silently overwriting it away.
      await _withStorageLock(() async {
        final currentList = await pendingActions();
        currentList.removeWhere((a) => confirmedIds.contains(a.clientActionId));
        await _saveList(_pendingStorageKey, currentList);
      });
    } finally {
      _isFlushingNow = false;
    }
  }

  Future<http.Response> _sendAction(PendingAction action) {
    // Always substitute the freshest available login header rather than
    // trusting the one saved on the action at queue time — see
    // authHeaderProvider above for why.
    final headers = Map<String, String>.from(action.headers);
    final freshAuthHeader = authHeaderProvider?.call();
    if (freshAuthHeader != null) headers.addAll(freshAuthHeader);

    switch (action.method) {
      case "POST":
        return http.post(Uri.parse(action.url), headers: headers, body: action.body);
      case "PATCH":
        return http.patch(Uri.parse(action.url), headers: headers, body: action.body);
      case "DELETE":
        return http.delete(Uri.parse(action.url), headers: headers, body: action.body);
      default:
        throw Exception("Unsupported queued method: ${action.method}");
    }
  }
}
