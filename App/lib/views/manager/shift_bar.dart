import 'dart:async';

import 'package:flutter/material.dart';

// Links to the shared network service tool
import '../../services/api_service.dart';

/// The shift bar, shown at the top of the manager's Dashboard.
///
/// With no official shift open it is a card with the shift state and an
/// Open New Shift button. With a shift active it shrinks to a slim green
/// strip with a small Close Shift button. The current state is always read
/// from the server rather than assumed, and re-read every few seconds,
/// since the shift can also change on its own in the background when the
/// buffer shift takes over between official shifts. Opening or closing a
/// shift still works even if the router is briefly down: it is saved and
/// synced automatically once the connection returns.
class ShiftBar extends StatefulWidget {
  final ApiService apiService;

  /// Called right after a shift is confirmed closed (not when the closure
  /// is merely queued offline: the jump to Business Summary only makes
  /// sense once there is something new for it to show). Wired by the
  /// manager's navigation shell to switch across to the Business Summary
  /// tab automatically.
  final VoidCallback? onShiftClosed;

  const ShiftBar({super.key, required this.apiService, this.onShiftClosed});

  @override
  State<ShiftBar> createState() => _ShiftBarState();
}

class _ShiftBarState extends State<ShiftBar> {
  bool? _isShiftActive;
  bool _isLoadingState = true;
  bool _isProcessingNetworkCall = false;
  String? _loadErrorMessage;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _loadCurrentShiftState();
    _refreshTimer = Timer.periodic(const Duration(seconds: 15), (_) => _loadCurrentShiftState(quietly: true));
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadCurrentShiftState({bool quietly = false}) async {
    if (!quietly) {
      setState(() {
        _isLoadingState = true;
        _loadErrorMessage = null;
      });
    }

    try {
      final data = await widget.apiService.fetchCurrentShiftState();
      if (!mounted) return;
      setState(() {
        _isShiftActive = data['is_official_shift_active'] ?? false;
        _isLoadingState = false;
        _loadErrorMessage = null;
      });
    } catch (e) {
      if (!mounted) return;
      // A background refresh that cannot reach the server keeps showing
      // what was last known.
      if (quietly && _isShiftActive != null) return;
      setState(() {
        _loadErrorMessage = e.toString().replaceAll("Exception: ", "");
        _isLoadingState = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoadingState && _isShiftActive == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 10),
        child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xffd4af37)))),
      );
    }

    if (_loadErrorMessage != null && _isShiftActive == null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                "Could not load shift state: $_loadErrorMessage",
                style: const TextStyle(color: Color(0xffe0584a), fontSize: 12),
              ),
            ),
            TextButton(onPressed: _loadCurrentShiftState, child: const Text("Try Again")),
          ],
        ),
      );
    }

    return (_isShiftActive ?? false) ? _buildActiveStrip() : _buildOpenCard();
  }

  /// A shift is open: one slim green strip with a small Close Shift button.
  Widget _buildActiveStrip() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xff14703f),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          const Icon(Icons.circle, size: 10, color: Colors.white),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              "Shift open",
              style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 13),
            ),
          ),
          TextButton.icon(
            onPressed: _isProcessingNetworkCall ? null : _toggleShiftStateOnServer,
            style: TextButton.styleFrom(
              foregroundColor: Colors.white,
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            icon: _isProcessingNetworkCall
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.lock_clock, size: 16),
            label: const Text("Close Shift", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          ),
        ],
      ),
    );
  }

  /// No official shift is open: the state and the Open New Shift button.
  Widget _buildOpenCard() {
    return Card(
      color: const Color(0xff111f3a),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("Current Shift State:", style: TextStyle(fontSize: 16)),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xffc0392b),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    "NO OFFICIAL SHIFT OPEN",
                    style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xff1e9e5a),
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                ),
                onPressed: _isProcessingNetworkCall ? null : _toggleShiftStateOnServer,
                child: _isProcessingNetworkCall ? _buildLoadingSpinner(false) : _buildButtonContent(false),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadingSpinner(bool isActive) {
    return SizedBox(
      width: 20,
      height: 20,
      child: CircularProgressIndicator(strokeWidth: 2, color: isActive ? Colors.white : Colors.black),
    );
  }

  Widget _buildButtonContent(bool isActive) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(isActive ? Icons.lock_clock : Icons.play_arrow),
        const SizedBox(width: 8),
        Text(
          isActive ? "Close Official Shift" : "Open New Shift",
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ],
    );
  }

  /// Always asks for a plain confirmation before closing a shift, every
  /// time, regardless of what has or hasn't been logged on Daily Costs —
  /// costs may simply be entered later in the day, so a check on them
  /// would mislead. Opening a shift needs no confirmation.
  Future<bool> _confirmCloseShift() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Close this shift?"),
        content: const Text("This closes the current official shift and cannot be undone."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("Cancel")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xffc0392b)),
            onPressed: () => Navigator.pop(context, true),
            child: const Text("Close Shift"),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _toggleShiftStateOnServer() async {
    final bool isActive = _isShiftActive ?? false;

    if (isActive) {
      final bool okToProceed = await _confirmCloseShift();
      if (!okToProceed) return;
    }

    setState(() => _isProcessingNetworkCall = true);

    try {
      final result = isActive ? await widget.apiService.closeShift() : await widget.apiService.openShift();

      final bool wasQueuedOffline = result['queued_offline'] == true;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: wasQueuedOffline ? const Color(0xffc9971f) : const Color(0xff14703f),
            content: Text(
              wasQueuedOffline
                  ? "Saved. Pending, will be sent when the connection returns."
                  : (result["status"] ?? "Shift state updated."),
            ),
          ),
        );
      }

      // Reload the real state from the server rather than assuming the
      // toggle succeeded, since a queued offline action has not actually
      // changed anything on the server yet.
      await _loadCurrentShiftState();

      // Only jump across to Business Summary once the closure is actually
      // confirmed — jumping there for a closure that is still only
      // "pending" would show yesterday's figures and look like nothing
      // happened.
      if (isActive && !wasQueuedOffline) {
        widget.onShiftClosed?.call();
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xffc0392b),
            content: Text("Shift operation failed: ${error.toString().replaceAll("Exception: ", "")}"),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessingNetworkCall = false);
    }
  }
}
