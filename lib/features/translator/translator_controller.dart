import 'package:flutter/material.dart';

import 'translator_service.dart';

enum TypingAction { armed, disarmed, translated, restored, unchanged, ignored }

/// What to actually send, plus the untouched original when [text] is a
/// translation (store it, e.g. as `originalText`, so it stays reversible).
class TranslatedSend {
  final String text;
  final String? original;
  const TranslatedSend(this.text, this.original);
}

/// Per-input state for typing translation. Original text is kept here,
/// separate from the text field, so restore is always exact.
class TranslatorController extends ChangeNotifier {
  TranslatorController(this.input) {
    input.addListener(_onInput);
  }

  final TextEditingController input;
  bool _armed = false; // icon on the left: translate on send
  bool _busy = false;
  bool _disposed = false;
  String? _original; // exact text before in-field translation

  bool get armed => _armed;
  bool get busy => _busy;
  bool get canRestore => _original != null;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _setBusy(bool v) {
    _busy = v;
    _notify();
  }

  void _setText(String t) => input.value =
      TextEditingValue(text: t, selection: TextSelection.collapsed(offset: t.length));

  // Field emptied (message sent / cleared) -> nothing left to restore.
  void _onInput() {
    if (_original != null && !_busy && input.text.isEmpty) {
      _original = null;
      _notify();
    }
  }

  Future<TranslationResult> _one(String t) async =>
      (await TranslatorService.translate([t.trim()])).first;

  /// Swipe on the icon.
  /// restore (if translated) > arm/disarm (if field empty) > translate field.
  Future<TypingAction> onSwipe() async {
    if (_busy) return TypingAction.ignored;
    final o = _original;
    if (o != null) {
      _original = null;
      _setText(o);
      _notify();
      return TypingAction.restored;
    }
    final text = input.text;
    if (text.trim().isEmpty) {
      _armed = !_armed;
      _notify();
      return _armed ? TypingAction.armed : TypingAction.disarmed;
    }
    _setBusy(true);
    try {
      final r = await _one(text);
      if (input.text != text) return TypingAction.ignored; // user kept typing
      if (r.text.trim().isEmpty || r.text.trim() == text.trim()) {
        _armed = false;
        return TypingAction.unchanged;
      }
      _original = text;
      _setText(r.text);
      _armed = false;
      return TypingAction.translated;
    } finally {
      _setBusy(false);
    }
  }

  /// Call right before sending [text]. Throws [TranslatorException] on
  /// failure - then do NOT send and do NOT clear the field.
  Future<TranslatedSend> beforeSend(String text) async {
    final o = _original;
    if (o != null) {
      _original = null;
      _notify();
      return TranslatedSend(text, o);
    }
    if (_armed && text.trim().isNotEmpty && !_busy) {
      _setBusy(true);
      try {
        final r = await _one(text);
        final out = r.text.trim().isEmpty ? text : r.text.trim();
        _armed = false;
        return TranslatedSend(out, out == text.trim() ? null : text);
      } finally {
        _setBusy(false);
      }
    }
    return TranslatedSend(text, null);
  }

  @override
  void dispose() {
    _disposed = true;
    try {
      input.removeListener(_onInput);
    } catch (_) {}
    super.dispose();
  }
}
