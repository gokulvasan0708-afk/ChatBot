// ================================================================
// ACTIVE CONVERSATION TRACKER
// ----------------------------------------------------------------
// Tiny, dependency-free record of WHICH conversation screen the user
// is looking at right now.
//
// WHY IT EXISTS
// -------------
// The in-app heads-up banner (see widgets/incoming_message_alert.dart)
// must behave like a real notification: it pops for a new message in
// ANY other chat or group, but it must NEVER pop for the very chat /
// group whose screen is already open -- there the message simply
// appears in the thread, so a banner on top of it would be noise.
//
// This lives in its own file (instead of inside the banner widget)
// purely so pages/chat_screen.dart and pages/groupchat.dart can push
// and pop their own identity without importing the banner file, and
// the banner file can import the chat pages for tap-to-open, with no
// circular import between them.
//
// USAGE
// -----
//   // chat_screen.dart
//   ActiveConversation.push(ActiveConversation.chatKey(chatId));   // initState
//   ActiveConversation.pop(ActiveConversation.chatKey(chatId));    // dispose
//
//   // groupchat.dart
//   ActiveConversation.push(ActiveConversation.groupKey(groupId));
//   ActiveConversation.pop(ActiveConversation.groupKey(groupId));
//
// A STACK, not a single value: opening chat B from inside chat A
// (e.g. forward -> open) means B's initState runs BEFORE A's dispose,
// so a single "current" field would be cleared by the screen that was
// just closed and leave the app thinking nothing is open. Push/pop of
// explicit keys is immune to that ordering.
// ================================================================

class ActiveConversation {
  ActiveConversation._();

  static final List<String> _stack = <String>[];

  /// Stable key for a 1-to-1 chat document id.
  static String chatKey(String chatId) => 'chat:$chatId';

  /// Stable key for a group document id.
  static String groupKey(String groupDocId) => 'group:$groupDocId';

  /// Marks this conversation screen as on-screen.
  static void push(String key) {
    if (key.trim().isEmpty) return;
    _stack.add(key);
  }

  /// Marks this conversation screen as gone. Removes only the LAST
  /// occurrence of this exact key, so a screen closing never clears a
  /// different screen that opened over it.
  static void pop(String key) {
    for (int i = _stack.length - 1; i >= 0; i--) {
      if (_stack[i] == key) {
        _stack.removeAt(i);
        return;
      }
    }
  }

  /// True while the given conversation's own screen is open.
  static bool isOpen(String key) => _stack.contains(key);

  /// Sign out / account switch -- forget everything.
  static void clear() => _stack.clear();
}