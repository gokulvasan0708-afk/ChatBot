import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'app_theme.dart';
import '../widgets/top_alert.dart';
import '../widgets/incoming_message_alert.dart';
import '../widgets/nexus_notify.dart';
import '../widgets/wind_down_alert.dart';

// ================================================================
// NEXUS NOTIFY -- SETTINGS PAGE
// ----------------------------------------------------------------
// Reached from Me -> Settings -> "Nexus Notify" (placed right below
// the Mode/Dark-Light row). Lets the user:
//
//   * "Notify"  -- a Switch that turns the top-of-screen greeting
//     bar (widgets/nexus_notify.dart) on/off. Stored as
//     users/{uid}.notifyEnabled (bool). When this is OFF,
//     NexusNotify.maybeShow() no-ops, so the bar never appears.
//
//   * "Name"    -- only shown while Notify is ON. Tapping it (or
//     the "Set"/name text on its trailing edge) opens a small
//     dialog to type/edit the greeting name. Saved to
//     users/{uid}.notifyName -- the SAME field the greeting bar
//     itself reads, so setting/editing it here is reflected in the
//     next "Good morning/afternoon/evening, <name>" greeting too.
//     Turning Notify OFF hides this row entirely; turning it back
//     ON restores it (and whatever name was already saved).
//
//   * "Profile reminder" -- a Switch for the once-a-day bar that
//     nudges the user to set their public and private name and
//     profile photo (NexusProfileNotify in
//     widgets/nexus_notify.dart). Stored as
//     users/{uid}.notifyProfileReminder (bool, absent == ON). The bar
//     itself appears 5 minutes after the app is opened, at most once
//     per calendar day, and stops for good once all four fields are
//     filled in.
//
//   * "Wind Down mode" -- a separate Switch, unrelated to the
//     greeting bar above. When ON, a "Starts at" row appears letting
//     the user pick an hour/minute (e.g. 10:00 PM). From that time
//     every night until a FIXED 5:00 AM, no push notifications
//     (chat/connection/call) are delivered to this device. The
//     window is checked fresh every time a notification is about to
//     be sent (see NotificationService._isReceiverInWindDown), so it
//     repeats automatically every day with no daily re-arming needed
//     -- it only stops happening once the user flips this Switch
//     back OFF themselves. Stored as users/{uid}.windDownEnabled
//     (bool), windDownStartHour (0-23), windDownStartMinute (0-59).
// ================================================================

class NexusNotifySettingsPage extends StatefulWidget {
  const NexusNotifySettingsPage({super.key});

  @override
  State<NexusNotifySettingsPage> createState() =>
      _NexusNotifySettingsPageState();
}

class _NexusNotifySettingsPageState extends State<NexusNotifySettingsPage> {
  bool _loading = true;
  bool _notifyEnabled = true;
  bool _greetingBarEnabled = true;
  String? _notifyName;
  bool _messageReminderEnabled = true;

  // "Message pop-up" -- the in-app heads-up bar that slides in from
  // the top when a message lands in another chat/group while the app
  // is open (widgets/incoming_message_alert.dart). Stored as
  // users/{uid}.notifyMessagePopup.
  bool _messagePopupEnabled = true;

  // "Profile reminder" -- the once-a-day nudge to set the public and
  // private name + profile photo on the Me page
  // (NexusProfileNotify in widgets/nexus_notify.dart). Stored as
  // users/{uid}.notifyProfileReminder.
  bool _profileReminderEnabled = true;

  bool _windDownEnabled = false;
  int _windDownStartHour = 22; // default 10:00 PM
  int _windDownStartMinute = 0;

  DocumentReference<Map<String, dynamic>>? get _userDoc {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;
    return FirebaseFirestore.instance.collection('users').doc(user.uid);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final docRef = _userDoc;
    if (docRef == null) {
      setState(() => _loading = false);
      return;
    }

    try {
      final snap = await docRef.get();
      final data = snap.data();

      setState(() {
        // Field absent (older accounts, or never touched before) ==
        // Notify defaults to ON, matching the greeting bar's existing
        // behaviour prior to this setting being introduced.
        _notifyEnabled = (data?['notifyEnabled'] as bool?) ?? true;
        _greetingBarEnabled =
            (data?['notifyGreetingBarEnabled'] as bool?) ?? true;
        _notifyName = data?['notifyName'] as String?;
        // Absent field (older accounts / never touched here) == the
        // message reminder defaults to ON.
        _messageReminderEnabled =
            (data?['notifyMessageReminder'] as bool?) ?? true;
        // Absent field == the pop-up bar defaults to ON, matching how
        // it behaved before this switch existed.
        _messagePopupEnabled =
            (data?['notifyMessagePopup'] as bool?) ?? true;
        // Absent field == the profile reminder defaults to ON, so a
        // brand new account gets the nudge without opting in.
        _profileReminderEnabled =
            (data?['notifyProfileReminder'] as bool?) ?? true;

        _windDownEnabled = (data?['windDownEnabled'] as bool?) ?? false;
        _windDownStartHour =
            (data?['windDownStartHour'] as num?)?.toInt() ?? 22;
        _windDownStartMinute =
            (data?['windDownStartMinute'] as num?)?.toInt() ?? 0;

        _loading = false;
      });
    } catch (e) {
      debugPrint('NexusNotify settings load error: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _setNotifyEnabled(bool value) async {
    setState(() => _notifyEnabled = value);

    final docRef = _userDoc;
    if (docRef == null) return;

    try {
      await docRef.set({'notifyEnabled': value}, SetOptions(merge: true));
      NexusNotify.updateCache(enabled: value);
      // Master switch also gates the in-app incoming-message bar
      // (widgets/incoming_message_alert.dart).
      IncomingMessageAlert.updateCache(enabled: value);
      // ...and the once-a-day "complete your profile" reminder.
      NexusProfileNotify.updateCache(enabled: value);
    } catch (e) {
      debugPrint('NexusNotify enable save error: $e');
      if (!mounted) return;
      showTopAlert(context, 'Could not save Notify setting', isError: true);
    }
  }

  Future<void> _setGreetingBarEnabled(bool value) async {
    setState(() => _greetingBarEnabled = value);

    final docRef = _userDoc;
    if (docRef == null) return;

    try {
      await docRef.set(
        {'notifyGreetingBarEnabled': value},
        SetOptions(merge: true),
      );
      NexusNotify.updateCache(greetingBarEnabled: value);
    } catch (e) {
      debugPrint('Greetings bar save error: $e');
      if (!mounted) return;
      showTopAlert(context, 'Could not save Greetings bar setting',
          isError: true);
    }
  }

  Future<void> _setMessageReminderEnabled(bool value) async {
    setState(() => _messageReminderEnabled = value);

    final docRef = _userDoc;
    if (docRef == null) return;

    try {
      await docRef.set(
        {'notifyMessageReminder': value},
        SetOptions(merge: true),
      );
      // Takes effect immediately -- turning it off also drops any
      // reminder bar that is currently on screen or queued.
      NexusUnseenNotify.updateCache(reminderEnabled: value);
    } catch (e) {
      debugPrint('Message reminder save error: $e');
      if (!mounted) return;
      showTopAlert(context, 'Could not save Message reminder setting',
          isError: true);
    }
  }

  Future<void> _setMessagePopupEnabled(bool value) async {
    setState(() => _messagePopupEnabled = value);

    final docRef = _userDoc;
    if (docRef == null) return;

    try {
      await docRef.set(
        {'notifyMessagePopup': value},
        SetOptions(merge: true),
      );
      // Takes effect immediately -- turning it off also drops any bar
      // currently on screen or queued.
      IncomingMessageAlert.updateCache(popupEnabled: value);
    } catch (e) {
      debugPrint('Message pop-up save error: $e');
      if (!mounted) return;
      showTopAlert(context, 'Could not save Message pop-up setting',
          isError: true);
    }
  }

  Future<void> _setProfileReminderEnabled(bool value) async {
    setState(() => _profileReminderEnabled = value);

    final docRef = _userDoc;
    if (docRef == null) return;

    try {
      await docRef.set(
        {'notifyProfileReminder': value},
        SetOptions(merge: true),
      );
      // Takes effect immediately -- turning it off also cancels the
      // pending 5-minute check and drops the bar if it is up.
      NexusProfileNotify.updateCache(reminderEnabled: value);
    } catch (e) {
      debugPrint('Profile reminder save error: $e');
      if (!mounted) return;
      showTopAlert(context, 'Could not save Profile reminder setting',
          isError: true);
    }
  }

  Future<void> _openNameDialog() async {
    final controller = TextEditingController(text: _notifyName ?? '');

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: AppColors.darkSheet,
          title: Text(
            (_notifyName == null || _notifyName!.trim().isEmpty)
                ? 'Set Name'
                : 'Edit Name',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
          content: TextField(
            controller: controller,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            cursorColor: AppColors.tan,
            decoration: const InputDecoration(
              hintText: 'Enter name',
              hintStyle: TextStyle(color: AppColors.darkTextMuted),
              enabledBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: AppColors.darkCardBorder),
              ),
              focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: AppColors.tan, width: 2),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('CANCEL'),
            ),
            TextButton(
              onPressed: () async {
                final name = controller.text.trim();
                Navigator.pop(dialogContext);
                await _saveName(name);
              },
              child: const Text(
                'OK',
                style: TextStyle(
                  color: AppColors.tan,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _saveName(String name) async {
    final docRef = _userDoc;
    if (docRef == null) return;

    try {
      await docRef.set({'notifyName': name}, SetOptions(merge: true));
      NexusNotify.updateCache(name: name);
      if (!mounted) return;
      setState(() => _notifyName = name.isEmpty ? null : name);
    } catch (e) {
      debugPrint('NexusNotify name save error: $e');
      if (!mounted) return;
      showTopAlert(context, 'Could not save name', isError: true);
    }
  }

  // ================================================================
  // WIND DOWN MODE
  // ================================================================

  Future<void> _setWindDownEnabled(bool value) async {
    setState(() => _windDownEnabled = value);

    final docRef = _userDoc;
    if (docRef == null) return;

    try {
      await docRef.set({'windDownEnabled': value}, SetOptions(merge: true));
      WindDownAlert.updateCache(enabled: value);
    } catch (e) {
      debugPrint('Wind Down enable save error: $e');
      if (!mounted) return;
      showTopAlert(context, 'Could not save Wind Down setting', isError: true);
    }
  }

  Future<void> _pickWindDownStartTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: _windDownStartHour,
        minute: _windDownStartMinute,
      ),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.dark(
              primary: AppColors.tan,
              onPrimary: Colors.black,
              surface: AppColors.darkSheet,
              onSurface: Colors.white,
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked == null) return;
    await _saveWindDownStartTime(picked.hour, picked.minute);
  }

  Future<void> _saveWindDownStartTime(int hour, int minute) async {
    final docRef = _userDoc;
    if (docRef == null) return;

    try {
      await docRef.set(
        {
          'windDownStartHour': hour,
          'windDownStartMinute': minute,
        },
        SetOptions(merge: true),
      );
      WindDownAlert.updateCache(startHour: hour, startMinute: minute);
      if (!mounted) return;
      setState(() {
        _windDownStartHour = hour;
        _windDownStartMinute = minute;
      });
    } catch (e) {
      debugPrint('Wind Down start time save error: $e');
      if (!mounted) return;
      showTopAlert(context, 'Could not save Wind Down start time', isError: true);
    }
  }

  String _formatTime(int hour, int minute) {
    final period = hour >= 12 ? 'PM' : 'AM';
    final displayHour = hour % 12 == 0 ? 12 : hour % 12;
    final displayMinute = minute.toString().padLeft(2, '0');
    return '$displayHour:$displayMinute $period';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Nexus Notify',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.tan),
            )
          : ListView(
              children: [
                // "Notify" is now the single master switch for
                // everything below it -- the greeting bar, the Name
                // field, the Message reminder, and Wind Down mode.
                // Turning it OFF hides every row underneath (they only
                // make sense as sub-options of Notify) AND turns their
                // functionality off too, regardless of what each of
                // their own switches was individually set to.
                ListTile(
                  leading: Icon(
                    _notifyEnabled
                        ? Icons.notifications_active_rounded
                        : Icons.notifications_off_rounded,
                    color: AppColors.tan,
                  ),
                  title: const Text(
                    'Notify',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  subtitle: Text(
                    _notifyEnabled
                        ? 'Greetings, message reminders and Wind Down are on'
                        : 'All Nexus Notify alerts are off',
                    style: const TextStyle(color: AppColors.darkTextMuted),
                  ),
                  trailing: Switch(
                    value: _notifyEnabled,
                    activeThumbColor: AppColors.tan,
                    onChanged: _setNotifyEnabled,
                  ),
                  onTap: () => _setNotifyEnabled(!_notifyEnabled),
                ),

                // Everything from here down is a sub-option of Notify --
                // hidden completely (not just greyed out) the moment
                // it's off.
                if (_notifyEnabled) ...[
                  ListTile(
                    leading: const Icon(
                      Icons.badge_outlined,
                      color: AppColors.tan,
                    ),
                    title: const Text(
                      'Name',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    trailing: GestureDetector(
                      onTap: _openNameDialog,
                      child: Text(
                        (_notifyName == null || _notifyName!.trim().isEmpty)
                            ? 'Set'
                            : _notifyName!,
                        style: const TextStyle(
                          color: AppColors.tan,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    onTap: _openNameDialog,
                  ),

                  // "Greetings bar" -- own on/off for just the time-of-
                  // day greeting bar (widgets/nexus_notify.dart's
                  // NexusNotify), sitting right under Name. Message
                  // reminder and Wind Down mode below are unaffected by
                  // this one.
                  ListTile(
                    leading: Icon(
                      _greetingBarEnabled
                          ? Icons.wb_sunny_rounded
                          : Icons.wb_sunny_outlined,
                      color: AppColors.tan,
                    ),
                    title: const Text(
                      'Greetings bar',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    subtitle: Text(
                      _greetingBarEnabled
                          ? 'Good morning/afternoon/evening bar is shown'
                          : 'Greetings bar is hidden',
                      style: const TextStyle(color: AppColors.darkTextMuted),
                    ),
                    trailing: Switch(
                      value: _greetingBarEnabled,
                      activeThumbColor: AppColors.tan,
                      onChanged: _setGreetingBarEnabled,
                    ),
                    onTap: () => _setGreetingBarEnabled(!_greetingBarEnabled),
                  ),

                  // "Message reminder" -- controls the unseen-messages
                  // reminder bar (NexusUnseenNotify in
                  // widgets/nexus_notify.dart): the one that says
                  // "<name> have a unseen messages" for chats/groups
                  // still showing an unread dot, repeating about once an
                  // hour. OFF here means it never appears.
                  ListTile(
                    leading: Icon(
                      _messageReminderEnabled
                          ? Icons.mark_chat_unread_rounded
                          : Icons.mark_chat_read_outlined,
                      color: AppColors.tan,
                    ),
                    title: const Text(
                      'Message reminder',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    subtitle: Text(
                      _messageReminderEnabled
                          ? 'Reminds you about unseen messages'
                          : 'Unseen message reminders are off',
                      style: const TextStyle(color: AppColors.darkTextMuted),
                    ),
                    trailing: Switch(
                      value: _messageReminderEnabled,
                      activeThumbColor: AppColors.tan,
                      onChanged: _setMessageReminderEnabled,
                    ),
                    onTap: () => _setMessageReminderEnabled(
                        !_messageReminderEnabled),
                  ),

                  // "Message pop-up" -- this bar's own on/off switch,
                  // sitting directly above "Wind Down mode". Controls
                  // the in-app heads-up bar shown when a message lands
                  // in ANOTHER chat/group while the app is open
                  // (IncomingMessageAlert in
                  // widgets/incoming_message_alert.dart). OFF here means
                  // that bar never appears; the system notification for
                  // a closed/backgrounded app is unaffected, and so are
                  // Greetings bar / Message reminder / Wind Down mode.
                  ListTile(
                    leading: Icon(
                      _messagePopupEnabled
                          ? Icons.chat_bubble_rounded
                          : Icons.chat_bubble_outline_rounded,
                      color: AppColors.tan,
                    ),
                    title: const Text(
                      'Message pop-up',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    subtitle: Text(
                      _messagePopupEnabled
                          ? 'New messages pop up at the top while the app is open'
                          : 'No pop-up bar for new messages inside the app',
                      style: const TextStyle(color: AppColors.darkTextMuted),
                    ),
                    trailing: Switch(
                      value: _messagePopupEnabled,
                      activeThumbColor: AppColors.tan,
                      onChanged: _setMessagePopupEnabled,
                    ),
                    onTap: () =>
                        _setMessagePopupEnabled(!_messagePopupEnabled),
                  ),

                  // "Profile reminder" -- the once-a-day nudge to set
                  // the public AND private name + profile photo on the
                  // Me page (NexusProfileNotify in
                  // widgets/nexus_notify.dart). It appears 5 minutes
                  // after the app is opened, only once per day, and
                  // retires itself for good as soon as all four are
                  // set. OFF here means it never appears.
                  ListTile(
                    leading: Icon(
                      _profileReminderEnabled
                          ? Icons.account_circle_rounded
                          : Icons.account_circle_outlined,
                      color: AppColors.tan,
                    ),
                    title: const Text(
                      'Profile reminder',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    subtitle: Text(
                      _profileReminderEnabled
                          ? 'Reminds you once a day to set your name and photo'
                          : 'Profile reminders are off',
                      style: const TextStyle(color: AppColors.darkTextMuted),
                    ),
                    trailing: Switch(
                      value: _profileReminderEnabled,
                      activeThumbColor: AppColors.tan,
                      onChanged: _setProfileReminderEnabled,
                    ),
                    onTap: () =>
                        _setProfileReminderEnabled(!_profileReminderEnabled),
                  ),

                  // "Wind Down mode" -- now also a sub-option of Notify:
                  // turning the master switch off silences this too (see
                  // WindDownAlert.maybeShow and
                  // NotificationService._isReceiverInWindDown), not just
                  // this row's own visibility.
                  ListTile(
                    leading: Icon(
                      _windDownEnabled
                          ? Icons.nightlight_round
                          : Icons.nightlight_outlined,
                      color: AppColors.tan,
                    ),
                    title: const Text(
                      'Wind Down mode',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    subtitle: Text(
                      _windDownEnabled
                          ? 'Silent from ${_formatTime(_windDownStartHour, _windDownStartMinute)} '
                              'to 5:00 AM, every day'
                          : 'No notifications during your sleep hours',
                      style: const TextStyle(color: AppColors.darkTextMuted),
                    ),
                    trailing: Switch(
                      value: _windDownEnabled,
                      activeThumbColor: AppColors.tan,
                      onChanged: _setWindDownEnabled,
                    ),
                    onTap: () => _setWindDownEnabled(!_windDownEnabled),
                  ),

                  // "Starts at" -- only shown while Wind Down mode is ON.
                  // The end time is fixed at 5:00 AM and is not editable.
                  if (_windDownEnabled)
                    ListTile(
                      leading: const Icon(
                        Icons.access_time_rounded,
                        color: AppColors.tan,
                      ),
                      title: const Text(
                        'Starts at',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      subtitle: const Text(
                        'Ends automatically at 5:00 AM',
                        style: TextStyle(color: AppColors.darkTextMuted),
                      ),
                      trailing: GestureDetector(
                        onTap: _pickWindDownStartTime,
                        child: Text(
                          _formatTime(
                              _windDownStartHour, _windDownStartMinute),
                          style: const TextStyle(
                            color: AppColors.tan,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      onTap: _pickWindDownStartTime,
                    ),
                ],
              ],
            ),
    );
  }
}