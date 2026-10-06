import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'groupchat.dart';
import 'community_members_page.dart';
import 'community_announcements_page.dart';
import 'community_events_page.dart';
import 'community_groups_page.dart';
import 'community_clubs_page.dart';
import 'community_activities_page.dart';
import 'community_feed_page.dart';
import 'community_polls_page.dart';
import 'community_resources_page.dart';
import 'community_search_page.dart';
import 'community_notice_board.dart';
import 'community_this_week_card.dart';
import 'community_member_profile_page.dart';
import 'edit_community_dialog.dart';
import '../club/club_icons.dart';
import '../services/community_service.dart';
import '../services/community_badge_service.dart';
import '../services/community_member_profile_service.dart';
import '../services/community_feed_service.dart';
import '../services/community_activity_service.dart';
import '../services/community_group_service.dart';
import '../services/community_poll_service.dart';
import '../services/event_service.dart';
import '../services/announcement_service.dart';
import '../widgets/community_about_section.dart';
import '../widgets/community_widgets.dart';
import '../widgets/top_alert.dart';

// ================================================================
// COMMUNITY HOME
// ----------------------------------------------------------------
// The Community dashboard (spec section 1). The top bar shows the
// community's profile + name (tap to open its details sheet), with quick
// navigation into the sections that are wired up so far: the
// Community Chat (a real GroupChatScreen -- see community_service.dart
// for why that "just works"), Announcements (community_announcements_page.dart
// / announcement_service.dart), Events (community_events_page.dart /
// event_service.dart), Groups (community_groups_page.dart /
// community_group_service.dart) and the Members directory, plus a
// "latest announcement" preview card, plus Feed, Polls and the
// Resources library, Activities and the unified Community Search,
// plus a "This week" digest card (community_this_week_card.dart,
// built on community_ai_context_service.dart). Member profiles with
// Contributions open from the Members page and from Search.
// Everything else in the full spec (Moderation, ...) is designed for in the data model already
// (CommunityService.isPrivileged(), the 'communities' collection
// shape) but not built yet -- rather than ship dead buttons for
// those, this screen only surfaces what is actually live today.
// ================================================================
class CommunityHomePage extends StatefulWidget {
  final String communityDocId;

  const CommunityHomePage({super.key, required this.communityDocId});

  @override
  State<CommunityHomePage> createState() => _CommunityHomePageState();
}

class _CommunityHomePageState extends State<CommunityHomePage> {
  late final String _uid = FirebaseAuth.instance.currentUser?.uid ?? '';
  late final Stream<DocumentSnapshot<Map<String, dynamic>>> _communityStream =
      CommunityService.watchCommunity(widget.communityDocId);

  // ==========================================================
  // NEW-ITEM BADGES
  // ----------------------------------------------------------
  // Numbers (Announcements / Events / Feed / Polls / Activities)
  // = how many items that section currently has (Events: upcoming).
  // Dots (Groups / Community Chat) = a new group or unread group
  // messages / unread community chat messages.
  // See community_badge_service.dart.
  // ==========================================================
  final List<StreamSubscription<dynamic>> _subs = [];
  Timer? _minuteTick;
  StreamSubscription<dynamic>? _chatSub;
  String _watchedChatGroupId = '';

  Map<String, DateTime> _seen = {};
  final Map<String, DateTime> _localSeen = {};
  bool _seenLoaded = false;
  bool _baselineRequested = false;
  DateTime? _chatLocalReadAt;

  List<Map<String, dynamic>> _announcements = [];
  List<Map<String, dynamic>> _events = [];
  List<Map<String, dynamic>> _posts = [];
  List<Map<String, dynamic>> _polls = [];
  List<Map<String, dynamic>> _activities = [];
  List<Map<String, dynamic>> _groups = [];
  Map<String, dynamic>? _chatGroup;

  @override
  void initState() {
    super.initState();
    final id = widget.communityDocId;

    // A member of the old (uid-based) data gets their member profile
    // (Profile ID) created once, from the data they already have.
    CommunityService.watchCommunity(id).first
        .then((snap) {
          final data = snap.data();
          if (data != null) {
            CommunityMemberProfileService.ensureMyProfile(id, data);
          }
        })
        .catchError((Object e) {
          debugPrint('Member profile check error: $e');
        });

    // Upcoming-events badge changes as events end, so re-check every minute.
    _minuteTick = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });

    void listen<T>(Stream<T> stream, void Function(T value) onData) {
      _subs.add(
        stream.listen(
          (value) {
            if (!mounted) return;
            setState(() => onData(value));
          },
          onError: (Object e) {
            debugPrint('Community badge stream error: $e');
          },
        ),
      );
    }

    listen<Map<String, DateTime>>(CommunityBadgeService.watchSeen(id), (m) {
      _seen = m;
      _seenLoaded = true;
      _ensureBaseline();
    });
    listen<List<Map<String, dynamic>>>(
      AnnouncementService.watchAnnouncements(id),
      (l) => _announcements = l,
    );
    listen<List<Map<String, dynamic>>>(
      EventService.watchEvents(id),
      (l) => _events = l,
    );
    listen<CommunityFeedSnapshot>(
      CommunityFeedService.watchPosts(id),
      (f) => _posts = f.posts,
    );
    listen<List<Map<String, dynamic>>>(
      CommunityPollService.watchPolls(id),
      (l) => _polls = l,
    );
    listen<CommunityFeedSnapshot>(
      CommunityActivityService.watchActivities(id),
      (f) => _activities = f.posts,
    );
    listen<List<Map<String, dynamic>>>(
      CommunityGroupService.watchGroups(id),
      (l) => _groups = l,
    );

    // Community Chat is a normal group doc; find it from the
    // community doc, then watch it for unread messages.
    _subs.add(
      CommunityService.watchCommunity(id).listen(
        (snap) {
          final gid = (snap.data()?['groupDocId'] ?? '').toString();
          if (gid.isEmpty || gid == _watchedChatGroupId) return;
          _watchedChatGroupId = gid;
          _chatSub?.cancel();
          _chatSub = CommunityGroupService.watchGroup(gid).listen(
            (doc) {
              if (!mounted) return;
              setState(() => _chatGroup = doc.data());
            },
            onError: (Object e) {
              debugPrint('Community chat badge error: $e');
            },
          );
        },
        onError: (Object e) {
          debugPrint('Community badge stream error: $e');
        },
      ),
    );
  }

  @override
  void dispose() {
    _minuteTick?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _chatSub?.cancel();
    super.dispose();
  }

  /// First time in this community: start counting from NOW so an
  /// existing community doesn't open with a huge number.
  void _ensureBaseline() {
    if (_baselineRequested || !_seenLoaded) return;
    _baselineRequested = true;
    // Only Groups still uses a "last opened" marker (new-group dot).
    final missing = const [
      'groups',
    ].where((s) => !_seen.containsKey(s)).toList();
    if (missing.isEmpty) return;
    final now = DateTime.now();
    for (final s in missing) {
      _localSeen[s] = now;
    }
    CommunityBadgeService.markSeen(widget.communityDocId, sections: missing);
  }

  /// Later of the server marker and the optimistic local one (a
  /// server timestamp reads back null until the write is confirmed).
  DateTime? _seenAt(String section) {
    final server = _seen[section];
    final local = _localSeen[section];
    if (server == null) return local;
    if (local == null) return server;
    return local.isAfter(server) ? local : server;
  }

  // ----------------------------------------------------------
  // Count badges (top-right of the card). The number is how many
  // items the section currently has -- the same ones its page
  // lists -- and nothing is shown when the section is empty.
  // ----------------------------------------------------------

  int get _announcementsCount => _announcements.length;

  /// Events badge = how many events are upcoming (or live right now),
  /// i.e. the same events the Events page lists as "upcoming".
  int get _eventsUpcoming =>
      _events.where((e) => !EventService.isPast(e)).length;

  int get _feedCount =>
      _posts.where((p) => !CommunityFeedService.isReported(p, _uid)).length;

  /// Community-wide polls plus polls of groups I'm in (same rule as
  /// the Polls page's visibility check).
  List<Map<String, dynamic>> get _visiblePolls {
    final myGroupIds = <String>{
      for (final g in _groups)
        if (CommunityBadgeService.isMember(g, _uid)) (g['id'] ?? '').toString(),
    };
    return _polls.where((p) {
      switch ((p['scope'] ?? 'community').toString()) {
        case 'group':
          return myGroupIds.contains((p['scopeId'] ?? '').toString());
        case 'community':
          return true;
        default:
          return false; // legacy club polls never show here
      }
    }).toList();
  }

  int get _pollsCount => _visiblePolls.length;

  int get _activitiesCount => _activities
      .where((p) => !CommunityFeedService.isReported(p, _uid))
      .length;

  /// Dot on Groups: a new group (made by someone else) since I last
  /// opened Groups, OR unread messages in a group I'm a member of.
  bool get _groupsDot {
    final seenAt = _seenAt('groups');
    for (final g in _groups) {
      if (CommunityGroupService.isExpired(g)) continue;

      final created = CommunityBadgeService.dateOf(g['createdAt']);
      final isNewGroup =
          seenAt != null &&
          created != null &&
          created.isAfter(seenAt) &&
          (g['adminUid'] ?? '').toString() != _uid;
      if (isNewGroup) return true;

      if (CommunityBadgeService.isMember(g, _uid) &&
          !CommunityBadgeService.isMuted(g, _uid) &&
          CommunityBadgeService.groupHasUnread(g, _uid)) {
        return true;
      }
    }
    return false;
  }

  bool get _chatDot {
    final g = _chatGroup;
    if (g == null) return false;
    return CommunityBadgeService.groupHasUnread(
      g,
      _uid,
      localReadAt: _chatLocalReadAt,
    );
  }

  void _touch(String section) {
    // Only Groups tracks a last-opened time (count badges don't).
    if (!mounted || section != 'groups') return;
    setState(() => _localSeen[section] = DateTime.now());
    CommunityBadgeService.markSeen(widget.communityDocId, sections: [section]);
  }

  /// Opens a section page; the section counts as seen when opened and
  /// again when coming back (so things that arrived while inside
  /// don't light the badge up).
  Future<void> _open(String section, Widget page) async {
    _touch(section);
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    _touch(section);
  }

  Future<void> _openChat(String groupDocId) async {
    setState(() => _chatLocalReadAt = DateTime.now());
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GroupChatScreen(groupDocId: groupDocId),
      ),
    );
    if (!mounted) return;
    setState(() => _chatLocalReadAt = DateTime.now());
  }

  @override
  Widget build(BuildContext context) {
    final uid = _uid;
    final communityDocId = widget.communityDocId;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: _communityStream,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(
                child: CircularProgressIndicator(color: Color(0xFFD2B48C)),
              );
            }

            if (snapshot.hasError) {
              return _MessageState(
                icon: Icons.error_outline_rounded,
                title: 'Unable to load Community',
                subtitle: 'Something went wrong. Please try again.',
                actionLabel: 'Go Back',
                onAction: () => Navigator.of(context).pop(),
              );
            }

            final data = snapshot.data?.data();
            if (data == null) {
              return _MessageState(
                icon: Icons.public_off_rounded,
                title: 'Community not found',
                subtitle: 'This community may have been deleted.',
                actionLabel: 'Go Back',
                onAction: () => Navigator.of(context).pop(),
              );
            }

            final name = (data['name'] ?? '').toString();
            final communityId = (data['communityId'] ?? '').toString();
            final type = (data['type'] ?? 'normal').toString();
            final collegeName = (data['collegeName'] ?? '').toString();
            final vision = (data['vision'] ?? '').toString();
            final mission = (data['mission'] ?? '').toString();
            final location = (data['location'] ?? '').toString();
            final locationLink = (data['locationLink'] ?? '').toString();
            final logoUrl = (data['logoUrl'] ?? '').toString();
            // College communities can have a wide cover image.
            final coverUrl =
                type == 'college' ? (data['coverUrl'] ?? '').toString() : '';
            final membersCount = (data['membersCount'] is int)
                ? data['membersCount'] as int
                : (data['members'] is List
                      ? (data['members'] as List).length
                      : 0);
            final groupDocId = (data['groupDocId'] ?? '').toString();
            final privileged = CommunityService.isPrivileged(data, uid);

            final page = CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                    child: Row(
                      children: [
                        IconButton(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(
                            Icons.arrow_back_ios_new_rounded,
                            color: Colors.white,
                            size: 18,
                          ),
                        ),
                        Expanded(
                          child: InkWell(
                            borderRadius: BorderRadius.circular(30),
                            onTap: () => _showCommunityDetails(
                              context,
                              name: name,
                              communityId: communityId,
                              type: type,
                              collegeName: collegeName,
                              vision: vision,
                              mission: mission,
                              location: location,
                              locationLink: locationLink,
                              logoUrl: logoUrl,
                              coverUrl: coverUrl,
                              membersCount: membersCount,
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Row(
                                children: [
                                  _CommunityAvatar(logoUrl: logoUrl, size: 38),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      name.isEmpty ? 'Community' : name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 17,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        _MyProfileButton(
                          uid: uid,
                          communityDocId: communityDocId,
                          onTap: () => _openMyProfile(),
                        ),
                      ],
                    ),
                  ),
                ),

                // -------- Notice Board (live items, under the name) --------
                SliverToBoxAdapter(
                  child: CommunityNoticeBoard(
                    communityDocId: communityDocId,
                    uid: uid,
                    announcements: _announcements,
                    events: _events,
                    posts: _posts,
                    polls: _polls,
                    community: data,
                  ),
                ),

                // -------- This week (live: events, polls, posts) --------
                SliverToBoxAdapter(
                  child: CommunityThisWeekCard(
                    communityDocId: communityDocId,
                    uid: uid,
                    announcements: _announcements,
                    events: _events,
                    posts: _posts,
                    polls: _visiblePolls,
                  ),
                ),

                SliverToBoxAdapter(child: const SizedBox(height: 16)),

                // -------- Quick nav --------
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: _QuickNavCard(
                                icon: Icons.forum_rounded,
                                label: 'Community Chat',
                                showDot: _chatDot,
                                onTap: groupDocId.isEmpty
                                    ? null
                                    : () => _openChat(groupDocId),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _QuickNavCard(
                                icon: Icons.campaign_rounded,
                                label: 'Announcements',
                                badgeCount: _announcementsCount,
                                onTap: () => _open(
                                  'announcements',
                                  CommunityAnnouncementsPage(
                                    communityDocId: communityDocId,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: _QuickNavCard(
                                icon: Icons.event_rounded,
                                label: 'Events',
                                badgeCount: _eventsUpcoming,
                                onTap: () => _open(
                                  'events',
                                  CommunityEventsPage(
                                    communityDocId: communityDocId,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _QuickNavCard(
                                icon: Icons.people_alt_rounded,
                                label: 'Members',
                                onTap: () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => CommunityMembersPage(
                                      communityDocId: communityDocId,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: _QuickNavCard(
                                icon: Icons.groups_rounded,
                                label: 'Groups',
                                showDot: _groupsDot,
                                onTap: () => _open(
                                  'groups',
                                  CommunityGroupsPage(
                                    communityDocId: communityDocId,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            // Community clubs: stored separately from the
                            // Hubs clubs, listed only inside this community.
                            Expanded(
                              child: _QuickNavCard(
                                icon: ClubIcons.club,
                                label: 'Clubs',
                                onTap: () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => CommunityClubsPage(
                                      communityDocId: communityDocId,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: _QuickNavCard(
                                icon: Icons.dynamic_feed_rounded,
                                label: 'Feed',
                                badgeCount: _feedCount,
                                onTap: () => _open(
                                  'feed',
                                  CommunityFeedPage(
                                    communityDocId: communityDocId,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _QuickNavCard(
                                icon: Icons.poll_rounded,
                                label: 'Polls',
                                badgeCount: _pollsCount,
                                onTap: () => _open(
                                  'polls',
                                  CommunityPollsPage(
                                    communityDocId: communityDocId,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: _QuickNavCard(
                                icon: Icons.folder_copy_rounded,
                                label: 'Resources',
                                onTap: () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => CommunityResourcesPage(
                                      communityDocId: communityDocId,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _QuickNavCard(
                                icon: Icons.emoji_events_rounded,
                                label: 'Activities',
                                badgeCount: _activitiesCount,
                                onTap: () => _open(
                                  'activities',
                                  CommunityActivitiesPage(
                                    communityDocId: communityDocId,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        // Search: a wide rectangular bar (not a square card).
                        _SearchBarButton(
                          label: 'Search this Community',
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => CommunitySearchPage(
                                communityDocId: communityDocId,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                SliverToBoxAdapter(child: const SizedBox(height: 18)),

                // -------- Latest announcement preview --------
                SliverToBoxAdapter(
                  child: Builder(
                    builder: (context) {
                      final list = _announcements;
                      if (list.isEmpty) return const SizedBox.shrink();
                      final latest = list.first;
                      final title = (latest['title'] ?? '').toString();
                      final isUrgent = latest['isUrgent'] == true;

                      return Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
                        child: Material(
                          color: const Color(0xFF1B120A),
                          borderRadius: BorderRadius.circular(16),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(16),
                            onTap: () => _open(
                              'announcements',
                              CommunityAnnouncementsPage(
                                communityDocId: communityDocId,
                              ),
                            ),
                            child: Container(
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: isUrgent
                                      ? Colors.redAccent.withValues(alpha: .55)
                                      : const Color(
                                          0xFFD2B48C,
                                        ).withValues(alpha: .3),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    isUrgent
                                        ? Icons.priority_high_rounded
                                        : Icons.campaign_rounded,
                                    color: isUrgent
                                        ? Colors.redAccent
                                        : const Color(0xFFFFE9B0),
                                    size: 20,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const Text(
                                          'Latest announcement',
                                          style: TextStyle(
                                            color: Colors.white38,
                                            fontSize: 10.5,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          title.isEmpty ? 'Untitled' : title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.w600,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const Icon(
                                    Icons.chevron_right_rounded,
                                    color: Colors.white38,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),

                if (privileged)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'You manage this community',
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 11.5,
                          ),
                        ),
                      ),
                    ),
                  ),

                SliverToBoxAdapter(child: const SizedBox(height: 40)),
              ],
            );

            return page;
          },
        ),
      ),
    );
  }

  void _showCommunityDetails(
    BuildContext context, {
    required String name,
    required String communityId,
    required String type,
    required String collegeName,
    required String vision,
    required String mission,
    required String location,
    required String locationLink,
    required String logoUrl,
    String coverUrl = '',
    required int membersCount,
  }) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1B120A),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(25)),
      ),
      builder: (sheetContext) => _CoverBackdrop(
        coverUrl: coverUrl,
        child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sheetContext).size.height * 0.8,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 20),
                _CommunityAvatar(logoUrl: logoUrl, size: 92),
                const SizedBox(height: 12),
                Text(
                  name,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  communityId,
                  style: const TextStyle(
                    color: Color(0xFFFFE9B0),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (type == 'college' && collegeName.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.school_rounded,
                        color: Colors.white54,
                        size: 14,
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          collegeName,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 12.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 10),
                Text(
                  '$membersCount member${membersCount == 1 ? '' : 's'}',
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
                SizedBox(
                  width: double.infinity,
                  child: CommunityAboutSection(
                    vision: vision,
                    mission: mission,
                    location: location,
                    locationLink: locationLink,
                  ),
                ),

                // Community management actions are limited to the active
                // Controller or Principal profile.
                StreamBuilder<Map<String, dynamic>?>(
                  stream: CommunityMemberProfileService.watchActiveProfile(
                    widget.communityDocId,
                    _uid,
                  ),
                  builder: (_, profileSnap) {
                    final role = (profileSnap.data?['role'] ?? '').toString();
                    final canDelete =
                        role == CommunityMemberProfileService.roleController ||
                        role == CommunityMemberProfileService.rolePrincipal;
                    if (!canDelete) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: 22),
                      child: Column(
                        children: [
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed: () => _editCommunity(
                                sheetContext,
                                communityId: communityId,
                                name: name,
                                type: type,
                                collegeName: collegeName,
                                vision: vision,
                                mission: mission,
                                location: location,
                                locationLink: locationLink,
                                logoUrl: logoUrl,
                                coverUrl: coverUrl,
                              ),
                              icon: const Icon(Icons.edit_rounded, size: 20),
                              label: const Text('Edit Community'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: const Color(0xFFFFE9B0),
                                side: const BorderSide(
                                  color: Color(0xFFD2B48C),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed: () =>
                                  _confirmDeleteCommunity(sheetContext, name),
                              icon: const Icon(
                                Icons.delete_forever_rounded,
                                size: 20,
                              ),
                              label: const Text('Delete Community'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.redAccent,
                                side: const BorderSide(color: Colors.redAccent),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
      ),
    );
  }

  Future<void> _editCommunity(
    BuildContext sheetContext, {
    required String communityId,
    required String name,
    required String type,
    required String collegeName,
    required String vision,
    required String mission,
    required String location,
    required String locationLink,
    required String logoUrl,
    String coverUrl = '',
  }) async {
    final updated = await showDialog<bool>(
      context: sheetContext,
      builder: (_) => EditCommunityDialog(
        communityDocId: widget.communityDocId,
        communityId: communityId,
        name: name,
        type: type,
        collegeName: collegeName,
        vision: vision,
        mission: mission,
        location: location,
        locationLink: locationLink,
        logoUrl: logoUrl,
        coverUrl: coverUrl,
      ),
    );
    if (updated == true && sheetContext.mounted) {
      Navigator.of(sheetContext).pop();
    }
  }

  Future<void> _confirmDeleteCommunity(
    BuildContext sheetContext,
    String name,
  ) async {
    // Still valid after this page closes (used for the final message).
    final rootContext = Navigator.of(context, rootNavigator: true).context;

    final ok = await showDialog<bool>(
      context: sheetContext,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF1B120A),
        title: const Text(
          'Delete Community?',
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          '"${name.isEmpty ? 'This community' : name}" will be deleted for '
          'everyone. This can\'t be undone.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('CANCEL'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text(
              'DELETE',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;

    try {
      await CommunityService.deleteCommunity(
        communityDocId: widget.communityDocId,
        requesterUid: _uid,
      );
      if (sheetContext.mounted) Navigator.of(sheetContext).pop(); // sheet
      if (mounted) Navigator.of(context).pop(); // Community Home
      if (rootContext.mounted) {
        showTopAlert(rootContext, 'Community deleted');
      }
    } catch (e) {
      if (sheetContext.mounted) {
        showTopAlert(
          sheetContext,
          e.toString().replaceFirst('Exception: ', ''),
          isError: true,
        );
      }
    }
  }

  Future<void> _openMyProfile() async {
    final left = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) =>
            CommunityMemberProfilePage(communityDocId: widget.communityDocId),
      ),
    );
    // Left / deleted the community from the profile page -> close Home too.
    if (left == true && mounted) {
      Navigator.of(context).pop();
    } else if (mounted) {
      // The profile in use may have been switched -> refresh the avatar.
      setState(() {});
    }
  }
}

/// Cover image behind the top of the community profile sheet, fading
/// into the sheet colour.
class _CoverBackdrop extends StatelessWidget {
  final String coverUrl;
  final Widget child;
  const _CoverBackdrop({required this.coverUrl, required this.child});

  @override
  Widget build(BuildContext context) {
    if (coverUrl.isEmpty) return child;
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(25)),
      child: Stack(
        children: [
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: 300,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.network(
                  coverUrl,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: .35),
                        const Color(0xFF1B120A),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class _MyProfileButton extends StatelessWidget {
  final String uid;
  final String communityDocId;
  final VoidCallback onTap;

  const _MyProfileButton({
    required this.uid,
    required this.communityDocId,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (uid.isEmpty) return const SizedBox.shrink();

    return StreamBuilder<Map<String, dynamic>?>(
      stream: CommunityMemberProfileService.watchActiveProfile(
        communityDocId,
        uid,
      ),
      builder: (context, snap) {
        // The profile this account is using here: its name, else its role.
        final profile = snap.data;
        final name = CommunityMemberProfileService.displayName(
          (profile?['name'] ?? '').toString(),
          (profile?['role'] ?? CommunityMemberProfileService.roleMember)
              .toString(),
        );

        return Tooltip(
          message: 'My profile',
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: const Color(0xFFD2B48C),
                    width: 1.5,
                  ),
                ),
                child: CommunityAvatar(url: '', name: name, radius: 16),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CommunityAvatar extends StatelessWidget {
  final String logoUrl;
  final double size;

  const _CommunityAvatar({required this.logoUrl, required this.size});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFF2A1B0E),
        border: Border.all(color: const Color(0xFFD2B48C), width: 2),
      ),
      child: logoUrl.isEmpty
          ? Icon(
              Icons.public_rounded,
              color: const Color(0xFFD2B48C),
              size: size * 0.42,
            )
          : ClipOval(
              child: Image.network(
                logoUrl,
                width: size,
                height: size,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Icon(
                  Icons.public_rounded,
                  color: const Color(0xFFD2B48C),
                  size: size * 0.42,
                ),
              ),
            ),
    );
  }
}

/// Rectangular search bar shown on the Community home (opens the
/// Community search page when tapped).
class _SearchBarButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _SearchBarButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF1B120A),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: double.infinity,
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: const Color(0xFFD2B48C).withValues(alpha: .35),
            ),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.search_rounded,
                color: Color(0xFFFFE9B0),
                size: 22,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white54, fontSize: 14),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuickNavCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  /// > 0 shows a red number badge on the top-right corner.
  final int badgeCount;

  /// Shows a small red dot on the top-right corner (ignored when
  /// [badgeCount] > 0).
  final bool showDot;

  const _QuickNavCard({
    required this.icon,
    required this.label,
    this.onTap,
    this.badgeCount = 0,
    this.showDot = false,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.passthrough,
      children: [
        Material(
          color: const Color(0xFF1B120A),
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(16),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 18),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: const Color(0xFFD2B48C).withValues(alpha: .35),
                ),
              ),
              child: Column(
                children: [
                  Icon(icon, color: const Color(0xFFFFE9B0), size: 24),
                  const SizedBox(height: 8),
                  Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 12.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (badgeCount > 0)
          Positioned(
            top: 8,
            right: 10,
            child: IgnorePointer(
              child: Container(
                constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
                padding: const EdgeInsets.symmetric(horizontal: 5),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.redAccent,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  badgeCount > 99 ? '99+' : '$badgeCount',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    height: 1.1,
                  ),
                ),
              ),
            ),
          )
        else if (showDot)
          Positioned(
            top: 10,
            right: 12,
            child: IgnorePointer(
              child: Container(
                width: 11,
                height: 11,
                decoration: BoxDecoration(
                  color: Colors.redAccent,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: const Color(0xFF1B120A),
                    width: 1.5,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _MessageState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String actionLabel;
  final VoidCallback onAction;

  const _MessageState({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.actionLabel,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: const Color(0xFFD2B48C)),
            const SizedBox(height: 16),
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 12.5),
            ),
            const SizedBox(height: 18),
            OutlinedButton(
              onPressed: onAction,
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Color(0xFFD2B48C)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
              ),
              child: Text(
                actionLabel,
                style: const TextStyle(color: Color(0xFFFFE9B0)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}