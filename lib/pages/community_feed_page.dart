import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'community_announcements_page.dart';
import 'community_post_card.dart';
import 'community_resources_page.dart';
import 'create_post_sheet.dart';
import '../services/announcement_service.dart';
import '../services/community_feed_service.dart';
import '../services/community_service.dart';
import '../widgets/community_widgets.dart';

// ================================================================
// COMMUNITY FEED  (spec -- Section 6)
// ----------------------------------------------------------------
// Social feed for Community content. Sorting / filtering tabs:
// Latest, Trending, Events, Announcements, Questions, Achievements
// (+ Saved), and tappable #hashtags. Announcements are the existing
// AnnouncementService data -- nothing is duplicated.
// Loading / empty / error / offline / permission states included.
// ================================================================
class CommunityFeedPage extends StatefulWidget {
  final String communityDocId;
  final String initialFilter;
  final String initialHashtag;

  const CommunityFeedPage({
    super.key,
    required this.communityDocId,
    this.initialFilter = 'latest',
    this.initialHashtag = '',
  });

  @override
  State<CommunityFeedPage> createState() => _CommunityFeedPageState();
}

class _CommunityFeedPageState extends State<CommunityFeedPage> {
  late String _filter;
  late String _hashtag;
  int _retryKey = 0;

  String get _uid => FirebaseAuth.instance.currentUser?.uid ?? '';

  @override
  void initState() {
    super.initState();
    _filter = CommunityFeedService.filters.contains(widget.initialFilter)
        ? widget.initialFilter
        : 'latest';
    _hashtag = widget.initialHashtag.replaceAll('#', '').toLowerCase();
  }

  Future<void> _createPost() async {
    // On the Resources tab the "+" uploads a resource instead.
    if (_filter == 'resources') {
      await CommunityResourcesBody.openUploadSheet(
        context,
        communityDocId: widget.communityDocId,
      );
      return;
    }
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CreatePostSheet(communityDocId: widget.communityDocId),
    );
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

            return Column(
              children: [
                _buildHeader(isMember),
                _buildFilterRow(),
                Expanded(
                  child: _filter == 'announcements'
                      ? _buildAnnouncements(community)
                      : _filter == 'resources'
                          ? CommunityResourcesBody(
                              key: const ValueKey('feed-resources'),
                              communityDocId: widget.communityDocId,
                              community: community,
                              isMember: isMember,
                              showUploadButton: false,
                            )
                          : _buildPosts(community, communityName, isMember),
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
      padding: const EdgeInsets.fromLTRB(8, 12, 12, 0),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.arrow_back_ios_new_rounded,
                color: Colors.white, size: 18),
          ),
          const Expanded(
            child: Text('Community Feed',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold)),
          ),
          if (isMember)
            IconButton(
              onPressed: _createPost,
              tooltip: _filter == 'resources' ? 'Upload resource' : 'Create post',
              icon: const Icon(Icons.add_circle_outline_rounded,
                  color: CommunityColors.tan, size: 26),
            ),
        ],
      ),
    );
  }

  Widget _buildFilterRow() {
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        children: [
          for (final f in CommunityFeedService.filters)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(CommunityFeedService.filterLabels[f] ?? f),
                selected: _filter == f,
                onSelected: (_) => setState(() => _filter = f),
                selectedColor: CommunityColors.tan,
                backgroundColor: CommunityColors.card,
                labelStyle: TextStyle(
                  color: _filter == f ? Colors.black : Colors.white70,
                  fontWeight: FontWeight.w600,
                  fontSize: 12.5,
                ),
                side: BorderSide(color: CommunityColors.tan.withValues(alpha: .3)),
              ),
            ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------
  // Announcements tab (existing AnnouncementService data)
  // ------------------------------------------------------------

  Widget _buildAnnouncements(Map<String, dynamic> community) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: AnnouncementService.watchAnnouncements(widget.communityDocId),
      builder: (context, snap) {
        if (snap.hasError) {
          return CommunityStateMessage(
            icon: Icons.error_outline_rounded,
            title: 'Unable to load announcements',
            subtitle: 'Something went wrong. Please try again.',
            actionLabel: 'Retry',
            onAction: () => setState(() => _retryKey++),
          );
        }
        if (snap.connectionState == ConnectionState.waiting) {
          return const CommunityLoading();
        }
        final list = snap.data ?? [];
        if (list.isEmpty) {
          return const CommunityStateMessage(
            icon: Icons.campaign_outlined,
            title: 'No announcements yet',
            subtitle: 'Important updates from Community admins will show up here.',
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          itemCount: list.length,
          itemBuilder: (_, i) {
            final a = list[i];
            final urgent = a['isUrgent'] == true;
            final pinned = a['isPinned'] == true;
            final created = communityToDate(a['createdAt']);
            final body = (a['body'] ?? '').toString();

            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Material(
                color: CommunityColors.card,
                borderRadius: BorderRadius.circular(16),
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => CommunityAnnouncementsPage(
                          communityDocId: widget.communityDocId),
                    ),
                  ),
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: urgent
                            ? CommunityColors.danger.withValues(alpha: .55)
                            : CommunityColors.tan.withValues(alpha: .25),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              urgent
                                  ? Icons.priority_high_rounded
                                  : Icons.campaign_rounded,
                              color: urgent
                                  ? CommunityColors.danger
                                  : CommunityColors.glow,
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text((a['title'] ?? 'Untitled').toString(),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 14.5)),
                            ),
                            if (pinned)
                              const Icon(Icons.push_pin_rounded,
                                  color: CommunityColors.glow, size: 15),
                          ],
                        ),
                        if (body.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(body,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 13, height: 1.35)),
                        ],
                        const SizedBox(height: 8),
                        Text(
                          '${(a['authorName'] ?? 'Admin')} · ${communityTimeAgo(created)}',
                          style: const TextStyle(color: Colors.white38, fontSize: 11.5),
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

  // ------------------------------------------------------------
  // Posts
  // ------------------------------------------------------------

  Widget _buildPosts(
    Map<String, dynamic> community,
    String communityName,
    bool isMember,
  ) {
    return StreamBuilder<CommunityFeedSnapshot>(
      key: ValueKey(_retryKey),
      stream: CommunityFeedService.watchPosts(widget.communityDocId),
      builder: (context, snap) {
        if (snap.hasError) {
          return CommunityStateMessage(
            icon: Icons.error_outline_rounded,
            title: 'Unable to load the feed',
            subtitle: 'Check your connection and try again.',
            actionLabel: 'Retry',
            onAction: () => setState(() => _retryKey++),
          );
        }
        if (snap.connectionState == ConnectionState.waiting) {
          return const CommunityLoading();
        }

        final feed = snap.data ?? const CommunityFeedSnapshot(posts: [], fromCache: false);
        final visible = CommunityFeedService.applyFilter(
          feed.posts,
          filter: _filter,
          uid: _uid,
          hashtag: _hashtag,
        );
        final tags = CommunityFeedService.topHashtags(feed.posts);

        return Column(
          children: [
            if (feed.fromCache && feed.posts.isNotEmpty) const CommunityOfflineBanner(),
            if (_hashtag.isNotEmpty || tags.isNotEmpty)
              SizedBox(
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                  children: [
                    if (_hashtag.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: InputChip(
                          label: Text('#$_hashtag'),
                          onDeleted: () => setState(() => _hashtag = ''),
                          backgroundColor: CommunityColors.tan.withValues(alpha: .25),
                          labelStyle: const TextStyle(
                              color: CommunityColors.glow, fontSize: 12),
                          deleteIconColor: CommunityColors.glow,
                        ),
                      ),
                    for (final t in tags.where((t) => t != _hashtag))
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ActionChip(
                          label: Text('#$t'),
                          onPressed: () => setState(() => _hashtag = t),
                          backgroundColor: CommunityColors.card,
                          labelStyle: const TextStyle(
                              color: CommunityColors.tan, fontSize: 12),
                          side: BorderSide(
                              color: CommunityColors.tan.withValues(alpha: .25)),
                        ),
                      ),
                  ],
                ),
              ),
            Expanded(
              child: visible.isEmpty
                  ? _buildEmpty(isMember, feed.posts.isEmpty)
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                      itemCount: visible.length,
                      itemBuilder: (_, i) => CommunityPostCard(
                        key: ValueKey(visible[i]['id']),
                        post: visible[i],
                        community: community,
                        communityName: communityName,
                        onHashtagTap: (t) => setState(() => _hashtag = t),
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildEmpty(bool isMember, bool feedIsEmpty) {
    String title;
    String subtitle;
    IconData icon = Icons.dynamic_feed_rounded;

    if (feedIsEmpty) {
      title = 'No posts yet';
      subtitle = isMember
          ? 'Be the first to share something with the community.'
          : 'Join this community to see and create posts.';
    } else if (_hashtag.isNotEmpty) {
      title = 'Nothing tagged #$_hashtag';
      subtitle = 'Try another hashtag or clear the filter.';
      icon = Icons.tag_rounded;
    } else {
      switch (_filter) {
        case 'events':
          title = 'No event posts';
          subtitle = 'Event posts will appear here.';
          icon = Icons.event_busy_rounded;
          break;
        case 'questions':
          title = 'No questions yet';
          subtitle = 'Ask something — someone in the community can help.';
          icon = Icons.help_outline_rounded;
          break;
        case 'achievements':
          title = 'No achievements yet';
          subtitle = 'Share a certification, win or milestone.';
          icon = Icons.emoji_events_outlined;
          break;
        case 'saved':
          title = 'No saved posts';
          subtitle = 'Tap the bookmark on a post to keep it here.';
          icon = Icons.bookmark_border_rounded;
          break;
        default:
          title = 'Nothing here yet';
          subtitle = 'Posts will show up here.';
      }
    }

    return CommunityStateMessage(
      icon: icon,
      title: title,
      subtitle: subtitle,
      actionLabel: (feedIsEmpty && isMember) ? 'Create post' : null,
      onAction: (feedIsEmpty && isMember) ? _createPost : null,
    );
  }
}
