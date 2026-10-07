import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'community_feed_page.dart';
import 'community_post_card.dart';
import 'create_post_sheet.dart';
import '../services/community_activity_service.dart';
import '../services/community_feed_service.dart';
import '../services/community_service.dart';
import '../widgets/community_widgets.dart';

// ================================================================
// COMMUNITY ACTIVITIES  (spec -- Section 9)
// ----------------------------------------------------------------
// Student achievements: hackathons, certifications, competitions,
// sports, cultural activities, internships and projects.
//
// An activity is a normal Community post of type 'achievement', so
// each card already shows the student's profile, title, description,
// certificate / image, date, reactions and comments, and supports
// share / save / report / edit / delete -- via CommunityPostCard.
// This page adds the dedicated view: filter by kind, "Highlighted"
// and "My activities", and highlighting by authorized admins.
// ================================================================
class CommunityActivitiesPage extends StatefulWidget {
  final String communityDocId;
  final String initialFilter;

  const CommunityActivitiesPage({
    super.key,
    required this.communityDocId,
    this.initialFilter = 'all',
  });

  @override
  State<CommunityActivitiesPage> createState() =>
      _CommunityActivitiesPageState();
}

class _CommunityActivitiesPageState extends State<CommunityActivitiesPage> {
  late String _filter;
  int _retryKey = 0;
  Future<HighlightScope>? _scopeFuture;

  String get _uid => FirebaseAuth.instance.currentUser?.uid ?? '';

  @override
  void initState() {
    super.initState();
    final all = [
      ...CommunityActivityService.specialFilters,
      ...CommunityFeedService.achievementKinds,
    ];
    _filter = all.contains(widget.initialFilter) ? widget.initialFilter : 'all';
  }

  Future<void> _addActivity() async {
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CreatePostSheet(
        communityDocId: widget.communityDocId,
        initialType: 'achievement',
      ),
    );
  }

  void _openHashtag(String tag) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CommunityFeedPage(
        communityDocId: widget.communityDocId,
        initialHashtag: tag,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: CommunityService.watchCommunity(widget.communityDocId),
          builder: (context, communitySnap) {
            if (communitySnap.connectionState == ConnectionState.waiting) {
              return const CommunityLoading();
            }
            if (communitySnap.hasError) {
              return CommunityStateMessage(
                icon: Icons.error_outline_rounded,
                title: 'Unable to load Community',
                subtitle: 'Something went wrong. Please try again.',
                actionLabel: 'Retry',
                onAction: () => setState(() => _retryKey++),
              );
            }
            final community = communitySnap.data?.data();
            if (community == null) {
              return const CommunityStateMessage(
                icon: Icons.public_off_rounded,
                title: 'Community not found',
                subtitle: 'This community may have been deleted.',
              );
            }

            final isMember = community['members'] is List &&
                (community['members'] as List).contains(_uid);
            final communityName = (community['name'] ?? '').toString();

            // Loaded once per screen; the write is re-checked server-
            // side of the service anyway, this only decides whether to
            // show the "Highlight" action.
            _scopeFuture ??= CommunityActivityService.loadHighlightScope(
              communityDocId: widget.communityDocId,
              community: community,
              uid: _uid,
            ).catchError((_) => HighlightScope.none);

            return Column(
              children: [
                _buildHeader(isMember),
                Expanded(
                  child: StreamBuilder<CommunityFeedSnapshot>(
                    key: ValueKey('activities-$_retryKey'),
                    stream: CommunityActivityService.watchActivities(
                        widget.communityDocId),
                    builder: (context, snap) {
                      if (snap.hasError) {
                        return CommunityStateMessage(
                          icon: Icons.error_outline_rounded,
                          title: 'Unable to load activities',
                          subtitle:
                              'Check your connection and try again. If this keeps happening, the required Firestore index may not be created yet.',
                          actionLabel: 'Retry',
                          onAction: () => setState(() => _retryKey++),
                        );
                      }
                      if (!snap.hasData) return const CommunityLoading();

                      final all = snap.data!.posts;
                      final list = CommunityActivityService.applyFilter(all,
                          filter: _filter, uid: _uid);
                      final counts = CommunityActivityService.countByKind(all);
                      final highlightedCount = all
                          .where(CommunityActivityService.isHighlighted)
                          .length;

                      return Column(
                        children: [
                          if (snap.data!.fromCache)
                            const CommunityOfflineBanner(),
                          _buildFilterRow(counts, highlightedCount),
                          Expanded(
                            child: list.isEmpty
                                ? _buildEmpty(isMember)
                                : _buildList(list, community, communityName),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildHeader(bool isMember) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 12, 4),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.arrow_back_ios_new_rounded,
                color: Colors.white, size: 18),
          ),
          const Expanded(
            child: Text('Activities',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold)),
          ),
          if (isMember)
            IconButton(
              onPressed: _addActivity,
              tooltip: 'Share an achievement',
              icon: const Icon(Icons.add_circle_outline_rounded,
                  color: CommunityColors.tan, size: 26),
            ),
        ],
      ),
    );
  }

  Widget _buildFilterRow(Map<String, int> counts, int highlightedCount) {
    final entries = <MapEntry<String, String>>[
      for (final f in CommunityActivityService.specialFilters)
        MapEntry(
          f,
          f == 'highlighted' && highlightedCount > 0
              ? '${CommunityActivityService.specialFilterLabels[f]} ($highlightedCount)'
              : CommunityActivityService.specialFilterLabels[f]!,
        ),
      for (final k in CommunityFeedService.achievementKinds)
        MapEntry(
          k,
          (counts[k] ?? 0) > 0
              ? '${CommunityFeedService.achievementKindLabels[k] ?? k} (${counts[k]})'
              : CommunityFeedService.achievementKindLabels[k] ?? k,
        ),
    ];

    return SizedBox(
      height: 46,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        itemCount: entries.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final e = entries[i];
          final selected = _filter == e.key;
          return ChoiceChip(
            label: Text(e.value),
            selected: selected,
            onSelected: (_) => setState(() => _filter = e.key),
            selectedColor: CommunityColors.tan,
            backgroundColor: const Color(0xFF18181F),
            labelStyle: TextStyle(
              color: selected ? Colors.black : Colors.white70,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
            side: BorderSide(color: CommunityColors.tan.withValues(alpha: .3)),
          );
        },
      ),
    );
  }

  Widget _buildEmpty(bool isMember) {
    String title;
    String subtitle;
    switch (_filter) {
      case 'highlighted':
        title = 'No highlighted achievements';
        subtitle =
            'Community admins can highlight important achievements so everyone sees them here first.';
        break;
      case 'mine':
        title = 'You haven\'t shared an activity yet';
        subtitle =
            'Completed a certification, hackathon or project? Let the Community know.';
        break;
      case 'all':
        title = 'No activities yet';
        subtitle = 'Be the first to share an achievement with the Community.';
        break;
      default:
        title =
            'No ${CommunityFeedService.achievementKindLabels[_filter]?.toLowerCase() ?? ''} activities';
        subtitle = 'Nothing has been shared under this category yet.';
    }
    return CommunityStateMessage(
      icon: Icons.emoji_events_outlined,
      title: title,
      subtitle: subtitle,
      actionLabel: isMember && (_filter == 'all' || _filter == 'mine')
          ? 'Share an achievement'
          : null,
      onAction: isMember && (_filter == 'all' || _filter == 'mine')
          ? _addActivity
          : null,
    );
  }

  Widget _buildList(
    List<Map<String, dynamic>> list,
    Map<String, dynamic> community,
    String communityName,
  ) {
    return FutureBuilder<HighlightScope>(
      future: _scopeFuture,
      initialData: HighlightScope.none,
      builder: (context, scopeSnap) {
        final scope = scopeSnap.data ?? HighlightScope.none;
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          itemCount: list.length,
          itemBuilder: (_, i) {
            final post = list[i];
            return CommunityPostCard(
              key: ValueKey(post['id']),
              post: post,
              community: community,
              communityName: communityName,
              onHashtagTap: _openHashtag,
              highlightAllowed: scope.canHighlight(post),
            );
          },
        );
      },
    );
  }
}
