import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../pages/app_theme.dart';
import 'ai_chat_controller.dart';
import 'chat_message.dart';
import 'markdown_text.dart';

/// Compact chat window, mounted inline by AiLauncher.
class AiChatPanel extends StatefulWidget {
  final VoidCallback onClose;
  const AiChatPanel({super.key, required this.onClose});

  /// Responsive size: phone ~360x480, tablet/web up to 400x560, shrinks with keyboard.
  static Size sizeFor(MediaQueryData mq) {
    final wide = mq.size.width >= 600;
    final bottom = math.max(mq.viewInsets.bottom, mq.padding.bottom);
    final avail = mq.size.height - bottom - mq.padding.top - 24;
    final w = math.min(mq.size.width - 24, wide ? 400.0 : 360.0);
    final h = math.max(120.0, math.min(avail, wide ? 560.0 : 480.0));
    return Size(w, h);
  }

  @override
  State<AiChatPanel> createState() => _AiChatPanelState();
}

class _AiChatPanelState extends State<AiChatPanel> {
  final _c = AiChatController.instance;
  final _input = TextEditingController();
  final _scroll = ScrollController();
  late final FocusNode _focus = FocusNode(onKeyEvent: _onKey);
  int _lastCount = 0;
  double _lastInset = 0;

  @override
  void initState() {
    super.initState();
    _c.addListener(_onChange);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _toBottom(jump: true);
      if (kIsWeb && mounted) _focus.requestFocus(); // no auto keyboard on phones
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final i = MediaQuery.viewInsetsOf(context).bottom;
    if (i != _lastInset) {
      _lastInset = i;
      _toBottom(jump: true); // keep latest message visible when keyboard moves
    }
  }

  @override
  void dispose() {
    _c.removeListener(_onChange);
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChange() {
    if (!mounted) return;
    setState(() {});
    if (_c.messages.length != _lastCount || _c.loading) _toBottom();
    _lastCount = _c.messages.length;
  }

  void _toBottom({bool jump = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final max = _scroll.position.maxScrollExtent;
      jump
          ? _scroll.jumpTo(max)
          : _scroll.animateTo(max,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut);
    });
  }

  // Enter = send, Shift+Enter = newline (web/desktop keyboards).
  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    final enter = e.logicalKey == LogicalKeyboardKey.enter ||
        e.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (e is! KeyDownEvent || !enter) return KeyEventResult.ignored;
    if (HardwareKeyboard.instance.isShiftPressed) return KeyEventResult.ignored;
    final comp = _input.value.composing; // IME (e.g. Tamil) still composing
    if (comp.isValid && !comp.isCollapsed) return KeyEventResult.ignored;
    _send();
    return KeyEventResult.handled;
  }

  void _send() {
    final t = _input.text;
    if (t.trim().isEmpty || _c.loading) return;
    _input.clear();
    _c.send(t);
    _focus.requestFocus(); // keep keyboard open for the next message
  }

  void _close() {
    FocusManager.instance.primaryFocus?.unfocus();
    widget.onClose();
  }

  bool get _dark => Theme.of(context).brightness == Brightness.dark;
  Color get _accent => _dark ? AppColors.tan : AppColors.saddleBrown;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final a = _accent;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
      child: Material(
        color: c.bgMid,
        elevation: 12,
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: a.withAlpha(64)),
          ),
          child: Column(
            children: [
              _header(c, a),
              Expanded(child: _body(c, a)),
              _inputBar(c, a),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(AppColorSet c, Color a) => Container(
        color: c.sheet,
        padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
        child: Row(
          children: [
            Icon(Icons.auto_awesome, color: a, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text('Nexus AI',
                  style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
            ),
            IconButton(
              tooltip: 'Clear chat',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.delete_outline, size: 20),
              color: c.textMuted,
              onPressed: (_c.messages.isEmpty || _c.loading) ? null : _c.clear,
            ),
            IconButton(
              tooltip: 'Close',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close, size: 20),
              color: c.textMuted,
              onPressed: _close,
            ),
          ],
        ),
      );

  Widget _body(AppColorSet c, Color a) {
    if (_c.messages.isEmpty && !_c.loading) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Text('Ask me anything about Nexus 👋',
              style: TextStyle(color: c.textMuted, fontSize: 14)),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
      itemCount: _c.messages.length + (_c.loading ? 1 : 0),
      itemBuilder: (_, i) {
        if (i == _c.messages.length) return _typing(c, a);
        final m = _c.messages[i];
        final isLastErr = m.isError && i == _c.messages.length - 1;
        return _Bubble(message: m, onRetry: isLastErr ? _c.retry : null);
      },
    );
  }

  Widget _typing(AppColorSet c, Color a) => Align(
        alignment: Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
              color: c.sheet, borderRadius: BorderRadius.circular(14)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: a)),
            const SizedBox(width: 8),
            Text('Thinking...',
                style: TextStyle(color: c.textMuted, fontSize: 13)),
          ]),
        ),
      );

  Widget _inputBar(AppColorSet c, Color a) => Container(
        color: c.sheet,
        padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _input,
                focusNode: _focus,
                minLines: 1,
                maxLines: 3,
                maxLength: 4000,
                keyboardType: TextInputType.multiline,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                style: TextStyle(color: c.textPrimary, fontSize: 14),
                cursorColor: a,
                decoration: InputDecoration(
                  hintText: 'Ask Nexus AI...',
                  hintStyle: TextStyle(color: c.textMuted),
                  counterText: '',
                  isDense: true,
                  filled: true,
                  fillColor: c.bgMid,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            ListenableBuilder(
              listenable: _input,
              builder: (_, _) => IconButton(
                tooltip: 'Send',
                onPressed: (_c.loading || _input.text.trim().isEmpty)
                    ? null
                    : _send,
                icon: const Icon(Icons.send_rounded),
                color: a,
                disabledColor: c.textMuted,
              ),
            ),
          ],
        ),
      );
}

class _Bubble extends StatelessWidget {
  final ChatMessage message;
  final VoidCallback? onRetry;
  const _Bubble({required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    final user = message.isUser;
    final err = message.isError;
    final c = AppColors.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final a = dark ? AppColors.tan : AppColors.saddleBrown;
    final bg = user
        ? a
        : err
            ? const Color(0xFF3B1D1D)
            : c.card;
    final fg = user
        ? (dark ? AppColors.lightTextPrimary : AppColors.cream)
        : (err ? const Color(0xFFFCA5A5) : c.textPrimary);

    return LayoutBuilder(
      builder: (_, box) => Align(
        alignment: user ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          constraints: BoxConstraints(maxWidth: box.maxWidth * 0.85),
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(14),
            border: err
                ? Border.all(color: const Color(0xFFEF4444), width: .8)
                : (user ? null : Border.all(color: c.cardBorder, width: .6)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (user || err)
                SelectableText(message.text,
                    style: TextStyle(color: fg, fontSize: 14, height: 1.35))
              else
                SelectableText.rich(markdownSpan(message.text,
                    TextStyle(color: fg, fontSize: 14, height: 1.35))),
              if (onRetry != null)
                TextButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh, size: 14),
                  label: const Text('Retry', style: TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white,
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 28),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
