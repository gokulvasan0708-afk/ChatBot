import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_theme.dart';
import '../services/api_service.dart';
import '../services/notification_service.dart';
import 'chat_screen.dart';
import 'private_chat_screen.dart';
import 'groupchat.dart';

import '../widgets/top_alert.dart';
// ================================================================
// PROFILE IMAGE PROVIDER
// ----------------------------------------------------------------
// Same small helper duplicated in chat_page.dart / chat_screen.dart /
// private_chat_screen.dart -- public/private profile pictures (and
// now group profile pictures) are Cloudinary https:// URLs stored in
// Firestore, not bundled assets, so they need NetworkImage rather
// than AssetImage.
// ================================================================

ImageProvider? _profileImageProvider(String path) {
  final value = path.trim();
  if (value.isEmpty) return null;
  if (value.startsWith('http://') || value.startsWith('https://')) {
    return NetworkImage(value);
  }
  return AssetImage(value);
}

// ================================================================
// GROUPS TAB
// ----------------------------------------------------------------
// Hosted inside the "Groups" segment of the Hubs page's Community /
// Clubs / Groups switcher (see community_page.dart). Self-contained,
// exactly like ChatPage / MePage / CommunityPage itself -- it reads
// FirebaseAuth.instance.currentUser directly instead of needing it
// passed in.
//
// Empty state (no groups yet):
//   "Join Group" / "Create Group" -- same two-button empty state
//   pattern already used for Community/Clubs/Groups in
//   community_page.dart.
//
// Has at least one group:
//   Search field + "+" (opens Create Group) at the top, the list of
//   groups underneath.
// ================================================================

class GroupsTab extends StatefulWidget {
  const GroupsTab({super.key});

  @override
  State<GroupsTab> createState() => _GroupsTabState();
}

class _GroupsTabState extends State<GroupsTab> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  String _searchQuery = '';

  // ==========================================================
  // GROUPS STREAM
  // ----------------------------------------------------------
  // Created ONCE here (not inline inside build()). A Query's
  // .snapshots() called directly in build() returns a brand new
  // Stream object on every rebuild, which makes StreamBuilder
  // drop its old subscription and start a fresh one -- briefly
  // going back to ConnectionState.waiting and rebuilding the
  // whole subtree (including the search TextField) from scratch
  // every time. Since every keystroke in the search box calls
  // setState() -> rebuild, that was tearing down and recreating
  // the TextField on every character, which is what was closing
  // the keyboard after each letter. Keeping one stable Stream
  // instance across rebuilds fixes it.
  // ==========================================================
  Stream<QuerySnapshot<Map<String, dynamic>>>? _groupsStream;

  // ==========================================================
  // GROUP DISCOVERY (search suggestion)
  // ----------------------------------------------------------
  // Separate from the local filter below -- this looks up ANY
  // group in the whole app (not just ones the user is a member
  // of) by an EXACT (not partial) groupName match, so someone
  // can find "Gaming City" and join it without already being a
  // member. Debounced and re-checked against the live text so a
  // slow query response can't clobber a newer keystroke.
  // ==========================================================
  Timer? _debounce;
  Map<String, dynamic>? _discoveredGroup;

  @override
  void initState() {
    super.initState();
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      _groupsStream = FirebaseFirestore.instance
          .collection('groups')
          .where('members', arrayContains: uid)
          .snapshots();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  // Drops focus (and closes the keyboard) on the search field. Used
  // both for the general "tap anywhere" dismiss below, and explicitly
  // around opening a group's chat -- once BEFORE navigating away (in
  // case the field was still focused at the moment of the tap) and
  // once again AFTER returning from it, since Flutter can otherwise
  // restore the field's previous focus when this tab's route becomes
  // active again on the way back from GroupChatScreen.
  void _unfocusSearch() {
    if (_searchFocusNode.hasFocus) _searchFocusNode.unfocus();
  }

  void _onSearchChanged(String value) {
    setState(() => _searchQuery = value);

    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 350),
      () => _lookupExactGroup(value),
    );
  }

  Future<void> _lookupExactGroup(String rawValue) async {
    final query = rawValue.trim();

    if (query.isEmpty) {
      if (mounted) setState(() => _discoveredGroup = null);
      return;
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      final snap = await FirebaseFirestore.instance
          .collection('groups')
          .where('groupName', isEqualTo: query)
          .limit(1)
          .get();

      // The user may have kept typing while this query was in
      // flight -- if the box no longer holds what we searched
      // for, drop this result instead of showing a stale suggestion.
      if (!mounted || _searchController.text.trim() != query) return;

      if (snap.docs.isEmpty) {
        setState(() => _discoveredGroup = null);
        return;
      }

      final doc = snap.docs.first;
      final data = doc.data();
      final members = (data['members'] is List)
          ? List<String>.from(data['members'])
          : <String>[];

      // Already a member -> it's already in the list below, no
      // need for a "discover and join" suggestion for it.
      if (members.contains(user.uid)) {
        setState(() => _discoveredGroup = null);
        return;
      }

      setState(() {
        _discoveredGroup = {
          'groupId': (data['groupId'] ?? '').toString(),
          'groupName': (data['groupName'] ?? '').toString(),
          'groupProfileImage': (data['groupProfileImage'] ?? '').toString(),
        };
      });
    } catch (e) {
      debugPrint('Group discovery search error: $e');
    }
  }

  void _openJoinDiscoveredGroup() {
    final group = _discoveredGroup;
    if (group == null) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _JoinGroupDialog(
        initialGroupId: group['groupId']?.toString(),
      ),
    );
  }

  void _openCreateGroup() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _CreateGroupDialog(),
    );
  }

  // ==========================================================
  // JOIN GROUP
  // Opened from the empty-state "Join Group" button. Group ID +
  // password are entered manually -- see _JoinGroupDialog.
  // ==========================================================

  void _openJoinGroup() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _JoinGroupDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || _groupsStream == null) return const SizedBox.shrink();

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _groupsStream,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Center(
            child: Text(
              'Unable to load groups',
              style: TextStyle(color: Colors.white54),
            ),
          );
        }

        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(color: Color(0xFFD2B48C)),
          );
        }

        // Community chats / community groups live inside Community only --
        // never in this Groups tab.
        final groups = (snapshot.data?.docs ?? []).where((doc) {
          final d = doc.data();
          if (d['isCommunityChat'] == true) return false;
          if ((d['communityId'] ?? '').toString().isNotEmpty) return false;
          if ((d['communityDocId'] ?? '').toString().isNotEmpty) return false;
          return true;
        }).toList();

        // ====================================================
        // EMPTY STATE -- Join Group / Create Group only.
        // ====================================================
        if (groups.isEmpty) {
          return _GroupsEmptyState(
            onJoin: _openJoinGroup,
            onCreate: _openCreateGroup,
          );
        }

        // ====================================================
        // HAS GROUPS -- Search + "+" + list.
        // ----------------------------------------------------
        // Search only ever filters this user's own groups (created,
        // joined by accepting a group request, or joined by Group
        // ID + password) -- it never queries or shows groups the
        // user isn't a member of. Clearing the search box returns
        // the full list.
        // ====================================================
        final query = _searchQuery.trim().toLowerCase();

        final filtered = query.isEmpty
            ? groups
            : groups.where((doc) {
                final data = doc.data();
                final name = (data['groupName'] ?? '').toString().toLowerCase();
                final gid = (data['groupId'] ?? '').toString().toLowerCase();
                return name.contains(query) || gid.contains(query);
              }).toList();

        final sortedGroups =
            List<QueryDocumentSnapshot<Map<String, dynamic>>>.from(filtered);
        sortedGroups.sort((a, b) {
          final aTime = a.data()['createdAt'];
          final bTime = b.data()['createdAt'];
          final aT = aTime is Timestamp ? aTime : null;
          final bT = bTime is Timestamp ? bTime : null;
          if (aT == null && bT == null) return 0;
          if (aT == null) return 1;
          if (bT == null) return -1;
          return bT.compareTo(aT);
        });

        return GestureDetector(
          // Tapping anywhere else in the tab (empty space, a group
          // tile, the "+" button, etc.) drops focus from the search
          // field and closes the keyboard. Translucent so it never
          // blocks the taps on the buttons/tiles underneath it.
          behavior: HitTestBehavior.translucent,
          onTap: () => FocusScope.of(context).unfocus(),
          child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ------------------------------------------------
            // Search (top) + "+" (next to search)
            // ------------------------------------------------
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Row(
                children: [
                  Expanded(
                    child: _GroupSearchField(
                      controller: _searchController,
                      focusNode: _searchFocusNode,
                      onChanged: _onSearchChanged,
                    ),
                  ),
                  const SizedBox(width: 10),
                  _AddGroupButton(onTap: _openCreateGroup),
                ],
              ),
            ),

            // ------------------------------------------------
            // Discover-and-join suggestion -- only shown when the
            // typed text is an EXACT match for a group the user
            // isn't already in (see _lookupExactGroup above).
            // ------------------------------------------------
            if (_discoveredGroup != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: _GroupSuggestionTile(
                  group: _discoveredGroup!,
                  onTap: _openJoinDiscoveredGroup,
                ),
              ),

            // ------------------------------------------------
            // Groups list
            // ------------------------------------------------
            Expanded(
              child: sortedGroups.isEmpty
                  ? const Center(
                      child: Text(
                        'No groups match your search',
                        style: TextStyle(color: Colors.white54),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                      itemCount: sortedGroups.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        return _GroupListTile(
                          doc: sortedGroups[index],
                          onUnfocusSearch: _unfocusSearch,
                        );
                      },
                    ),
            ),
          ],
          ),
        );
      },
    );
  }
}

// ================================================================
// SEARCH FIELD (top of Groups tab, once >=1 group exists)
// ================================================================

class _GroupSearchField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;
  final ValueChanged<String> onChanged;

  const _GroupSearchField({
    required this.controller,
    this.focusNode,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF1B120A),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: const Color(0xFFD2B48C).withValues(alpha: .35),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.search_rounded, color: Colors.white54, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              onChanged: onChanged,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: const InputDecoration(
                hintText: 'Search groups',
                hintStyle: TextStyle(color: Colors.white38, fontSize: 14),
                border: InputBorder.none,
                isDense: true,
              ),
            ),
          ),
          // Clear ("x") icon -- only appears once there's text typed,
          // right-aligned inside the search bar. Tapping it clears
          // the field and re-runs onChanged('') so the filtered list
          // (and the discover-and-join lookup) reset immediately.
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) {
              if (value.text.isEmpty) return const SizedBox.shrink();
              return GestureDetector(
                onTap: () {
                  controller.clear();
                  onChanged('');
                },
                child: const Padding(
                  padding: EdgeInsets.only(left: 6),
                  child: Icon(Icons.close_rounded, color: Colors.white54, size: 18),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

// ================================================================
// GROUP SUGGESTION TILE (exact-match search result, not a member)
// ----------------------------------------------------------------
// Tapping it opens _JoinGroupDialog with the Group ID pre-filled --
// the user still has to enter the password themselves, same as a
// manual "Join Group".
// ================================================================

class _GroupSuggestionTile extends StatelessWidget {
  final Map<String, dynamic> group;
  final VoidCallback onTap;

  const _GroupSuggestionTile({
    required this.group,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final String name = (group['groupName'] ?? '').toString();
    final String groupId = (group['groupId'] ?? '').toString();
    final String image = (group['groupProfileImage'] ?? '').toString();

    return Material(
      color: const Color(0xFF1B120A),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: const Color(0xFFD2B48C).withValues(alpha: .5),
            ),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: const Color(0xFF2A1B0E),
                backgroundImage: _profileImageProvider(image),
                child: image.isEmpty
                    ? const Icon(Icons.diversity_3_rounded,
                        color: Colors.white70, size: 20)
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      groupId,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                'Join',
                style: TextStyle(
                  color: Color(0xFFD2B48C),
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.arrow_forward_ios_rounded,
                  color: Color(0xFFD2B48C), size: 13),
            ],
          ),
        ),
      ),
    );
  }
}

// ================================================================
// "+" BUTTON (next to search) -- opens Create Group
// ================================================================

class _AddGroupButton extends StatelessWidget {
  final VoidCallback onTap;

  const _AddGroupButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: AppColors.goldGradient,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: const SizedBox(
            width: 44,
            height: 44,
            child: Icon(Icons.add_rounded, color: Color(0xFF1B120A), size: 24),
          ),
        ),
      ),
    );
  }
}

// ================================================================
// GROUP ACTIVE-MEMBERS STATUS
// ----------------------------------------------------------------
// Shared by the Groups tab list tile below (_GroupListTile) and the
// group chat screen's own header (groupchat.dart) so both places
// report the exact same live "N active" count, using the exact same
// green presence dot already used for 1-to-1 chats in
// chat_screen.dart's PresenceStatusDot. It listens to the `users`
// collection for every member of the group and counts how many of
// them currently have `isActive == true` -- the same field written
// by ChatSettingsService.updatePresence() and read by
// ChatSettingsService.activeLabel() for private chats.
//
// - 0 members active right now -> `fallback` is shown instead, so
//   existing call sites keep their current content (the Group ID in
//   the tab list, "N members" in the group chat header).
// - >=1 member active -> a single pulsing green dot + "N active".
// - The signed-in user's own presence is excluded from this count --
//   a member should never see themselves counted as one of the
//   "active" people in their own group.
//
// NOTE: Firestore's `whereIn` supports at most 30 values, so for
// groups bigger than 30 members only the first 30 member UIDs are
// checked. This keeps the query simple and index-free for the
// overwhelming majority of groups; chunk + merge multiple queries
// later if larger groups need exact counts.
// ================================================================

class GroupActiveMembersStatus extends StatelessWidget {
  final List<String> members;
  final Widget fallback;
  final TextStyle? textStyle;

  const GroupActiveMembersStatus({
    super.key,
    required this.members,
    required this.fallback,
    this.textStyle,
  });

  @override
  Widget build(BuildContext context) {
    final uids = members.take(30).toList();
    if (uids.isEmpty) return fallback;

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      // Filtered by document ID only (no compound `isActive` filter
      // in the query itself) so this never needs a composite index --
      // the isActive check happens client-side below.
      stream: FirebaseFirestore.instance
          .collection('users')
          .where(FieldPath.documentId, whereIn: uids)
          .snapshots(),
      builder: (context, snapshot) {
        final docs = snapshot.data?.docs ?? const [];
        final myUid = FirebaseAuth.instance.currentUser?.uid;
        final activeCount = docs
            .where((d) => d.id != myUid && d.data()['isActive'] == true)
            .length;

        if (activeCount <= 0) return fallback;

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const PresenceStatusDot(isActive: true),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                '$activeCount active',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textStyle ??
                    const TextStyle(color: Colors.white54, fontSize: 12.5),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ================================================================
// GROUP LIST TILE
// ================================================================

class _GroupListTile extends StatefulWidget {
  final QueryDocumentSnapshot<Map<String, dynamic>> doc;
  final VoidCallback onUnfocusSearch;

  const _GroupListTile({required this.doc, required this.onUnfocusSearch});

  @override
  State<_GroupListTile> createState() => _GroupListTileState();
}

class _GroupListTileState extends State<_GroupListTile> {
  // Ticks once every 30s ONLY while the group is asleep, so the
  // "Sleeps in Xh Ym" countdown next to the member count keeps
  // counting down live, and the tile flips back to normal on its
  // own once the timer/date passes -- without needing a fresh
  // Firestore write. Idle (not sleeping) tiles don't tick at all.
  Timer? _tick;

  // ==========================================================
  // UNREAD DOT -- optimistic local read marker
  // ----------------------------------------------------------
  // markGroupRead() (groupchat.dart) writes a SERVER timestamp
  // into groups/<id>.lastReadAt[<uid>]. A server timestamp reads
  // back as null on the local snapshot until the server confirms
  // the write, which would make the dot flicker back on for a
  // moment right after opening a group. So the moment we mark it
  // read we also remember the time locally and treat the read
  // marker as whichever of the two is LATER -- the local one
  // covers the gap, the server one then takes over (and is what
  // keeps the dot in sync across the user's other devices).
  // ==========================================================
  DateTime? _localReadAt;

  void _ensureTicking(bool sleeping) {
    if (sleeping && _tick == null) {
      _tick = Timer.periodic(const Duration(seconds: 30), (_) {
        if (mounted) setState(() {});
      });
    } else if (!sleeping && _tick != null) {
      _tick!.cancel();
      _tick = null;
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.doc.data();
    final String name = (data['groupName'] ?? '').toString();
    final String groupId = (data['groupId'] ?? '').toString();
    final String image = (data['groupProfileImage'] ?? '').toString();
    final List<String> members = data['members'] is List
        ? List<String>.from(data['members'] as List)
        : <String>[];
    final int membersCount = (data['membersCount'] is int)
        ? data['membersCount'] as int
        : members.length;

    final Timestamp? sleepUntilTs =
        data['sleepUntil'] is Timestamp ? data['sleepUntil'] as Timestamp : null;
    final String sleepType = (data['sleepType'] ?? 'timer').toString();
    final DateTime? sleepUntil = sleepUntilTs?.toDate();
    final bool isSleeping =
        sleepUntil != null && sleepUntil.isAfter(DateTime.now());

    WidgetsBinding.instance
        .addPostFrameCallback((_) => _ensureTicking(isSleeping));

    // ------------------------------------------------------
    // UNREAD?
    // ------------------------------------------------------
    // Derived purely from fields already present on this group
    // document (no extra Firestore listener per tile):
    //   lastMessageAt     -- when the newest message was sent
    //   lastMessageSender -- who sent it (my own don't count)
    //   lastReadAt[<uid>] -- when I last opened this group
    // Dot shows when someone ELSE's message is newer than my
    // last read marker.
    // ------------------------------------------------------
    final String? myUid = FirebaseAuth.instance.currentUser?.uid;

    final Timestamp? lastMessageAtTs = data['lastMessageAt'] is Timestamp
        ? data['lastMessageAt'] as Timestamp
        : null;
    final String lastMessageSender =
        (data['lastMessageSender'] ?? '').toString();

    DateTime? myReadAt = _localReadAt;
    if (myUid != null && data['lastReadAt'] is Map) {
      final readMap = Map<String, dynamic>.from(data['lastReadAt'] as Map);
      final serverRead = readMap[myUid];
      if (serverRead is Timestamp) {
        final serverReadAt = serverRead.toDate();
        if (myReadAt == null || serverReadAt.isAfter(myReadAt)) {
          myReadAt = serverReadAt;
        }
      }
    }

    final bool hasUnread = myUid != null &&
        lastMessageAtTs != null &&
        lastMessageSender.isNotEmpty &&
        lastMessageSender != myUid &&
        (myReadAt == null || lastMessageAtTs.toDate().isAfter(myReadAt));

    return Material(
      color: const Color(0xFF1B120A),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () async {
          // A sleeping group stays paused -- tapping it just surfaces
          // the countdown instead of opening the chat, same as before.
          if (isSleeping) {
            showTopAlert(context, '"$name" is sleeping (${sleepLabel(sleepUntil, sleepType)})');
            return;
          }
          // Unfocus BEFORE navigating away (in case the search field
          // still had focus at the moment of this tap), then again
          // AFTER coming back -- Flutter can otherwise restore the
          // field's previous focus once this tab's route is active
          // again, popping the keyboard back open on return.
          widget.onUnfocusSearch();

          // Opening the group clears its unread dot immediately --
          // locally first (so it disappears on the very next frame)
          // and on the server via markGroupRead().
          if (mounted) setState(() => _localReadAt = DateTime.now());
          unawaited(markGroupRead(widget.doc.id));

          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => GroupChatScreen(groupDocId: widget.doc.id),
            ),
          );

          // Anything that arrived while the chat was open has been
          // seen too, so refresh the read marker on the way back.
          if (mounted) setState(() => _localReadAt = DateTime.now());
          if (context.mounted) widget.onUnfocusSearch();
        },
        onLongPress: () {
          HapticFeedback.mediumImpact();
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => GroupProfilePage(groupDocId: widget.doc.id),
            ),
          );
        },
        child: Opacity(
          opacity: isSleeping ? 0.55 : 1,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: const Color(0xFFD2B48C).withValues(alpha: .25),
              ),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 26,
                  backgroundColor: const Color(0xFF2A1B0E),
                  backgroundImage: _profileImageProvider(image),
                  child: image.isEmpty
                      ? const Icon(Icons.diversity_3_rounded,
                          color: Colors.white70)
                      : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 3),
                      // Shows a live "N active" + green dot (same dot
                      // as the 1-to-1 chat header) whenever at least
                      // one member of this group is active right now;
                      // otherwise falls back to the Group ID, same as
                      // before.
                      GroupActiveMembersStatus(
                        members: members,
                        fallback: Text(
                          groupId,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 12.5,
                          ),
                        ),
                      ),
                      if (isSleeping) ...[
                        const SizedBox(height: 4),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.bedtime_rounded,
                                size: 12, color: Color(0xFFD2B48C)),
                            const SizedBox(width: 4),
                            Text(
                              sleepLabel(sleepUntil, sleepType),
                              style: const TextStyle(
                                color: Color(0xFFD2B48C),
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '$membersCount',
                  style: const TextStyle(color: Colors.white38, fontSize: 12.5),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.people_alt_rounded,
                    color: Colors.white38, size: 16),
                // ------------------------------------------
                // UNREAD DOT (right edge of the tile)
                // ------------------------------------------
                // Same small cream dot the Chats list already
                // uses for unread 1-to-1 chats
                // (chat_page.dart's _UnreadDot), so the two
                // lists stay visually consistent. A fixed-width
                // gap is kept when there's nothing to show so
                // the member count never shifts sideways as the
                // dot appears/disappears.
                const SizedBox(width: 8),
                hasUnread
                    ? Container(
                        width: 10,
                        height: 10,
                        decoration: const BoxDecoration(
                          color: Color(0xFFFFE9B0),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Color(0x66FFE9B0),
                              blurRadius: 6,
                              spreadRadius: 1,
                            ),
                          ],
                        ),
                      )
                    : const SizedBox(width: 10),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ================================================================
// SLEEP LABEL / DATE FORMATTING HELPERS
// ----------------------------------------------------------------
// No `intl` dependency assumed here (not seen anywhere else in
// this file), so dates are formatted by hand.
// ================================================================

const List<String> _kMonthNames = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _formatDate(DateTime dt) {
  return '${dt.day} ${_kMonthNames[dt.month - 1]} ${dt.year}';
}

String sleepLabel(DateTime sleepUntil, String sleepType) {
  if (sleepType == 'date') {
    return 'Wakes ${_formatDate(sleepUntil)}';
  }

  final remaining = sleepUntil.difference(DateTime.now());
  if (remaining.isNegative) return 'Waking up…';

  final days = remaining.inDays;
  final hours = remaining.inHours % 24;
  final minutes = remaining.inMinutes % 60;

  if (days > 0) return 'Sleeps ${days}d ${hours}h';
  if (hours > 0) return 'Sleeps ${hours}h ${minutes}m';
  return 'Sleeps ${minutes}m';
}

// ================================================================
// GROUP PROFILE PAGE
// ----------------------------------------------------------------
// Opened via long-press on a group card in the list above
// (_GroupListTile.onLongPress). Shows the group's own image/name/ID,
// the admin/creator, and the full member list -- live, via the same
// 'groups/{docId}' document the list tile already reads from.
//
// Each member (admin included) resolves to their private name/image
// if the current user is connected to them, public otherwise --
// exactly the same connected-vs-not logic _AddMemberSheet already
// uses for the Create Group dialog's Add Member sheet, just reused
// here for display instead of selection.
// ================================================================

// ================================================================
// GROUP PROFILE TABS
// ----------------------------------------------------------------
// "Files" is the default/auto-selected tab when the page opens.
// "Members" swaps in the existing member list. Voice/Video are
// plain action icons (not tabs) -- wired to a "coming soon" snack
// for now, same placeholder pattern GroupChatScreen already uses
// for its own header call icons, until group calling is built.
// ================================================================

enum _GroupProfileTab { files, members }

class GroupProfilePage extends StatefulWidget {
  final String groupDocId;

  const GroupProfilePage({super.key, required this.groupDocId});

  @override
  State<GroupProfilePage> createState() => _GroupProfilePageState();
}

class _GroupProfilePageState extends State<GroupProfilePage> {
  _GroupProfileTab _tab = _GroupProfileTab.files;

  void _callComingSoon(String label) {
    showTopAlert(context, 'Group $label calling is coming soon.');
  }

  Widget _tabIcon({
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        width: 52,
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: selected ? AppColors.goldGradient : null,
          color: selected ? null : const Color(0xFF1B120A),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: const Color(0xFFD2B48C).withValues(alpha: selected ? 0 : .3),
          ),
        ),
        child: Icon(
          icon,
          color: selected ? const Color(0xFF1B120A) : const Color(0xFFD2B48C),
          size: 20,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return Scaffold(
      backgroundColor: const Color(0xFF120B06),
      appBar: AppBar(
        backgroundColor: const Color(0xFF120B06),
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text(
          'Group Profile',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 17,
          ),
        ),
        actions: [
          _GroupIdButton(groupDocId: widget.groupDocId),
          _GroupSettingsButton(groupDocId: widget.groupDocId),
        ],
      ),
      body: user == null
          ? const SizedBox.shrink()
          : StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              stream: FirebaseFirestore.instance
                  .collection('groups')
                  .doc(widget.groupDocId)
                  .snapshots(),
              builder: (context, groupSnapshot) {
                if (groupSnapshot.hasError) {
                  return const Center(
                    child: Text(
                      'Unable to load group',
                      style: TextStyle(color: Colors.white54),
                    ),
                  );
                }

                if (groupSnapshot.connectionState ==
                    ConnectionState.waiting) {
                  return const Center(
                    child:
                        CircularProgressIndicator(color: Color(0xFFD2B48C)),
                  );
                }

                final groupData = groupSnapshot.data?.data();

                if (groupData == null) {
                  return const Center(
                    child: Text(
                      'This group no longer exists.',
                      style: TextStyle(color: Colors.white54),
                    ),
                  );
                }

                final String name = (groupData['groupName'] ?? '').toString();
                final String image =
                    (groupData['groupProfileImage'] ?? '').toString();
                final String adminUid =
                    (groupData['adminUid'] ?? '').toString();
                final List<String> members = groupData['members'] is List
                    ? List<String>.from(groupData['members'] as List)
                    : <String>[];
                final int membersCount = (groupData['membersCount'] is int)
                    ? groupData['membersCount'] as int
                    : members.length;
                final List<String> coAdminUids =
                    groupData['coAdminUids'] is List
                        ? List<String>.from(groupData['coAdminUids'] as List)
                        : <String>[];
                final bool currentUserIsAdmin =
                    adminUid.isNotEmpty && adminUid == user.uid;
                final bool currentUserIsCoAdmin =
                    coAdminUids.contains(user.uid);

                return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  // Connected accounts -- drives whether each member
                  // (admin included) below shows their private or
                  // public name/image.
                  stream: FirebaseFirestore.instance
                      .collection('connections')
                      .where('users', arrayContains: user.uid)
                      .where('status', isEqualTo: 'connected')
                      .snapshots(),
                  builder: (context, connectionsSnapshot) {
                    final connectedUids = <String>{};

                    for (final doc in connectionsSnapshot.data?.docs ?? []) {
                      final users =
                          List<String>.from(doc.data()['users'] ?? []);
                      final otherUid = users.firstWhere(
                        (id) => id != user.uid,
                        orElse: () => '',
                      );
                      if (otherUid.isNotEmpty) connectedUids.add(otherUid);
                    }

                    // Admin shown first, then everyone else in the
                    // order Firestore already stores them in.
                    final orderedMembers = <String>[
                      if (adminUid.isNotEmpty) adminUid,
                      ...members.where((uid) => uid != adminUid),
                    ];

                    return ListView(
                      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
                      children: [
                        // ---------------------------------------
                        // GROUP IMAGE + NAME + ID + MEMBER COUNT
                        // ---------------------------------------
                        Center(
                          child: CircleAvatar(
                            radius: 48,
                            backgroundColor: const Color(0xFF2A1B0E),
                            backgroundImage: _profileImageProvider(image),
                            child: image.isEmpty
                                ? const Icon(Icons.diversity_3_rounded,
                                    color: Colors.white70, size: 42)
                                : null,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Center(
                          child: Text(
                            name.isEmpty ? 'Group' : name,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Center(
                          child: Text(
                            '$membersCount member${membersCount == 1 ? '' : 's'}',
                            style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 12.5,
                            ),
                          ),
                        ),

                        const SizedBox(height: 24),

                        // ---------------------------------------
                        // TABS -- Files (auto-selected first) /
                        // Members, then Voice call / Video call.
                        // ---------------------------------------
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _tabIcon(
                              icon: Icons.folder_rounded,
                              selected: _tab == _GroupProfileTab.files,
                              onTap: () =>
                                  setState(() => _tab = _GroupProfileTab.files),
                            ),
                            const SizedBox(width: 10),
                            _tabIcon(
                              icon: Icons.people_alt_rounded,
                              selected: _tab == _GroupProfileTab.members,
                              onTap: () => setState(
                                  () => _tab = _GroupProfileTab.members),
                            ),
                            const SizedBox(width: 10),
                            _tabIcon(
                              icon: Icons.call_rounded,
                              selected: false,
                              onTap: () => _callComingSoon('voice'),
                            ),
                            const SizedBox(width: 10),
                            _tabIcon(
                              icon: Icons.videocam_rounded,
                              selected: false,
                              onTap: () => _callComingSoon('video'),
                            ),
                          ],
                        ),

                        const SizedBox(height: 22),

                        // ---------------------------------------
                        // FILES TAB -- every photo/video/audio/file
                        // sent in the group chat.
                        // ---------------------------------------
                        if (_tab == _GroupProfileTab.files)
                          _GroupFilesGrid(groupDocId: widget.groupDocId)

                        // ---------------------------------------
                        // MEMBERS TAB (admin first, with "Admin" /
                        // "You" badges for proper indication -- a
                        // member who is both the admin and the
                        // signed-in account gets both badges).
                        // ---------------------------------------
                        else if (orderedMembers.isEmpty)
                          const Text(
                            'No members yet.',
                            style: TextStyle(color: Colors.white38),
                          )
                        else
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: orderedMembers.map((uid) {
                              return _GroupMemberTile(
                                groupDocId: widget.groupDocId,
                                uid: uid,
                                isAdmin: uid == adminUid,
                                isCoAdmin: coAdminUids.contains(uid),
                                isSelf: uid == user.uid,
                                isConnected: connectedUids.contains(uid),
                                currentUserIsAdmin: currentUserIsAdmin,
                                currentUserIsCoAdmin: currentUserIsCoAdmin,
                              );
                            }).toList(),
                          ),
                      ],
                    );
                  },
                );
              },
            ),
    );
  }
}

// ================================================================
// GROUP FILES GRID (Group Profile page's "Files" tab)
// ----------------------------------------------------------------
// Every photo/video/audio/file message from the group chat's own
// 'groups/{groupDocId}/messages' subcollection, newest first --
// the exact same fields GroupChatScreen writes when an attachment
// is sent (see _sendPickedAttachments in groupchat.dart), just
// rendered as a tap-to-open grid here instead of chat bubbles.
// ================================================================

class _GroupFilesGrid extends StatelessWidget {
  final String groupDocId;

  const _GroupFilesGrid({required this.groupDocId});

  IconData _iconFor(String messageType) {
    switch (messageType) {
      case 'video':
        return Icons.videocam_rounded;
      case 'audio':
        return Icons.audiotrack_rounded;
      default:
        return Icons.insert_drive_file_rounded;
    }
  }

  Future<void> _open(String url) async {
    if (url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('Group file open error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('groups')
          .doc(groupDocId)
          .collection('messages')
          .where('messageType', whereIn: ['photo', 'video', 'audio', 'file'])
          .orderBy('sentAt', descending: true)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Center(
              child: Text(
                'Unable to load files',
                style: TextStyle(color: Colors.white54),
              ),
            ),
          );
        }

        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Center(
              child: CircularProgressIndicator(color: Color(0xFFD2B48C)),
            ),
          );
        }

        final docs = snapshot.data?.docs ?? [];

        if (docs.isEmpty) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Center(
              child: Text(
                'No photos, videos, files or audio shared yet.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white38, fontSize: 12.5),
              ),
            ),
          );
        }

        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          itemCount: docs.length,
          itemBuilder: (context, index) {
            final data = docs[index].data();
            final String messageType = (data['messageType'] ?? '').toString();
            final String url = (data['fileUrl'] ?? '').toString();
            final String fileName = (data['fileName'] ?? '').toString();

            return Material(
              color: const Color(0xFF1B120A),
              borderRadius: BorderRadius.circular(12),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => _open(url),
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: const Color(0xFFD2B48C).withValues(alpha: .25),
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: messageType == 'photo' && url.isNotEmpty
                      ? Image.network(
                          url,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const Icon(
                            Icons.broken_image_rounded,
                            color: Colors.white38,
                          ),
                        )
                      : Padding(
                          padding: const EdgeInsets.all(8),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                _iconFor(messageType),
                                color: const Color(0xFFD2B48C),
                                size: 24,
                              ),
                              const SizedBox(height: 6),
                              Text(
                                fileName.isEmpty ? messageType : fileName,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 10.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

// ================================================================
// GROUP SETTINGS BUTTON (Group Profile page app bar, everyone)
// ----------------------------------------------------------------
// Admin sees "Sleep Mode" + "Delete Group". Every other member
// sees "Exit Group" instead. Listens to the group doc itself just
// to know who the admin is -- cheap, same doc the page already
// streams below.
// ================================================================

// ================================================================
// GROUP ID BUTTON (Group Profile app bar -- link icon)
// ----------------------------------------------------------------
// Replaces the old "#groupId" text that used to sit under the group
// name -- same "Account ID" pattern the Me page's link icon already
// uses (_showAccountId in me_page.dart): tap to see the Group ID in
// a selectable, copyable dialog instead of it being shown inline.
// ================================================================

class _GroupIdButton extends StatelessWidget {
  final String groupDocId;

  const _GroupIdButton({required this.groupDocId});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('groups')
          .doc(groupDocId)
          .snapshots(),
      builder: (context, snapshot) {
        final groupId = (snapshot.data?.data()?['groupId'] ?? '').toString();

        return IconButton(
          icon: const Icon(Icons.link_rounded, color: Colors.white),
          onPressed:
              groupId.isEmpty ? null : () => _showGroupIdDialog(context, groupId),
        );
      },
    );
  }
}

void _showGroupIdDialog(BuildContext context, String groupId) {
  showDialog(
    context: context,
    builder: (context) {
      return AlertDialog(
        backgroundColor: const Color(0xFF1B120A),
        title: const Text(
          'Group ID',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            color: const Color(0xFF2A1B0E),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFD2B48C)),
          ),
          child: SelectableText(
            groupId,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFFD2B48C),
              fontSize: 18,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.5,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('CLOSE', style: TextStyle(color: Color(0xFFD2B48C))),
          ),
        ],
      );
    },
  );
}

class _GroupSettingsButton extends StatelessWidget {
  final String groupDocId;

  const _GroupSettingsButton({required this.groupDocId});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return const SizedBox.shrink();

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('groups')
          .doc(groupDocId)
          .snapshots(),
      builder: (context, snapshot) {
        final data = snapshot.data?.data();
        if (data == null) return const SizedBox.shrink();

        final String adminUid = (data['adminUid'] ?? '').toString();
        final bool isAdmin = adminUid.isNotEmpty && adminUid == user.uid;
        final List<String> coAdminUids = data['coAdminUids'] is List
            ? List<String>.from(data['coAdminUids'] as List)
            : <String>[];
        final bool isCoAdmin = coAdminUids.contains(user.uid);
        final String groupName = (data['groupName'] ?? 'this group').toString();

        return IconButton(
          icon: const Icon(Icons.settings_rounded, color: Colors.white),
          onPressed: () => _openGroupSettingsSheet(
            context,
            groupDocId: groupDocId,
            groupName: groupName,
            isAdmin: isAdmin,
            isCoAdmin: isCoAdmin,
            currentSleepUntil: data['sleepUntil'] is Timestamp
                ? (data['sleepUntil'] as Timestamp).toDate()
                : null,
            currentSleepType: (data['sleepType'] ?? 'timer').toString(),
            uid: user.uid,
          ),
        );
      },
    );
  }
}

void _openGroupSettingsSheet(
  BuildContext context, {
  required String groupDocId,
  required String groupName,
  required bool isAdmin,
  bool isCoAdmin = false,
  required DateTime? currentSleepUntil,
  required String currentSleepType,
  required String uid,
}) {
  final bool isSleeping =
      currentSleepUntil != null && currentSleepUntil.isAfter(DateTime.now());

  showModalBottomSheet(
    context: context,
    backgroundColor: const Color(0xFF1B120A),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (sheetContext) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),

              // Edit Group is available to the admin AND any
              // co-admin -- everything else below it (Sleep Mode,
              // Delete Group) stays admin-only.
              if (isAdmin || isCoAdmin)
                ListTile(
                  leading: const Icon(Icons.edit_rounded,
                      color: Color(0xFFD2B48C)),
                  title: const Text(
                    'Edit Group',
                    style: TextStyle(color: Colors.white),
                  ),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    showDialog(
                      context: context,
                      builder: (_) => EditGroupDialog(groupDocId: groupDocId),
                    );
                  },
                ),

              if (isAdmin) ...[
                ListTile(
                  leading: const Icon(Icons.bedtime_rounded,
                      color: Color(0xFFD2B48C)),
                  title: Text(
                    isSleeping ? 'Sleep Mode (active)' : 'Sleep Mode',
                    style: const TextStyle(color: Colors.white),
                  ),
                  subtitle: isSleeping
                      ? Text(
                          sleepLabel(currentSleepUntil, currentSleepType),
                          style: const TextStyle(color: Colors.white54),
                        )
                      : null,
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    showDialog(
                      context: context,
                      barrierDismissible: false,
                      builder: (_) => SleepModeDialog(
                        groupDocId: groupDocId,
                        currentSleepUntil: currentSleepUntil,
                        currentSleepType: currentSleepType,
                        isCurrentlySleeping: isSleeping,
                      ),
                    );
                  },
                ),
                ListTile(
                  leading:
                      const Icon(Icons.delete_forever_rounded, color: Colors.redAccent),
                  title: const Text(
                    'Delete Group',
                    style: TextStyle(color: Colors.redAccent),
                  ),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    confirmDeleteGroup(context, groupDocId, groupName);
                  },
                ),
              ] else
                ListTile(
                  leading: const Icon(Icons.logout_rounded, color: Colors.redAccent),
                  title: const Text(
                    'Exit Group',
                    style: TextStyle(color: Colors.redAccent),
                  ),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    confirmExitGroup(context, groupDocId, groupName, uid);
                  },
                ),
            ],
          ),
        ),
      );
    },
  );
}

// ================================================================
// SLEEP MODE DIALOG (admin only)
// ----------------------------------------------------------------
// Either a timer (duration from now) OR a fixed date -- mutually
// exclusive, whichever the admin picks -- both resolve down to a
// single absolute `sleepUntil` timestamp written on the group doc.
// `sleepType` is kept alongside purely so the display (list tile /
// this sheet) knows whether to show a live countdown or a fixed
// date for that timestamp.
// ================================================================

class SleepModeDialog extends StatefulWidget {
  final String groupDocId;
  final DateTime? currentSleepUntil;
  final String currentSleepType;
  final bool isCurrentlySleeping;

  const SleepModeDialog({super.key, 
    required this.groupDocId,
    required this.currentSleepUntil,
    required this.currentSleepType,
    required this.isCurrentlySleeping,
  });

  @override
  State<SleepModeDialog> createState() => SleepModeDialogState();
}

class SleepModeDialogState extends State<SleepModeDialog> {
  late String _mode =
      widget.currentSleepType == 'date' ? 'date' : 'timer';

  final TextEditingController _durationController =
      TextEditingController(text: '1');
  String _durationUnit = 'hours'; // 'hours' | 'days'

  DateTime? _selectedDate;
  TimeOfDay? _selectedTime;

  bool _saving = false;

  @override
  void dispose() {
    _durationController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate ?? now.add(const Duration(days: 1)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 3650)),
    );
    if (picked == null) return;

    if (!mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: _selectedTime ?? const TimeOfDay(hour: 23, minute: 59),
    );

    setState(() {
      _selectedDate = picked;
      _selectedTime = time ?? _selectedTime;
    });
  }

  Future<void> _submit() async {
    DateTime sleepUntil;

    if (_mode == 'timer') {
      final value = int.tryParse(_durationController.text.trim());
      if (value == null || value <= 0) {
        showTopAlert(context, 'Enter a valid duration');
        return;
      }
      final duration =
          _durationUnit == 'days' ? Duration(days: value) : Duration(hours: value);
      sleepUntil = DateTime.now().add(duration);
    } else {
      if (_selectedDate == null) {
        showTopAlert(context, 'Pick a date');
        return;
      }
      final time = _selectedTime ?? const TimeOfDay(hour: 23, minute: 59);
      sleepUntil = DateTime(
        _selectedDate!.year,
        _selectedDate!.month,
        _selectedDate!.day,
        time.hour,
        time.minute,
      );
      if (!sleepUntil.isAfter(DateTime.now())) {
        showTopAlert(context, 'Pick a date/time in the future');
        return;
      }
    }

    setState(() => _saving = true);
    try {
      await FirebaseFirestore.instance
          .collection('groups')
          .doc(widget.groupDocId)
          .update({
        'sleepMode': true,
        'sleepUntil': Timestamp.fromDate(sleepUntil),
        'sleepType': _mode,
      });

      if (!mounted) return;
      Navigator.of(context).pop();
      showTopAlert(context, 'Sleep Mode set — ${sleepLabel(sleepUntil, _mode)}');
    } catch (e) {
      debugPrint('Set sleep mode error: $e');
      if (!mounted) return;
      setState(() => _saving = false);
      showTopAlert(context, 'Failed to set Sleep Mode.', isError: true);
    }
  }

  Future<void> _turnOff() async {
    setState(() => _saving = true);
    try {
      await FirebaseFirestore.instance
          .collection('groups')
          .doc(widget.groupDocId)
          .update({
        'sleepMode': false,
        'sleepUntil': FieldValue.delete(),
        'sleepType': FieldValue.delete(),
      });

      if (!mounted) return;
      Navigator.of(context).pop();
      showTopAlert(context, 'Sleep Mode turned off');
    } catch (e) {
      debugPrint('Turn off sleep mode error: $e');
      if (!mounted) return;
      setState(() => _saving = false);
      showTopAlert(context, 'Failed to turn off Sleep Mode.', isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1B120A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Sleep Mode',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'The group stays inactive for everyone until it wakes up.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54, fontSize: 12.5),
              ),
              const SizedBox(height: 18),

              // -------------------------------------------------
              // TIMER / DATE TOGGLE -- one or the other, never both.
              // -------------------------------------------------
              Row(
                children: [
                  Expanded(
                    child: _ModeChip(
                      label: 'Timer',
                      selected: _mode == 'timer',
                      onTap: () => setState(() => _mode = 'timer'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _ModeChip(
                      label: 'Fix a Date',
                      selected: _mode == 'date',
                      onTap: () => setState(() => _mode = 'date'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),

              if (_mode == 'timer') ...[
                const _FieldLabel('Sleep for'),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: _DialogTextField(
                        controller: _durationController,
                        hintText: 'e.g. 6',
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Container(
                        height: 48,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2A1B0E),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: const Color(0xFFD2B48C).withValues(alpha: .3),
                          ),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: _durationUnit,
                            dropdownColor: const Color(0xFF2A1B0E),
                            isExpanded: true,
                            style: const TextStyle(color: Colors.white, fontSize: 14),
                            items: const [
                              DropdownMenuItem(value: 'hours', child: Text('Hours')),
                              DropdownMenuItem(value: 'days', child: Text('Days')),
                            ],
                            onChanged: (value) {
                              if (value != null) setState(() => _durationUnit = value);
                            },
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ] else ...[
                const _FieldLabel('Wake-up date & time'),
                const SizedBox(height: 6),
                InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: _pickDate,
                  child: Container(
                    height: 48,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2A1B0E),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: const Color(0xFFD2B48C).withValues(alpha: .3),
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.calendar_month_rounded,
                            color: Colors.white54, size: 18),
                        const SizedBox(width: 10),
                        Text(
                          _selectedDate == null
                              ? 'Pick a date & time'
                              : '${_formatDate(_selectedDate!)}'
                                  '${_selectedTime != null ? ' • ${_selectedTime!.format(context)}' : ''}',
                          style: TextStyle(
                            color: _selectedDate == null
                                ? Colors.white38
                                : Colors.white,
                            fontSize: 13.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 22),

              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: AppColors.goldGradient,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: _saving ? null : _submit,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      child: Center(
                        child: _saving
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  color: Color(0xFF1B120A),
                                  strokeWidth: 2.4,
                                ),
                              )
                            : const Text(
                                'Set Sleep Mode',
                                style: TextStyle(
                                  color: Color(0xFF1B120A),
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                ),
                              ),
                      ),
                    ),
                  ),
                ),
              ),

              if (widget.isCurrentlySleeping) ...[
                const SizedBox(height: 8),
                Center(
                  child: TextButton(
                    onPressed: _saving ? null : _turnOff,
                    child: const Text(
                      'Turn Off Sleep Mode',
                      style: TextStyle(color: Colors.redAccent),
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 4),
              Center(
                child: TextButton(
                  onPressed: _saving ? null : () => Navigator.of(context).pop(),
                  child: const Text(
                    'Cancel',
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ================================================================
// EDIT GROUP DIALOG (admin only)
// ----------------------------------------------------------------
// Lets the admin change the group's profile image (add / replace /
// remove) and its name. The Group ID is derived from the name --
// same "@(groupname)-(first 4 digits of admin's Account ID)" formula
// _CreateGroupDialogState._updateGroupIdPreview() uses when the
// group is first created -- so renaming the group always keeps its
// ID in sync with the new name instead of leaving a stale one.
// Goes straight to Firestore (no backend call): unlike create/join,
// nothing here touches the group password, so there's no
// hashing/salt step that needs the server.
// ================================================================

class EditGroupDialog extends StatefulWidget {
  final String groupDocId;

  const EditGroupDialog({super.key, required this.groupDocId});

  @override
  State<EditGroupDialog> createState() => _EditGroupDialogState();
}

class _EditGroupDialogState extends State<EditGroupDialog> {
  static const String _cloudName = 'db4zevmud';
  static const String _uploadPreset = 'nexus_profile_images';

  final ImagePicker _imagePicker = ImagePicker();
  final TextEditingController _nameController = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  bool _uploadingImage = false;

  // '' means "no image" (removed or never set) -- distinct from
  // null, which just means "hasn't loaded yet".
  String? _groupImageUrl;
  String _accountIdSuffix = '';
  String _adminAccountId = ''; // full 10-char Account ID

  @override
  void initState() {
    super.initState();
    _loadGroup();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _loadGroup() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final groupDoc = await FirebaseFirestore.instance
        .collection('groups')
        .doc(widget.groupDocId)
        .get();
    final groupData = groupDoc.data() ?? {};

    // The admin OR a co-admin can see this dialog now (see
    // _openGroupSettingsSheet), so the signed-in account is no
    // longer guaranteed to be the admin -- always look up the
    // group's real adminUid's Account ID for the "@name-suffix"
    // formula, never the signed-in account's own ID, so a co-admin
    // editing the group can't accidentally change the group ID's
    // suffix to their own account.
    final String adminUid = (groupData['adminUid'] ?? '').toString();
    final userDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(adminUid.isNotEmpty ? adminUid : user.uid)
        .get();
    final accountId = (userDoc.data()?['userId'] ?? '').toString();

    if (!mounted) return;
    setState(() {
      _nameController.text = (groupData['groupName'] ?? '').toString();
      _groupImageUrl = (groupData['groupProfileImage'] ?? '').toString();
      _adminAccountId = accountId;
      _accountIdSuffix =
          accountId.length >= 4 ? accountId.substring(0, 4) : accountId;
      _loading = false;
    });
  }

  Future<void> _pickImage() async {
    try {
      final XFile? image = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 80,
        maxWidth: 800,
        maxHeight: 800,
      );
      if (image == null) return;
      if (!mounted) return;

      setState(() => _uploadingImage = true);

      final request = http.MultipartRequest(
        'POST',
        Uri.parse('https://api.cloudinary.com/v1_1/$_cloudName/image/upload'),
      );
      request.fields['upload_preset'] = _uploadPreset;
      request.files.add(await http.MultipartFile.fromPath('file', image.path));

      final response = await request.send();
      final responseBody = await response.stream.bytesToString();
      if (!mounted) return;

      if (response.statusCode != 200) {
        debugPrint('Cloudinary group image upload failed: $responseBody');
        setState(() => _uploadingImage = false);
        showTopAlert(context, 'Group image upload failed.', isError: true);
        return;
      }

      final Map<String, dynamic> data = jsonDecode(responseBody);
      final String imageUrl = (data['secure_url'] ?? '').toString();
      if (imageUrl.isEmpty) throw Exception('Cloudinary URL not received.');

      setState(() {
        _groupImageUrl = imageUrl;
        _uploadingImage = false;
      });
    } catch (e) {
      debugPrint('Group image pick/upload error: $e');
      if (!mounted) return;
      setState(() => _uploadingImage = false);
      showTopAlert(context, 'Group image upload failed.', isError: true);
    }
  }

  void _removeImage() {
    setState(() => _groupImageUrl = '');
  }

  // ==========================================================
  // ADD MEMBER (existing group)
  // ----------------------------------------------------------
  // Same account picker as the Create Group dialog's Add Member
  // sheet (public/private chat accounts, connected ones showing
  // their private name/image) -- but instead of collecting a local
  // "selected members" list to send with a not-yet-created group,
  // each tap here immediately sends a real invite: a 'groupRequests'
  // doc (same shape _CreateGroupDialogState writes after creating a
  // group) plus a push notification, exactly the invite-then-accept
  // flow notification.dart's group-request card completes. The
  // picker excludes anyone already a member OR already invited
  // (live, via the group doc's `members` + `pendingMembers`), so a
  // re-opened sheet never offers someone twice.
  // ==========================================================

  Future<void> _openAddMember() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1B120A),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(25)),
      ),
      builder: (sheetContext) {
        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection('groups')
              .doc(widget.groupDocId)
              .snapshots(),
          builder: (context, groupSnapshot) {
            final groupData = groupSnapshot.data?.data() ?? {};
            final existingMembers = groupData['members'] is List
                ? List<String>.from(groupData['members'] as List)
                : <String>[];
            final pendingMembers = groupData['pendingMembers'] is List
                ? List<String>.from(groupData['pendingMembers'] as List)
                : <String>[];

            return _AddMemberSheet(
              currentUid: user.uid,
              initiallySelected: const {},
              excludeUids: {...existingMembers, ...pendingMembers},
              onToggle: (member, selected) {
                if (selected) _inviteMember(member);
              },
            );
          },
        );
      },
    );
  }

  Future<void> _inviteMember(_SelectedMember member) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      final groupDoc = await FirebaseFirestore.instance
          .collection('groups')
          .doc(widget.groupDocId)
          .get();
      final groupData = groupDoc.data() ?? {};
      final currentGroupName = (groupData['groupName'] ?? '').toString();
      final currentGroupId = (groupData['groupId'] ?? '').toString();
      final currentGroupImage =
          (groupData['groupProfileImage'] ?? '').toString();
      final adminUid = (groupData['adminUid'] ?? '').toString();

      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();
      final userData = userDoc.data() ?? {};
      final senderName =
          (userData['privateName'] ?? userData['publicName'] ?? 'Someone')
              .toString()
              .trim();

      final requestRef = FirebaseFirestore.instance
          .collection('groupRequests')
          .doc('${widget.groupDocId}_${member.uid}');

      await requestRef.set({
        'groupDocId': widget.groupDocId,
        'groupId': currentGroupId,
        'groupName': currentGroupName,
        'groupProfileImage': currentGroupImage,
        'adminUid': adminUid,
        'adminAccountId': _adminAccountId,
        'senderUid': user.uid,
        'senderName': senderName,
        'receiverUid': member.uid,
        'status': 'pending',
        'createdAt': FieldValue.serverTimestamp(),
      });

      await FirebaseFirestore.instance
          .collection('groups')
          .doc(widget.groupDocId)
          .update({
        'pendingMembers': FieldValue.arrayUnion([member.uid]),
      });

      unawaited(
        NotificationService.instance.sendToUser(
          receiverUid: member.uid,
          senderName: senderName,
          message: '$senderName invited you to join "$currentGroupName"',
          type: 'group_request',
          senderUid: user.uid,
        ),
      );

      if (!mounted) return;
      showTopAlert(context, 'Invite sent to ${member.name}');
    } catch (e) {
      debugPrint('Invite member error: $e');
      if (!mounted) return;
      showTopAlert(context, 'Failed to send invite.', isError: true);
    }
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      showTopAlert(context, 'Enter a group name');
      return;
    }

    setState(() => _saving = true);

    // Same "@(groupname)-(first 4 digits of admin Account ID)" the
    // group was created with -- recomputed from the (possibly new)
    // name so the ID always matches whatever name is saved.
    final newGroupId = '@$name-$_accountIdSuffix';

    try {
      await FirebaseFirestore.instance
          .collection('groups')
          .doc(widget.groupDocId)
          .update({
        'groupName': name,
        'groupId': newGroupId,
        'groupProfileImage': _groupImageUrl ?? '',
      });

      if (!mounted) return;
      Navigator.of(context).pop();
      showTopAlert(context, 'Group updated');
    } catch (e) {
      debugPrint('Edit group error: $e');
      if (!mounted) return;
      setState(() => _saving = false);
      showTopAlert(context, 'Failed to update group.', isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1B120A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: _loading
            ? const Padding(
                padding: EdgeInsets.all(32),
                child: Center(
                  child: CircularProgressIndicator(color: Color(0xFFD2B48C)),
                ),
              )
            : SingleChildScrollView(
                padding: const EdgeInsets.all(22),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Edit Group',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 18),

                    // -------------------------------------------
                    // GROUP IMAGE -- tap to change, small remove
                    // badge shown only when an image is set.
                    // -------------------------------------------
                    Center(
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          GestureDetector(
                            onTap: _uploadingImage ? null : _pickImage,
                            child: CircleAvatar(
                              radius: 44,
                              backgroundColor: const Color(0xFF2A1B0E),
                              backgroundImage:
                                  _profileImageProvider(_groupImageUrl ?? ''),
                              child: _uploadingImage
                                  ? const CircularProgressIndicator(
                                      color: Color(0xFFD2B48C))
                                  : (_groupImageUrl ?? '').isEmpty
                                      ? const Icon(Icons.diversity_3_rounded,
                                          color: Colors.white70, size: 36)
                                      : null,
                            ),
                          ),
                          Positioned(
                            bottom: 0,
                            right: -4,
                            child: Material(
                              color: const Color(0xFF8B4513),
                              shape: const CircleBorder(),
                              child: InkWell(
                                customBorder: const CircleBorder(),
                                onTap: _uploadingImage ? null : _pickImage,
                                child: const Padding(
                                  padding: EdgeInsets.all(6),
                                  child: Icon(Icons.camera_alt_rounded,
                                      color: Colors.white, size: 16),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if ((_groupImageUrl ?? '').isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Center(
                        child: TextButton.icon(
                          onPressed: _uploadingImage ? null : _removeImage,
                          icon: const Icon(Icons.delete_outline_rounded,
                              color: Colors.redAccent, size: 18),
                          label: const Text(
                            'Remove photo',
                            style: TextStyle(color: Colors.redAccent),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),

                    // -------------------------------------------
                    // GROUP NAME
                    // -------------------------------------------
                    const _FieldLabel('Group Name'),
                    const SizedBox(height: 6),
                    _DialogTextField(
                      controller: _nameController,
                      hintText: 'Enter group name',
                      maxLength: 30,
                    ),
                    const SizedBox(height: 4),
                    // Live preview of the new Group ID -- same
                    // "@name-suffix" format the group already uses,
                    // so the admin sees exactly what will change.
                    AnimatedBuilder(
                      animation: _nameController,
                      builder: (context, _) {
                        final preview = _nameController.text.trim();
                        if (preview.isEmpty) return const SizedBox.shrink();
                        return Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Row(
                            children: [
                              const Icon(Icons.tag_rounded,
                                  size: 13, color: Color(0xFFD2B48C)),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  '@$preview-$_accountIdSuffix',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Color(0xFFD2B48C),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 22),

                    // -------------------------------------------
                    // ADD MEMBER
                    // -------------------------------------------
                    const _FieldLabel('Members'),
                    const SizedBox(height: 6),
                    OutlinedButton.icon(
                      onPressed: _openAddMember,
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        side: const BorderSide(
                            color: Color(0xFFD2B48C), width: 1.1),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      icon: const Icon(Icons.person_add_alt_1_rounded,
                          color: Color(0xFFFFE9B0), size: 18),
                      label: const Text(
                        'Add Member',
                        style: TextStyle(
                          color: Color(0xFFFFE9B0),
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    const SizedBox(height: 22),

                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: (_saving || _uploadingImage) ? null : _save,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF8B4513),
                          padding:
                              const EdgeInsets.symmetric(vertical: 13),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: _saving
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text(
                                'Save Changes',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Center(
                      child: TextButton(
                        onPressed: (_saving || _uploadingImage)
                            ? null
                            : () => Navigator.of(context).pop(),
                        child: const Text(
                          'Cancel',
                          style: TextStyle(color: Colors.white54),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ModeChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: selected ? AppColors.goldGradient : null,
          color: selected ? null : const Color(0xFF2A1B0E),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: const Color(0xFFD2B48C).withValues(alpha: selected ? 0 : .3),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? const Color(0xFF1B120A) : Colors.white70,
            fontWeight: FontWeight.bold,
            fontSize: 13.5,
          ),
        ),
      ),
    );
  }
}

// ================================================================
// DELETE GROUP (admin only)
// ----------------------------------------------------------------
// Deletes the group doc itself plus any pending 'groupRequests'
// docs that still point at it (unaccepted invites created by
// Create Group) -- there's no group-chat 'messages' subcollection
// in this codebase yet, so nothing else references a group doc.
// ================================================================

void confirmDeleteGroup(
  BuildContext context,
  String groupDocId,
  String groupName,
) {
  showDialog(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: const Color(0xFF1B120A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: const Text('Delete Group?', style: TextStyle(color: Colors.white)),
      content: Text(
        'This permanently deletes "$groupName" for everyone. This can\'t be undone.',
        style: const TextStyle(color: Colors.white70),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
        ),
        TextButton(
          onPressed: () async {
            Navigator.of(dialogContext).pop();
            try {
              final firestore = FirebaseFirestore.instance;
              final batch = firestore.batch();

              batch.delete(firestore.collection('groups').doc(groupDocId));

              final pendingRequests = await firestore
                  .collection('groupRequests')
                  .where('groupDocId', isEqualTo: groupDocId)
              .where('senderUid', isEqualTo: FirebaseAuth.instance.currentUser?.uid)
                  .get();
              for (final req in pendingRequests.docs) {
                batch.delete(req.reference);
              }

              await batch.commit();

              if (!context.mounted) return;
              Navigator.of(context).pop(); // leave GroupProfilePage
              showTopAlert(context, '"$groupName" deleted');
            } catch (e) {
              debugPrint('Delete group error: $e');
              if (!context.mounted) return;
              showTopAlert(context, 'Failed to delete group.', isError: true);
            }
          },
          child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
        ),
      ],
    ),
  );
}

// ================================================================
// EXIT GROUP (everyone except the admin)
// ================================================================

void confirmExitGroup(
  BuildContext context,
  String groupDocId,
  String groupName,
  String uid,
) {
  showDialog(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: const Color(0xFF1B120A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: const Text('Exit Group?', style: TextStyle(color: Colors.white)),
      content: Text(
        'You\'ll leave "$groupName" and stop seeing it in your Groups tab.',
        style: const TextStyle(color: Colors.white70),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
        ),
        TextButton(
          onPressed: () async {
            Navigator.of(dialogContext).pop();
            try {
              await FirebaseFirestore.instance
                  .collection('groups')
                  .doc(groupDocId)
                  .update({
                'members': FieldValue.arrayRemove([uid]),
                'membersCount': FieldValue.increment(-1),
              });

              if (!context.mounted) return;
              Navigator.of(context).pop(); // leave GroupProfilePage
              showTopAlert(context, 'You left "$groupName"');
            } catch (e) {
              debugPrint('Exit group error: $e');
              if (!context.mounted) return;
              showTopAlert(context, 'Failed to exit group.', isError: true);
            }
          },
          child: const Text('Exit', style: TextStyle(color: Colors.redAccent)),
        ),
      ],
    ),
  );
}

// ================================================================
// GROUP MEMBER TILE
// ----------------------------------------------------------------
// Profile image + name for one member of the Group Profile page's
// member list. Connected -> private name/image, not connected ->
// public name/image, same resolution _AddMemberSheet already uses.
// The admin gets a small gold "Admin" badge next to their name, a
// co-admin gets a "Co-Admin" badge in that same style, and the
// signed-in account gets a "You" badge combined with either one
// ("You • Admin" / "You • Co-Admin") so the current account's
// private profile/name is clearly marked.
//
// Long-press a member to manage them:
//  - The group admin can Remove Member and Assign/Remove Co-Admin
//    on any other member (never on themselves).
//  - A co-admin can only Remove Member on any other non-admin
//    member -- Assign/Remove Co-Admin stays admin-only.
//  - A regular member gets no long-press menu at all.
// ================================================================

class _GroupMemberTile extends StatelessWidget {
  final String groupDocId;
  final String uid;
  final bool isAdmin;
  final bool isCoAdmin;
  final bool isSelf;
  final bool isConnected;
  final bool currentUserIsAdmin;
  final bool currentUserIsCoAdmin;

  const _GroupMemberTile({
    required this.groupDocId,
    required this.uid,
    required this.isAdmin,
    this.isCoAdmin = false,
    this.isSelf = false,
    required this.isConnected,
    this.currentUserIsAdmin = false,
    this.currentUserIsCoAdmin = false,
  });

  void _handleLongPress(BuildContext context) {
    // Nobody gets a management menu on their own tile, and nobody
    // (not even the admin) can manage the admin's own tile.
    if (isSelf || isAdmin) return;

    // Only the admin or a co-admin can manage members at all.
    if (!currentUserIsAdmin && !currentUserIsCoAdmin) return;

    _showMemberManageSheet(
      context,
      groupDocId: groupDocId,
      uid: uid,
      isTargetCoAdmin: isCoAdmin,
      // Assign/Remove Co-Admin stays admin-only; a co-admin managing
      // another member only ever sees Remove Member.
      canManageCoAdmin: currentUserIsAdmin,
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream:
          FirebaseFirestore.instance.collection('users').doc(uid).snapshots(),
      builder: (context, snapshot) {
        final userData = snapshot.data?.data();
        if (userData == null) return const SizedBox.shrink();

        final privateName = (userData['privateName'] ?? '').toString().trim();
        final publicName = (userData['publicName'] ?? '').toString().trim();
        final name = (isConnected && privateName.isNotEmpty)
            ? privateName
            : publicName;

        final privateImage =
            (userData['privateImage'] ?? '').toString().trim();
        final publicImage = (userData['publicImage'] ?? '').toString().trim();
        final image = (isConnected && privateImage.isNotEmpty)
            ? privateImage
            : publicImage;

        // Same rule as the tab's "N active" count above: a member
        // never sees their own presence reflected back at them, so
        // the "active now" row only ever renders for other members.
        final showActiveNow = !isSelf && userData['isActive'] == true;

        final String badgeText = (isSelf && isAdmin)
            ? 'You • Admin'
            : (isSelf && isCoAdmin)
                ? 'You • Co-Admin'
                : isSelf
                    ? 'You'
                    : isAdmin
                        ? 'Admin'
                        : 'Co-Admin';

        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () {
              // Connected -> private profile (private name/image,
              // same fields already used above), not connected ->
              // public profile. Same connected-check the rest of
              // the app (chat header, Me -> Members) already uses.
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => isConnected
                      ? PrivateMemberProfilePage(
                          uid: uid,
                          initialData: userData,
                        )
                      : PublicMemberProfilePage(
                          uid: uid,
                          initialData: userData,
                        ),
                ),
              );
            },
            onLongPress: () => _handleLongPress(context),
            child: Row(
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: const Color(0xFF2A1B0E),
                backgroundImage: _profileImageProvider(image),
                child: image.isEmpty
                    ? const Icon(Icons.person_rounded, color: Colors.white70)
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      name.isEmpty ? 'Unnamed' : name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    if (showActiveNow) ...[
                      const SizedBox(height: 3),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          PresenceStatusDot(isActive: true),
                          SizedBox(width: 5),
                          Text(
                            'active now',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 11.5,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              if (isSelf || isAdmin || isCoAdmin) ...[
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    gradient: AppColors.goldGradient,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    badgeText,
                    style: const TextStyle(
                      color: Color(0xFF1B120A),
                      fontSize: 10.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ],
            ),
          ),
        );
      },
    );
  }
}

// ================================================================
// MEMBER MANAGE SHEET (long-press on a member in the Group
// Profile page's member list)
// ----------------------------------------------------------------
// Shown to the admin (Remove Member + Assign/Remove Co-Admin) or a
// co-admin (Remove Member only) on any other non-admin member.
// ================================================================

void _showMemberManageSheet(
  BuildContext context, {
  required String groupDocId,
  required String uid,
  required bool isTargetCoAdmin,
  required bool canManageCoAdmin,
}) {
  showModalBottomSheet(
    context: context,
    backgroundColor: const Color(0xFF1B120A),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (sheetContext) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              if (canManageCoAdmin)
                ListTile(
                  leading: Icon(
                    isTargetCoAdmin
                        ? Icons.remove_moderator_rounded
                        : Icons.add_moderator_rounded,
                    color: const Color(0xFFD2B48C),
                  ),
                  title: Text(
                    isTargetCoAdmin ? 'Remove Co-Admin' : 'Assign Co-Admin',
                    style: const TextStyle(color: Colors.white),
                  ),
                  onTap: () async {
                    Navigator.of(sheetContext).pop();
                    try {
                      await FirebaseFirestore.instance
                          .collection('groups')
                          .doc(groupDocId)
                          .update({
                        'coAdminUids': isTargetCoAdmin
                            ? FieldValue.arrayRemove([uid])
                            : FieldValue.arrayUnion([uid]),
                      });
                    } catch (e) {
                      debugPrint('Assign/remove co-admin error: $e');
                      if (!context.mounted) return;
                      showTopAlert(context, 'Failed to update co-admin.', isError: true);
                    }
                  },
                ),
              ListTile(
                leading:
                    const Icon(Icons.person_remove_rounded, color: Colors.redAccent),
                title: const Text(
                  'Remove Member',
                  style: TextStyle(color: Colors.redAccent),
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _confirmRemoveMember(context, groupDocId: groupDocId, uid: uid);
                },
              ),
            ],
          ),
        ),
      );
    },
  );
}

void _confirmRemoveMember(
  BuildContext context, {
  required String groupDocId,
  required String uid,
}) {
  showDialog(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: const Color(0xFF1B120A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: const Text('Remove Member?', style: TextStyle(color: Colors.white)),
      content: const Text(
        'They will be removed from this group and stop seeing it in their Groups tab.',
        style: TextStyle(color: Colors.white70),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
        ),
        TextButton(
          onPressed: () async {
            Navigator.of(dialogContext).pop();
            try {
              await FirebaseFirestore.instance
                  .collection('groups')
                  .doc(groupDocId)
                  .update({
                'members': FieldValue.arrayRemove([uid]),
                'membersCount': FieldValue.increment(-1),
                // A removed member also loses co-admin status, if any.
                'coAdminUids': FieldValue.arrayRemove([uid]),
              });

              if (!context.mounted) return;
              showTopAlert(context, 'Member removed.');
            } catch (e) {
              debugPrint('Remove member error: $e');
              if (!context.mounted) return;
              showTopAlert(context, 'Failed to remove member.', isError: true);
            }
          },
          child: const Text('Remove', style: TextStyle(color: Colors.redAccent)),
        ),
      ],
    ),
  );
}

// ================================================================
// GROUPS EMPTY STATE
// ----------------------------------------------------------------
// Same look as _CommunityEmptyState in community_page.dart --
// duplicated locally (it's a private class over there and can't be
// imported) rather than pulled out into a shared widget, to avoid
// touching community_page.dart's existing Community/Clubs empty
// states.
// ================================================================

class _GroupsEmptyState extends StatelessWidget {
  final VoidCallback onJoin;
  final VoidCallback onCreate;

  const _GroupsEmptyState({required this.onJoin, required this.onCreate});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF8B4513).withValues(alpha: .22),
                border: Border.all(
                  color: const Color(0xFFD2B48C).withValues(alpha: .45),
                ),
              ),
              child: const Icon(Icons.diversity_3_rounded,
                  size: 40, color: Color(0xFFFFE9B0)),
            ),
            const SizedBox(height: 20),
            const Text(
              'No groups yet',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Join a group to see it here, or start your own.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54, fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 28),
            SizedBox(
              width: double.infinity,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: AppColors.goldGradient,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: onJoin,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 14),
                      child: Center(
                        child: Text(
                          'Join Group',
                          style: TextStyle(
                            color: Color(0xFF1B120A),
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: onCreate,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  side: const BorderSide(color: Color(0xFFD2B48C), width: 1.2),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: const Text(
                  'Create Group',
                  style: TextStyle(
                    color: Color(0xFFFFE9B0),
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ================================================================
// SELECTED MEMBER (for the Create Group dialog's Add Member list)
// ================================================================

class _SelectedMember {
  final String uid;
  final String name;
  final String image;
  final bool isConnected;

  const _SelectedMember({
    required this.uid,
    required this.name,
    required this.image,
    required this.isConnected,
  });
}

// ================================================================
// CREATE GROUP DIALOG
// ================================================================

class _CreateGroupDialog extends StatefulWidget {
  const _CreateGroupDialog();

  @override
  State<_CreateGroupDialog> createState() => _CreateGroupDialogState();
}

class _CreateGroupDialogState extends State<_CreateGroupDialog> {
  // ==========================================================
  // CLOUDINARY -- same cloud name + upload flow already used for
  // profile images (me_page.dart). Reusing the existing preset here
  // keeps this on the exact upload path that's already configured
  // and working in the Cloudinary dashboard, per the requirement to
  // mirror the existing profile-image upload process.
  // ==========================================================
  static const String _cloudName = 'db4zevmud';
  static const String _uploadPreset = 'nexus_profile_images';

  final ImagePicker _imagePicker = ImagePicker();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  String? _groupImageUrl;
  bool _uploadingImage = false;

  String? _creatorAccountId; // full 10-char Account ID
  String _groupIdPreview = '';

  final List<_SelectedMember> _selectedMembers = [];

  bool _obscurePassword = true;
  bool _creating = false;

  @override
  void initState() {
    super.initState();
    _loadCreatorAccountId();
    _nameController.addListener(_updateGroupIdPreview);
  }

  @override
  void dispose() {
    _nameController.removeListener(_updateGroupIdPreview);
    _nameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  // ==========================================================
  // LOAD CREATOR'S ACCOUNT ID (needed for the Group ID suffix)
  // ==========================================================

  Future<void> _loadCreatorAccountId() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();

    final accountId = (doc.data()?['userId'] ?? '').toString();

    if (!mounted) return;

    setState(() {
      _creatorAccountId = accountId;
      _updateGroupIdPreview();
    });
  }

  // ==========================================================
  // GROUP ID PREVIEW
  // "@(groupname)-(first 4 digits of creator's Account ID)"
  // Recomputed live on every keystroke of the Group Name field.
  // ==========================================================

  void _updateGroupIdPreview() {
    final name = _nameController.text.trim();
    final accountId = _creatorAccountId ?? '';
    final suffix =
        accountId.length >= 4 ? accountId.substring(0, 4) : accountId;

    setState(() {
      _groupIdPreview = name.isEmpty ? '' : '@$name-$suffix';
    });
  }

  // ==========================================================
  // PICK + UPLOAD GROUP PROFILE IMAGE
  // Mirrors me_page.dart's _pickPrivateProfileImage exactly, just
  // saving the resulting URL into local dialog state instead of the
  // user's own profile.
  // ==========================================================

  Future<void> _pickGroupImage() async {
    try {
      final XFile? image = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 80,
        maxWidth: 800,
        maxHeight: 800,
      );

      if (image == null) return;
      if (!mounted) return;

      setState(() => _uploadingImage = true);

      final request = http.MultipartRequest(
        'POST',
        Uri.parse('https://api.cloudinary.com/v1_1/$_cloudName/image/upload'),
      );

      request.fields['upload_preset'] = _uploadPreset;
      request.files.add(await http.MultipartFile.fromPath('file', image.path));

      final response = await request.send();
      final responseBody = await response.stream.bytesToString();

      if (!mounted) return;

      if (response.statusCode != 200) {
        debugPrint('Cloudinary group image upload failed: $responseBody');
        setState(() => _uploadingImage = false);
        showTopAlert(context, 'Group image upload failed.', isError: true);
        return;
      }

      final Map<String, dynamic> data = jsonDecode(responseBody);
      final String imageUrl = (data['secure_url'] ?? '').toString();

      if (imageUrl.isEmpty) {
        throw Exception('Cloudinary URL not received.');
      }

      setState(() {
        _groupImageUrl = imageUrl;
        _uploadingImage = false;
      });
    } catch (e) {
      debugPrint('Group image pick/upload error: $e');
      if (!mounted) return;
      setState(() => _uploadingImage = false);
      showTopAlert(context, 'Group image upload failed.', isError: true);
    }
  }

  // ==========================================================
  // ADD MEMBER
  // ----------------------------------------------------------
  // Opens a bottom sheet listing the same accounts the Chats page
  // shows (Public + Private, connected + not-connected) -- i.e.
  // every account this user already has an open chat with, from the
  // 'chats' collection, exactly the source _buildChats() in
  // chat_page.dart reads from.
  // ==========================================================

  Future<void> _openAddMember() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1B120A),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(25)),
      ),
      builder: (sheetContext) {
        return _AddMemberSheet(
          currentUid: user.uid,
          initiallySelected: _selectedMembers.map((m) => m.uid).toSet(),
          onToggle: (member, selected) {
            setState(() {
              if (selected) {
                if (!_selectedMembers.any((m) => m.uid == member.uid)) {
                  _selectedMembers.add(member);
                }
              } else {
                _selectedMembers.removeWhere((m) => m.uid == member.uid);
              }
            });
          },
        );
      },
    );
  }

  void _removeSelectedMember(String uid) {
    setState(() {
      _selectedMembers.removeWhere((m) => m.uid == uid);
    });
  }

  // ==========================================================
  // PASSWORD VALIDATION
  // Exactly 6 characters -- digits and special characters only.
  // ==========================================================

  static final RegExp _passwordPattern = RegExp(
    r'^[0-9!@#$%^&*()\-_=+\[\]{};:' r"'" r'",.<>/?\\|`~]{6}$',
  );

  String? _validatePassword(String value) {
    if (value.isEmpty) return 'Password is required';
    if (value.length != 6) return 'Password must be exactly 6 characters';
    if (!_passwordPattern.hasMatch(value)) {
      return 'Only numbers and special characters are allowed';
    }
    return null;
  }

  // ==========================================================
  // CREATE
  // ==========================================================

  Future<void> _create() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final name = _nameController.text.trim();
    final password = _passwordController.text;

    if (name.isEmpty) {
      showTopAlert(context, 'Group name is required', isError: true);
      return;
    }

    final passwordError = _validatePassword(password);
    if (passwordError != null) {
      showTopAlert(context, passwordError, isError: true);
      return;
    }

    if (_creatorAccountId == null) {
      showTopAlert(context, 'Still loading your account, try again in a moment.');
      return;
    }

    setState(() => _creating = true);

    try {
      final currentUserDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();

      final currentUserData = currentUserDoc.data() ?? {};
      final creatorName = (currentUserData['privateName'] ??
              currentUserData['publicName'] ??
              'Someone')
          .toString()
          .trim();

      final result = await ApiService.createGroup(
        groupId: _groupIdPreview,
        groupName: name,
        groupProfileImage: _groupImageUrl ?? '',
        adminUid: user.uid,
        adminAccountId: _creatorAccountId!,
        members: _selectedMembers.map((m) => m.uid).toList(),
        password: password,
      );

      if (!mounted) return;

      if (result['success'] != true) {
        setState(() => _creating = false);
        showTopAlert(context, (result['message'] ?? 'Failed to create group').toString(), isError: true);
        return;
      }

      // ------------------------------------------------------
      // PERSIST GROUP REQUESTS
      // Mirrors the 'connections' pending-request pattern used
      // throughout the app (see chat_page.dart's _sendConnectionRequest
      // and notification.dart's _ConnectionRequestCard): one
      // Firestore doc per invited member, so the Notification page
      // can show a live, persistent Group Request card (with
      // Accept/Decline) instead of relying on the transient push
      // notification alone. Doc id is "<groupDocId>_<memberUid>" so
      // re-inviting the same member never creates a duplicate. No
      // password/passwordHash/passwordSalt field is ever written
      // here -- the group password never leaves the create-group
      // API call above.
      // ------------------------------------------------------
      final String createdGroupDocId = (result['docId'] ?? '').toString();
      final String createdGroupId =
          (result['groupId'] ?? _groupIdPreview).toString();

      for (final member in _selectedMembers) {
        final requestRef = FirebaseFirestore.instance
            .collection('groupRequests')
            .doc('${createdGroupDocId}_${member.uid}');

        await requestRef.set({
          'groupDocId': createdGroupDocId,
          'groupId': createdGroupId,
          'groupName': name,
          'groupProfileImage': _groupImageUrl ?? '',
          'adminUid': user.uid,
          'adminAccountId': _creatorAccountId ?? '',
          'senderUid': user.uid,
          'senderName': creatorName,
          'receiverUid': member.uid,
          'status': 'pending',
          'createdAt': FieldValue.serverTimestamp(),
        });

        // --------------------------------------------------
        // NOTIFY SELECTED MEMBER
        // Every selected account gets a group-request push
        // notification through the same NotificationService the
        // rest of the app already uses for chat/connection
        // notifications, on top of the persisted request above.
        // --------------------------------------------------
        unawaited(
          NotificationService.instance.sendToUser(
            receiverUid: member.uid,
            senderName: creatorName,
            message: '$creatorName invited you to join "$name"',
            type: 'group_request',
            senderUid: user.uid,
          ),
        );
      }

      if (!mounted) return;

      Navigator.of(context).pop();

      showTopAlert(context, '"$name" created');
    } catch (e) {
      debugPrint('Create group error: $e');
      if (!mounted) return;
      setState(() => _creating = false);
      showTopAlert(context, 'Failed to create group.', isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1B120A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 640),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Create Group',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 18),

              // ---------------------------------------------
              // GROUP PROFILE IMAGE (top center)
              // ---------------------------------------------
              Center(
                child: GestureDetector(
                  onTap: _uploadingImage ? null : _pickGroupImage,
                  child: Stack(
                    children: [
                      Container(
                        width: 90,
                        height: 90,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFF2A1B0E),
                          border: Border.all(
                            color: const Color(0xFFD2B48C),
                            width: 2,
                          ),
                        ),
                        child: _uploadingImage
                            ? const Center(
                                child: SizedBox(
                                  width: 26,
                                  height: 26,
                                  child: CircularProgressIndicator(
                                    color: Color(0xFFD2B48C),
                                    strokeWidth: 2.4,
                                  ),
                                ),
                              )
                            : (_groupImageUrl != null &&
                                    _groupImageUrl!.isNotEmpty)
                                ? ClipOval(
                                    child: Image(
                                      image: _profileImageProvider(
                                          _groupImageUrl!)!,
                                      fit: BoxFit.cover,
                                    ),
                                  )
                                : const Icon(
                                    Icons.diversity_3_rounded,
                                    color: Colors.white70,
                                    size: 42,
                                  ),
                      ),
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: Container(
                          width: 26,
                          height: 26,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: AppColors.goldGradient,
                          ),
                          child: const Icon(
                            Icons.camera_alt_rounded,
                            size: 14,
                            color: Color(0xFF1B120A),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
              const Center(
                child: Text(
                  'Tap to add a group image (optional)',
                  style: TextStyle(color: Colors.white38, fontSize: 11.5),
                ),
              ),

              const SizedBox(height: 20),

              // ---------------------------------------------
              // GROUP NAME
              // ---------------------------------------------
              const _FieldLabel('Group Name'),
              const SizedBox(height: 6),
              _DialogTextField(
                controller: _nameController,
                hintText: 'e.g. Gaming City',
                maxLength: 60,
              ),

              const SizedBox(height: 4),

              // ---------------------------------------------
              // GROUP ID (auto generated, live)
              // ---------------------------------------------
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    const Icon(Icons.tag_rounded,
                        size: 15, color: Color(0xFFD2B48C)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _groupIdPreview.isEmpty
                            ? 'Group ID will appear here'
                            : _groupIdPreview,
                        style: TextStyle(
                          color: _groupIdPreview.isEmpty
                              ? Colors.white38
                              : const Color(0xFFFFE9B0),
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 18),

              // ---------------------------------------------
              // ADD MEMBER
              // ---------------------------------------------
              const _FieldLabel('Members'),
              const SizedBox(height: 6),
              OutlinedButton.icon(
                onPressed: _openAddMember,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  side: const BorderSide(color: Color(0xFFD2B48C), width: 1.1),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                icon: const Icon(Icons.person_add_alt_1_rounded,
                    color: Color(0xFFFFE9B0), size: 18),
                label: const Text(
                  'Add Member',
                  style: TextStyle(
                    color: Color(0xFFFFE9B0),
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ),

              // ---------------------------------------------
              // SELECTED MEMBERS -- "[profile image | name | (-)]"
              // Only the first 4 rows show at once; beyond that the
              // list scrolls in place (fixed-height ListView) rather
              // than pushing the rest of the form down.
              // ---------------------------------------------
              if (_selectedMembers.isNotEmpty) ...[
                const SizedBox(height: 10),
                SizedBox(
                  height:
                      (_selectedMembers.length > 4 ? 4 : _selectedMembers.length) *
                          46.0,
                  child: ListView.builder(
                    padding: EdgeInsets.zero,
                    itemCount: _selectedMembers.length,
                    itemBuilder: (context, index) {
                      final member = _selectedMembers[index];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: [
                            CircleAvatar(
                              radius: 16,
                              backgroundColor: const Color(0xFF2A1B0E),
                              backgroundImage:
                                  _profileImageProvider(member.image),
                              child: member.image.isEmpty
                                  ? const Icon(Icons.person_rounded,
                                      color: Colors.white70, size: 16)
                                  : null,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                member.name.isEmpty ? 'Unnamed' : member.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13.5,
                                ),
                              ),
                            ),
                            GestureDetector(
                              onTap: () => _removeSelectedMember(member.uid),
                              child: Container(
                                width: 22,
                                height: 22,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                      color: Colors.redAccent, width: 1.2),
                                ),
                                child: const Icon(
                                  Icons.remove_rounded,
                                  color: Colors.redAccent,
                                  size: 14,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],

              const SizedBox(height: 12),

              // ---------------------------------------------
              // PASSWORD
              // ---------------------------------------------
              const _FieldLabel('Password'),
              const SizedBox(height: 6),
              _DialogTextField(
                controller: _passwordController,
                hintText: '6 digits / symbols',
                obscureText: _obscurePassword,
                maxLength: 6,
                keyboardType: TextInputType.visiblePassword,
                inputFormatters: [
                  // Numbers and special characters only -- letters
                  // and whitespace are rejected as the user types.
                  FilteringTextInputFormatter.deny(RegExp(r'[A-Za-z\s]')),
                  LengthLimitingTextInputFormatter(6),
                ],
                suffixIcon: IconButton(
                  onPressed: () {
                    setState(() => _obscurePassword = !_obscurePassword);
                  },
                  icon: Icon(
                    _obscurePassword
                        ? Icons.visibility_off_rounded
                        : Icons.visibility_rounded,
                    color: Colors.white54,
                    size: 18,
                  ),
                ),
              ),

              const SizedBox(height: 22),

              // ---------------------------------------------
              // CREATE
              // ---------------------------------------------
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: AppColors.goldGradient,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: _creating ? null : _create,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      child: Center(
                        child: _creating
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  color: Color(0xFF1B120A),
                                  strokeWidth: 2.4,
                                ),
                              )
                            : const Text(
                                'Create',
                                style: TextStyle(
                                  color: Color(0xFF1B120A),
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                ),
                              ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: TextButton(
                  onPressed: _creating
                      ? null
                      : () => Navigator.of(context).pop(),
                  child: const Text(
                    'Cancel',
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ================================================================
// JOIN GROUP DIALOG
// ----------------------------------------------------------------
// Opened from the Groups tab's empty-state "Join Group" button.
// Group ID + Group Password -> POST /api/join-group (server.js /
// index.js), which is the one place that knows the group's
// passwordHash/passwordSalt and can check the entered password
// without the client ever reading either field.
// ================================================================

class _JoinGroupDialog extends StatefulWidget {
  // Set when opened from a search-suggestion tap (_GroupSuggestionTile) --
  // pre-fills and locks the Group ID field, since the user already
  // picked the exact group. Null for the manual "Join Group" entry
  // point (empty state), where both fields start blank.
  final String? initialGroupId;

  const _JoinGroupDialog({this.initialGroupId});

  @override
  State<_JoinGroupDialog> createState() => _JoinGroupDialogState();
}

class _JoinGroupDialogState extends State<_JoinGroupDialog> {
  late final TextEditingController _groupIdController =
      TextEditingController(text: widget.initialGroupId ?? '');
  final TextEditingController _passwordController = TextEditingController();

  bool _obscurePassword = true;
  bool _joining = false;

  bool get _groupIdLocked =>
      widget.initialGroupId != null && widget.initialGroupId!.isNotEmpty;

  @override
  void dispose() {
    _groupIdController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  // ==========================================================
  // JOIN
  // ==========================================================

  Future<void> _join() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final groupId = _groupIdController.text.trim();
    final password = _passwordController.text;

    if (groupId.isEmpty) {
      showTopAlert(context, 'Group ID is required', isError: true);
      return;
    }

    if (password.isEmpty) {
      showTopAlert(context, 'Group password is required', isError: true);
      return;
    }

    setState(() => _joining = true);

    try {
      final result = await ApiService.joinGroup(
        groupId: groupId,
        password: password,
        uid: user.uid,
      );

      if (!mounted) return;

      // ------------------------------------------------------
      // ALREADY A MEMBER -- distinct message, dialog closes
      // (the group already shows in the tab; nothing more to do).
      // ------------------------------------------------------
      if (result['alreadyMember'] == true) {
        Navigator.of(context).pop();
        showTopAlert(context, (result['message'] ?? "You're already a member of this group")
                  .toString());
        return;
      }

      // ------------------------------------------------------
      // WRONG GROUP ID / WRONG PASSWORD / OTHER FAILURE --
      // dialog stays open so the user can correct and retry.
      // ------------------------------------------------------
      if (result['success'] != true) {
        setState(() => _joining = false);
        showTopAlert(context, (result['message'] ?? 'Failed to join group').toString(), isError: true);
        return;
      }

      // ------------------------------------------------------
      // SUCCESS -- notify the group's admin that someone joined,
      // same push-notification pattern Create Group already uses
      // to notify invited members (see _CreateGroupDialogState
      // above). Fire-and-forget: it must never block closing the
      // dialog or block on a failed notification.
      // ------------------------------------------------------
      final String joinedGroupName =
          (result['groupName'] ?? groupId).toString();
      final String adminUid = (result['adminUid'] ?? '').toString();

      if (adminUid.isNotEmpty && adminUid != user.uid) {
        final currentUserDoc = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .get();
        final currentUserData = currentUserDoc.data() ?? {};
        final joinerName = (currentUserData['privateName'] ??
                currentUserData['publicName'] ??
                'Someone')
            .toString()
            .trim();

        unawaited(
          NotificationService.instance.sendToUser(
            receiverUid: adminUid,
            senderName: joinerName,
            message: '$joinerName joined "$joinedGroupName"',
            type: 'group_join',
            senderUid: user.uid,
          ),
        );
      }

      if (!mounted) return;
      Navigator.of(context).pop();
      showTopAlert(context, 'Joined "$joinedGroupName"');
    } catch (e) {
      debugPrint('Join group error: $e');
      if (!mounted) return;
      setState(() => _joining = false);
      showTopAlert(context, 'Failed to join group.', isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1B120A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Join Group',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 18),

              // ---------------------------------------------
              // GROUP ID
              // ---------------------------------------------
              const _FieldLabel('Group ID'),
              const SizedBox(height: 6),
              _DialogTextField(
                controller: _groupIdController,
                hintText: 'e.g. @gaming-city-1a2b',
                enabled: !_groupIdLocked,
              ),

              const SizedBox(height: 16),

              // ---------------------------------------------
              // GROUP PASSWORD
              // ---------------------------------------------
              const _FieldLabel('Group Password'),
              const SizedBox(height: 6),
              _DialogTextField(
                controller: _passwordController,
                hintText: '6 digits / symbols',
                obscureText: _obscurePassword,
                maxLength: 6,
                keyboardType: TextInputType.visiblePassword,
                inputFormatters: [
                  // Numbers and special characters only -- letters
                  // and whitespace are rejected as the user types,
                  // mirroring the Create Group password field.
                  FilteringTextInputFormatter.deny(RegExp(r'[A-Za-z\s]')),
                  LengthLimitingTextInputFormatter(6),
                ],
                suffixIcon: IconButton(
                  onPressed: () {
                    setState(() => _obscurePassword = !_obscurePassword);
                  },
                  icon: Icon(
                    _obscurePassword
                        ? Icons.visibility_off_rounded
                        : Icons.visibility_rounded,
                    color: Colors.white54,
                    size: 18,
                  ),
                ),
              ),

              const SizedBox(height: 22),

              // ---------------------------------------------
              // JOIN
              // ---------------------------------------------
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: AppColors.goldGradient,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: _joining ? null : _join,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      child: Center(
                        child: _joining
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  color: Color(0xFF1B120A),
                                  strokeWidth: 2.4,
                                ),
                              )
                            : const Text(
                                'Join',
                                style: TextStyle(
                                  color: Color(0xFF1B120A),
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                ),
                              ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: TextButton(
                  onPressed:
                      _joining ? null : () => Navigator.of(context).pop(),
                  child: const Text(
                    'Cancel',
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ================================================================
// FIELD LABEL
// ================================================================

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: Color(0xFFD2B48C),
        fontSize: 12.5,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

// ================================================================
// DIALOG TEXT FIELD (shared styling for name/password inputs)
// ================================================================

class _DialogTextField extends StatelessWidget {
  final TextEditingController controller;
  final String hintText;
  final bool obscureText;
  final int? maxLength;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final Widget? suffixIcon;
  final bool enabled;

  const _DialogTextField({
    required this.controller,
    required this.hintText,
    this.obscureText = false,
    this.maxLength,
    this.keyboardType,
    this.inputFormatters,
    this.suffixIcon,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscureText,
      maxLength: maxLength,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      enabled: enabled,
      style: const TextStyle(color: Colors.white, fontSize: 14),
      decoration: InputDecoration(
        counterText: '',
        hintText: hintText,
        hintStyle: const TextStyle(color: Colors.white38, fontSize: 13.5),
        suffixIcon: suffixIcon,
        filled: true,
        fillColor: const Color(0xFF2A1B0E),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(
            color: const Color(0xFFD2B48C).withValues(alpha: .3),
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(
            color: const Color(0xFFD2B48C).withValues(alpha: .3),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFFD2B48C), width: 1.4),
        ),
      ),
    );
  }
}

// ================================================================
// ADD MEMBER SHEET
// ----------------------------------------------------------------
// Same account universe the Chats page's Public/Private list is
// built from: every account in the 'chats' collection this user is
// a participant in, connected or not. Connected accounts show their
// private name/image, everyone else shows public name/image --
// exactly _resolveDisplayName / _resolveDisplayImage in
// chat_page.dart.
//
// A search bar at the top filters that list by name as you type,
// and -- once exactly 10 characters are entered, same rule as the
// Chats page's own Account ID search (_handleSearchChanged in
// chat_page.dart) -- does an exact `userId` lookup instead, so a new
// account can be found and added even if there's no existing chat
// with them yet.
//
// Each row's leading checkbox reflects selection state from this
// widget's OWN State (not a scoped rebuild-losing local variable),
// so tapping a row fills/unfills its circle immediately and stays
// that way.
// ================================================================

class _AddMemberSheet extends StatefulWidget {
  final String currentUid;
  final Set<String> initiallySelected;
  final void Function(_SelectedMember member, bool selected) onToggle;
  // Accounts to hide from the picker entirely -- used when adding a
  // member to an EXISTING group, so people already in the group or
  // already invited (pending) never show up here again. Defaults to
  // empty for the Create Group dialog's original use of this sheet.
  final Set<String> excludeUids;

  const _AddMemberSheet({
    required this.currentUid,
    required this.initiallySelected,
    required this.onToggle,
    this.excludeUids = const {},
  });

  @override
  State<_AddMemberSheet> createState() => _AddMemberSheetState();
}

class _AddMemberSheetState extends State<_AddMemberSheet> {
  late final Set<String> _localSelected;
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  Timer? _idSearchDebounce;
  int _idSearchRequest = 0;
  bool _idSearching = false;
  Map<String, dynamic>? _idSearchResult; // null once searched = not found

  @override
  void initState() {
    super.initState();
    _localSelected = {...widget.initiallySelected};
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _idSearchDebounce?.cancel();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  bool get _isIdSearch => _query.length == 10;

  void _onSearchChanged() {
    final text = _searchController.text.trim();
    _idSearchDebounce?.cancel();

    setState(() {
      _query = text;
      if (text.length != 10) _idSearchResult = null;
    });

    if (text.length == 10) {
      final requestId = ++_idSearchRequest;
      _idSearchDebounce = Timer(const Duration(milliseconds: 250), () {
        _lookupAccountId(text, requestId);
      });
    }
  }

  Future<void> _lookupAccountId(String accountId, int requestId) async {
    if (!mounted || requestId != _idSearchRequest) return;
    setState(() => _idSearching = true);

    try {
      final result = await FirebaseFirestore.instance
          .collection('users')
          .where('userId', isEqualTo: accountId)
          .limit(1)
          .get();

      if (!mounted || requestId != _idSearchRequest) return;

      Map<String, dynamic>? data;
      if (result.docs.isNotEmpty) {
        data = Map<String, dynamic>.from(result.docs.first.data());
        data['uid'] = (data['uid'] ?? result.docs.first.id).toString();
      }

      setState(() {
        _idSearching = false;
        _idSearchResult = data;
      });
    } catch (e) {
      debugPrint('Add member account ID search error: $e');
      if (!mounted || requestId != _idSearchRequest) return;
      setState(() {
        _idSearching = false;
        _idSearchResult = null;
      });
    }
  }

  String _resolveName(Map<String, dynamic> userData, bool isConnected) {
    final privateName = (userData['privateName'] ?? '').toString().trim();
    final publicName = (userData['publicName'] ?? '').toString().trim();
    if (isConnected && privateName.isNotEmpty) return privateName;
    return publicName;
  }

  String _resolveImage(Map<String, dynamic> userData, bool isConnected) {
    final privateImage = (userData['privateImage'] ?? '').toString().trim();
    final publicImage = (userData['publicImage'] ?? '').toString().trim();
    if (isConnected && privateImage.isNotEmpty) return privateImage;
    return publicImage;
  }

  void _toggleSelect({
    required String uid,
    required String name,
    required String image,
    required bool isConnected,
  }) {
    final next = !_localSelected.contains(uid);
    setState(() {
      if (next) {
        _localSelected.add(uid);
      } else {
        _localSelected.remove(uid);
      }
    });
    widget.onToggle(
      _SelectedMember(uid: uid, name: name, image: image, isConnected: isConnected),
      next,
    );
  }

  Widget _memberTile({
    required String uid,
    required Map<String, dynamic> userData,
    required bool isConnected,
  }) {
    final name = _resolveName(userData, isConnected);
    final image = _resolveImage(userData, isConnected);
    final selected = _localSelected.contains(uid);

    return ListTile(
      leading: CircleAvatar(
        radius: 20,
        backgroundColor: const Color(0xFF2A1B0E),
        backgroundImage: _profileImageProvider(image),
        child: image.isEmpty
            ? const Icon(Icons.person_rounded, color: Colors.white70)
            : null,
      ),
      title: Text(
        name.isEmpty ? 'Unnamed' : name,
        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
      ),
      subtitle: isConnected
          ? const Text(
              'Connected',
              style: TextStyle(color: Color(0xFFD2B48C), fontSize: 11.5),
            )
          : null,
      trailing: Icon(
        selected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
        color: selected ? const Color(0xFFFFE9B0) : Colors.white38,
      ),
      onTap: () => _toggleSelect(
        uid: uid,
        name: name,
        image: image,
        isConnected: isConnected,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      // ------------------------------------------------------
      // Connected accounts (drives which name/image is shown).
      // ------------------------------------------------------
      stream: FirebaseFirestore.instance
          .collection('connections')
          .where('users', arrayContains: widget.currentUid)
          .where('status', isEqualTo: 'connected')
          .snapshots(),
      builder: (context, connectionsSnapshot) {
        final connectedUids = <String>{};

        for (final doc in connectionsSnapshot.data?.docs ?? []) {
          final users = List<String>.from(doc.data()['users'] ?? []);
          final otherUid = users
              .firstWhere((id) => id != widget.currentUid, orElse: () => '');
          if (otherUid.isNotEmpty) connectedUids.add(otherUid);
        }

        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          // ------------------------------------------------------
          // Accounts available to add -- the same 'chats' collection
          // the Chats page's Public/Private list reads from.
          // ------------------------------------------------------
          stream: FirebaseFirestore.instance
              .collection('chats')
              .where('participants', arrayContains: widget.currentUid)
              .snapshots(),
          builder: (context, chatsSnapshot) {
            final otherUids = <String>{};

            for (final doc in chatsSnapshot.data?.docs ?? []) {
              final participants =
                  List<String>.from(doc.data()['participants'] ?? []);
              final otherUid = participants.firstWhere(
                (id) => id != widget.currentUid,
                orElse: () => '',
              );
              if (otherUid.isNotEmpty &&
                  !widget.excludeUids.contains(otherUid)) {
                otherUids.add(otherUid);
              }
            }

            // The exact-ID search result, if any, resolved into the
            // same shape as everything else -- but only ever shown
            // when it isn't the current user and isn't already
            // excluded (already a member / already invited).
            final idResult = _idSearchResult;
            final idResultUid = idResult == null ? null : idResult['uid']?.toString();
            final idResultUsable = idResultUid != null &&
                idResultUid.isNotEmpty &&
                idResultUid != widget.currentUid &&
                !widget.excludeUids.contains(idResultUid);

            return DraggableScrollableSheet(
              initialChildSize: 0.75,
              minChildSize: 0.4,
              maxChildSize: 0.92,
              expand: false,
              builder: (context, scrollController) {
                return SafeArea(
                  child: Column(
                    children: [
                      const Padding(
                        padding: EdgeInsets.fromLTRB(20, 16, 20, 12),
                        child: Text(
                          'Add Member',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      // -----------------------------------------
                      // SEARCH BAR -- name filter, or exact 10-
                      // character Account ID lookup once the full
                      // ID has been typed.
                      // -----------------------------------------
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                        child: TextField(
                          controller: _searchController,
                          style: const TextStyle(color: Colors.white, fontSize: 14),
                          decoration: InputDecoration(
                            hintText: 'Search name or 10-digit Account ID',
                            hintStyle: const TextStyle(
                                color: Colors.white38, fontSize: 13),
                            prefixIcon: const Icon(Icons.search_rounded,
                                color: Colors.white54, size: 20),
                            suffixIcon: _searchController.text.isEmpty
                                ? null
                                : IconButton(
                                    icon: const Icon(Icons.close_rounded,
                                        color: Colors.white54, size: 18),
                                    onPressed: () => _searchController.clear(),
                                  ),
                            filled: true,
                            fillColor: const Color(0xFF2A1B0E),
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 0),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                              borderSide: BorderSide(
                                color:
                                    const Color(0xFFD2B48C).withValues(alpha: .3),
                              ),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                              borderSide: BorderSide(
                                color:
                                    const Color(0xFFD2B48C).withValues(alpha: .3),
                              ),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                              borderSide: const BorderSide(
                                  color: Color(0xFFD2B48C), width: 1.4),
                            ),
                          ),
                        ),
                      ),
                      const Divider(color: Colors.white12, height: 1),
                      Expanded(
                        child: _isIdSearch
                            // ---------------------------------
                            // EXACT ACCOUNT ID SEARCH RESULT
                            // ---------------------------------
                            ? (_idSearching
                                ? const Center(
                                    child: CircularProgressIndicator(
                                        color: Color(0xFFD2B48C)),
                                  )
                                : !idResultUsable
                                    ? const Center(
                                        child: Padding(
                                          padding: EdgeInsets.all(24),
                                          child: Text(
                                            'No account found with that ID.',
                                            textAlign: TextAlign.center,
                                            style:
                                                TextStyle(color: Colors.white54),
                                          ),
                                        ),
                                      )
                                    : ListView(
                                        controller: scrollController,
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 8),
                                        children: [
                                          _memberTile(
                                            uid: idResultUid,
                                            userData: idResult!,
                                            isConnected:
                                                connectedUids.contains(idResultUid),
                                          ),
                                        ],
                                      ))
                            // ---------------------------------
                            // NORMAL LIST -- optionally filtered
                            // by name as the user types.
                            // ---------------------------------
                            : otherUids.isEmpty
                                ? const Center(
                                    child: Padding(
                                      padding: EdgeInsets.all(24),
                                      child: Text(
                                        'No accounts to add yet. Start a chat with someone first.',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(color: Colors.white54),
                                      ),
                                    ),
                                  )
                                : ListView.builder(
                                    controller: scrollController,
                                    padding:
                                        const EdgeInsets.symmetric(vertical: 8),
                                    itemCount: otherUids.length,
                                    itemBuilder: (context, index) {
                                      final uid = otherUids.elementAt(index);
                                      final isConnected =
                                          connectedUids.contains(uid);

                                      return StreamBuilder<
                                          DocumentSnapshot<Map<String, dynamic>>>(
                                        stream: FirebaseFirestore.instance
                                            .collection('users')
                                            .doc(uid)
                                            .snapshots(),
                                        builder: (context, userSnapshot) {
                                          final userData =
                                              userSnapshot.data?.data();
                                          if (userData == null) {
                                            return const SizedBox.shrink();
                                          }

                                          if (_query.isNotEmpty) {
                                            final name = _resolveName(
                                                    userData, isConnected)
                                                .toLowerCase();
                                            if (!name.contains(
                                                _query.toLowerCase())) {
                                              return const SizedBox.shrink();
                                            }
                                          }

                                          return _memberTile(
                                            uid: uid,
                                            userData: userData,
                                            isConnected: isConnected,
                                          );
                                        },
                                      );
                                    },
                                  ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}