import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../navigation_key.dart';
import '../pages/app_theme.dart';

// ================================================================
// NEXUS NOTIFY -- top-of-screen time-of-day greeting bar
// ----------------------------------------------------------------
// A rectangular bar that slides in from the TOP of the screen
// (same slot as widgets/top_alert.dart, but this one is its own
// self-contained file since it has its own state machine, its own
// Firestore-backed "already shown today" bookkeeping, and its own
// inline "set name" form).
//
// BEHAVIOUR
// ---------
// * If the signed-in user has never saved a name for this bar yet
//   (see below), opening or resuming the app shows an inline
//   "Set Name" prompt (text field + OK) IMMEDIATELY -- every single
//   time, with no time-of-day restriction and no once-a-day limit.
//   There is nothing to rate-limit here: the prompt stops appearing
//   for good the instant a name is saved, so seeing it again on the
//   next open just means it is still genuinely unset.
//
// * Once a name has been saved, the bar switches to a plain greeting
//   and THEN the time-of-day / once-per-day rules kick in: whenever
//   the current time falls in one of three windows, the bar shows a
//   one-time-per-window greeting:
//       05:00 - 11:59  -> "Good morning, <name>"
//       12:00 - 15:59  -> "Good afternoon, <name>"
//       16:00 - 19:59  -> "Good evening, <name>"
//   Outside 5 AM - 8 PM, no greeting is shown (no window is defined).
//   "One-time per window" is tracked per calendar day in Firestore
//   (users/{uid}.notifyShown = {morning|afternoon|evening: 'yyyy-MM-dd'})
//   so it will not reappear on every app open within the same window,
//   only the first time that window is entered on a given day.
//
// * The bar's left corner shows a small icon for the active window
//   (sunrise / sun / crescent-moon) followed by the live clock time.
//   Outside 5 AM - 8 PM the "Set Name" prompt still needs *an* icon,
//   so it falls back to the crescent-moon (evening) icon in that case
//   -- purely cosmetic, it has no bearing on the once-per-window logic
//   above, which only ever runs once a name already exists.
//
// * The GREETING uses a display name that lives only in this bar's
//   own Firestore field (users/{uid}.notifyName) -- it is deliberately
//   kept separate from publicName/privateName (user_profile_service.dart)
//   since those are chat-identity fields, not this bar's welcome name.
//   Saving the name flips the SAME bar to a green "Name accepted"
//   confirmation, and every later greeting uses the saved name.
//
// * Swiping the bar left or right dismisses it immediately. Left
//   untouched, it dismisses itself after 5 seconds. The one exception
//   is while the name text field is focused/being typed into -- the
//   5 second auto-timer is held off there (swipe-to-dismiss still
//   works) since 5 seconds is not enough time to type a name.
//
// USAGE
// -----
//   Call `NexusNotify.maybeShow(context)` once the home shell is on
//   screen (see pages/home_shell.dart). It no-ops instantly when
//   Notify (or just its Greetings bar switch) is off; otherwise it
//   shows the "Set Name" prompt right away if no name is saved yet,
//   or the once-per-window greeting if one is.
// ================================================================

enum _GreetingPeriod { morning, afternoon, evening }

enum _BarMode { greeting, setName, nameAccepted }

class NexusNotify {
  NexusNotify._();

  static OverlayEntry? _currentEntry;

  // In-memory cache for this app session so repeated `maybeShow` calls
  // (e.g. on every resume) don't re-hit Firestore once we already know
  // today's shown-state and the saved name.
  static Map<String, dynamic>? _cachedShown;
  static String? _cachedName;
  static bool? _cachedEnabled;
  static bool? _cachedGreetingBarEnabled;

  static _GreetingPeriod? _periodForNow(DateTime now) {
    final hour = now.hour;
    if (hour >= 5 && hour < 12) return _GreetingPeriod.morning;
    if (hour >= 12 && hour < 16) return _GreetingPeriod.afternoon;
    if (hour >= 16 && hour < 20) return _GreetingPeriod.evening;
    return null;
  }

  static String _periodKey(_GreetingPeriod p) {
    switch (p) {
      case _GreetingPeriod.morning:
        return 'morning';
      case _GreetingPeriod.afternoon:
        return 'afternoon';
      case _GreetingPeriod.evening:
        return 'evening';
    }
  }

  static String _todayKey(DateTime now) {
    final y = now.year.toString().padLeft(4, '0');
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  /// Checks whether a greeting is due for the current time window and,
  /// if so, shows the bar. Safe to call from initState/app-resume --
  /// it silently does nothing when there's no signed-in user, no
  /// active window (8 PM - 5 AM), or today's window was already shown.
  /// Lets the Settings -> Nexus Notify page (see
  /// pages/nexus_notify_settings_page.dart) push a fresh Notify
  /// on/off and/or name value straight into this session's cache the
  /// moment the user changes it, so the next `maybeShow` call (e.g.
  /// the very next app resume) reflects it immediately instead of
  /// only after Firestore is re-read on a cold start.
  static void updateCache({bool? enabled, String? name, bool? greetingBarEnabled}) {
    if (enabled != null) _cachedEnabled = enabled;
    if (name != null) _cachedName = name;
    if (greetingBarEnabled != null) _cachedGreetingBarEnabled = greetingBarEnabled;
  }

  /// Notify on/off as far as this session already knows it (null when
  /// the user document hasn't been read yet). Shared with the unseen
  /// messages reminder below so the two bars obey the single
  /// Settings -> Nexus Notify switch without reading the same field
  /// twice.
  static bool? get cachedEnabled => _cachedEnabled;

  static Future<void> maybeShow(BuildContext context) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final now = DateTime.now();
    // May be null (8 PM - 5 AM has no greeting window) -- that used to
    // mean "do nothing at all", but the "set your name" prompt below
    // must not depend on the time of day, so it is only used from here
    // on to decide whether a *greeting* is possible, not to bail out
    // early.
    final period = _periodForNow(now);

    final docRef = FirebaseFirestore.instance.collection('users').doc(user.uid);

    Map<String, dynamic> shown = _cachedShown ?? const {};
    String? name = _cachedName;
    bool enabled = _cachedEnabled ?? true;
    bool greetingBarEnabled = _cachedGreetingBarEnabled ?? true;

    if (_cachedShown == null) {
      final snap = await docRef.get();
      final data = snap.data();
      shown = Map<String, dynamic>.from(
        (data?['notifyShown'] as Map<String, dynamic>?) ?? {},
      );
      name = data?['notifyName'] as String?;
      // Absent field (older accounts / Notify never touched in
      // Settings -> Nexus Notify) defaults to enabled, so existing
      // behaviour is unchanged until the user turns it off.
      enabled = (data?['notifyEnabled'] as bool?) ?? true;
      greetingBarEnabled =
          (data?['notifyGreetingBarEnabled'] as bool?) ?? true;
      _cachedShown = shown;
      _cachedName = name;
      _cachedEnabled = enabled;
      _cachedGreetingBarEnabled = greetingBarEnabled;
    }

    // Master "Notify" switch off -> every Nexus Notify alert
    // (greeting bar, message reminder, Wind Down heads-up) is off, so
    // stop here regardless of the individual switches below it.
    if (!enabled) return;
    // Master is on but the "Greetings bar" switch itself is off:
    // just this one bar stays off, Message reminder / Wind Down are
    // unaffected.
    if (!greetingBarEnabled) return;

    if (!context.mounted) return;

    final needsName = name == null || name.trim().isEmpty;

    if (needsName) {
      // No name saved yet: show the "set your name" prompt the moment
      // the user opens/resumes the app, every time, with none of the
      // greeting window/once-per-day bookkeeping below -- there is
      // nothing to protect the user from seeing repeatedly here, since
      // it stops for good the instant a name is saved.
      _present(
        context,
        period: period ?? _GreetingPeriod.evening,
        name: name,
        needsName: true,
        onNameSaved: (savedName) async {
          _cachedName = savedName;
          await docRef.set({'notifyName': savedName}, SetOptions(merge: true));
        },
      );
      return;
    }

    // From here on a name already exists, so this is the ordinary
    // once-per-window greeting -- which only exists inside the
    // 5 AM - 8 PM windows.
    if (period == null) return;

    final key = _periodKey(period);
    final today = _todayKey(now);
    if (shown[key] == today) return; // already greeted for this window today

    // Mark as shown right away -- the window has been "used" the
    // moment the bar appears, regardless of how the user dismisses it.
    shown = {...shown, key: today};
    _cachedShown = shown;
    unawaited(docRef.set({'notifyShown': shown}, SetOptions(merge: true)));

    _present(
      context,
      period: period,
      name: name,
      needsName: false,
      onNameSaved: (savedName) async {
        _cachedName = savedName;
        await docRef.set({'notifyName': savedName}, SetOptions(merge: true));
      },
    );
  }

  static void _present(
    BuildContext context, {
    required _GreetingPeriod period,
    required String? name,
    required bool needsName,
    required Future<void> Function(String) onNameSaved,
  }) {
    _currentEntry?.remove();
    _currentEntry = null;

    final overlay = Overlay.of(context, rootOverlay: true);

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => _NexusNotifyBar(
        period: period,
        name: name,
        needsName: needsName,
        onNameSaved: onNameSaved,
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

class _NexusNotifyBar extends StatefulWidget {
  final _GreetingPeriod period;
  final String? name;
  final bool needsName;
  final Future<void> Function(String) onNameSaved;
  final VoidCallback onDismissed;

  const _NexusNotifyBar({
    required this.period,
    required this.name,
    required this.needsName,
    required this.onNameSaved,
    required this.onDismissed,
  });

  @override
  State<_NexusNotifyBar> createState() => _NexusNotifyBarState();
}

class _NexusNotifyBarState extends State<_NexusNotifyBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entrance;
  late final Animation<Offset> _slide;
  late final Animation<double> _fade;

  late _BarMode _mode;
  final TextEditingController _nameController = TextEditingController();
  final FocusNode _nameFocus = FocusNode();

  Timer? _autoDismissTimer;
  Timer? _clockTimer;
  DateTime _now = DateTime.now();
  bool _savingName = false;

  @override
  void initState() {
    super.initState();
    _mode = widget.needsName ? _BarMode.setName : _BarMode.greeting;

    _entrance = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
      reverseDuration: const Duration(milliseconds: 220),
    );
    _slide = Tween<Offset>(begin: const Offset(0, -1), end: Offset.zero)
        .animate(CurvedAnimation(parent: _entrance, curve: Curves.easeOutCubic));
    _fade = CurvedAnimation(parent: _entrance, curve: Curves.easeOut);
    _entrance.forward();

    // Buzz the phone the moment the greeting bar appears.
    HapticFeedback.vibrate();

    // Live clock next to the period symbol.
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });

    _nameFocus.addListener(() {
      // Typing needs more than 5 seconds -- hold the auto-dismiss off
      // while the field is focused, resume it once focus is lost.
      if (_nameFocus.hasFocus) {
        _autoDismissTimer?.cancel();
      } else if (_mode == _BarMode.setName) {
        _armAutoDismiss();
      }
    });

    if (_mode != _BarMode.setName) {
      _armAutoDismiss();
    }
  }

  void _armAutoDismiss() {
    _autoDismissTimer?.cancel();
    _autoDismissTimer = Timer(const Duration(seconds: 5), _dismiss);
  }

  Future<void> _dismiss() async {
    _autoDismissTimer?.cancel();
    _clockTimer?.cancel();
    if (!mounted) {
      widget.onDismissed();
      return;
    }
    await _entrance.reverse();
    widget.onDismissed();
  }

  Future<void> _saveName() async {
    final value = _nameController.text.trim();
    if (value.isEmpty || _savingName) return;

    setState(() => _savingName = true);
    await widget.onNameSaved(value);
    if (!mounted) return;

    setState(() {
      _savingName = false;
      _mode = _BarMode.nameAccepted;
    });
    _armAutoDismiss();
  }

  @override
  void dispose() {
    _autoDismissTimer?.cancel();
    _clockTimer?.cancel();
    _entrance.dispose();
    _nameController.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  IconData get _periodIcon {
    switch (widget.period) {
      case _GreetingPeriod.morning:
        return Icons.wb_twilight_rounded; // sunrise
      case _GreetingPeriod.afternoon:
        return Icons.wb_sunny_rounded; // sun
      case _GreetingPeriod.evening:
        return Icons.nights_stay_rounded; // dusk / night
    }
  }

  String get _periodWord {
    switch (widget.period) {
      case _GreetingPeriod.morning:
        return 'morning';
      case _GreetingPeriod.afternoon:
        return 'afternoon';
      case _GreetingPeriod.evening:
        return 'evening';
    }
  }

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;
    final timeText = TimeOfDay.fromDateTime(_now).format(context);

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
                  key: const ValueKey('nexus_notify_bar'),
                  direction: DismissDirection.horizontal,
                  onDismissed: (_) {
                    _autoDismissTimer?.cancel();
                    _clockTimer?.cancel();
                    widget.onDismissed();
                  },
                  child: _buildBox(timeText),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBox(String timeText) {
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
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ---- left corner: period symbol + live time -----------------
          Column(
            children: [
              Icon(_periodIcon, color: AppColors.glow, size: 22),
              const SizedBox(height: 2),
              Text(
                timeText,
                style: const TextStyle(
                  color: AppColors.tan,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(child: _buildContent()),
        ],
      ),
    );
  }

  Widget _buildContent() {
    switch (_mode) {
      case _BarMode.greeting:
        final greetName = (widget.name ?? '').trim();
        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            'Good $_periodWord, $greetName',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        );

      case _BarMode.nameAccepted:
        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            'Name accepted \u2713',
            style: const TextStyle(
              color: Color(0xFF4CD964), // green confirmation text
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
        );

      case _BarMode.setName:
        return Row(
          children: [
            Expanded(
              child: TextField(
                controller: _nameController,
                focusNode: _nameFocus,
                autofocus: true,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                cursorColor: AppColors.tan,
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'Set your name',
                  hintStyle: TextStyle(color: AppColors.darkTextMuted, fontSize: 14),
                  enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: AppColors.darkCardBorder),
                  ),
                  focusedBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: AppColors.tan),
                  ),
                ),
                onSubmitted: (_) => _saveName(),
              ),
            ),
            const SizedBox(width: 10),
            GestureDetector(
              onTap: _savingName ? null : _saveName,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  gradient: AppColors.goldGradient,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: _savingName
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation(Colors.white),
                        ),
                      )
                    : const Text(
                        'OK',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
              ),
            ),
          ],
        );
    }
  }
}
// ================================================================
// NEXUS NOTIFY -- UNSEEN MESSAGES REMINDER
// ----------------------------------------------------------------
// Second, independent bar that reuses the exact same slide-in-from-
// the-top slot and visual box as the greeting bar above, but instead
// of a time-of-day greeting it reminds the signed-in user about
// conversations that have a message they still haven't opened -- the
// same conversations that are showing the unread dot on their right
// hand side in the Chats list (public AND private) and in the Hubs ->
// Groups tab.
//
// WHEN IT FIRES
// -------------
//   * The moment the app is opened or resumed (from home_shell.dart,
//     alongside NexusNotify.maybeShow / WindDownAlert.maybeShow).
//   * Again roughly every hour, for as long as that same message is
//     STILL unopened while the app stays in the foreground.
//   * Straight away (on the next scan tick) if a brand new message
//     arrives in a conversation while the app is open and isn't read.
//   Once the conversation is actually opened its read marker moves
//   forward, it drops out of the scan, and the reminders stop by
//   themselves.
//
// WHAT IT LOOKS LIKE
// ------------------
//   [ message icon ]   * <name> have a unseen messages
//   [ 10:42 AM     ]
//   ...where `*` is a small green dot and <name> is:
//     * the sender's PRIVATE name  -- if that account is connected
//     * the sender's PUBLIC name   -- if it is not connected
//     * the GROUP name             -- for an unseen group message
//
// HOW "UNSEEN" IS DECIDED (cheaply)
// ---------------------------------
// Both a chat document and a group document carry a per-user read
// marker written when the conversation is opened:
//   chats/<id>  { lastMessageSenderId, lastMessageTime, lastReadAt: {uid: ts} }
//   groups/<id> { lastMessageSender,   lastMessageAt,   lastReadAt: {uid: ts} }
//     (see markChatRead() in pages/chat_screen.dart and
//      markGroupRead() in pages/groupchat.dart)
// so one query over each collection answers "is anything unseen?"
// for every conversation at once, instead of opening each one's
// messages subcollection. Chats created before this marker existed
// fall back to the old check -- their newest message's `readBy` --
// and only for those few candidates.
// ================================================================

class _UnseenConversation {
  /// 'chat:<chatId>' or 'group:<groupDocId>' -- stable identity used
  /// to remember when this conversation was last reminded about.
  final String key;
  final String name;
  final DateTime receivedAt;

  const _UnseenConversation({
    required this.key,
    required this.name,
    required this.receivedAt,
  });
}

class NexusUnseenNotify {
  NexusUnseenNotify._();

  /// How long an unseen message has to keep sitting there before the
  /// same conversation is reminded about again.
  static const Duration remindAfter = Duration(hours: 1);

  /// How often the (cheap, two-query) scan runs while the app is in
  /// the foreground. Also how quickly a brand new unread message that
  /// arrives mid-session gets its first reminder.
  static const Duration scanInterval = Duration(minutes: 10);

  static Timer? _scanTimer;
  static bool _scanning = false;

  static OverlayEntry? _currentEntry;
  static final List<_UnseenConversation> _queue = <_UnseenConversation>[];

  /// conversation key -> wall clock time it was last reminded about.
  static final Map<String, DateTime> _lastAlertedAt = <String, DateTime>{};

  /// conversation key -> the message timestamp that reminder was for,
  /// so a NEWER message in an already-reminded conversation doesn't
  /// have to wait out the remaining hour.
  static final Map<String, DateTime> _alertedForMessageAt =
      <String, DateTime>{};

  static String? _ownerUid;

  /// Per-scan display-name cache so two unseen chats with the same
  /// person (or repeated scans) don't re-read the user document.
  static final Map<String, String> _nameCache = <String, String>{};

  // ==========================================================
  // ENTRY POINTS
  // ==========================================================

  /// Runs a scan now and makes sure the hourly re-check timer is
  /// armed. Safe to call on every app open/resume.
  static void maybeShow(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    // Account switch -- previous account's reminder bookkeeping must
    // not leak into this one.
    if (_ownerUid != uid) {
      _ownerUid = uid;
      _cachedReminderEnabled = null;
      _lastAlertedAt.clear();
      _alertedForMessageAt.clear();
      _nameCache.clear();
      _queue.clear();
    }

    unawaited(_runScan());

    _scanTimer ??= Timer.periodic(scanInterval, (_) => unawaited(_runScan()));
  }

  /// Cancels the timer and clears everything (sign out / home shell
  /// teardown).
  static void stop() {
    _scanTimer?.cancel();
    _scanTimer = null;
    _queue.clear();
    _lastAlertedAt.clear();
    _alertedForMessageAt.clear();
    _nameCache.clear();
    _ownerUid = null;
    _cachedReminderEnabled = null;
    _currentEntry?.remove();
    _currentEntry = null;
  }

  // ==========================================================
  // SCAN
  // ==========================================================

  static Future<void> _runScan() async {
    if (_scanning) return;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    _scanning = true;
    try {
      // Settings -> Nexus Notify -> "Message reminder" (and the master
      // "Notify" switch above it): either one off means no reminders.
      if (!await _remindersEnabled(user.uid)) {
        _clearPending();
        return;
      }

      final unseen = await _findUnseen(user.uid);

      // Conversations that are no longer unseen (the user opened them)
      // forget their reminder history, so if they go unread again
      // later they alert immediately instead of being throttled.
      final activeKeys = unseen.map((c) => c.key).toSet();
      _lastAlertedAt.removeWhere((key, _) => !activeKeys.contains(key));
      _alertedForMessageAt.removeWhere((key, _) => !activeKeys.contains(key));

      final now = DateTime.now();
      final due = <_UnseenConversation>[];

      for (final conv in unseen) {
        final lastAlert = _lastAlertedAt[conv.key];
        final alertedFor = _alertedForMessageAt[conv.key];

        final bool isNewMessage =
            alertedFor == null || conv.receivedAt.isAfter(alertedFor);
        final bool hourElapsed =
            lastAlert != null && now.difference(lastAlert) >= remindAfter;

        if (lastAlert == null || isNewMessage || hourElapsed) {
          _lastAlertedAt[conv.key] = now;
          _alertedForMessageAt[conv.key] = conv.receivedAt;
          due.add(conv);
        }
      }

      if (due.isEmpty) return;

      // Newest first.
      due.sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
      _queue.addAll(due);
      _showNext();
    } catch (e) {
      debugPrint('Unseen messages scan error: $e');
    } finally {
      _scanning = false;
    }
  }

  /// Settings -> Nexus Notify -> "Message reminder" switch, as far as
  /// this session already knows it (null until the user document has
  /// been read once).
  static bool? _cachedReminderEnabled;

  /// Lets the settings page push the new value straight into this
  /// session the moment the user flips the switch, instead of waiting
  /// for the next cold start. Turning it OFF also clears anything
  /// currently on screen or queued, so no reminder can slip through
  /// after the switch is off.
  static void updateCache({bool? reminderEnabled}) {
    if (reminderEnabled == null) return;
    _cachedReminderEnabled = reminderEnabled;
    if (!reminderEnabled) _clearPending();
  }

  static void _clearPending() {
    _queue.clear();
    _currentEntry?.remove();
    _currentEntry = null;
  }

  /// Reminders need BOTH switches on: the master "Notify" switch (which
  /// also controls the greeting bar) and the dedicated "Message
  /// reminder" switch right under "Name".
  static Future<bool> _remindersEnabled(String uid) async {
    final notify = NexusNotify.cachedEnabled;
    final reminder = _cachedReminderEnabled;
    if (notify != null && reminder != null) return notify && reminder;

    try {
      final snap =
          await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final data = snap.data();
      // Absent field (older accounts / never touched in Settings)
      // defaults to ON, so behaviour is unchanged until the user
      // turns it off themselves.
      final notifyValue = (data?['notifyEnabled'] as bool?) ?? true;
      final reminderValue =
          (data?['notifyMessageReminder'] as bool?) ?? true;

      NexusNotify.updateCache(enabled: notifyValue);
      _cachedReminderEnabled = reminderValue;

      return notifyValue && reminderValue;
    } catch (_) {
      return true;
    }
  }

  static Future<List<_UnseenConversation>> _findUnseen(String uid) async {
    final fs = FirebaseFirestore.instance;
    final out = <_UnseenConversation>[];

    // ---- who am I connected to? (private vs public name) ----------
    final connected = <String>{};
    try {
      final conns = await fs
          .collection('connections')
          .where('users', arrayContains: uid)
          .where('status', isEqualTo: 'connected')
          .get();
      for (final doc in conns.docs) {
        final users = List<String>.from(doc.data()['users'] ?? []);
        final other = users.firstWhere((id) => id != uid, orElse: () => '');
        if (other.isNotEmpty) connected.add(other);
      }
    } catch (e) {
      debugPrint('Unseen scan connections error: $e');
    }

    // ---- 1-to-1 chats (public + private) --------------------------
    try {
      final chats = await fs
          .collection('chats')
          .where('participants', arrayContains: uid)
          .get();

      for (final doc in chats.docs) {
        final data = doc.data();

        final hiddenFor = List<String>.from(data['hiddenFor'] ?? []);
        if (hiddenFor.contains(uid)) continue;

        final sender = (data['lastMessageSenderId'] ?? '').toString();
        if (sender.isEmpty || sender == uid) continue;

        final lastTime = data['lastMessageTime'];
        if (lastTime is! Timestamp) continue;
        final receivedAt = lastTime.toDate();

        final readAt = _readAtFor(data, uid);
        if (readAt != null && !receivedAt.isAfter(readAt)) continue;

        // Legacy chat with no read marker yet -- fall back to the
        // newest message's readBy list (one extra read, only for
        // these few candidates).
        if (readAt == null && await _legacyChatAlreadyRead(doc.reference, uid)) {
          continue;
        }

        final participants = List<String>.from(data['participants'] ?? []);
        final other = participants.firstWhere(
          (id) => id != uid,
          orElse: () => '',
        );
        if (other.isEmpty) continue;

        final name = await _userDisplayName(other, connected.contains(other));
        if (name.isEmpty) continue;

        out.add(_UnseenConversation(
          key: 'chat:${doc.id}',
          name: name,
          receivedAt: receivedAt,
        ));
      }
    } catch (e) {
      debugPrint('Unseen scan chats error: $e');
    }

    // ---- groups ---------------------------------------------------
    try {
      final groups = await fs
          .collection('groups')
          .where('members', arrayContains: uid)
          .get();

      for (final doc in groups.docs) {
        final data = doc.data();

        final sender = (data['lastMessageSender'] ?? '').toString();
        if (sender.isEmpty || sender == uid) continue;

        final lastTime = data['lastMessageAt'];
        if (lastTime is! Timestamp) continue;
        final receivedAt = lastTime.toDate();

        final readAt = _readAtFor(data, uid);
        if (readAt != null && !receivedAt.isAfter(readAt)) continue;

        final name = (data['groupName'] ?? '').toString().trim();
        if (name.isEmpty) continue;

        out.add(_UnseenConversation(
          key: 'group:${doc.id}',
          name: name,
          receivedAt: receivedAt,
        ));
      }
    } catch (e) {
      debugPrint('Unseen scan groups error: $e');
    }

    return out;
  }

  /// Pulls `lastReadAt[<uid>]` out of a chat/group document.
  static DateTime? _readAtFor(Map<String, dynamic> data, String uid) {
    final raw = data['lastReadAt'];
    if (raw is! Map) return null;
    final value = Map<String, dynamic>.from(raw)[uid];
    if (value is Timestamp) return value.toDate();
    return null;
  }

  static Future<bool> _legacyChatAlreadyRead(
    DocumentReference<Map<String, dynamic>> chatRef,
    String uid,
  ) async {
    try {
      final last = await chatRef
          .collection('messages')
          .orderBy('sentAt', descending: true)
          .limit(1)
          .get();
      if (last.docs.isEmpty) return true;
      final readBy = List<String>.from(last.docs.first.data()['readBy'] ?? []);
      return readBy.contains(uid);
    } catch (e) {
      debugPrint('Unseen scan legacy read check error: $e');
      return true; // never nag on an unclear result
    }
  }

  /// Private name when connected (falling back to the public one when
  /// they never set a private name), public name otherwise -- exactly
  /// the same rule the Chats list uses for its tiles.
  static Future<String> _userDisplayName(String uid, bool isConnected) async {
    final cacheKey = '$uid:$isConnected';
    final cached = _nameCache[cacheKey];
    if (cached != null) return cached;

    try {
      final snap =
          await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final data = snap.data();
      if (data == null) return '';

      final privateName = (data['privateName'] ?? '').toString().trim();
      final publicName = (data['publicName'] ?? '').toString().trim();

      final name = (isConnected && privateName.isNotEmpty)
          ? privateName
          : publicName;

      if (name.isNotEmpty) _nameCache[cacheKey] = name;
      return name;
    } catch (e) {
      debugPrint('Unseen scan name lookup error: $e');
      return '';
    }
  }

  // ==========================================================
  // PRESENTATION (one bar at a time, queued)
  // ==========================================================

  static void _showNext() {
    if (_currentEntry != null) return; // a bar is already on screen
    if (_queue.isEmpty) return;

    final context = rootNavigatorKey.currentContext;
    if (context == null || !context.mounted) return;

    final conv = _queue.removeAt(0);
    final overlay = Overlay.of(context, rootOverlay: true);

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _UnseenAlertBar(
        name: conv.name,
        receivedAt: conv.receivedAt,
        onDismissed: () {
          if (_currentEntry == entry) _currentEntry = null;
          entry.remove();
          // Let the next queued reminder slide in right after.
          Future.delayed(const Duration(milliseconds: 250), _showNext);
        },
      ),
    );

    _currentEntry = entry;
    overlay.insert(entry);
  }
}

// ================================================================
// UNSEEN MESSAGE BAR
// ----------------------------------------------------------------
//   [icon]   * <name> have a unseen messages
//   [time]
// Same box, same slide/fade entrance, same swipe-to-dismiss and
// 5-second auto-dismiss as the greeting bar above.
// ================================================================

class _UnseenAlertBar extends StatefulWidget {
  final String name;
  final DateTime receivedAt;
  final VoidCallback onDismissed;

  const _UnseenAlertBar({
    required this.name,
    required this.receivedAt,
    required this.onDismissed,
  });

  @override
  State<_UnseenAlertBar> createState() => _UnseenAlertBarState();
}

class _UnseenAlertBarState extends State<_UnseenAlertBar>
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
      duration: const Duration(milliseconds: 280),
      reverseDuration: const Duration(milliseconds: 220),
    );
    _slide = Tween<Offset>(begin: const Offset(0, -1), end: Offset.zero)
        .animate(CurvedAnimation(parent: _entrance, curve: Curves.easeOutCubic));
    _fade = CurvedAnimation(parent: _entrance, curve: Curves.easeOut);
    _entrance.forward();

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

  /// Time the message actually arrived. Anything older than today
  /// also gets a small day/month line under it so an overnight
  /// reminder doesn't read as if it just landed.
  String _dateLabel() {
    final now = DateTime.now();
    final at = widget.receivedAt;
    final sameDay =
        now.year == at.year && now.month == at.month && now.day == at.day;
    if (sameDay) return '';
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${at.day} ${months[at.month - 1]}';
  }

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;
    final timeText = TimeOfDay.fromDateTime(widget.receivedAt).format(context);
    final dateText = _dateLabel();

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
                  key: ValueKey('nexus_unseen_${widget.name}_'
                      '${widget.receivedAt.millisecondsSinceEpoch}'),
                  direction: DismissDirection.horizontal,
                  onDismissed: (_) {
                    _autoDismissTimer?.cancel();
                    widget.onDismissed();
                  },
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: AppColors.darkSheet,
                      borderRadius: BorderRadius.circular(14),
                      border:
                          Border.all(color: AppColors.saddleBrown, width: 1),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black45,
                          blurRadius: 12,
                          offset: Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // ---- left corner: message icon + arrival time ----
                        Column(
                          children: [
                            const Icon(
                              Icons.mark_chat_unread_rounded,
                              color: AppColors.glow,
                              size: 22,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              timeText,
                              style: const TextStyle(
                                color: AppColors.tan,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (dateText.isNotEmpty)
                              Text(
                                dateText,
                                style: const TextStyle(
                                  color: AppColors.darkTextMuted,
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(width: 12),
                        // ---- green dot + "<name> have a unseen messages" ----
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  margin: const EdgeInsets.only(top: 5),
                                  width: 9,
                                  height: 9,
                                  decoration: const BoxDecoration(
                                    color: Color(0xFF4CD964),
                                    shape: BoxShape.circle,
                                    boxShadow: [
                                      BoxShadow(
                                        color: Color(0x664CD964),
                                        blurRadius: 6,
                                        spreadRadius: 1,
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: RichText(
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    text: TextSpan(
                                      children: [
                                        TextSpan(
                                          text: widget.name,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 15,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        const TextSpan(
                                          text: ' have a unseen messages',
                                          style: TextStyle(
                                            color: AppColors.tan,
                                            fontSize: 14,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
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

// ================================================================
// NEXUS NOTIFY -- PROFILE REMINDER  (public + private name & photo)
// ----------------------------------------------------------------
// Third independent bar in this file. Same slot, same box, same
// swipe / 5-second auto-dismiss as the two above -- but instead of a
// greeting or an unread message it nudges the signed-in user to
// finish setting up their identity on the Me page:
//
//   users/{uid}.publicName    publicImage
//   users/{uid}.privateName   privateImage
//       (all four written by services/user_profile_service.dart from
//        Me -> Public / Private profile)
//
// WHEN IT FIRES
// -------------
//   * 5 MINUTES after the app is opened / resumed onto the home
//     shell -- never instantly. A brand new account that just
//     finished signing up gets those 5 minutes to go and set their
//     name + photo themselves; if they did, the re-check at the end
//     of the 5 minutes finds the fields filled and NOTHING is shown.
//   * At most ONCE PER CALENDAR DAY, no matter how many times the
//     app is opened, resumed or reinstalled that day. The day it was
//     last shown on is kept in Firestore
//     (users/{uid}.notifyProfileReminderShown = 'yyyy-MM-dd') so a
//     cold start can't get a second reminder out of the same day.
//   * If the fields are still empty the next day, it fires again --
//     once -- and keeps doing that day after day until they're set.
//
// WHEN IT STOPS FOREVER
// ---------------------
// The moment all four fields (public name, public photo, private
// name, private photo) are non-empty. From then on the check exits
// immediately and the bar is never shown again -- no timer, no
// Firestore read beyond the one that discovered it was complete.
//
// SWITCHES
// --------
// Needs BOTH the master "Notify" switch and its own
// Settings -> Nexus Notify -> "Profile reminder" switch
// (users/{uid}.notifyProfileReminder, absent == ON) to be on.
// ================================================================

class NexusProfileNotify {
  NexusProfileNotify._();

  /// How long after opening / resuming the app the reminder waits
  /// before it checks and shows. Deliberately not instant: it is the
  /// grace period a fresh sign-up gets to set things up first.
  static const Duration remindAfter = Duration(minutes: 5);

  static String? _ownerUid;
  static Timer? _pendingTimer;
  static bool _checking = false;

  /// Own on/off switch as far as this session knows it.
  static bool? _cachedReminderEnabled;

  /// Flipped once the four fields have been seen filled in -- the
  /// reminder is retired for good after that.
  static bool _profileComplete = false;

  /// 'yyyy-MM-dd' this reminder was last shown on (null until the
  /// user document has been read once this session).
  static String? _shownOn;

  static OverlayEntry? _currentEntry;

  static String _dayKey(DateTime now) {
    final y = now.year.toString().padLeft(4, '0');
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  // ==========================================================
  // ENTRY POINTS
  // ==========================================================

  /// Arms the 5-minute check. Safe to call on every app open/resume
  /// (pages/home_shell.dart does) -- it no-ops when the profile is
  /// already complete, when today's reminder has been shown, or when
  /// a check is already waiting out its 5 minutes.
  static void maybeShow(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    // Account switch -- the previous account's bookkeeping says
    // nothing about this one.
    if (_ownerUid != uid) {
      _ownerUid = uid;
      _pendingTimer?.cancel();
      _pendingTimer = null;
      _cachedReminderEnabled = null;
      _profileComplete = false;
      _shownOn = null;
    }

    if (_profileComplete) return; // set up already -- never again
    if (_pendingTimer != null) return; // a check is already pending
    if (_cachedReminderEnabled == false) return;
    if (_shownOn != null && _shownOn == _dayKey(DateTime.now())) {
      return; // today's one-and-only reminder is already done
    }

    _pendingTimer = Timer(remindAfter, () {
      _pendingTimer = null;
      unawaited(_check());
    });
  }

  /// Cancels the pending check and clears everything (sign out /
  /// account switch / home shell teardown).
  static void stop() {
    _pendingTimer?.cancel();
    _pendingTimer = null;
    _checking = false;
    _ownerUid = null;
    _cachedReminderEnabled = null;
    _profileComplete = false;
    _shownOn = null;
    _currentEntry?.remove();
    _currentEntry = null;
  }

  /// Lets the settings page push its switches straight into this
  /// session. Turning either one off also cancels a pending check and
  /// drops anything on screen.
  static void updateCache({bool? enabled, bool? reminderEnabled}) {
    if (reminderEnabled != null) _cachedReminderEnabled = reminderEnabled;

    if (enabled == false || reminderEnabled == false) {
      _pendingTimer?.cancel();
      _pendingTimer = null;
      _currentEntry?.remove();
      _currentEntry = null;
    }
  }

  /// Called right after the user saves a name / photo from the Me
  /// page, so the reminder retires immediately instead of waiting for
  /// the next read. Passing anything still empty just leaves the
  /// normal check in place.
  static void markProfileComplete() {
    _profileComplete = true;
    _pendingTimer?.cancel();
    _pendingTimer = null;
    _currentEntry?.remove();
    _currentEntry = null;
  }

  // ==========================================================
  // THE CHECK  (runs 5 minutes after open/resume)
  // ==========================================================

  static Future<void> _check() async {
    if (_checking) return;

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    _checking = true;
    try {
      final ref = FirebaseFirestore.instance.collection('users').doc(uid);
      final snap = await ref.get();
      final data = snap.data() ?? const <String, dynamic>{};

      // Absent fields (older accounts / never touched in Settings)
      // default to ON, so the reminder works without the user having
      // to go and enable anything.
      final notifyEnabled = (data['notifyEnabled'] as bool?) ??
          NexusNotify.cachedEnabled ??
          true;
      final reminderEnabled =
          (data['notifyProfileReminder'] as bool?) ?? true;

      NexusNotify.updateCache(enabled: notifyEnabled);
      _cachedReminderEnabled = reminderEnabled;

      if (!notifyEnabled || !reminderEnabled) return;

      // Did they set it up during the 5 minutes? Then there is
      // nothing to remind about -- now or ever.
      final missing = _missingFrom(data);
      if (missing.isEmpty) {
        _profileComplete = true;
        return;
      }

      // The 5-minute Timer above keeps counting down even while the
      // app is minimized/backgrounded (it is not cancelled by
      // didChangeAppLifecycleState), so this check can end up running
      // while nothing is on screen. Showing the bar then is pointless
      // -- its own 5-second auto-dismiss timer would fire while
      // invisible, and stamping "shown today" below would burn the
      // day's one reminder on a bar the user never saw. So if we're
      // not actually in the foreground right now, bail out WITHOUT
      // stamping anything: maybeShow() will simply re-arm a fresh
      // 5-minute wait the next time the app is actually resumed.
      if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        return;
      }

      final today = _dayKey(DateTime.now());
      _shownOn = (data['notifyProfileReminderShown'] ?? '').toString().trim();
      if (_shownOn == today) return; // already reminded once today

      // Stamp the day BEFORE showing, so two overlapping checks (or a
      // restart seconds later) can't produce a second bar today.
      _shownOn = today;
      unawaited(ref.set(
        {'notifyProfileReminderShown': today},
        SetOptions(merge: true),
      ));

      _show(missing);
    } catch (e) {
      debugPrint('Profile reminder check error: $e');
    } finally {
      _checking = false;
    }
  }

  /// Human labels for whichever of the four identity fields are still
  /// empty, in Me-page order.
  static List<String> _missingFrom(Map<String, dynamic> data) {
    String value(String key) => (data[key] ?? '').toString().trim();

    final missing = <String>[];
    if (value('publicName').isEmpty) missing.add('Public name');
    if (value('publicImage').isEmpty) missing.add('Public photo');
    if (value('privateName').isEmpty) missing.add('Private name');
    if (value('privateImage').isEmpty) missing.add('Private photo');
    return missing;
  }

  // ==========================================================
  // PRESENTATION
  // ==========================================================

  static void _show(List<String> missing) {
    if (_currentEntry != null) return;

    final context = rootNavigatorKey.currentContext;
    if (context == null || !context.mounted) return;

    final overlay = Overlay.of(context, rootOverlay: true);

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _ProfileReminderBar(
        missing: missing,
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

// ================================================================
// PROFILE REMINDER BAR
// ----------------------------------------------------------------
//   [person icon]   Complete your profile
//   [ 10:42 AM  ]   Public name, Private photo not set yet
//                   Me -> Public / Private profile
// Same box, entrance, swipe-to-dismiss and 5-second auto-dismiss as
// the other two bars in this file.
// ================================================================

class _ProfileReminderBar extends StatefulWidget {
  final List<String> missing;
  final VoidCallback onDismissed;

  const _ProfileReminderBar({
    required this.missing,
    required this.onDismissed,
  });

  @override
  State<_ProfileReminderBar> createState() => _ProfileReminderBarState();
}

class _ProfileReminderBarState extends State<_ProfileReminderBar>
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
      duration: const Duration(milliseconds: 280),
      reverseDuration: const Duration(milliseconds: 220),
    );
    _slide = Tween<Offset>(begin: const Offset(0, -1), end: Offset.zero)
        .animate(CurvedAnimation(parent: _entrance, curve: Curves.easeOutCubic));
    _fade = CurvedAnimation(parent: _entrance, curve: Curves.easeOut);
    _entrance.forward();

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

  /// "Public name and Private photo" / "Public name, Public photo and
  /// Private name" -- reads like a sentence however many are missing.
  String _missingLabel() {
    final items = widget.missing;
    if (items.isEmpty) return 'Your name and profile photo';
    if (items.length == 1) return items.first;
    return '${items.sublist(0, items.length - 1).join(', ')} '
        'and ${items.last}';
  }

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;
    final timeText = TimeOfDay.fromDateTime(DateTime.now()).format(context);

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
                  key: const ValueKey('nexus_profile_reminder'),
                  direction: DismissDirection.horizontal,
                  onDismissed: (_) {
                    _autoDismissTimer?.cancel();
                    widget.onDismissed();
                  },
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: AppColors.darkSheet,
                      borderRadius: BorderRadius.circular(14),
                      border:
                          Border.all(color: AppColors.saddleBrown, width: 1),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black45,
                          blurRadius: 12,
                          offset: Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // ---- left corner: icon + clock ----
                        Column(
                          children: [
                            const Icon(
                              Icons.account_circle_rounded,
                              color: AppColors.glow,
                              size: 22,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              timeText,
                              style: const TextStyle(
                                color: AppColors.tan,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Complete your profile',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                '${_missingLabel()} not set yet',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: AppColors.tan,
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 2),
                              const Text(
                                'Me  ->  Public / Private profile',
                                style: TextStyle(
                                  color: AppColors.darkTextMuted,
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
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