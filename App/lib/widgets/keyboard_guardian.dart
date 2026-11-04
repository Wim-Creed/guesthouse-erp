import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

/// Makes the on-screen keyboard appear AT ONCE whenever a text field gets
/// the cursor — including a field that was focused automatically when a
/// screen or dialog opened.
///
/// Why this exists: on the receptionist's tablet, Flutter often gives an
/// autofocused field the cursor but never asks Android to show the
/// keyboard, so the receptionist has to tap the field again. This widget
/// is wrapped around the whole app once. It listens for focus moving to a
/// text field and, after the first frame, explicitly asks the system to
/// show the keyboard. It asks a second time a moment later, because a
/// dialog or page that is still sliding into place can swallow the first
/// request. Asking for a keyboard that is already showing does nothing.
///
/// Read-only fields (date pickers, for example) are skipped, so they do
/// not pop a keyboard up.
class KeyboardGuardian extends StatefulWidget {
  final Widget child;

  const KeyboardGuardian({super.key, required this.child});

  @override
  State<KeyboardGuardian> createState() => _KeyboardGuardianState();
}

class _KeyboardGuardianState extends State<KeyboardGuardian> {
  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onFocusChanged);
    super.dispose();
  }

  /// True when the field that currently has the cursor is a real,
  /// editable text field.
  bool _focusIsOnEditableText() {
    final BuildContext? focusedContext = FocusManager.instance.primaryFocus?.context;
    if (focusedContext == null) return false;
    final EditableText? editable = focusedContext.findAncestorWidgetOfExactType<EditableText>();
    return editable != null && !editable.readOnly;
  }

  void _showKeyboardIfStillOnTextField() {
    if (!mounted || !_focusIsOnEditableText()) return;
    SystemChannels.textInput.invokeMethod<void>('TextInput.show');
  }

  void _onFocusChanged() {
    if (!_focusIsOnEditableText()) return;
    SchedulerBinding.instance.addPostFrameCallback((_) => _showKeyboardIfStillOnTextField());
    Future<void>.delayed(const Duration(milliseconds: 250), _showKeyboardIfStillOnTextField);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
