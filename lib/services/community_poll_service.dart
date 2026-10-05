import 'package:cloud_firestore/cloud_firestore.dart';

import 'community_feed_service.dart';
import 'community_group_service.dart';
import 'community_service.dart';

// ================================================================
// COMMUNITY POLL SERVICE  (Community spec -- Section 7)
// ----------------------------------------------------------------
// Top-level 'communityPolls' collection, same conventions as the
// other Community services.
//
// Poll document:
//   communityDocId, authorUid, authorName, authorAvatarUrl,
//   question, options: [{id:'o0', text}], counts: {o0: n},
//   totalVotes (= number of voters), voters: [uid],
//   allowMultiple, isAnonymous,
//   resultMode: 'afterVote' | 'public' | 'afterEnd',
//   deadline (Timestamp?), closed (bool, manual early close),
//   scope: 'community' | 'group', scopeId, scopeName,
//   postId (feed post, '' if none), createdAt
//
// polls/{id}/votes/{uid}: { optionIds, votedAt, voterName? }
//   - always written, so the voter can see their own choice and a
//     duplicate vote is impossible;
//   - voterName is written ONLY for non-anonymous polls, and the UI
//     only ever lists voters to the poll's author on those polls.
//   - Recommended Firestore rule: a votes doc is readable by its own
//     uid, or by the poll author when the poll is not anonymous.
//
// Duplicate voting is prevented inside a transaction (the vote doc
// must not exist AND the uid must not be in 'voters').
// ================================================================

class CommunityPollService {
  CommunityPollService._();

  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  static CollectionReference<Map<String, dynamic>> get polls =>
      _firestore.collection('communityPolls');

  static const List<String> scopes = ['community', 'group'];

  static const List<String> resultModes = ['afterVote', 'public', 'afterEnd'];

  static const Map<String, String> resultModeLabels = {
    'afterVote': 'Show results after I vote',
    'public': 'Public results (visible to everyone, live)',
    'afterEnd': 'Show results only after the poll ends',
  };

  static const int minOptions = 2;
  static const int maxOptions = 10;

  // ==========================================================
  // ACCESS
  // ==========================================================

  /// Throws unless [uid] may take part in a poll of this scope:
  ///  - community: must be a Community member
  ///  - group:     must be a member of that group
  ///
  /// Clubs are standalone and have their own polls (club_polls_page.dart),
  /// so there is no 'club' scope here.
  static Future<void> assertCanAccess({
    required String communityDocId,
    required String scope,
    required String scopeId,
    required String uid,
  }) async {
    final communitySnap =
        await _firestore.collection('communities').doc(communityDocId).get();
    final community = communitySnap.data();
    if (community == null) throw Exception('This community no longer exists.');

    final members = _asStringList(community['members']);
    if (!members.contains(uid)) {
      throw Exception('Only Community members can do that.');
    }

    if (scope == 'group') {
      final g = await _firestore.collection('groups').doc(scopeId).get();
      if (!CommunityGroupService.isMember(g.data() ?? {}, uid)) {
        throw Exception('Only members of this group can do that.');
      }
    }
  }

  /// Group ids inside this Community that [uid] belongs to.
  /// Used to hide group-specific polls from everyone else and to fill
  /// the scope picker when creating a poll.
  static Future<PollAudience> loadAudience({
    required String communityDocId,
    required String uid,
  }) async {
    final groupsQuery = await _firestore
        .collection('groups')
        .where('communityDocId', isEqualTo: communityDocId)
        .get();

    final groups = <String, String>{};
    for (final d in groupsQuery.docs) {
      final data = d.data();
      if (data['isCommunityChat'] == true) continue;
      if (CommunityGroupService.isMember(data, uid)) {
        groups[d.id] = (data['groupName'] ?? data['name'] ?? 'Group').toString();
      }
    }

    return PollAudience(groups: groups);
  }

  // ==========================================================
  // CREATE
  // ==========================================================

  /// Creates the poll and (for community-wide polls) its feed post in
  /// ONE batch. Group-specific polls are NOT posted to the
  /// community feed -- that would leak the question to people who
  /// cannot vote -- they appear on the Polls page for eligible
  /// members only.
  static Future<String> createPoll({
    required String communityDocId,
    required String authorUid,
    required String authorName,
    required String authorAvatarUrl,
    required String question,
    required List<String> options,
    bool allowMultiple = false,
    bool isAnonymous = false,
    String resultMode = 'afterVote',
    DateTime? deadline,
    String scope = 'community',
    String scopeId = '',
    String scopeName = '',
    String caption = '',
  }) async {
    final q = question.trim();
    if (q.isEmpty) throw Exception('Please enter the poll question.');
    if (q.length > 300) throw Exception('Question is too long (max 300 characters).');

    final cleaned = <String>[];
    for (final o in options) {
      final t = o.trim();
      if (t.isEmpty) continue;
      if (t.length > 120) {
        throw Exception('Each option must be under 120 characters.');
      }
      if (cleaned.any((e) => e.toLowerCase() == t.toLowerCase())) {
        throw Exception('Options must be different from each other.');
      }
      cleaned.add(t);
    }
    if (cleaned.length < minOptions) {
      throw Exception('Add at least $minOptions options.');
    }
    if (cleaned.length > maxOptions) {
      throw Exception('A poll can have at most $maxOptions options.');
    }

    if (deadline != null && !deadline.isAfter(DateTime.now())) {
      throw Exception('The deadline must be in the future.');
    }

    final safeScope = scopes.contains(scope) ? scope : 'community';
    if (safeScope != 'community' && scopeId.isEmpty) {
      throw Exception('Choose which group this poll is for.');
    }

    await assertCanAccess(
      communityDocId: communityDocId,
      scope: safeScope,
      scopeId: scopeId,
      uid: authorUid,
    );

    final pollRef = polls.doc();
    final postToFeed = safeScope == 'community';
    final postRef = postToFeed ? CommunityFeedService.posts.doc() : null;

    final optionMaps = <Map<String, dynamic>>[
      for (var i = 0; i < cleaned.length; i++) {'id': 'o$i', 'text': cleaned[i]},
    ];

    final batch = _firestore.batch();
    batch.set(pollRef, {
      'communityDocId': communityDocId,
      'authorUid': authorUid,
      'authorName': authorName,
      'authorAvatarUrl': authorAvatarUrl,
      'question': q,
      'options': optionMaps,
      'counts': {for (final o in optionMaps) o['id'] as String: 0},
      'totalVotes': 0,
      'voters': <String>[],
      'allowMultiple': allowMultiple,
      'isAnonymous': isAnonymous,
      'resultMode': resultModes.contains(resultMode) ? resultMode : 'afterVote',
      'deadline': deadline == null ? null : Timestamp.fromDate(deadline),
      'closed': false,
      'scope': safeScope,
      'scopeId': safeScope == 'community' ? '' : scopeId,
      'scopeName': safeScope == 'community' ? '' : scopeName,
      'postId': postRef?.id ?? '',
      'createdAt': FieldValue.serverTimestamp(),
    });

    if (postRef != null) {
      batch.set(
        postRef,
        CommunityFeedService.buildPostData(
          communityDocId: communityDocId,
          authorUid: authorUid,
          authorName: authorName,
          authorAvatarUrl: authorAvatarUrl,
          type: 'poll',
          text: caption,
          pollId: pollRef.id,
        ),
      );
    }

    await batch.commit();
    return pollRef.id;
  }

  // ==========================================================
  // READ
  // ==========================================================

  static Stream<Map<String, dynamic>?> watchPoll(String pollId) {
    return polls.doc(pollId).snapshots().map(
          (d) => d.exists ? {...d.data()!, 'id': d.id} : null,
        );
  }

  static Stream<List<Map<String, dynamic>>> watchPolls(String communityDocId) {
    return polls
        .where('communityDocId', isEqualTo: communityDocId)
        .snapshots()
        .map((snap) {
      final list = snap.docs.map((d) => {...d.data(), 'id': d.id}).toList();
      list.sort((a, b) {
        final da = _date(a['createdAt']) ?? DateTime.now();
        final db = _date(b['createdAt']) ?? DateTime.now();
        return db.compareTo(da);
      });
      return list;
    });
  }

  /// The signed-in user's own choice(s), or null if they haven't voted.
  static Stream<List<String>?> watchMyVote(String pollId, String uid) {
    return polls.doc(pollId).collection('votes').doc(uid).snapshots().map((d) {
      final data = d.data();
      if (data == null) return null;
      return _asStringList(data['optionIds']);
    });
  }

  /// Voter list -- only for the poll's author, only when the poll is
  /// NOT anonymous.
  static Future<List<Map<String, dynamic>>> loadVoters({
    required String pollId,
    required String requesterUid,
  }) async {
    final pollSnap = await polls.doc(pollId).get();
    final poll = pollSnap.data();
    if (poll == null) throw Exception('This poll no longer exists.');
    if (poll['isAnonymous'] == true) {
      throw Exception('This poll is anonymous.');
    }
    if ((poll['authorUid'] ?? '').toString() != requesterUid) {
      throw Exception('Only the poll creator can see who voted.');
    }
    final votes = await polls.doc(pollId).collection('votes').get();
    return votes.docs.map((d) => {...d.data(), 'uid': d.id}).toList();
  }

  // ==========================================================
  // VOTE (duplicate-proof, deadline-checked)
  // ==========================================================

  static Future<void> vote({
    required String pollId,
    required String uid,
    required String voterName,
    required List<String> optionIds,
  }) async {
    final pollRef = polls.doc(pollId);
    final voteRef = pollRef.collection('votes').doc(uid);

    final pre = await pollRef.get();
    final preData = pre.data();
    if (preData == null) throw Exception('This poll no longer exists.');

    await assertCanAccess(
      communityDocId: (preData['communityDocId'] ?? '').toString(),
      scope: (preData['scope'] ?? 'community').toString(),
      scopeId: (preData['scopeId'] ?? '').toString(),
      uid: uid,
    );

    await _firestore.runTransaction((tx) async {
      final snap = await tx.get(pollRef);
      final poll = snap.data();
      if (poll == null) throw Exception('This poll no longer exists.');

      if (isEnded(poll)) throw Exception('This poll has ended.');

      final voters = _asStringList(poll['voters']);
      final myVoteSnap = await tx.get(voteRef);
      if (voters.contains(uid) || myVoteSnap.exists) {
        throw Exception('You have already voted in this poll.');
      }

      final validIds = _optionIds(poll);
      final chosen = optionIds.toSet().toList();
      if (chosen.isEmpty) throw Exception('Select an option to vote.');
      if (chosen.any((id) => !validIds.contains(id))) {
        throw Exception('That option is no longer available.');
      }
      if (poll['allowMultiple'] != true && chosen.length > 1) {
        throw Exception('This poll allows only one choice.');
      }

      final updates = <String, dynamic>{
        'voters': FieldValue.arrayUnion([uid]),
        'totalVotes': FieldValue.increment(1),
      };
      for (final id in chosen) {
        updates['counts.$id'] = FieldValue.increment(1);
      }
      tx.update(pollRef, updates);

      tx.set(voteRef, {
        'optionIds': chosen,
        'votedAt': FieldValue.serverTimestamp(),
        if (poll['isAnonymous'] != true) 'voterName': voterName,
      });
    });
  }

  // ==========================================================
  // MANAGE
  // ==========================================================

  /// Author or Community owner/admin/moderator.
  static Future<void> closePoll({
    required String pollId,
    required String requesterUid,
    required Map<String, dynamic> community,
  }) async {
    await _requireAuthorOrPrivileged(pollId, requesterUid, community);
    await polls.doc(pollId).update({'closed': true});
  }

  static Future<void> deletePoll({
    required String pollId,
    required String requesterUid,
    required Map<String, dynamic> community,
  }) async {
    final poll = await _requireAuthorOrPrivileged(pollId, requesterUid, community);
    final postId = (poll['postId'] ?? '').toString();

    // Deleting the feed post also removes the poll (and its comments).
    if (postId.isNotEmpty) {
      final postSnap = await CommunityFeedService.posts.doc(postId).get();
      if (postSnap.exists) {
        await CommunityFeedService.deletePost(
          postId: postId,
          requesterUid: requesterUid,
          community: community,
        );
        return;
      }
    }
    await polls.doc(pollId).delete();
  }

  static Future<Map<String, dynamic>> _requireAuthorOrPrivileged(
    String pollId,
    String requesterUid,
    Map<String, dynamic> community,
  ) async {
    final snap = await polls.doc(pollId).get();
    final poll = snap.data();
    if (poll == null) throw Exception('This poll no longer exists.');
    final isAuthor = (poll['authorUid'] ?? '').toString() == requesterUid;
    if (!isAuthor && !CommunityService.isPrivileged(community, requesterUid)) {
      throw Exception('You don\'t have permission to do that.');
    }
    return poll;
  }

  // ==========================================================
  // STATE HELPERS
  // ==========================================================

  static DateTime? deadlineOf(Map<String, dynamic> poll) =>
      _date(poll['deadline']);

  static bool isEnded(Map<String, dynamic> poll) {
    if (poll['closed'] == true) return true;
    final d = deadlineOf(poll);
    return d != null && !d.isAfter(DateTime.now());
  }

  static bool hasVoted(Map<String, dynamic> poll, String uid) =>
      _asStringList(poll['voters']).contains(uid);

  static bool isAuthor(Map<String, dynamic> poll, String uid) =>
      (poll['authorUid'] ?? '').toString() == uid;

  /// Whether the results may be shown to [uid] right now.
  static bool canSeeResults(Map<String, dynamic> poll, String uid) {
    if (isEnded(poll)) return true;
    if (isAuthor(poll, uid)) return true;
    switch ((poll['resultMode'] ?? 'afterVote').toString()) {
      case 'public':
        return true;
      case 'afterEnd':
        return false;
      case 'afterVote':
      default:
        return hasVoted(poll, uid);
    }
  }

  /// Whether a poll should be listed for this user (hides group-specific
  /// polls from people outside that group).
  static bool isVisibleTo(
    Map<String, dynamic> poll,
    String uid,
    PollAudience audience,
  ) {
    switch ((poll['scope'] ?? 'community').toString()) {
      case 'group':
        return audience.groups.containsKey((poll['scopeId'] ?? '').toString());
      case 'club':
        // Legacy: club polls used to be stored here. Clubs now keep their
        // own polls, so old ones must never leak into the community list.
        return false;
      default:
        return true;
    }
  }

  static List<String> _optionIds(Map<String, dynamic> poll) {
    final raw = poll['options'];
    if (raw is! List) return <String>[];
    return raw
        .whereType<Map>()
        .map((o) => (o['id'] ?? '').toString())
        .where((id) => id.isNotEmpty)
        .toList();
  }

  static DateTime? _date(dynamic v) => v is Timestamp ? v.toDate() : null;

  static List<String> _asStringList(dynamic v) =>
      v is List ? v.map((e) => e.toString()).toList() : <String>[];
}

class PollAudience {
  /// groupDocId -> group name
  final Map<String, String> groups;

  const PollAudience({required this.groups});

  static const PollAudience empty = PollAudience(groups: {});
}
