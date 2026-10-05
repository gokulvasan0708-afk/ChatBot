import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';

import 'community_member_profile_service.dart';
import 'community_service.dart';

// ================================================================
// COMMUNITY FEED SERVICE  (Community spec -- Section 6)
// ----------------------------------------------------------------
// Same pattern as AnnouncementService / EventService:
// a top-level Firestore collection ('communityPosts') scoped by
// 'communityDocId', direct client-side writes, and
// CommunityService.isPrivileged() as the single source of truth for
// "authorized" (pin, moderate/delete others' posts).
//
// One 'communityPosts' document = one feed post. The same collection
// also powers Activities (type == 'achievement', Section 9) so there
// is exactly ONE place where community posts live.
//
// Post types:
//   text | image | video | poll | question | event | achievement |
//   help | lostfound
//
// Subcollections:
//   communityPosts/{id}/comments/{commentId}  (comment + reply via parentId)
//   communityPosts/{id}/reports/{uid}         (report reason per reporter)
//
// Needs ONE composite index: communityPosts
//   communityDocId ASC, createdAt DESC
// (identical in shape to the index announcements already use).
// ================================================================

class CommunityFeedSnapshot {
  final List<Map<String, dynamic>> posts;
  final bool fromCache;

  const CommunityFeedSnapshot({required this.posts, required this.fromCache});
}

class CommunityFeedService {
  CommunityFeedService._();

  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  static CollectionReference<Map<String, dynamic>> get posts =>
      _firestore.collection('communityPosts');

  // ==========================================================
  // CONSTANTS
  // ==========================================================

  static const List<String> types = [
    'text',
    'image',
    'video',
    'poll',
    'question',
    'event',
    'achievement',
    'help',
    'lostfound',
  ];

  static const Map<String, String> typeLabels = {
    'text': 'Text',
    'image': 'Image',
    'video': 'Video',
    'poll': 'Poll',
    'question': 'Question',
    'event': 'Event',
    'achievement': 'Achievement',
    'help': 'Help / Request',
    'lostfound': 'Lost & Found',
  };

  /// Feed sort / filter tabs (Section 6). 'announcements' and
  /// 'resources' show the existing Announcements / Resources library
  /// data (nothing is copied into 'communityPosts'); 'saved' is a
  /// personal shortcut.
  static const List<String> filters = [
    'latest',
    'trending',
    'events',
    'announcements',
    'questions',
    'achievements',
    'resources',
    'saved',
  ];

  static const Map<String, String> filterLabels = {
    'latest': 'Latest',
    'trending': 'Trending',
    'events': 'Events',
    'announcements': 'Announcements',
    'questions': 'Questions',
    'achievements': 'Achievements',
    'resources': 'Resources',
    'saved': 'Saved',
  };

  static const List<String> suggestedHashtags = [
    'Placement',
    'Hackathon',
    'Exam',
    'Event',
    'LostAndFound',
    'Project',
    'Help',
  ];

  static const List<String> reactionEmojis = ['👍', '❤️', '😂', '😮', '🎉'];

  /// Achievement / activity kinds -- shared with the Activities page.
  static const List<String> achievementKinds = [
    'certification',
    'hackathon',
    'competition',
    'sports',
    'cultural',
    'internship',
    'project',
    'other',
  ];

  static const Map<String, String> achievementKindLabels = {
    'certification': 'Certification',
    'hackathon': 'Hackathon',
    'competition': 'Competition',
    'sports': 'Sports',
    'cultural': 'Cultural',
    'internship': 'Internship',
    'project': 'Project',
    'other': 'Other',
  };

  static const List<String> reportReasons = [
    'Spam',
    'Inappropriate content',
    'Harassment or bullying',
    'Misinformation',
    'Other',
  ];

  static const int maxTextLength = 2000;
  static const int maxImages = 4;

  // ==========================================================
  // HASHTAGS
  // ==========================================================

  static final RegExp hashtagPattern = RegExp(r'#([A-Za-z0-9_]{2,40})');

  /// Lower-cased, de-duplicated hashtags (without '#') found in [texts].
  static List<String> extractHashtags(Iterable<String> texts) {
    final found = <String>{};
    for (final t in texts) {
      for (final m in hashtagPattern.allMatches(t)) {
        found.add(m.group(1)!.toLowerCase());
      }
    }
    return found.toList();
  }

  // ==========================================================
  // CREATE
  // ==========================================================

  /// Builds the Firestore map for a new post. Also used by
  /// CommunityPollService so a poll post is byte-identical in shape to
  /// every other post.
  static Map<String, dynamic> buildPostData({
    required String communityDocId,
    required String authorUid,
    required String authorName,
    required String authorAvatarUrl,
    required String type,
    String authorProfileId = '',
    String title = '',
    String text = '',
    List<String> mediaUrls = const [],
    String mediaType = '',
    String pollId = '',
    Map<String, dynamic>? event,
    Map<String, dynamic>? achievement,
    Map<String, dynamic>? lostFound,
  }) {
    final cleanTitle = title.trim();
    final cleanText = text.trim();

    return {
      'communityDocId': communityDocId,
      'authorUid': authorUid,
      // Profile ID that wrote the post (Contributions are per profile).
      'authorProfileId': authorProfileId,
      'authorName': authorName,
      'authorAvatarUrl': authorAvatarUrl,
      'type': types.contains(type) ? type : 'text',
      'title': cleanTitle,
      'text': cleanText,
      'mediaUrls': mediaUrls,
      'mediaType': mediaType,
      'hashtags': extractHashtags([cleanTitle, cleanText]),
      'pollId': pollId,
      'event': event,
      'achievement': achievement,
      'lostFound': lostFound,
      'isPinned': false,
      'isResolved': false,
      'reactions': <String, dynamic>{}, // uid -> emoji
      'commentCount': 0,
      'sharedCount': 0,
      'savedBy': <String>[],
      'reportedBy': <String>[],
      'createdAt': FieldValue.serverTimestamp(),
      'editedAt': null,
    };
  }

  static Future<void> _requireMember(
      String communityDocId, String uid) async {
    final snap = await _firestore
        .collection('communities')
        .doc(communityDocId)
        .get();
    final data = snap.data();
    if (data == null) throw Exception('This community no longer exists.');
    final members = _asStringList(data['members']);
    if (!members.contains(uid)) {
      throw Exception('Only Community members can post here.');
    }
  }

  static Future<String> createPost({
    required String communityDocId,
    required String authorUid,
    required String authorName,
    required String authorAvatarUrl,
    required String type,
    String title = '',
    String text = '',
    List<String> mediaUrls = const [],
    String mediaType = '',
    Map<String, dynamic>? event,
    Map<String, dynamic>? achievement,
    Map<String, dynamic>? lostFound,
  }) async {
    if (!types.contains(type) || type == 'poll') {
      throw Exception('Unsupported post type.');
    }

    final cleanText = text.trim();
    final cleanTitle = title.trim();

    if (cleanText.length > maxTextLength) {
      throw Exception('Post is too long (max $maxTextLength characters).');
    }

    switch (type) {
      case 'text':
      case 'question':
      case 'help':
        if (cleanText.isEmpty) throw Exception('Please write something first.');
        break;
      case 'image':
        if (mediaUrls.isEmpty) throw Exception('Please add at least one image.');
        break;
      case 'video':
        if (mediaUrls.isEmpty) throw Exception('Please add a video.');
        break;
      case 'event':
        if (cleanTitle.isEmpty) throw Exception('Event title is required.');
        if (event == null || event['dateTime'] == null) {
          throw Exception('Please choose the event date and time.');
        }
        break;
      case 'achievement':
        if (cleanTitle.isEmpty) throw Exception('Achievement title is required.');
        break;
      case 'lostfound':
        final item = (lostFound?['item'] ?? '').toString().trim();
        if (item.isEmpty) throw Exception('Please name the item.');
        break;
    }

    await _requireMember(communityDocId, authorUid);

    final authorProfileId =
        await CommunityMemberProfileService.currentProfileId(communityDocId);

    final ref = posts.doc();
    await ref.set(buildPostData(
      communityDocId: communityDocId,
      authorUid: authorUid,
      authorProfileId: authorProfileId,
      authorName: authorName,
      authorAvatarUrl: authorAvatarUrl,
      type: type,
      title: cleanTitle,
      text: cleanText,
      mediaUrls: mediaUrls,
      mediaType: mediaType,
      event: event,
      achievement: achievement,
      lostFound: lostFound,
    ));
    return ref.id;
  }

  // ==========================================================
  // READ
  // ==========================================================

  /// Newest 200 posts of a community (server-ordered). Trending /
  /// filtering / pinned-first ordering is done client-side by
  /// [applyFilter] so ONE index serves every tab.
  static Stream<CommunityFeedSnapshot> watchPosts(String communityDocId) {
    return posts
        .where('communityDocId', isEqualTo: communityDocId)
        .snapshots()
        .map((snap) {
      final list = snap.docs.map((d) => {...d.data(), 'id': d.id}).toList();
      int ms(dynamic v) => v is Timestamp ? v.millisecondsSinceEpoch : 0;
      list.sort((a, b) => ms(b['createdAt']).compareTo(ms(a['createdAt'])));
      return CommunityFeedSnapshot(
        posts: list.take(200).toList(),
        fromCache: snap.metadata.isFromCache,
      );
    });
  }

  static Stream<Map<String, dynamic>?> watchPost(String postId) {
    return posts.doc(postId).snapshots().map(
          (d) => d.exists ? {...d.data()!, 'id': d.id} : null,
        );
  }

  // ==========================================================
  // FILTER / SORT
  // ==========================================================

  static DateTime _createdAt(Map<String, dynamic> p) =>
      communityDateOf(p['createdAt']) ?? DateTime.now();

  static DateTime? communityDateOf(dynamic v) =>
      v is Timestamp ? v.toDate() : (v is DateTime ? v : null);

  static int reactionCount(Map<String, dynamic> p) =>
      p['reactions'] is Map ? (p['reactions'] as Map).length : 0;

  static int commentCount(Map<String, dynamic> p) =>
      p['commentCount'] is int ? p['commentCount'] as int : 0;

  static int saveCount(Map<String, dynamic> p) =>
      _asStringList(p['savedBy']).length;

  /// Engagement decayed by age -- a fresh post with a few reactions
  /// outranks an old post with many. Comments weigh more than likes
  /// (conversation is more useful than a tap).
  static double trendingScore(Map<String, dynamic> p) {
    final engagement = reactionCount(p) +
        commentCount(p) * 2 +
        saveCount(p) * 2 +
        ((p['sharedCount'] is int) ? p['sharedCount'] as int : 0) * 2;
    final ageHours =
        DateTime.now().difference(_createdAt(p)).inMinutes.clamp(0, 1 << 30) / 60;
    return (engagement + 1) / pow(ageHours + 2, 1.3);
  }

  static bool isSaved(Map<String, dynamic> p, String uid) =>
      _asStringList(p['savedBy']).contains(uid);

  static bool isReported(Map<String, dynamic> p, String uid) =>
      _asStringList(p['reportedBy']).contains(uid);

  /// Applies a tab ([filter]) and optional [hashtag] to [all] and
  /// returns the display order. Posts the user has reported are
  /// hidden for that user.
  static List<Map<String, dynamic>> applyFilter(
    List<Map<String, dynamic>> all, {
    required String filter,
    required String uid,
    String hashtag = '',
  }) {
    var list = all.where((p) => !isReported(p, uid)).toList();

    if (hashtag.isNotEmpty) {
      final tag = hashtag.toLowerCase();
      list = list.where((p) => _asStringList(p['hashtags']).contains(tag)).toList();
    }

    switch (filter) {
      case 'trending':
        list.sort((a, b) => trendingScore(b).compareTo(trendingScore(a)));
        break;
      case 'events':
        list = list.where((p) => p['type'] == 'event').toList();
        final now = DateTime.now();
        DateTime eventAt(Map<String, dynamic> p) =>
            communityDateOf((p['event'] as Map?)?['dateTime']) ?? _createdAt(p);
        final upcoming = list.where((p) => !eventAt(p).isBefore(now)).toList()
          ..sort((a, b) => eventAt(a).compareTo(eventAt(b)));
        final past = list.where((p) => eventAt(p).isBefore(now)).toList()
          ..sort((a, b) => eventAt(b).compareTo(eventAt(a)));
        list = [...upcoming, ...past];
        break;
      case 'questions':
        list = list
            .where((p) => p['type'] == 'question' || p['type'] == 'help')
            .toList();
        list.sort((a, b) {
          final ra = a['isResolved'] == true;
          final rb = b['isResolved'] == true;
          if (ra != rb) return ra ? 1 : -1; // unresolved first
          return _createdAt(b).compareTo(_createdAt(a));
        });
        break;
      case 'achievements':
        list = list.where((p) => p['type'] == 'achievement').toList();
        list.sort((a, b) => _createdAt(b).compareTo(_createdAt(a)));
        break;
      case 'saved':
        list = list.where((p) => isSaved(p, uid)).toList();
        list.sort((a, b) => _createdAt(b).compareTo(_createdAt(a)));
        break;
      case 'latest':
      default:
        list.sort((a, b) {
          final pa = a['isPinned'] == true;
          final pb = b['isPinned'] == true;
          if (pa != pb) return pa ? -1 : 1;
          return _createdAt(b).compareTo(_createdAt(a));
        });
    }
    return list;
  }

  /// Most-used hashtags across [all] (for the quick tag row).
  static List<String> topHashtags(List<Map<String, dynamic>> all,
      {int limit = 10}) {
    final counts = <String, int>{};
    for (final p in all) {
      for (final t in _asStringList(p['hashtags'])) {
        counts[t] = (counts[t] ?? 0) + 1;
      }
    }
    final entries = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries.take(limit).map((e) => e.key).toList();
  }

  // ==========================================================
  // REACT / SAVE / SHARE COUNT
  // ==========================================================

  /// Passing the emoji the user already has removes their reaction.
  static Future<void> toggleReaction({
    required String postId,
    required String uid,
    required String emoji,
    required String currentEmoji,
  }) async {
    if (currentEmoji == emoji) {
      await posts.doc(postId).update({'reactions.$uid': FieldValue.delete()});
    } else {
      await posts.doc(postId).update({'reactions.$uid': emoji});
    }
  }

  static Future<void> setSaved({
    required String postId,
    required String uid,
    required bool saved,
  }) async {
    await posts.doc(postId).update({
      'savedBy':
          saved ? FieldValue.arrayUnion([uid]) : FieldValue.arrayRemove([uid]),
    });
  }

  static Future<void> incrementShareCount(String postId) async {
    await posts.doc(postId).update({'sharedCount': FieldValue.increment(1)});
  }

  // ==========================================================
  // EDIT / DELETE / PIN / RESOLVE / REPORT
  // ==========================================================

  static Future<Map<String, dynamic>> _loadPost(String postId) async {
    final snap = await posts.doc(postId).get();
    final data = snap.data();
    if (data == null) throw Exception('This post no longer exists.');
    return data;
  }

  /// Author-only ("Edit own post").
  static Future<void> editPost({
    required String postId,
    required String requesterUid,
    String? title,
    required String text,
  }) async {
    final post = await _loadPost(postId);
    if ((post['authorUid'] ?? '').toString() != requesterUid) {
      throw Exception('You can only edit your own posts.');
    }

    final cleanText = text.trim();
    final type = (post['type'] ?? 'text').toString();
    final needsText = type == 'text' || type == 'question' || type == 'help';
    if (needsText && cleanText.isEmpty) {
      throw Exception('Post text can\'t be empty.');
    }
    if (cleanText.length > maxTextLength) {
      throw Exception('Post is too long (max $maxTextLength characters).');
    }

    final cleanTitle = (title ?? (post['title'] ?? '')).toString().trim();
    if (title != null && cleanTitle.isEmpty && (type == 'event' || type == 'achievement')) {
      throw Exception('Title can\'t be empty.');
    }

    await posts.doc(postId).update({
      'text': cleanText,
      if (title != null) 'title': cleanTitle,
      'hashtags': extractHashtags([cleanTitle, cleanText]),
      'editedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Author ("Delete own post") or Community owner/admin/moderator.
  static Future<void> deletePost({
    required String postId,
    required String requesterUid,
    required Map<String, dynamic> community,
  }) async {
    final post = await _loadPost(postId);
    final isAuthor = (post['authorUid'] ?? '').toString() == requesterUid;
    if (!isAuthor && !CommunityService.isPrivileged(community, requesterUid)) {
      throw Exception('You don\'t have permission to delete this post.');
    }

    // Comments live in a subcollection, which Firestore does not
    // cascade -- remove them (in chunks) so nothing is orphaned.
    final commentsRef = posts.doc(postId).collection('comments');
    while (true) {
      final chunk = await commentsRef.limit(400).get();
      if (chunk.docs.isEmpty) break;
      final batch = _firestore.batch();
      for (final d in chunk.docs) {
        batch.delete(d.reference);
      }
      await batch.commit();
      if (chunk.docs.length < 400) break;
    }

    final pollId = (post['pollId'] ?? '').toString();
    final batch = _firestore.batch();
    if (pollId.isNotEmpty) {
      batch.delete(_firestore.collection('communityPolls').doc(pollId));
    }
    batch.delete(posts.doc(postId));
    await batch.commit();
  }

  /// Community owner/admin/moderator only.
  static Future<void> setPinned({
    required String postId,
    required String requesterUid,
    required Map<String, dynamic> community,
    required bool pinned,
  }) async {
    if (!CommunityService.isPrivileged(community, requesterUid)) {
      throw Exception('Only Community admins/moderators can pin posts.');
    }
    await posts.doc(postId).update({'isPinned': pinned});
  }

  /// Author-only: mark a question / help request / lost-and-found
  /// post as resolved.
  static Future<void> setResolved({
    required String postId,
    required String requesterUid,
    required bool resolved,
  }) async {
    final post = await _loadPost(postId);
    if ((post['authorUid'] ?? '').toString() != requesterUid) {
      throw Exception('Only the author can change this.');
    }
    await posts.doc(postId).update({'isResolved': resolved});
  }

  static Future<void> reportPost({
    required String postId,
    required String uid,
    required String reason,
  }) async {
    final post = await _loadPost(postId);
    if ((post['authorUid'] ?? '').toString() == uid) {
      throw Exception('You can\'t report your own post.');
    }

    final batch = _firestore.batch();
    batch.update(posts.doc(postId), {
      'reportedBy': FieldValue.arrayUnion([uid]),
    });
    batch.set(posts.doc(postId).collection('reports').doc(uid), {
      'reporterUid': uid,
      'reason': reason,
      'createdAt': FieldValue.serverTimestamp(),
    });
    await batch.commit();
  }

  // ==========================================================
  // COMMENTS + REPLIES
  // ==========================================================

  static CollectionReference<Map<String, dynamic>> _comments(String postId) =>
      posts.doc(postId).collection('comments');

  static Stream<List<Map<String, dynamic>>> watchComments(String postId) {
    return _comments(postId)
        .orderBy('createdAt')
        .snapshots()
        .map((s) => s.docs.map((d) => {...d.data(), 'id': d.id}).toList());
  }

  /// [parentId] empty => top-level comment, otherwise a reply.
  static Future<void> addComment({
    required String postId,
    required String uid,
    required String authorName,
    required String authorAvatarUrl,
    required String text,
    String parentId = '',
  }) async {
    final clean = text.trim();
    if (clean.isEmpty) throw Exception('Write something first.');
    if (clean.length > 1000) {
      throw Exception('Comment is too long (max 1000 characters).');
    }

    // The profile (Profile ID) that is writing the comment.
    var authorProfileId = '';
    try {
      final postSnap = await posts.doc(postId).get();
      final cid = (postSnap.data()?['communityDocId'] ?? '').toString();
      authorProfileId =
          await CommunityMemberProfileService.currentProfileId(cid);
    } catch (_) {}

    final commentRef = _comments(postId).doc();
    final batch = _firestore.batch();
    batch.set(commentRef, {
      'authorUid': uid,
      'authorProfileId': authorProfileId,
      'authorName': authorName,
      'authorAvatarUrl': authorAvatarUrl,
      'text': clean,
      'parentId': parentId,
      'createdAt': FieldValue.serverTimestamp(),
    });
    batch.update(posts.doc(postId), {
      'commentCount': FieldValue.increment(1),
    });
    await batch.commit();
  }

  /// Author of the comment, the post author, or a privileged member.
  /// Deleting a top-level comment also deletes its replies.
  static Future<void> deleteComment({
    required String postId,
    required String commentId,
    required String requesterUid,
    required Map<String, dynamic> community,
  }) async {
    final commentSnap = await _comments(postId).doc(commentId).get();
    final comment = commentSnap.data();
    if (comment == null) return;

    final post = await _loadPost(postId);
    final allowed = (comment['authorUid'] ?? '').toString() == requesterUid ||
        (post['authorUid'] ?? '').toString() == requesterUid ||
        CommunityService.isPrivileged(community, requesterUid);
    if (!allowed) {
      throw Exception('You don\'t have permission to delete this comment.');
    }

    final replies =
        await _comments(postId).where('parentId', isEqualTo: commentId).get();

    final batch = _firestore.batch();
    batch.delete(commentSnap.reference);
    for (final r in replies.docs) {
      batch.delete(r.reference);
    }
    batch.update(posts.doc(postId), {
      'commentCount': FieldValue.increment(-(1 + replies.docs.length)),
    });
    await batch.commit();
  }

  // ==========================================================
  // PERMISSION HELPERS (used by UI to show/hide actions)
  // ==========================================================

  static bool isAuthor(Map<String, dynamic> post, String uid) =>
      (post['authorUid'] ?? '').toString() == uid;

  static bool canDelete(
          Map<String, dynamic> post, Map<String, dynamic> community, String uid) =>
      isAuthor(post, uid) || CommunityService.isPrivileged(community, uid);

  static bool supportsResolved(Map<String, dynamic> post) {
    final t = (post['type'] ?? '').toString();
    return t == 'question' || t == 'help' || t == 'lostfound';
  }

  static List<String> _asStringList(dynamic v) =>
      v is List ? v.map((e) => e.toString()).toList() : <String>[];
}