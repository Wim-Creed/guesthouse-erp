import 'dart:async';
import 'package:flutter/material.dart';

import '../services/offline_outbox.dart';

/// A small icon, shown in both the manager and receptionist app bars,
/// that reports how many actions are still waiting to be sent to the
/// server and how many were rejected and need a person's attention.
/// Nothing queued offline should ever be invisible to the people running
/// the business, even though it is handled automatically in the
/// background. The word "Sync" is never used anywhere in this screen —
/// everything waiting is simply called "Pending".
class SyncStatusIndicator extends StatefulWidget {
  const SyncStatusIndicator({super.key});

  @override
  State<SyncStatusIndicator> createState() => _SyncStatusIndicatorState();
}

class _SyncStatusIndicatorState extends State<SyncStatusIndicator> {
  int _pendingCount = 0;
  int _failedCount = 0;
  late Timer _refreshTimer;

  @override
  void initState() {
    super.initState();
    _refreshCounts();
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) => _refreshCounts());
  }

  @override
  void dispose() {
    _refreshTimer.cancel();
    super.dispose();
  }

  Future<void> _refreshCounts() async {
    final pending = await OfflineOutbox.instance.pendingCount();
    final failed = await OfflineOutbox.instance.failedCount();
    if (mounted) {
      setState(() {
        _pendingCount = pending;
        _failedCount = failed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool hasAnything = _pendingCount > 0 || _failedCount > 0;
    if (!hasAnything) {
      // Nothing waiting and nothing failed: stay out of the way entirely.
      return const SizedBox.shrink();
    }

    // This icon lives on the gold top bar, so it is drawn in deep navy
    // (amber would vanish against the gold). The count badge is red when
    // something needs attention and navy when things are just waiting.
    final Color badgeColor = _failedCount > 0 ? const Color(0xffc0392b) : const Color(0xff0b1a33);

    return IconButton(
      tooltip: "Pending",
      icon: Badge(
        label: Text("${_pendingCount + _failedCount}", style: const TextStyle(color: Colors.white)),
        backgroundColor: badgeColor,
        child: Icon(_failedCount > 0 ? Icons.sync_problem : Icons.hourglass_top, color: const Color(0xff0b1a33)),
      ),
      onPressed: () => _showPendingDialog(context),
    );
  }

  void _showPendingDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text("Pending"),
              content: SizedBox(
                width: double.maxFinite,
                child: FutureBuilder(
                  future: Future.wait([
                    OfflineOutbox.instance.pendingActions(),
                    OfflineOutbox.instance.failedActions(),
                  ]),
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xffd4af37))),
                      );
                    }

                    final pending = List<PendingAction>.from(snapshot.data![0]);
                    final failed = List<PendingAction>.from(snapshot.data![1]);

                    return SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (pending.isNotEmpty) ...[
                            const Text("Pending", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white70)),
                            const SizedBox(height: 4),
                            const Text(
                              "Saved. Pending, will be sent when the connection returns.",
                              style: TextStyle(fontSize: 12, color: Colors.white54),
                            ),
                            const SizedBox(height: 8),
                            ...pending.map((action) => Material(type: MaterialType.transparency, child: ListTile(
                                  dense: true,
                                  leading: const Icon(Icons.hourglass_top, color: Color(0xffc9971f), size: 20),
                                  title: Text(action.description),
                                  subtitle: Text("Saved ${_formatWhen(action.queuedAt)}"),
                                ))),
                            const SizedBox(height: 16),
                          ],
                          if (failed.isNotEmpty) ...[
                            const Text("Needs Attention", style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xffc0392b))),
                            const SizedBox(height: 4),
                            const Text(
                              "The server was reached, but rejected these. They will not retry automatically — review and redo them if needed.",
                              style: TextStyle(fontSize: 12, color: Colors.white54),
                            ),
                            const SizedBox(height: 8),
                            ...failed.map((action) => Material(type: MaterialType.transparency, child: ListTile(
                                  dense: true,
                                  leading: const Icon(Icons.error_outline, color: Color(0xffc0392b), size: 20),
                                  title: Text(action.description),
                                  subtitle: Text("Saved ${_formatWhen(action.queuedAt)}"),
                                  trailing: TextButton(
                                    onPressed: () async {
                                      await OfflineOutbox.instance.dismissFailedAction(action.clientActionId);
                                      setDialogState(() {});
                                      _refreshCounts();
                                    },
                                    child: const Text("Dismiss"),
                                  ),
                                ))),
                          ],
                          if (pending.isEmpty && failed.isEmpty)
                            const Text("Everything has been sent.", style: TextStyle(color: Colors.white70)),
                        ],
                      ),
                    );
                  },
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context), child: const Text("Close")),
              ],
            );
          },
        );
      },
    );
  }

  String _formatWhen(DateTime when) {
    final now = DateTime.now();
    final difference = now.difference(when);
    if (difference.inMinutes < 1) return "just now";
    if (difference.inHours < 1) return "${difference.inMinutes}m ago";
    if (difference.inDays < 1) return "${difference.inHours}h ago";
    return "${difference.inDays}d ago";
  }
}
