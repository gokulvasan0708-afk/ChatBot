import 'package:cloud_firestore/cloud_firestore.dart';

import 'announcement_service.dart';
import 'community_member_profile_service.dart';
import 'community_feed_service.dart';
import 'community_group_service.dart';
import 'community_poll_service.dart';
import 'community_resource_service.dart';

// ================================================================
// COMMUNITY SEARCH SERVICE  (Community spec -- Section 11)
// ----------------------------------------------------------------
// One search across Members, Groups, Posts, Events,
// Resources, Announcements and Polls of a single Community.
//
// HOW IT WORKS
//   1. [loadCorpus] reads each section ONCE (existing collections,
//      existing indexes -- nothing new to deploy) and applies every
//      privacy rule up front. The result, a [CommunityCorpus], only
//      ever contains things the signed-in user is allowed to see.
//   2. [search] ranks that corpus locally for each keystroke, so
//      typing costs no extra Firestore reads.
//
// The corpus / search split is deliberate: the Nexus AI assistant
// (Section 19) will call the same two functions, so the AI can only
// ever see what the user could already find by hand.
//
// PRIVACY RULES (enforced in [loadCorpus], not in the UI)
//   - Caller must be a Community member.
//   - Members: only public name, public image, public skills and
//     Community role. Bio, private name/image, email, account ids
//     are never read into the corpus.
//   - Groups: private groups are hidden from non-members; expired /
//     archived groups are hidden from non-members; the auto-created
//     "Community Chat" is not a group result.
//   - Polls: group-specific polls only for their members.
//     Voters and votes are never part of a search result.
//   - Posts: poll posts are covered by Polls; posts the user has
//     reported are hidden.
//   - Resources: ones the user reported are hidden.
//   - Announcements: scheduled-but-unpublished ones are hidden and
//     year/department-targeted ones are not searched (the audience
//     of those is not known here) -- only community-wide ones.
//
// If one section can't be loaded (for example a Firestore index has
// not been created yet) the rest still work; [CommunityCorpus
// .failedSections] tells the UI what was skipped.
// ================================================================

class CommunitySearchKind {
  CommunitySearchKind._();

  static const String member = 'member';
  static const String group = 'group';
  static const String post = 'post';
  static const String event = 'event';
  static const String resource = 'resource';
  static const String announcement = 'announcement';
  static const String poll = 'poll';

  static const List<String> all = [
    member,
    group,
    post,
    event,
    resource,
    announcement,
    poll,
  ];

  static const Map<String, String> labels = {
    member: 'Members',
    group: 'Groups',
    post: 'Posts',
    event: 'Events',
    resource: 'Resources',
    announcement: 'Announcements',
    poll: 'Polls',
  };

  static const Map<String, String> singular = {
    member: 'Member',
    group: 'Group',
    post: 'Post',
    event: 'Event',
    resource: 'Resource',
    announcement: 'Announcement',
    poll: 'Poll',
  };
}

class CommunitySearchHit {
  final String kind;
  final String id;
  final String title;
  final String subtitle;
  final String imageUrl;
  final int score;
  final DateTime? date;

  /// The full source document (already privacy-filtered).
  final Map<String, dynamic> data;

  const CommunitySearchHit({
    required this.kind,
    required this.id,
    required this.title,
    required this.subtitle,
    required this.imageUrl,
    required this.score,
    required this.data,
    this.date,
  });
}

class CommunityCorpus {
  final String communityDocId;
  final Map<String, dynamic> community;
  final List<Map<String, dynamic>> members;
  final List<Map<String, dynamic>> groups;
  final List<Map<String, dynamic>> posts;
  final List<Map<String, dynamic>> events;
  final List<Map<String, dynamic>> resources;
  final List<Map<String, dynamic>> announcements;
  final List<Map<String, dynamic>> polls;

  /// True when the data came from the offline cache.
  final bool fromCache;

  /// Human names of sections that could not be loaded.
  final List<String> failedSections;

  /// True when the member list was capped for size.
  final bool membersTruncated;

  const CommunityCorpus({
    required this.communityDocId,
    required this.community,
    required this.members,
    required this.groups,
    required this.posts,
    required this.events,
    required this.resources,
    required this.announcements,
    required this.polls,
    required this.fromCache,
    required this.failedSections,
    required this.membersTruncated,
  });

  int get totalItems =>
      members.length +
      groups.length +
      posts.length +
      events.length +
      resources.length +
      announcements.length +
      polls.length;
}

class CommunitySearchService {
  CommunitySearchService._();

  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Members loaded into the corpus (users are read 10 per query).
  static const int maxMembers = 300;

  static const int minQueryLength = 2;

  // ==========================================================
  // LOAD (privacy filtering happens here)
  // ==========================================================

  static Future<CommunityCorpus> loadCorpus({
    required String communityDocId,
    required String uid,
  }) async {
    final communitySnap =
        await _firestore.collection('communities').doc(communityDocId).get();
    final community = communitySnap.data();
    if (community == null) {
      throw Exception('This community no longer exists.');
    }
    final memberUids = _asStringList(community['members']);
    if (!memberUids.contains(uid)) {
      throw Exception('Only Community members can search this Community.');
    }

    final failed = <String>[];
    var fromCache = communitySnap.metadata.isFromCache;

    Future<List<Map<String, dynamic>>> guarded(
      String section,
      Future<List<Map<String, dynamic>>> Function() load,
    ) async {
      try {
        return await load();
      } catch (_) {
        failed.add(section);
        return <Map<String, dynamic>>[];
      }
    }

    Future<List<Map<String, dynamic>>> query(
      Query<Map<String, dynamic>> q,
    ) async {
      final snap = await q.get();
      if (snap.metadata.isFromCache) fromCache = true;
      return snap.docs.map((d) => {...d.data(), 'id': d.id}).toList();
    }

    PollAudience audience = PollAudience.empty;
    try {
      audience = await CommunityPollService.loadAudience(
        communityDocId: communityDocId,
        uid: uid,
      );
    } catch (_) {
      // Without the audience only community-wide polls are searched.
    }

    final results = await Future.wait<List<Map<String, dynamic>>>([
      guarded('Members',
          () => _loadMembers(community, memberUids, communityDocId)),
      guarded(
        'Groups',
        () => query(_firestore
            .collection('groups')
            .where('communityDocId', isEqualTo: communityDocId)),
      ),
      guarded(
        'Posts',
        () => query(CommunityFeedService.posts
            .where('communityDocId', isEqualTo: communityDocId)),
      ),
      guarded(
        'Events',
        () => query(_firestore
            .collection('communityEvents')
            .where('communityDocId', isEqualTo: communityDocId)),
      ),
      guarded(
        'Resources',
        () => query(CommunityResourceService.resources
            .where('communityDocId', isEqualTo: communityDocId)),
      ),
      guarded(
        'Announcements',
        () => AnnouncementService.watchAnnouncements(communityDocId).first,
      ),
      guarded(
        'Polls',
        () => query(CommunityPollService.polls
            .where('communityDocId', isEqualTo: communityDocId)),
      ),
    ]);

    // ---- privacy filters ----
    final groups = results[1].where((g) {
      if (g['isCommunityChat'] == true) return false;
      final isMember = CommunityGroupService.isMember(g, uid);
      if (isMember) return true;
      if ((g['groupType'] ?? 'public') == 'private') return false;
      if (CommunityGroupService.isExpired(g)) return false;
      return true;
    }).toList();

    final posts = results[2].where((p) {
      if ((p['type'] ?? '') == 'poll') return false; // covered by Polls
      if (CommunityFeedService.isReported(p, uid)) return false;
      return true;
    }).toList();

    final resources = results[4]
        .where((r) => !CommunityResourceService.isReportedBy(r, uid))
        .toList();

    final announcements = results[5].where((a) {
      if (a['isScheduled'] == true && a['publishedAt'] == null) {
        // watchAnnouncements already dropped unpublished ones; this
        // is a belt-and-braces check for scheduled items.
        final at = (a['scheduledFor'] as Timestamp?)?.toDate();
        if (at == null || at.isAfter(DateTime.now())) return false;
      }
      return AnnouncementService.isVisibleTo(
        announcement: a,
        memberYear: '',
        memberDepartment: '',
      ) &&
          (a['audienceKind'] ?? 'community') == 'community';
    }).toList();

    final polls = results[6]
        .where((p) => CommunityPollService.isVisibleTo(p, uid, audience))
        .toList();

    return CommunityCorpus(
      communityDocId: communityDocId,
      community: community,
      members: results[0],
      groups: groups,
      posts: posts,
      events: results[3],
      resources: resources,
      announcements: announcements,
      polls: polls,
      fromCache: fromCache,
      failedSections: failed,
      membersTruncated: memberUids.length > maxMembers,
    );
  }

  /// Public fields only -- see the privacy note in the file header.
  /// Members are MEMBER PROFILES (Profile IDs): an account that joined
  /// with two roles is found twice, once per profile.
  static Future<List<Map<String, dynamic>>> _loadMembers(
    Map<String, dynamic> community,
    List<String> memberUids,
    String communityDocId,
  ) async {
    final profiles =
        await CommunityMemberProfileService.profilesRef(communityDocId).get();

    // Skills belong to the PROFILE (memberProfiles/{profileId}.skills).
    // Only a profile that never saved a list of its own, on an account
    // with a single profile, falls back to the old account-level list
    // (users/{uid}.publicSkills) -- never when the account has several.
    final profileCount = <String, int>{};
    for (final d in profiles.docs) {
      final u = (d.data()['uid'] ?? '').toString();
      profileCount[u] = (profileCount[u] ?? 0) + 1;
    }
    final uids = <String>{
      for (final d in profiles.docs)
        if (CommunityMemberProfileService.isActive(d.data()) &&
            d.data()['skills'] is! List &&
            profileCount[(d.data()['uid'] ?? '').toString()] == 1)
          (d.data()['uid'] ?? '').toString(),
    }..remove('');
    final legacySkillsByUid = <String, List<String>>{};
    final list = uids.toList();
    for (var i = 0; i < list.length; i += 10) {
      final chunk =
          list.sublist(i, i + 10 > list.length ? list.length : i + 10);
      try {
        final snap = await _firestore
            .collection('users')
            .where(FieldPath.documentId, whereIn: chunk)
            .get();
        for (final doc in snap.docs) {
          final skills = doc.data()['publicSkills'];
          legacySkillsByUid[doc.id] = skills is List
              ? skills.map((e) => e.toString()).toList()
              : <String>[];
        }
      } catch (_) {}
    }

    final out = <Map<String, dynamic>>[];
    for (final doc in profiles.docs) {
      final d = doc.data();
      if (!CommunityMemberProfileService.isActive(d)) continue;
      final name = (d['name'] ?? '').toString().trim();
      if (name.isEmpty) continue; // nothing public to find them by
      final uid = (d['uid'] ?? '').toString();
      out.add({
        'id': doc.id,
        'profileId': doc.id,
        'uid': uid,
        'publicName': name,
        'publicImage': '', // avatar = first letter of the name
        'publicSkills': d['skills'] is List
            ? (d['skills'] as List).map((e) => e.toString()).toList()
            : (legacySkillsByUid[uid] ?? <String>[]),
        'role': CommunityMemberProfileService.effectiveRole(
            {...d, 'id': doc.id}, community),
      });
      if (out.length >= maxMembers) break;
    }
    return out;
  }

  // ==========================================================
  // RANKING
  // ==========================================================

  static List<String> queryWords(String query) => query
      .toLowerCase()
      .replaceAll('#', ' ')
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();

  /// Points for one word inside one field. 0 = no match.
  /// Start-of-field and start-of-word matches score a little higher.
  static int _wordScore(String word, String text, int weight) {
    if (text.isEmpty) return 0;
    final i = text.indexOf(word);
    if (i < 0) return 0;
    if (i == 0) return weight + 3;
    final before = text[i - 1];
    if (before == ' ' || before == '-' || before == '_' || before == '/') {
      return weight + 1;
    }
    return weight;
  }

  /// Every query word must match at least one field; fields carry
  /// weights (title 10 ... body 2). Returns 0 when something doesn't
  /// match. [fields] must already be lower-cased.
  static int _score(List<String> words, List<MapEntry<String, int>> fields) {
    var total = 0;
    for (final w in words) {
      var best = 0;
      var sum = 0;
      for (final f in fields) {
        final s = _wordScore(w, f.key, f.value);
        if (s > 0) {
          sum += s;
          if (s > best) best = s;
        }
      }
      if (best == 0) return 0;
      // Best field counts fully, other fields add a little.
      total += best + ((sum - best) ~/ 4);
    }
    return total;
  }

  static MapEntry<String, int> _f(dynamic text, int weight) =>
      MapEntry(text.toString().toLowerCase(), weight);

  static DateTime? _date(dynamic v) => v is Timestamp ? v.toDate() : null;

  /// Ranks [corpus] for [query]. [kinds] limits the sections;
  /// null / empty = all. Each section is capped at [perKindLimit].
  static List<CommunitySearchHit> search(
    CommunityCorpus corpus,
    String query, {
    Set<String>? kinds,
    int perKindLimit = 30,
  }) {
    final words = queryWords(query);
    if (words.isEmpty || query.trim().length < minQueryLength) {
      return const [];
    }
    bool want(String k) => kinds == null || kinds.isEmpty || kinds.contains(k);
    final phrase = words.join(' ');
    final hits = <CommunitySearchHit>[];

    // An exact name / title match should float to the top.
    int exactBonus(String title) =>
        title.trim().toLowerCase() == phrase ? 12 : 0;

    // ---------------- Members ----------------
    if (want(CommunitySearchKind.member)) {
      for (final m in corpus.members) {
        final name = (m['publicName'] ?? '').toString();
        final skills = (m['publicSkills'] as List).map((e) => e.toString());
        final score = _score(words, [
          _f(name, 10),
          for (final s in skills) _f(s, 9),
        ]);
        if (score == 0) continue;

        final matched = skills
            .where((s) => words.any((w) => s.toLowerCase().contains(w)))
            .toList();
        final shown = matched.isNotEmpty ? matched : skills.take(3).toList();
        hits.add(CommunitySearchHit(
          kind: CommunitySearchKind.member,
          id: (m['uid'] ?? '').toString(),
          title: name,
          subtitle: [
            (m['role'] ?? 'Member').toString(),
            if (shown.isNotEmpty) shown.join(' · '),
          ].join(' · '),
          imageUrl: (m['publicImage'] ?? '').toString(),
          score: score + exactBonus(name),
          data: m,
        ));
      }
    }

    // ---------------- Groups ----------------
    if (want(CommunitySearchKind.group)) {
      for (final g in corpus.groups) {
        final name = (g['groupName'] ?? g['name'] ?? '').toString();
        final desc = (g['description'] ?? '').toString();
        final score = _score(words, [_f(name, 10), _f(desc, 3)]);
        if (score == 0) continue;
        final count = g['membersCount'] is int ? g['membersCount'] as int : 0;
        final type = (g['groupType'] ?? 'public').toString();
        hits.add(CommunitySearchHit(
          kind: CommunitySearchKind.group,
          id: (g['id'] ?? '').toString(),
          title: name.isEmpty ? 'Group' : name,
          subtitle: '$count member${count == 1 ? '' : 's'} · '
              '${type[0].toUpperCase()}${type.substring(1)} group'
              '${desc.isEmpty ? '' : ' · $desc'}',
          imageUrl: (g['groupProfileImage'] ?? '').toString(),
          score: score + 2 + exactBonus(name),
          date: _date(g['createdAt']),
          data: g,
        ));
      }
    }

    // ---------------- Posts ----------------
    if (want(CommunitySearchKind.post)) {
      for (final p in corpus.posts) {
        final title = (p['title'] ?? '').toString();
        final text = (p['text'] ?? '').toString();
        final type = (p['type'] ?? 'text').toString();
        final tags = p['hashtags'] is List
            ? (p['hashtags'] as List).map((e) => e.toString())
            : const Iterable<String>.empty();
        final lf = p['lostFound'] is Map ? p['lostFound'] as Map : const {};
        final ev = p['event'] is Map ? p['event'] as Map : const {};
        final score = _score(words, [
          _f(title, 10),
          for (final t in tags) _f(t, 8),
          _f(lf['item'] ?? '', 8),
          _f(CommunityFeedService.typeLabels[type] ?? type, 3),
          _f(text, 3),
          _f(lf['location'] ?? '', 2),
          _f(ev['location'] ?? '', 2),
          _f(p['authorName'] ?? '', 2),
        ]);
        if (score == 0) continue;
        final created = _date(p['createdAt']);
        final headline = title.isNotEmpty ? title : text;
        hits.add(CommunitySearchHit(
          kind: CommunitySearchKind.post,
          id: (p['id'] ?? '').toString(),
          title: headline.isEmpty ? 'Post' : headline,
          subtitle: '${CommunityFeedService.typeLabels[type] ?? 'Post'} · '
              'by ${(p['authorName'] ?? 'Member')}',
          imageUrl: '',
          score: score,
          date: created,
          data: p,
        ));
      }
    }

    // ---------------- Events ----------------
    if (want(CommunitySearchKind.event)) {
      for (final e in corpus.events) {
        final title = (e['title'] ?? '').toString();
        final score = _score(words, [
          _f(title, 10),
          _f(e['category'] ?? '', 5),
          _f(e['description'] ?? '', 3),
          _f(e['location'] ?? '', 2),
          _f(e['organizerName'] ?? '', 1),
        ]);
        if (score == 0) continue;
        final start = _date(e['startAt']);
        final cancelled = e['cancelled'] == true;
        final upcoming = start != null && start.isAfter(DateTime.now());
        hits.add(CommunitySearchHit(
          kind: CommunitySearchKind.event,
          id: (e['id'] ?? '').toString(),
          title: title.isEmpty ? 'Event' : title,
          subtitle: [
            if (cancelled) 'Cancelled',
            if (start != null) _shortDateTime(start),
            if ((e['location'] ?? '').toString().isNotEmpty)
              (e['location']).toString(),
          ].join(' · '),
          imageUrl: (e['coverImageUrl'] ?? '').toString(),
          // Upcoming events are slightly more useful than past ones.
          score: score + 1 + (upcoming && !cancelled ? 3 : 0) + exactBonus(title),
          date: start,
          data: e,
        ));
      }
    }

    // ---------------- Resources ----------------
    if (want(CommunitySearchKind.resource)) {
      for (final r in corpus.resources) {
        final score = CommunityResourceService.matchScore(r, phrase);
        if (score == 0) continue;
        final title = (r['title'] ?? '').toString();
        hits.add(CommunitySearchHit(
          kind: CommunitySearchKind.resource,
          id: (r['id'] ?? '').toString(),
          title: title.isEmpty ? (r['fileName'] ?? 'Resource').toString() : title,
          subtitle:
              '${CommunityResourceService.categoryLabel((r['category'] ?? '').toString())}'
              ' · ${(r['uploaderName'] ?? 'Member')}',
          imageUrl: '',
          score: score + 1 + exactBonus(title),
          date: _date(r['createdAt']),
          data: r,
        ));
      }
    }

    // ---------------- Announcements ----------------
    if (want(CommunitySearchKind.announcement)) {
      for (final a in corpus.announcements) {
        final title = (a['title'] ?? '').toString();
        final score = _score(words, [
          _f(title, 10),
          _f(a['type'] ?? '', 3),
          _f(a['body'] ?? '', 3),
        ]);
        if (score == 0) continue;
        hits.add(CommunitySearchHit(
          kind: CommunitySearchKind.announcement,
          id: (a['id'] ?? '').toString(),
          title: title.isEmpty ? 'Announcement' : title,
          subtitle:
              '${a['isUrgent'] == true ? 'Urgent · ' : ''}by ${(a['authorName'] ?? 'Admin')}',
          imageUrl: '',
          score: score + 1 + (a['isUrgent'] == true ? 1 : 0),
          date: _date(a['createdAt']),
          data: a,
        ));
      }
    }

    // ---------------- Polls ----------------
    if (want(CommunitySearchKind.poll)) {
      for (final p in corpus.polls) {
        final question = (p['question'] ?? '').toString();
        final options = p['options'] is List
            ? (p['options'] as List)
                .whereType<Map>()
                .map((o) => (o['text'] ?? '').toString())
            : const Iterable<String>.empty();
        final score = _score(words, [
          _f(question, 10),
          for (final o in options) _f(o, 4),
        ]);
        if (score == 0) continue;
        final scope = (p['scope'] ?? 'community').toString();
        final scopeName = (p['scopeName'] ?? '').toString();
        hits.add(CommunitySearchHit(
          kind: CommunitySearchKind.poll,
          id: (p['id'] ?? '').toString(),
          title: question.isEmpty ? 'Poll' : question,
          subtitle: [
            CommunityPollService.isEnded(p) ? 'Ended' : 'Open',
            if (scope != 'community' && scopeName.isNotEmpty) scopeName,
          ].join(' · '),
          imageUrl: '',
          score: score + exactBonus(question),
          date: _date(p['createdAt']),
          data: p,
        ));
      }
    }

    // ---- order: score desc, newer first; then cap per section ----
    hits.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      final da = a.date ?? DateTime.fromMillisecondsSinceEpoch(0);
      final db = b.date ?? DateTime.fromMillisecondsSinceEpoch(0);
      return db.compareTo(da);
    });

    final perKind = <String, int>{};
    final capped = <CommunitySearchHit>[];
    for (final h in hits) {
      final n = perKind[h.kind] ?? 0;
      if (n >= perKindLimit) continue;
      perKind[h.kind] = n + 1;
      capped.add(h);
    }
    return capped;
  }

  /// kind -> number of hits, for the filter chips.
  static Map<String, int> countByKind(List<CommunitySearchHit> hits) {
    final counts = <String, int>{};
    for (final h in hits) {
      counts[h.kind] = (counts[h.kind] ?? 0) + 1;
    }
    return counts;
  }

  static const List<String> _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  static String _shortDateTime(DateTime d) {
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final m = d.minute.toString().padLeft(2, '0');
    return '${d.day} ${_months[d.month - 1]}, $h:$m ${d.hour >= 12 ? 'PM' : 'AM'}';
  }

  static List<String> _asStringList(dynamic v) =>
      v is List ? v.map((e) => e.toString()).toList() : <String>[];
}