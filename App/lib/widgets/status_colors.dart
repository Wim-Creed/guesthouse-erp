import 'package:flutter/material.dart';

/// Holds the muted, refined color set used to represent room status
/// throughout the app. Kept in one place so the receptionist's room grid
/// and the manager's read-only room overview always match exactly.
class StatusColors {
  // A deep, vibrant emerald for rooms that are free and ready to book:
  // deep rather than washed out, but not neon.
  static const Color available = Color(0xff1e9e5a);

  // A rich brick red for rooms currently occupied by a guest. Strong enough
  // not to look faded, calm enough not to look like it is bleeding.
  static const Color occupied = Color(0xffc4402e);

  // A warm, subdued amber for rooms whose paid time has run out.
  // Kept visually distinct from the app's brand gold accent color.
  static const Color timeUp = Color(0xffc9971f);

  // A soft slate gray for rooms that need cleaning before reuse.
  static const Color dirty = Color(0xff6b7280);

  // The soft black used for running-total boxes and banners: a deep
  // blue-black, lighter than the canvas behind it so it sits in the navy
  // and gold palette instead of reading as an empty hole. It is black, not
  // grey, and is never used to mean a room's state.
  static const Color softBlack = Color(0xff0e1a31);

  /// Returns the correct status color for a given room status string.
  static Color forStatus(String status) {
    switch (status) {
      case "AVAILABLE":
        return available;
      case "OCCUPIED":
        return occupied;
      case "TIME_UP":
        return timeUp;
      case "DIRTY":
        return dirty;
      default:
        return dirty;
    }
  }
}
