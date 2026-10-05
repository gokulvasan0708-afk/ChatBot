import 'package:cloud_firestore/cloud_firestore.dart';

import 'community_feed_service.dart';
import 'community_service.dart';

// ================================================================
// COMMUNITY ACTIVITY SERVICE  (Community spec -- Section 9)
// ----------------------------------------------------------------
// "Activities" are NOT a second content type. An activity is a
// normal 'communityPosts' document with type == 'achievement'
// (created by CreatePostSheet, rendered by CommunityPostCard), so
// reactions, comments, replies, sharing, saving, reporting,
// editing and deleting all keep working through
// CommunityFeedService with zero duplication.
//
// This service only adds what Activities need on top of the feed:
//   - a dedicated, type-filtered stream
//   - kind / highlighted / mine filtering + ordering
//   - "highlight" (spec: authorized Community admins can highlight
//     important achievements)
//
// HIGHLIGHT PERMISSION
//   - Community owner / admin / moderator (CommunityService
//     .isPrivileged) can highlight ANY achievement.
//   - Nobody else can. Clubs are standalone and have no say over
//     Community activity, so there is no Club-leader rule.
//   The same rule is re-checked here at write time; the UI only
//   uses [HighlightScope] to decide whether to SHOW the action.
//
// Needs ONE composite index: communityPosts
//   communityDocId ASC, type ASC, createdAt DESC
// ================================================================

/// Which achievements the signed-in user may highlight.
class HighlightScope {
  /// Owner / admin / moderator of the Community.
  final bool all;

  const HighlightScope({required this.all});

  static const HighlightScope none = HighlightScope(all: false);

  bool canHighlight(Map<String, dynamic> post) {
    if ((post['type'] ?? '') != 'achievement') return false;
    return all;
  }
}

class CommunityActivityService {
  CommunityActivityService._();

  // ==========================================================
  // CONSTANTS
  // ==========================================================

  /// Filter chips on the Activities page (kinds come from
  /// CommunityFeedService.achievementKinds).
  static const List<String> specialFilters = ['all', 'highlighted', 'mine'];

  static const Map<String, String> specialFilterLabels = {
    'all': 'All',
    'highlighted': 'Highlighted',
    'mine': 'My activities',
  };

  // ==========================================================
  // READ
  // ==========================================================

  /// Newest 300 achievements of a community.
  static Stream<CommunityFeedSnapshot> watchActivities(
      String communityDocId) {
    return CommunityFeedService.posts
        .where('communityDocId', isEqualTo: communityDocId)
        .where('type', isEqualTo: 'achievement')
        .snapshots()
        .map((snap) {
      final list = snap.docs.map((d) => {...d.data(), 'id': d.id}).toList();
      int ms(dynamic v) => v is Timestamp ? v.millisecondsSinceEpoch : 0;
      list.sort((a, b) => ms(b['createdAt']).compareTo(ms(a['createdAt'])));
      return CommunityFeedSnapshot(
        posts: list.take(300).toList(),
        fromCache: snap.metadata.isFromCache,
      );
    });
  }

  // ==========================================================
  // FILTER / SORT
  // ==========================================================

  static String kindOf(Map<String, dynamic> post) {
    final a = post['achievement'];
    return a is Map ? (a['kind'] ?? 'other').toString() : 'other';
  }

  /// The date the achievement happened (falls back to post date).
  static DateTime dateOf(Map<String, dynamic> post) {
    final a = post['achievement'];
    if (a is Map) {
      final d = CommunityFeedService.communityDateOf(a['date']);
      if (d != null) return d;
    }
    return CommunityFeedService.communityDateOf(post['createdAt']) ??
        DateTime.now();
  }

  static bool isHighlighted(Map<String, dynamic> post) =>
      post['isHighlighted'] == true;

  /// [filter] is one of [specialFilters] or an achievement kind.
  /// Highlighted items come first, then newest first. Posts the user
  /// has reported are hidden for that user (same rule as the Feed).
  static List<Map<String, dynamic>> applyFilter(
    List<Map<String, dynamic>> all, {
    required String filter,
    required String uid,
  }) {
    var list = all
        .where((p) =>
            (p['type'] ?? '') == 'achievement' &&
            !CommunityFeedService.isReported(p, uid))
        .toList();

    if (filter == 'highlighted') {
      list = list.where(isHighlighted).toList();
    } else if (filter == 'mine') {
      list = list.where((p) => CommunityFeedService.isAuthor(p, uid)).toList();
    } else if (CommunityFeedService.achievementKinds.contains(filter)) {
      list = list.where((p) => kindOf(p) == filter).toList();
    }

    list.sort((a, b) {
      final ha = isHighlighted(a);
      final hb = isHighlighted(b);
      if (ha != hb) return ha ? -1 : 1;
      return dateOf(b).compareTo(dateOf(a));
    });
    return list;
  }

  /// kind -> number of achievements (for chip counts).
  static Map<String, int> countByKind(List<Map<String, dynamic>> all) {
    final counts = <String, int>{};
    for (final p in all) {
      if ((p['type'] ?? '') != 'achievement') continue;
      final k = kindOf(p);
      counts[k] = (counts[k] ?? 0) + 1;
    }
    return counts;
  }

  // ==========================================================
  // HIGHLIGHT
  // ==========================================================

  /// Works out what [uid] may highlight. No query needed: only
  /// privileged Community members can highlight.
  static Future<HighlightScope> loadHighlightScope({
    required String communityDocId,
    required Map<String, dynamic> community,
    required String uid,
  }) async {
    if (uid.isEmpty) return HighlightScope.none;
    return HighlightScope(all: CommunityService.isPrivileged(community, uid));
  }

  static Future<void> setHighlighted({
    required String postId,
    required String requesterUid,
    required Map<String, dynamic> community,
    required bool highlighted,
  }) async {
    final snap = await CommunityFeedService.posts.doc(postId).get();
    final post = snap.data();
    if (post == null) throw Exception('This activity no longer exists.');
    if ((post['type'] ?? '') != 'achievement') {
      throw Exception('Only achievements can be highlighted.');
    }

    if ((post['authorUid'] ?? '').toString() == requesterUid) {
      throw Exception('You can\'t highlight your own achievement.');
    }

    final communityDocId = (post['communityDocId'] ?? '').toString();
    final scope = await loadHighlightScope(
      communityDocId: communityDocId,
      community: community,
      uid: requesterUid,
    );
    if (!scope.canHighlight(post)) {
      throw Exception(
          'Only Community admins can highlight this.');
    }

    await CommunityFeedService.posts.doc(postId).update({
      'isHighlighted': highlighted,
      'highlightedBy': highlighted ? requesterUid : FieldValue.delete(),
      'highlightedAt':
          highlighted ? FieldValue.serverTimestamp() : FieldValue.delete(),
    });
  }

}