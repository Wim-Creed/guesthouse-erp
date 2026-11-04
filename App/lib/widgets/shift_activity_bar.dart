import 'package:flutter/material.dart';

import '../services/api_service.dart';
import 'status_colors.dart';

/// "What has happened so far this shift", for the receptionist's screens.
///
/// Two small chips sit at the left, under the gold bar: how many bookings
/// have been made this shift (an extension counts as a booking) and how many
/// shop sales have been made and what they came to. Each covers the WHOLE
/// shift, whoever made the entries. Tapping a chip opens a short list
/// directly beneath it:
///
///   - Bookings: one line per booking or extension with the room, the hours
///     and the price.
///   - Sales: one line per item with the quantity and the total price.
///
/// No name is ever shown. A person at the front desk can see what the shift
/// has taken in without seeing how much any one colleague brought in, and
/// the manager's screens stay closed to them.
///
/// Anything this tablet has saved but the server has not yet received is
/// already included in these lists (see ApiService.refreshShiftActivity), so
/// they stay right while the server is down.
///
/// Colours here are design colours only (navy, black, gold, white); none of
/// the status colours (green, red, grey, amber) are used.
class ShiftActivityBar extends StatefulWidget {
  final ApiService apiService;

  const ShiftActivityBar({super.key, required this.apiService});

  @override
  State<ShiftActivityBar> createState() => _ShiftActivityBarState();
}

enum _OpenPanel { none, bookings, sales }

class _ShiftActivityBarState extends State<ShiftActivityBar> {
  static const Color _gold = Color(0xffd4af37);

  /// The widest a drop-down list is allowed to be, so it stays a small
  /// panel under its chip however large the screen is.
  static const double _panelMaxWidth = 340;

  /// The tallest a drop-down list is allowed to be before it scrolls.
  static const double _panelMaxHeight = 220;

  _OpenPanel _open = _OpenPanel.none;

  void _toggle(_OpenPanel panel) => setState(() => _open = _open == panel ? _OpenPanel.none : panel);

  String _cedis(double amount) => "₵ ${amount.toStringAsFixed(2)}";

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ShiftActivity?>(
      valueListenable: widget.apiService.shiftActivity,
      builder: (context, activity, _) {
        final int bookings = activity?.bookingsTotal ?? 0;
        final int sales = activity?.salesTotal ?? 0;
        final double salesAmount = activity?.salesAmount ?? 0;

        return Container(
          width: double.infinity,
          color: const Color(0xff0a1426),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 10,
                runSpacing: 6,
                children: [
                  _SummaryChip(
                    icon: Icons.bed_outlined,
                    text: "$bookings ${bookings == 1 ? 'booking' : 'bookings'}",
                    isOpen: _open == _OpenPanel.bookings,
                    onTap: () => _toggle(_OpenPanel.bookings),
                  ),
                  _SummaryChip(
                    icon: Icons.shopping_bag_outlined,
                    text: "$sales ${sales == 1 ? 'sale' : 'sales'} · ${_cedis(salesAmount)}",
                    isOpen: _open == _OpenPanel.sales,
                    onTap: () => _toggle(_OpenPanel.sales),
                  ),
                ],
              ),
              if (_open == _OpenPanel.bookings)
                _buildPanel(
                  (activity?.bookings ?? const <ShiftBookingLine>[])
                      .map((line) => _PanelLine(
                            left: "${line.room} · ${line.hours} ${line.hours == 1 ? 'hour' : 'hours'}${line.isExtension ? ' · Extension' : ''}",
                            right: _cedis(line.price),
                          ))
                      .toList(),
                  "No bookings yet this shift.",
                ),
              if (_open == _OpenPanel.sales)
                _buildPanel(
                  (activity?.sales ?? const <ShiftSaleLine>[])
                      .map((line) => _PanelLine(
                            left: "${line.item} × ${line.quantity}",
                            right: _cedis(line.total),
                          ))
                      .toList(),
                  "Nothing sold yet this shift.",
                ),
            ],
          ),
        );
      },
    );
  }

  /// The drop-down: one line per entry, small, and aligned to the left under
  /// the chips.
  Widget _buildPanel(List<_PanelLine> lines, String emptyMessage) {
    return Container(
      margin: const EdgeInsets.only(top: 6),
      constraints: const BoxConstraints(maxWidth: _panelMaxWidth, maxHeight: _panelMaxHeight),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: StatusColors.softBlack,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _gold.withValues(alpha: 0.5), width: 0.6),
      ),
      child: lines.isEmpty
          ? Text(emptyMessage, style: const TextStyle(fontSize: 12, color: Colors.white54))
          : SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: lines
                    .map((line) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: Text(line.left, style: const TextStyle(fontSize: 13, color: Colors.white), overflow: TextOverflow.ellipsis),
                              ),
                              const SizedBox(width: 12),
                              Text(line.right, style: const TextStyle(fontSize: 13, color: Colors.white70)),
                            ],
                          ),
                        ))
                    .toList(),
              ),
            ),
    );
  }
}

/// One line of a drop-down: what it was, and what it came to.
class _PanelLine {
  final String left;
  final String right;

  const _PanelLine({required this.left, required this.right});
}

/// One tappable summary chip: black, thin gold edge, a small arrow that
/// turns over when its list is open. It is only as wide as its words.
class _SummaryChip extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool isOpen;
  final VoidCallback onTap;

  const _SummaryChip({required this.icon, required this.text, required this.isOpen, required this.onTap});

  @override
  Widget build(BuildContext context) {
    // Its own Material, so the tap ripple is drawn and Flutter never prints
    // the "ink splashes may be invisible" warning.
    return Material(
      color: StatusColors.softBlack,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xffd4af37), width: 0.8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: const Color(0xffd4af37)),
              const SizedBox(width: 8),
              Text(text, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white)),
              const SizedBox(width: 4),
              Icon(isOpen ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down, size: 18, color: Colors.white70),
            ],
          ),
        ),
      ),
    );
  }
}
