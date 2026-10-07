import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Shows a rectangular alert box that slides in from the TOP of the screen
/// (instead of the default Flutter SnackBar which shows at the bottom).
///
/// Usage (drop-in replacement for ScaffoldMessenger.of(context).showSnackBar):
///
///   showTopAlert(context, 'Group name is required');
///
/// Pass `isError: true` for a red/error style box (used automatically for
/// most failure messages if you don't specify it).
OverlayEntry? _currentTopAlertEntry;

void showTopAlert(
  BuildContext context,
  String message, {
  bool isError = false,
  Duration duration = const Duration(seconds: 3),
  // ==========================================================
  // NEW: optional custom leading icon (e.g. a bookmark/save icon
  // for "<user> saved this message" alerts). Falls back to the
  // usual error/info icon when not provided.
  // ==========================================================
  IconData? icon,
}) {
  // Remove any alert that's already showing so they don't stack up.
  _currentTopAlertEntry?.remove();
  _currentTopAlertEntry = null;

  final overlay = Overlay.of(context, rootOverlay: true);

  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) => _TopAlertBox(
      message: message,
      isError: isError,
      duration: duration,
      icon: icon,
      onDismissed: () {
        if (_currentTopAlertEntry == entry) {
          _currentTopAlertEntry = null;
        }
        entry.remove();
      },
    ),
  );

  _currentTopAlertEntry = entry;
  overlay.insert(entry);
}

class _TopAlertBox extends StatefulWidget {
  final String message;
  final bool isError;
  final Duration duration;
  final IconData? icon;
  final VoidCallback onDismissed;

  const _TopAlertBox({
    required this.message,
    required this.isError,
    required this.duration,
    this.icon,
    required this.onDismissed,
  });

  @override
  State<_TopAlertBox> createState() => _TopAlertBoxState();
}

class _TopAlertBoxState extends State<_TopAlertBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Offset> _slide;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
      reverseDuration: const Duration(milliseconds: 200),
    );
    _slide = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOut);

    _controller.forward();

    // Buzz the phone the moment the alert appears.
    HapticFeedback.vibrate();

    Future.delayed(widget.duration, () async {
      if (!mounted) return;
      await _controller.reverse();
      if (mounted) {
        widget.onDismissed();
      } else {
        widget.onDismissed();
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Material(
          color: Colors.transparent,
          child: SlideTransition(
            position: _slide,
            child: FadeTransition(
              opacity: _fade,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () async {
                  await _controller.reverse();
                  widget.onDismissed();
                },
                child: Padding(
                  padding: EdgeInsets.fromLTRB(16, topPadding > 0 ? 8 : 16, 16, 0),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    decoration: BoxDecoration(
                      color: widget.isError
                          ? const Color(0xFF3A1420)
                          : const Color(0xFF18181F),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: widget.isError
                            ? const Color(0xFFEF4444)
                            : const Color(0xFF7C3AED),
                        width: 1,
                      ),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black45,
                          blurRadius: 12,
                          offset: Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Icon(
                          widget.icon ??
                              (widget.isError
                                  ? Icons.error_outline_rounded
                                  : Icons.info_outline_rounded),
                          color: widget.isError
                              ? const Color(0xFFEF4444)
                              : const Color(0xFFA78BFA),
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            widget.message,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}