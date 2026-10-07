import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'nexus_bottom_nav.dart';
import 'groupstab.dart';
import 'create_community_dialog.dart';
import 'join_community_sheet.dart';
import 'community_home_page.dart';
import 'create_club_dialog.dart';
import 'club_detail_page.dart';
import '../services/community_service.dart';
import '../widgets/community_about_section.dart';
import '../club/club_icons.dart';
import '../services/club_service.dart';

// ================================================================
// HUBS PAGE
// ----------------------------------------------------------------
// Third tab of the bottom nav, sitting between Chats and Me.
// Holds three sub-tabs -- Community, Clubs and Groups -- each its
// own page with its own empty state (Join / Create) until real
// data exists.
// ================================================================

class CommunityPage extends StatefulWidget {
  // Same HomeShell-integration pattern as ChatPage/MePage: when
  // hosted inside HomeShell these just flip the IndexedStack index
  // instead of pushing/popping a route, so this page's own state
  // (which sub-tab is selected, scroll position, etc.) stays alive
  // in the background when the user switches away and back.
  final VoidCallback? onSwitchToChats;
  final VoidCallback? onSwitchToMe;

  const CommunityPage({
    super.key,
    this.onSwitchToChats,
    this.onSwitchToMe,
  });

  @override
  State<CommunityPage> createState() => _CommunityPageState();
}

enum _HubsTab { community, clubs, groups }

class _CommunityPageState extends State<CommunityPage> {
  _HubsTab _tab = _HubsTab.community;

  void _goToChats() {
    if (widget.onSwitchToChats != null) {
      widget.onSwitchToChats!();
      return;
    }
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  void _goToMe() {
    if (widget.onSwitchToMe != null) {
      widget.onSwitchToMe!();
    }
  }

  // ==========================================================
  // COMMUNITY ACTIONS
  // ==========================================================

  // "Join Community": find the community first, then show its
  // profile details (Join at the top right) -- the join requirements
  // only open after Join is tapped there.
  Future<void> _joinCommunity() async {
    final picked = await showJoinCommunitySheet(context, pickOnly: true);
    if (picked == null || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _CommunityPreviewPage(community: picked),
      ),
    );
  }

  Future<void> _createCommunity() => showDialog(
        context: context,
        builder: (_) => const CreateCommunityDialog(),
      );

  // Clubs are standalone: the Clubs tab lists the clubs the user is a
  // member of straight from the `clubs` collection (club_service.dart),
  // with no Community involved. Groups own their separate page
  // (GroupsTab, in groupstab.dart).

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ======================================
                    // "Hubs" TITLE (top left)
                    // ======================================
                    const _HubsTitleText(text: 'Hubs'),

                    const SizedBox(height: 14),

                    // ======================================
                    // Community | Clubs | Groups SWITCHER
                    // ======================================
                    _HubsTabSwitcher(
                      tab: _tab,
                      onChanged: (t) => setState(() => _tab = t),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 8),

              // ==========================================
              // BODY -- swaps between the Community, Clubs
              // and Groups pages, each its own separate page.
              // ==========================================
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  child: switch (_tab) {
                    _HubsTab.community => _CommunityTabPage(
                        key: const ValueKey('community'),
                        onJoin: _joinCommunity,
                        onCreate: _createCommunity,
                      ),
                    _HubsTab.clubs => const _ClubsPage(
                        key: ValueKey('clubs'),
                      ),
                    _HubsTab.groups => const GroupsTab(
                        key: ValueKey('groups'),
                      ),
                  },
                ),
              ),
            ],
          ),
        ),
      // Same shared bottom nav as Chats/Me -- Hubs is index 1,
      // the centre icon between Chats (0) and Me (2).
      bottomNavigationBar: NexusBottomNav(
        selectedIndex: 1,
        onChats: _goToChats,
        onCommunity: () {}, // already on Hubs
        onMe: _goToMe,
      ),
    );
  }
}

// ================================================================
// "Hubs" TITLE
// ================================================================

class _HubsTitleText extends StatelessWidget {
  final String text;
  const _HubsTitleText({required this.text});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 30,
        fontWeight: FontWeight.bold,
        letterSpacing: 0.4,
      ),
    );
  }
}

// ================================================================
// Community | Clubs | Groups SWITCHER
// ----------------------------------------------------------------
// A compact segmented control right under the "Hubs" title. Unlike
// every other toggle/tab-style control in the app (NexusToggleButton
// on the chat page, NexusBottomNav's own selected-item highlight),
// this one does NOT just swap a static color/gradient on the tapped
// segment -- there's a single pill-shaped indicator behind the
// labels that physically SLIDES from one segment to the next
// (AnimatedPositioned + a springy overshoot curve), while the label
// text itself animates into place at the same time. That sliding
// motion is unique to this switcher; no other control in the app
// moves like this.
// ================================================================

class _HubsTabSwitcher extends StatelessWidget {
  final _HubsTab tab;
  final ValueChanged<_HubsTab> onChanged;

  static const List<_HubsTab> _order = [
    _HubsTab.community,
    _HubsTab.clubs,
    _HubsTab.groups,
  ];

  const _HubsTabSwitcher({
    required this.tab,
    required this.onChanged,
  });

  String _labelFor(_HubsTab t) {
    switch (t) {
      case _HubsTab.community:
        return 'Community';
      case _HubsTab.clubs:
        return 'Clubs';
      case _HubsTab.groups:
        return 'Groups';
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedIndex = _order.indexOf(tab);

    return Container(
      // Compact -- smaller padding/height than a typical pill toggle
      // so three segments sit comfortably under the title.
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0xFF18181F),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(0xFFA78BFA).withValues(alpha: .35),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final segmentCount = _order.length;
          final totalWidth = constraints.maxWidth;
          final segmentWidth = totalWidth / segmentCount;

          return SizedBox(
            width: totalWidth,
            height: 34,
            child: Stack(
              children: [
                // -------- Sliding indicator --------
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 380),
                  curve: Curves.easeOutBack,
                  left: selectedIndex * segmentWidth,
                  top: 0,
                  bottom: 0,
                  width: segmentWidth,
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: AppColors.goldGradient,
                      borderRadius: BorderRadius.circular(13),
                    ),
                  ),
                ),

                // -------- Tap targets + labels --------
                Row(
                  children: _order.map((t) {
                    final selected = t == tab;
                    return SizedBox(
                      width: segmentWidth,
                      height: 34,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => onChanged(t),
                        child: Center(
                          child: AnimatedDefaultTextStyle(
                            duration: const Duration(milliseconds: 380),
                            curve: Curves.easeOutBack,
                            style: TextStyle(
                              color: selected
                                  ? const Color(0xFF18181F)
                                  : Colors.white70,
                              fontWeight: FontWeight.w700,
                              fontSize: 12.5,
                            ),
                            child: Text(
                              _labelFor(t),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ================================================================
// COMMUNITY TAB PAGE
// ----------------------------------------------------------------
// Same layout as the Groups tab (groupstab.dart):
//   * Search bar on top with a "+" button next to it. "+" opens the
//     Create Community dialog.
//   * Typing a community name or institution (college) name shows
//     matching communities the user has not joined yet as suggestions;
//     tapping one opens the Join sheet with its Community ID filled in.
//   * The same text also filters the user's own communities below.
//   * No communities yet and nothing typed -> Join / Create empty state.
// ================================================================

class _CommunityTabPage extends StatefulWidget {
  final VoidCallback onJoin;
  final VoidCallback onCreate;

  const _CommunityTabPage({
    super.key,
    required this.onJoin,
    required this.onCreate,
  });

  @override
  State<_CommunityTabPage> createState() => _CommunityTabPageState();
}

class _CommunityTabPageState extends State<_CommunityTabPage> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  String _searchQuery = '';

  // Created once (see GroupsTab: a stream built inside build() would
  // re-subscribe on every keystroke and close the keyboard).
  Stream<QuerySnapshot<Map<String, dynamic>>>? _myStream;

  // Discovery: communities anywhere in the app whose name or
  // institution name contains the typed text.
  Timer? _debounce;
  List<Map<String, dynamic>> _suggestions = [];
  List<Map<String, dynamic>>? _allCommunities; // cached per search session

  static const int _discoveryFetchLimit = 300;
  static const int _maxSuggestions = 8;

  @override
  void initState() {
    super.initState();
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) _myStream = CommunityService.myCommunities(uid);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    setState(() => _searchQuery = value);

    _debounce?.cancel();
    if (value.trim().isEmpty) {
      setState(() => _suggestions = []);
      _allCommunities = null; // fresh data next time the user searches
      return;
    }
    _debounce = Timer(
      const Duration(milliseconds: 300),
      () => _discover(value),
    );
  }

  Future<void> _discover(String rawValue) async {
    final query = rawValue.trim().toLowerCase();
    if (query.isEmpty) return;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      if (_allCommunities == null) {
        final snap = await FirebaseFirestore.instance
            .collection('communities')
            .limit(_discoveryFetchLimit)
            .get();
        _allCommunities = snap.docs
            .map((d) => <String, dynamic>{...d.data(), 'docId': d.id})
            .toList();
      }

      // The user may have kept typing while this was loading.
      if (!mounted || _searchController.text.trim().toLowerCase() != query) {
        return;
      }

      bool matches(Map<String, dynamic> c) {
        final name = (c['name'] ?? '').toString().toLowerCase();
        final college = (c['collegeName'] ?? '').toString().toLowerCase();
        return name.contains(query) || college.contains(query);
      }

      int rank(Map<String, dynamic> c) {
        // Names/institutions that START with the text come first.
        final name = (c['name'] ?? '').toString().toLowerCase();
        final college = (c['collegeName'] ?? '').toString().toLowerCase();
        return (name.startsWith(query) || college.startsWith(query)) ? 0 : 1;
      }

      final found = _allCommunities!.where((c) {
        final members = c['members'] is List
            ? List<String>.from(c['members'])
            : <String>[];
        // Already joined -> it is in the user's own list below.
        return matches(c) && !members.contains(user.uid);
      }).toList()
        ..sort((a, b) => rank(a).compareTo(rank(b)));

      setState(() => _suggestions = found.take(_maxSuggestions).toList());
    } catch (e) {
      debugPrint('Community discovery search error: $e');
    }
  }

  Future<void> _openJoinSuggestion(Map<String, dynamic> community) async {
    _searchFocusNode.unfocus();
    // Opens the community's details page; "Join" (top right) there
    // opens the join requirements (department, year, register number
    // ...) when the community's owner has set them.
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _CommunityPreviewPage(community: community),
      ),
    );

    // The user may have just joined -> refresh so that community moves
    // out of "Communities you can join" and into "Your communities".
    if (!mounted) return;
    _allCommunities = null;
    final text = _searchController.text;
    if (text.trim().isNotEmpty) _discover(text);
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || _myStream == null) {
      return _CommunityEmptyState(
        icon: Icons.public_rounded,
        title: 'No community yet',
        subtitle: 'Join a community to see it here, or start your own.',
        primaryLabel: 'Join Community',
        onPrimary: widget.onJoin,
        secondaryLabel: 'Create Community',
        onSecondary: widget.onCreate,
      );
    }

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _myStream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(color: Color(0xFFA78BFA)),
          );
        }

        if (snapshot.hasError) {
          return _CommunityEmptyState(
            icon: Icons.wifi_off_rounded,
            title: 'Unable to load Community',
            subtitle: 'Check your connection and try again.',
            primaryLabel: 'Join Community',
            onPrimary: widget.onJoin,
            secondaryLabel: 'Create Community',
            onSecondary: widget.onCreate,
          );
        }

        final docs = snapshot.data?.docs ?? [];

        // No community on the home page -> ONLY Join / Create
        // (no search bar).
        if (docs.isEmpty) {
          return _CommunityEmptyState(
            icon: Icons.public_rounded,
            title: 'No community yet',
            subtitle: 'Join a community to see it here, or start your own.',
            primaryLabel: 'Join Community',
            onPrimary: widget.onJoin,
            secondaryLabel: 'Create Community',
            onSecondary: widget.onCreate,
          );
        }

        final query = _searchQuery.trim().toLowerCase();

        // Own communities, filtered by name / institution / ID.
        final mine = query.isEmpty
            ? docs
            : docs.where((doc) {
                final d = doc.data();
                final name = (d['name'] ?? '').toString().toLowerCase();
                final college =
                    (d['collegeName'] ?? '').toString().toLowerCase();
                final cid = (d['communityId'] ?? '').toString().toLowerCase();
                return name.contains(query) ||
                    college.contains(query) ||
                    cid.contains(query);
              }).toList();

        final showSuggestions = query.isNotEmpty && _suggestions.isNotEmpty;
        final nothing =
            query.isNotEmpty && mine.isEmpty && _suggestions.isEmpty;

        return GestureDetector(
          // Tapping empty space drops focus and closes the keyboard, same
          // as the Groups tab. Translucent so it never blocks taps below.
          behavior: HitTestBehavior.translucent,
          onTap: () => FocusScope.of(context).unfocus(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ---------- Search (top) + "+" (next to search) ----------
              // Shown as soon as there is at least ONE community.
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: _CommunitySearchField(
                        controller: _searchController,
                        focusNode: _searchFocusNode,
                        onChanged: _onSearchChanged,
                      ),
                    ),
                    const SizedBox(width: 10),
                    _AddCommunityButton(onTap: widget.onCreate),
                  ],
                ),
              ),
              Expanded(
                child: nothing
                    ? const Center(
                        child: Text(
                          'No communities match your search',
                          style: TextStyle(color: Colors.white54),
                        ),
                      )
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                        children: [
                          if (showSuggestions) ...[
                            const _CommunitySectionLabel(
                                'Communities you can join'),
                            ..._suggestions.map(
                              (c) => _CommunitySuggestionTile(
                                community: c,
                                onTap: () => _openJoinSuggestion(c),
                              ),
                            ),
                            if (mine.isNotEmpty)
                              const _CommunitySectionLabel(
                                  'Your communities'),
                          ],
                          ...mine.map((doc) {
                            final data = doc.data();
                            return _CommunityListCard(
                              name: (data['name'] ?? '').toString(),
                              communityId:
                                  (data['communityId'] ?? '').toString(),
                              logoUrl: (data['logoUrl'] ?? '').toString(),
                              membersCount: (data['membersCount'] is int)
                                  ? data['membersCount'] as int
                                  : 0,
                              onTap: () {
                                _searchFocusNode.unfocus();
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => CommunityHomePage(
                                        communityDocId: doc.id),
                                  ),
                                );
                              },
                            );
                          }),
                        ],
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
// COMMUNITY PREVIEW (a community the member has not joined)
// ----------------------------------------------------------------
// Opened by tapping a search result. Shows the community's details
// (logo, name, ID, college, members, vision / mission / location)
// with a "Join" button in the top-right corner. Join opens the
// join requirements sheet; once the member has joined, this page
// closes.
// ================================================================
class _CommunityPreviewPage extends StatefulWidget {
  final Map<String, dynamic> community;
  const _CommunityPreviewPage({required this.community});

  @override
  State<_CommunityPreviewPage> createState() => _CommunityPreviewPageState();
}

class _CommunityPreviewPageState extends State<_CommunityPreviewPage> {
  bool _joining = false;

  String _s(String key) => (widget.community[key] ?? '').toString();

  Future<void> _join() async {
    if (_joining) return;
    setState(() => _joining = true);
    await showJoinCommunitySheet(context, initialCommunity: widget.community);
    if (!mounted) return;

    // Joined (the member list now has this user)? -> leave this page.
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final docId = _s('docId');
    var joined = false;
    if (uid != null && docId.isNotEmpty) {
      try {
        final snap = await FirebaseFirestore.instance
            .collection('communities')
            .doc(docId)
            .get();
        final members = snap.data()?['members'];
        joined = members is List && members.contains(uid);
      } catch (e) {
        debugPrint('Community preview join check error: $e');
      }
    }
    if (!mounted) return;
    if (joined) {
      Navigator.of(context).pop();
    } else {
      setState(() => _joining = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = _s('name');
    final communityId = _s('communityId');
    final type = _s('type');
    final collegeName = _s('collegeName');
    final logoUrl = _s('logoUrl');
    final coverUrl = type == 'college' ? _s('coverUrl') : '';
    final members = widget.community['members'];
    final membersCount = widget.community['membersCount'] is int
        ? widget.community['membersCount'] as int
        : (members is List ? members.length : 0);
    final hasCover = coverUrl.startsWith('http');

    return Scaffold(
      backgroundColor: const Color(0xFF18181F),
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text(
          'Community',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 17,
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 14),
            child: Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: AppColors.goldGradient,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: _joining ? null : _join,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 8),
                      child: _joining
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Color(0xFF18181F),
                              ),
                            )
                          : const Text(
                              'Join',
                              style: TextStyle(
                                color: Color(0xFF18181F),
                                fontWeight: FontWeight.w800,
                                fontSize: 14,
                              ),
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          if (hasCover)
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
                          Colors.black.withValues(alpha: .45),
                          const Color(0xFF18181F),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 56, 24, 32),
              child: Column(
                children: [
                  Container(
                    width: 104,
                    height: 104,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFF20202A),
                      border: Border.all(
                          color: const Color(0xFFA78BFA), width: 2),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: logoUrl.startsWith('http')
                        ? Image.network(
                            logoUrl,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => const Icon(
                                Icons.public_rounded,
                                color: Color(0xFFA78BFA),
                                size: 40),
                          )
                        : const Icon(Icons.public_rounded,
                            color: Color(0xFFA78BFA), size: 40),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    name.isEmpty ? 'Community' : name,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (communityId.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      communityId,
                      style: const TextStyle(
                        color: Color(0xFFC4B5FD),
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  if (type == 'college' && collegeName.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.school_rounded,
                            color: Colors.white54, size: 15),
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(
                            collegeName,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: Colors.white60, fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 10),
                  Text(
                    '$membersCount member${membersCount == 1 ? '' : 's'}',
                    style:
                        const TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                  SizedBox(
                    width: double.infinity,
                    child: CommunityAboutSection(
                      vision: _s('vision'),
                      mission: _s('mission'),
                      location: _s('location'),
                      locationLink: _s('locationLink'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ================================================================
// SEARCH FIELD / "+" BUTTON / SUGGESTION TILE
// (same look as the Groups tab's _GroupSearchField, _AddGroupButton
// and _GroupSuggestionTile)
// ================================================================

class _CommunitySearchField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;
  final ValueChanged<String> onChanged;

  const _CommunitySearchField({
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
        color: const Color(0xFF18181F),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: const Color(0xFFA78BFA).withValues(alpha: .35),
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
                hintText: 'Search community or institution',
                hintStyle: TextStyle(color: Colors.white38, fontSize: 14),
                border: InputBorder.none,
                isDense: true,
              ),
            ),
          ),
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
                  child:
                      Icon(Icons.close_rounded, color: Colors.white54, size: 18),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _AddCommunityButton extends StatelessWidget {
  final VoidCallback onTap;

  const _AddCommunityButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Create Community',
      child: DecoratedBox(
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
              child: Icon(Icons.add_rounded, color: Color(0xFF18181F), size: 24),
            ),
          ),
        ),
      ),
    );
  }
}

class _CommunitySectionLabel extends StatelessWidget {
  final String text;

  const _CommunitySectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 4, 2, 8),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white54,
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          letterSpacing: .3,
        ),
      ),
    );
  }
}

class _CommunitySuggestionTile extends StatelessWidget {
  final Map<String, dynamic> community;
  final VoidCallback onTap;

  const _CommunitySuggestionTile({
    required this.community,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final name = (community['name'] ?? '').toString();
    final college = (community['collegeName'] ?? '').toString();
    final communityId = (community['communityId'] ?? '').toString();
    final logoUrl = (community['logoUrl'] ?? '').toString();

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: const Color(0xFF18181F),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: const Color(0xFFA78BFA).withValues(alpha: .5),
              ),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 22,
                  backgroundColor: const Color(0xFF20202A),
                  backgroundImage:
                      logoUrl.startsWith('http') ? NetworkImage(logoUrl) : null,
                  child: logoUrl.startsWith('http')
                      ? null
                      : const Icon(Icons.public_rounded,
                          color: Colors.white70, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name.isEmpty ? 'Unnamed Community' : name,
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
                        [
                          if (college.isNotEmpty) college,
                          if (communityId.isNotEmpty) communityId,
                        ].join(' · '),
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
                  'View',
                  style: TextStyle(
                    color: Color(0xFFA78BFA),
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.arrow_forward_ios_rounded,
                    color: Color(0xFFA78BFA), size: 13),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ================================================================
// COMMUNITY LIST CARD (one row per community the user belongs to)
// ================================================================

class _CommunityListCard extends StatelessWidget {
  final String name;
  final String communityId;
  final String logoUrl;
  final int membersCount;
  final VoidCallback onTap;

  const _CommunityListCard({
    required this.name,
    required this.communityId,
    required this.logoUrl,
    required this.membersCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: const Color(0xFF18181F),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: const Color(0xFFA78BFA).withValues(alpha: .3),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF20202A),
                    border: Border.all(
                      color: const Color(0xFFA78BFA).withValues(alpha: .6),
                    ),
                  ),
                  child: logoUrl.isEmpty
                      ? const Icon(Icons.public_rounded,
                          color: Color(0xFFA78BFA), size: 22)
                      : ClipOval(
                          child: Image.network(logoUrl, fit: BoxFit.cover),
                        ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name.isEmpty ? 'Unnamed Community' : name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '$communityId · $membersCount member${membersCount == 1 ? '' : 's'}',
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, color: Colors.white38),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ================================================================
// CLUBS PAGE  (standalone -- the clubs the user is a member of)
// ----------------------------------------------------------------
// A club does not belong to a Community or a Group. This tab simply
// queries the 'clubs' collection for clubs whose `members` contains
// the signed-in user. Tapping "+" opens the create dialog directly.
// ================================================================

class _ClubsPage extends StatefulWidget {
  const _ClubsPage({super.key});

  @override
  State<_ClubsPage> createState() => _ClubsPageState();
}

class _ClubsPageState extends State<_ClubsPage> {
  // Created once. Building the stream inside build() would re-subscribe
  // to Firestore on every rebuild (tab switch animation, keyboard, ...).
  late final String? _uid = FirebaseAuth.instance.currentUser?.uid;
  late final Stream<List<Map<String, dynamic>>>? _clubsStream =
      _uid == null ? null : ClubService.watchMyClubs(_uid);

  @override
  Widget build(BuildContext context) {
    final uid = _uid;
    if (uid == null) {
      return const _ClubsMessage(
        icon: ClubIcons.club,
        title: 'No clubs yet',
        subtitle: 'Sign in to see and create clubs.',
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton(
        backgroundColor: const Color(0xFFA78BFA),
        onPressed: () => _createClub(context),
        child: const Icon(Icons.add_rounded, color: Color(0xFF18181F)),
      ),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _clubsStream,
        builder: (context, clubsSnap) {
          if (clubsSnap.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(color: Color(0xFFA78BFA)),
            );
          }
          if (clubsSnap.hasError) {
            return const _ClubsMessage(
              icon: Icons.error_outline_rounded,
              title: 'Unable to load clubs',
              subtitle: 'Something went wrong. Please try again.',
            );
          }
          final clubs = clubsSnap.data ?? [];
          if (clubs.isEmpty) {
            return _ClubsMessage(
              icon: ClubIcons.club,
              title: 'No clubs yet',
              subtitle: 'Start your first club.',
              actionLabel: 'Create Club',
              onAction: () => _createClub(context),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 90),
            itemCount: clubs.length,
            itemBuilder: (context, index) {
              final club = clubs[index];
              return _ClubListCard(
                club: club,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ClubDetailPage(clubDocId: club['id'] as String),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  /// Clubs are standalone -- no community has to be picked first.
  void _createClub(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => const CreateClubDialog(),
    );
  }
}

class _ClubListCard extends StatelessWidget {
  final Map<String, dynamic> club;
  final VoidCallback onTap;

  const _ClubListCard({required this.club, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final name = (club['name'] ?? '').toString();
    final category = (club['category'] ?? '').toString();
    final logoUrl = (club['logoUrl'] ?? '').toString();
    final membersCount = (club['membersCount'] is int) ? club['membersCount'] as int : 0;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: const Color(0xFF18181F),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFA78BFA).withValues(alpha: .3)),
            ),
            child: Row(
              children: [
                Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF20202A),
                    border: Border.all(color: const Color(0xFFA78BFA).withValues(alpha: .6)),
                  ),
                  child: logoUrl.isEmpty
                      ? const Icon(ClubIcons.club, color: Color(0xFFA78BFA), size: 22)
                      : ClipOval(child: Image.network(logoUrl, fit: BoxFit.cover)),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name.isEmpty ? 'Unnamed Club' : name,
                          style: const TextStyle(
                              color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
                      const SizedBox(height: 3),
                      Text(
                        [
                          if (category.isNotEmpty) category,
                          '$membersCount member${membersCount == 1 ? '' : 's'}',
                        ].join(' · '),
                        style: const TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, color: Colors.white38),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ClubsMessage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _ClubsMessage({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: const Color(0xFFA78BFA)),
            const SizedBox(height: 14),
            Text(title,
                style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54, fontSize: 12.5)),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 18),
              OutlinedButton(
                onPressed: onAction,
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFFA78BFA)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                ),
                child: Text(actionLabel!, style: const TextStyle(color: Color(0xFFC4B5FD))),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// Groups now has its own real page (GroupsTab, in groupstab.dart) with
// its own empty state, search, "+", list, and Create Group flow -- the
// _GroupsPage placeholder that used to live here is gone.

// ================================================================
// SHARED EMPTY STATE
// ----------------------------------------------------------------
// Centered icon + title/subtitle, primary gradient button on top
// ("Join ..."), plain outlined button right below it ("Create ...").
// ================================================================

class _CommunityEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String primaryLabel;
  final VoidCallback onPrimary;
  final String secondaryLabel;
  final VoidCallback onSecondary;

  const _CommunityEmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.primaryLabel,
    required this.onPrimary,
    required this.secondaryLabel,
    required this.onSecondary,
  });

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
                color: const Color(0xFF7C3AED).withValues(alpha: .22),
                border: Border.all(
                  color: const Color(0xFFA78BFA).withValues(alpha: .45),
                ),
              ),
              child: Icon(icon, size: 40, color: const Color(0xFFC4B5FD)),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 13,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 28),

            // -------- Join (primary, gradient) --------
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
                    onTap: onPrimary,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      child: Center(
                        child: Text(
                          primaryLabel,
                          style: const TextStyle(
                            color: Color(0xFF18181F),
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

            // -------- Create (secondary, outlined) --------
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: onSecondary,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  side: const BorderSide(
                    color: Color(0xFFA78BFA),
                    width: 1.2,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: Text(
                  secondaryLabel,
                  style: const TextStyle(
                    color: Color(0xFFC4B5FD),
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