import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../pages/app_theme.dart';
import 'nexus_notify.dart';

// ================================================================
// WIND DOWN ALERT -- "starts in N min" top bar
// ----------------------------------------------------------------
// A one-time-per-day heads-up shown in the 5 minutes right BEFORE
// Wind Down mode's saved start time (see
// pages/nexus_notify_settings_page.dart -- users/{uid}.windDownEnabled
// / windDownStartHour / windDownStartMinute), Instagram-style.
//
// BEHAVIOUR
// ---------
// * Whenever the signed-in user opens/resumes the app and the
//   current time falls inside [startTime - 5min, startTime), the bar
//   shows "Wind Down mode starts in N minute(s)", where N counts down
//   from 5 based on the ACTUAL time the check runs -- e.g. Wind Down
//   set for 10:00 PM: opening the app at 9:55 shows "5 minutes",
//   opening (or first opening) at 9:56 shows "4 minutes", at 9:57
//   shows "3 minutes", and so on. It does NOT re-show on every
//   open/resume inside that window -- only the first time the window
//   is entered on a given day (tracked as
//   users/{uid}.windDownAlertShownDate = 'yyyy-MM-dd').
// * Once Wind Down itself starts (current time >= start time) this
//   bar no longer applies -- that is a separate, already-existing
//   concern (silenced pushes, see NotificationService).
// * Wind Down being OFF (windDownEnabled == false) means this bar
//   never shows.
//
// This file is intentionally separate from widgets/nexus_notify.dart
// (the time-of-day greeting bar) -- different trigger condition,
// different Firestore fields, different one-shot bookkeeping key --
// even though it reuses the same slide-down-bar visual language.
//
// USAGE
// -----
//   Call `WindDownAlert.maybeShow(context)` anywhere NexusNotify.
//   maybeShow(context) is already called (see pages/home_shell.dart:
//   once on first frame, and again on every AppLifecycleState.resumed).
//   It no-ops instantly unless there is actually an unseen-today,
//   inside-the-5-minute-window alert to show.
// ================================================================

class WindDownAlert {
  WindDownAlert._();

  static OverlayEntry? _currentEntry;

  // In-memory cache for this app session, mirroring nexus_notify.dart's
  // approach, so repeated `maybeShow` calls (e.g. every resume) don't
  // re-hit Firestore once today's shown-state + settings are known.
  static bool? _cachedEnabled;
  static int? _cachedStartHour;
  static int? _cachedStartMinute;
  static String? _cachedShownDate;

  static const int _windowMinutes = 5;

  /// Lets the Settings -> Nexus Notify page push fresh Wind Down
  /// values straight into this session's cache the moment the user
  /// changes them, so the very next `maybeShow` call reflects it
  /// immediately instead of only after Firestore is re-read on a
  /// cold start.
  static void updateCache({bool? enabled, int? startHour, int? startMinute}) {
    if (enabled != null) _cachedEnabled = enabled;
    if (startHour != null) _cachedStartHour = startHour;
    if (startMinute != null) _cachedStartMinute = startMinute;
  }

  static String _todayKey(DateTime now) {
    final y = now.year.toString().padLeft(4, '0');
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  /// Minutes remaining until [startHour]:[startMinute], counting
  /// forward from `now` and wrapping past midnight (so a start time
  /// like 00:02 still has a normal 5-minute pre-window ending
  /// 23:57-00:01 the night before). Returns null when outside the
  /// 1..5 minute pre-window (0 = Wind Down has already started).
  static int? _minutesUntilStart(DateTime now, int startHour, int startMinute) {
    final nowMinutes = now.hour * 60 + now.minute;
    final startMinutes = startHour * 60 + startMinute;
    final diff = (startMinutes - nowMinutes + 1440) % 1440;
    if (diff >= 1 && diff <= _windowMinutes) return diff;
    return null;
  }

  static Future<void> maybeShow(BuildContext context) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final docRef = FirebaseFirestore.instance.collection('users').doc(user.uid);

    bool enabled = _cachedEnabled ?? false;
    int startHour = _cachedStartHour ?? 22;
    int startMinute = _cachedStartMinute ?? 0;
    String? shownDate = _cachedShownDate;
    // Master "Notify" switch (Settings -> Nexus Notify -> "Notify") --
    // shared with the greeting bar and the message reminder, read via
    // NexusNotify's own cache/Firestore field so this doesn't need a
    // second read of the same document.
    bool masterEnabled = NexusNotify.cachedEnabled ?? true;

    if (_cachedEnabled == null || NexusNotify.cachedEnabled == null) {
      final snap = await docRef.get();
      final data = snap.data();
      enabled = (data?['windDownEnabled'] as bool?) ?? false;
      startHour = (data?['windDownStartHour'] as num?)?.toInt() ?? 22;
      startMinute = (data?['windDownStartMinute'] as num?)?.toInt() ?? 0;
      shownDate = data?['windDownAlertShownDate'] as String?;
      masterEnabled = (data?['notifyEnabled'] as bool?) ?? true;
      _cachedEnabled = enabled;
      _cachedStartHour = startHour;
      _cachedStartMinute = startMinute;
      _cachedShownDate = shownDate;
      NexusNotify.updateCache(enabled: masterEnabled);
    }

    // Master Notify switch OFF turns this heads-up off too, even if
    // Wind Down mode itself is still enabled underneath it.
    if (!masterEnabled) return;
    if (!enabled) return;

    final now = DateTime.now();
    final minutesLeft = _minutesUntilStart(now, startHour, startMinute);
    if (minutesLeft == null) return; // not inside the 5-minute pre-window

    final today = _todayKey(now);
    if (shownDate == today) return; // already alerted once today

    if (!context.mounted) return;

    // Mark as shown right away -- one alert per day, regardless of
    // how it's dismissed.
    _cachedShownDate = today;
    unawaited(docRef.set({'windDownAlertShownDate': today}, SetOptions(merge: true)));

    _present(context, minutesLeft: minutesLeft);
  }

  static void _present(BuildContext context, {required int minutesLeft}) {
    _currentEntry?.remove();
    _currentEntry = null;

    final overlay = Overlay.of(context, rootOverlay: true);

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => _WindDownAlertBar(
        minutesLeft: minutesLeft,
        onDismissed: () {
          if (_currentEntry == entry) _currentEntry = null;
          entry.remove();
        },
      ),
    );

    _currentEntry = entry;
    overlay.insert(entry);
  }
}

class _WindDownAlertBar extends StatefulWidget {
  final int minutesLeft;
  final VoidCallback onDismissed;

  const _WindDownAlertBar({
    required this.minutesLeft,
    required this.onDismissed,
  });

  @override
  State<_WindDownAlertBar> createState() => _WindDownAlertBarState();
}

class _WindDownAlertBarState extends State<_WindDownAlertBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entrance;
  late final Animation<Offset> _slide;
  late final Animation<double> _fade;

  Timer? _autoDismissTimer;

  @override
  void initState() {
    super.initState();

    _entrance = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
    _slide = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _entrance, curve: Curves.easeOutCubic));
    _fade = CurvedAnimation(parent: _entrance, curve: Curves.easeOut);
    _entrance.forward();

    // Buzz the phone the moment the Wind Down heads-up appears.
    HapticFeedback.vibrate();

    _autoDismissTimer = Timer(const Duration(seconds: 5), _dismiss);
  }

  Future<void> _dismiss() async {
    _autoDismissTimer?.cancel();
    if (!mounted) {
      widget.onDismissed();
      return;
    }
    await _entrance.reverse();
    widget.onDismissed();
  }

  @override
  void dispose() {
    _autoDismissTimer?.cancel();
    _entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;
    final minuteWord = widget.minutesLeft == 1 ? 'minute' : 'minutes';

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
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, topPadding > 0 ? 8 : 16, 16, 0),
                child: Dismissible(
                  key: const ValueKey('wind_down_alert_bar'),
                  direction: DismissDirection.horizontal,
                  onDismissed: (_) {
                    _autoDismissTimer?.cancel();
                    widget.onDismissed();
                  },
                  child: _buildBox(minuteWord),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBox(String minuteWord) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.darkSheet,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.saddleBrown, width: 1),
        boxShadow: const [
          BoxShadow(color: Colors.black45, blurRadius: 12, offset: Offset(0, 4)),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Icon(Icons.nightlight_round, color: AppColors.glow, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Wind Down mode starts in ${widget.minutesLeft} $minuteWord',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}