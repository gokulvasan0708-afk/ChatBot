import 'package:flutter/material.dart';

import '../features/ai_assistant/ai_launcher.dart';

import 'chat_page.dart';
import 'community_page.dart';
import 'me_page.dart';
import 'public_name_dialog.dart';
import '../services/user_profile_service.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../widgets/incoming_message_alert.dart';
import '../widgets/nexus_notify.dart';
import '../widgets/wind_down_alert.dart';

// ================================================================
// HOME SHELL
// ----------------------------------------------------------------
// Hosts the Chats tab (ChatPage) and the Me tab (MePage) as the two
// children of a single IndexedStack, and owns which one is currently
// visible. This is the app's actual "home" destination now -- every
// place that used to navigate straight to `ChatPage()` on app entry
// (splash screen, login) now navigates to `HomeShell()` instead.
//
// WHY THIS FIXES "Chats <-> Me instant switching":
// Previously, tapping "Me" on the Chats page did
//   Navigator.pushReplacement(context, MaterialPageRoute(_) => MePage())
// and tapping "Chats" on the Me page did the reverse (push/pop, or a
// brand new ChatPage() on the swipe gesture). Every single switch
// therefore ran a full `initState()` on the destination page: its
// Firestore listeners (connections stream, profile stream, members
// stream, auth-state stream, etc.) were torn down and resubscribed,
// profile data was re-fetched, and the page visibly rebuilt from
// nothing before data started flowing back in.
//
// An IndexedStack lays out and keeps ALL of its children mounted in
// the widget tree at all times; it only controls which one is
// *painted and hit-testable* via `index`. Flutter's element/state
// reconciliation matches widgets to existing Elements by runtimeType
// + tree position (not identity of the widget instance a `build()`
// happens to construct), so on every HomeShellState rebuild the new
// `ChatPage(...)` / `MePage(...)` widget instances are diffed against
// the SAME underlying `State<ChatPage>` / `State<MePage>` objects --
// Flutter calls `didUpdateWidget` on them, never `initState` again.
// Switching tabs therefore becomes a synchronous index flip with no
// dispose/init cycle, no listener teardown, and no lost scroll
// position/search text/toggle state on either page.
//
// Both pages keep their own Scaffold (including their own
// bottomNavigationBar) exactly as before -- HomeShell does not wrap
// them in an outer Scaffold, so nothing about their layout or the
// existing bottom-nav visuals changes. Only ONE of the two Scaffolds
// is ever painted at a time (IndexedStack hides the rest), so there
// is no visual conflict from having two Scaffolds in the tree.
// ================================================================

class HomeShell extends StatefulWidget {
  /// Which tab to land on when the shell is first built.
  /// 0 = Chats (default), 1 = Community, 2 = Me.
  final int initialIndex;

  const HomeShell({super.key, this.initialIndex = 0});

  @override
  State<HomeShell> createState() => HomeShellState();
}

class HomeShellState extends State<HomeShell>
    with WidgetsBindingObserver, AiHomeVisibility {
  late int _index =
      (widget.initialIndex >= 0 && widget.initialIndex <= 2)
          ? widget.initialIndex
          : 0;

  // Ticks every time the Me page's swipe-to-Chats gesture wants the
  // already-alive ChatPage to reset to Public specifically (as
  // opposed to a plain bottom-nav tab switch, which must preserve
  // whatever state ChatPage was already in). ChatPage listens for
  // this in its own initState/dispose.
  final ValueNotifier<int> _publicResetSignal = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Fire once the first frame after landing on the home shell is
    // up, so the top greeting bar (see widgets/nexus_notify.dart)
    // can check whether the current time-of-day window still needs
    // to be shown today.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        NexusNotify.maybeShow(context);
        // Unseen-messages reminder (widgets/nexus_notify.dart) -- the
        // same conversations that are showing an unread dot in the
        // Chats list / Groups tab get a Notify bar here, repeated
        // about once an hour while they stay unopened.
        NexusUnseenNotify.maybeShow(context);
        // Wind Down "starts in N min" heads-up (widgets/wind_down_alert.dart)
        // -- separate one-time-per-day check, own Firestore bookkeeping.
        WindDownAlert.maybeShow(context);
        // "Complete your profile" reminder (widgets/nexus_notify.dart)
        // -- arms a 5-minute check, then shows at most once a day
        // until the public/private name and photo are set, after
        // which it retires itself.
        NexusProfileNotify.maybeShow(context);
        // In-app heads-up bar for NEW messages that land while the
        // app is open (widgets/incoming_message_alert.dart). Starts the
        // chats/groups listeners once; it no-ops if already running.
        IncomingMessageAlert.start();
        // Public name == Account ID is compulsory: block the app with
        // a non-dismissible dialog until it is set.
        _ensurePublicName();
      }
    });
  }

  bool _askingPublicName = false;

  Future<void> _ensurePublicName() async {
    if (_askingPublicName) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    _askingPublicName = true;
    try {
      final profile = await UserProfileService.getCurrentUserProfile();
      if (!mounted) return;
      if (!UserProfileService.needsPublicName(profile)) return;

      final old = (profile?['publicName'] ?? '').toString().trim();
      await showPublicNameDialog(
        context,
        mandatory: true,
        initial: UserProfileService.validatePublicName(old) == null ? old : '',
      );
    } catch (e) {
      debugPrint('Public name check error: $e');
    } finally {
      _askingPublicName = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-check on every foreground resume too (app minimized then
    // reopened later the same day, e.g. morning -> afternoon, or the
    // user reopening the app partway through the 5-minute Wind Down
    // pre-window).
    if (state == AppLifecycleState.resumed && mounted) {
      NexusNotify.maybeShow(context);
      NexusUnseenNotify.maybeShow(context);
      WindDownAlert.maybeShow(context);
      NexusProfileNotify.maybeShow(context);
      IncomingMessageAlert.start();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Stops the hourly unseen-messages re-check timer and clears its
    // per-account bookkeeping (important on sign out / account switch).
    NexusUnseenNotify.stop();
    // Drops the chats/groups listeners for the incoming-message bar
    // and clears its per-account bookkeeping.
    IncomingMessageAlert.stop();
    // Cancels the pending 5-minute profile check too.
    NexusProfileNotify.stop();
    _publicResetSignal.dispose();
    super.dispose();
  }

  void _switchTo(int index) {
    if (!mounted || _index == index) return;
    setState(() => _index = index);
  }

  void _switchToChatsTab() => _switchTo(0);

  void _switchToCommunityTab() => _switchTo(1);

  void _switchToMeTab() => _switchTo(2);

  void _goToPublicChats() {
    // Bump first so ChatPage's listener fires before/around the tab
    // switch regardless of build ordering.
    _publicResetSignal.value = _publicResetSignal.value + 1;
    _switchTo(0);
  }

  @override
  Widget build(BuildContext context) {
    return IndexedStack(
      index: _index,
      children: [
        ChatPage(
          onSwitchToMe: _switchToMeTab,
          onSwitchToCommunity: _switchToCommunityTab,
          publicResetSignal: _publicResetSignal,
        ),
        CommunityPage(
          onSwitchToChats: _switchToChatsTab,
          onSwitchToMe: _switchToMeTab,
        ),
        MePage(
          onSwitchToChats: _switchToChatsTab,
          onSwitchToCommunity: _switchToCommunityTab,
          onRequestPublicChats: _goToPublicChats,
        ),
      ],
    );
  }
}