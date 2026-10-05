import 'package:cloud_firestore/cloud_firestore.dart';

import 'community_activity_service.dart';
import 'community_feed_service.dart';
import 'community_member_profile_service.dart';
import 'community_resource_service.dart';

// ================================================================
// COMMUNITY CONTRIBUTION SERVICE  (Community spec -- Section 18)
// ----------------------------------------------------------------
// Builds the "Contributions" summary shown on a member's Community
// profile: resources shared, questions answered, events attended,
// achievements and answers that helped solve a
// question.
//
// NOT A RANKING SYSTEM
//   - Nothing here reads reaction counts, likes, download counts or
//     follower numbers, and nothing compares one member to another.
//   - The result is a plain personal summary (counts + a few recent
//     items). There is no score, level, badge or leaderboard.
//
// NO NEW COLLECTIONS, NO NEW INDEXES
//   Everything is derived from data that already exists:
//     resources     communityResources (uploaderUid)
//     answers       communityPosts/{id}/comments (authorUid) on
//                   'question' and 'help' posts
//     events        communityEvents.checkedInUids (real check-in,
//                   not just an RSVP)
//     achievements  communityPosts (type == 'achievement')
//   The question/help query uses the same composite index the
//   Activities page already needs
//   (communityPosts: communityDocId, type, createdAt DESC).
//
// PER PROFILE ID
//   One account can hold several member profiles in a community
//   (e.g. Student 711225205015 and Student 711225205016). Every
//   contribution is tagged with the Profile ID that made it
//   (uploaderProfileId / authorProfileId / checkedInProfileIds) and a
//   profile only counts ITS OWN items. Items written before the tags
//   existed have no Profile ID: they are counted only when the account
//   has a single profile (then they are unambiguous), never for an
//   account with several profiles.
//
// PRIVACY
//   - Viewer and member must both belong to the Community.
//   - Only things every Community member can already see are
//     counted; items the viewer reported are left out.
//   - Only public data is used (titles the member published).
//     Comment text, RSVP lists and private profile fields are
//     never returned.
//   - If one section can't load (missing index, offline) the rest
//     still work; [CommunityContribution.failedSections] says what
//     was skipped so the UI never shows a wrong "0".
// ================================================================

class ContributionEntry {
  final String id;
  final String title;
  final String subtitle;
  final DateTime? date;

  const ContributionEntry({
    required this.id,
    required this.title,
    required this.subtitle,
    this.date,
  });
}

class CommunityContribution {
  final String memberUid;

  final int resourcesShared;
  final List<ContributionEntry> recentResources;

  /// Question / help-request posts (by other members) the member has
  /// commented on or replied to.
  final int questionsAnswered;

  /// Of [questionsAnswered], the ones whose author marked the
  /// question as solved.
  final int answersOnSolved;

  /// True when only the newest [CommunityContributionService
  /// .answerScanLimit] questions were checked.
  final bool answersScanCapped;

  final int eventsAttended;
  final List<ContributionEntry> recentEvents;

  final int achievementsCount;
  final List<ContributionEntry> recentAchievements;

  final bool fromCache;
  final List<String> failedSections;

  const CommunityContribution({
    required this.memberUid,
    required this.resourcesShared,
    required this.recentResources,
    required this.questionsAnswered,
    required this.answersOnSolved,
    required this.answersScanCapped,
    required this.eventsAttended,
    required this.recentEvents,
    required this.achievementsCount,
    required this.recentAchievements,
    required this.fromCache,
    required this.failedSections,
  });

  bool get isEmpty =>
      resourcesShared == 0 &&
      questionsAnswered == 0 &&
      eventsAttended == 0 &&
      achievementsCount == 0;

  bool get hasFailures => failedSections.isNotEmpty;
}

class CommunityContributionService {
  CommunityContributionService._();

  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// How many of the newest question / help posts are checked for
  /// answers by the member (one small query per post).
  static const int answerScanLimit = 60;

  /// Recent items listed under each heading.
  static const int recentLimit = 3;

  static Future<CommunityContribution> load({
    required String communityDocId,
    required String memberUid,
    required String viewerUid,
    String memberProfileId = '',
  }) async {
    final communitySnap =
        await _firestore.collection('communities').doc(communityDocId).get();
    final community = communitySnap.data();
    if (community == null) {
      throw Exception('This community no longer exists.');
    }
    final members = _asStringList(community['members']);
    if (!members.contains(viewerUid)) {
      throw Exception('Only Community members can view contributions.');
    }
    if (!members.contains(memberUid)) {
      throw Exception('This person is not a member of this Community.');
    }

    var fromCache = communitySnap.metadata.isFromCache;
    final failed = <String>[];

    // ---- Which items belong to THIS profile? ----
    final byProfile =
        memberProfileId.isNotEmpty && !memberProfileId.startsWith('legacy_');
    var claimUntagged = true; // untagged (old) items count for this profile
    if (byProfile) {
      try {
        final mine = await CommunityMemberProfileService.profilesRef(
                communityDocId)
            .where('uid', isEqualTo: memberUid)
            .get();
        claimUntagged = mine.docs.length <= 1;
      } catch (_) {
        claimUntagged = false;
      }
    }

    /// [tagged] = the Profile ID stored on the item ('' when old data).
    bool owns(dynamic tagged) {
      if (!byProfile) return true;
      final t = (tagged ?? '').toString();
      return t.isEmpty ? claimUntagged : t == memberProfileId;
    }

    Future<T> guarded<T>(String section, T fallback, Future<T> Function() run) async {
      try {
        return await run();
      } catch (_) {
        failed.add(section);
        return fallback;
      }
    }

    final results = await Future.wait<dynamic>([
      guarded<_ResourcePart>(
        'Resources',
        _ResourcePart.empty,
        () async {
          final snap = await CommunityResourceService.resources
              .where('communityDocId', isEqualTo: communityDocId)
              .where('uploaderUid', isEqualTo: memberUid)
              .get();
          if (snap.metadata.isFromCache) fromCache = true;
          final list = snap.docs
              .map((d) => {...d.data(), 'id': d.id})
              .where((r) => owns(r['uploaderProfileId']))
              .where((r) => !CommunityResourceService.isReportedBy(r, viewerUid))
              .toList()
            ..sort((a, b) => CommunityResourceService.createdAtOf(b)
                .compareTo(CommunityResourceService.createdAtOf(a)));
          return _ResourcePart(
            count: list.length,
            recent: [
              for (final r in list.take(recentLimit))
                ContributionEntry(
                  id: (r['id'] ?? '').toString(),
                  title: _firstNonEmpty([r['title'], r['fileName']], 'Resource'),
                  subtitle: CommunityResourceService.categoryLabel(
                      (r['category'] ?? '').toString()),
                  date: CommunityResourceService.createdAtOf(r),
                ),
            ],
          );
        },
      ),
      guarded<_AchievementPart>(
        'Achievements',
        _AchievementPart.empty,
        () async {
          final snap = await CommunityFeedService.posts
              .where('communityDocId', isEqualTo: communityDocId)
              .where('authorUid', isEqualTo: memberUid)
              .get();
          if (snap.metadata.isFromCache) fromCache = true;
          final list = snap.docs
              .map((d) => {...d.data(), 'id': d.id})
              .where((p) =>
                  (p['type'] ?? '') == 'achievement' &&
                  owns(p['authorProfileId']) &&
                  !CommunityFeedService.isReported(p, viewerUid))
              .toList()
            ..sort((a, b) => CommunityActivityService.dateOf(b)
                .compareTo(CommunityActivityService.dateOf(a)));
          return _AchievementPart(
            count: list.length,
            recent: [
              for (final p in list.take(recentLimit))
                ContributionEntry(
                  id: (p['id'] ?? '').toString(),
                  title: _firstNonEmpty([p['title'], p['text']], 'Achievement'),
                  subtitle: CommunityFeedService.achievementKindLabels[
                          CommunityActivityService.kindOf(p)] ??
                      'Achievement',
                  date: CommunityActivityService.dateOf(p),
                ),
            ],
          );
        },
      ),
      guarded<_AnswerPart>(
        'Answers',
        _AnswerPart.empty,
        () => _loadAnswers(
          communityDocId: communityDocId,
          memberUid: memberUid,
          viewerUid: viewerUid,
          owns: owns,
          onCache: () => fromCache = true,
        ),
      ),
      guarded<_EventPart>(
        'Events',
        _EventPart.empty,
        () async {
          final snap = await _firestore
              .collection('communityEvents')
              .where('communityDocId', isEqualTo: communityDocId)
              .get();
          if (snap.metadata.isFromCache) fromCache = true;
          final list = <Map<String, dynamic>>[];
          for (final d in snap.docs) {
            final e = {...d.data(), 'id': d.id};
            if (e['cancelled'] == true) continue;
            // Real check-in made by THIS profile. Old check-ins carry no
            // Profile ID (only the account's uid).
            final ids = _asStringList(e['checkedInProfileIds']);
            final attended = byProfile
                ? (ids.contains(memberProfileId) ||
                    (ids.isEmpty &&
                        claimUntagged &&
                        _asStringList(e['checkedInUids']).contains(memberUid)))
                : _asStringList(e['checkedInUids']).contains(memberUid);
            if (!attended) continue;
            list.add(e);
          }
          list.sort((a, b) => (_date(b['startAt']) ?? _epoch)
              .compareTo(_date(a['startAt']) ?? _epoch));
          return _EventPart(
            count: list.length,
            recent: [
              for (final e in list.take(recentLimit))
                ContributionEntry(
                  id: (e['id'] ?? '').toString(),
                  title: _firstNonEmpty([e['title']], 'Event'),
                  subtitle: (e['location'] ?? '').toString(),
                  date: _date(e['startAt']),
                ),
            ],
          );
        },
      ),
    ]);

    final resources = results[0] as _ResourcePart;
    final achievements = results[1] as _AchievementPart;
    final answers = results[2] as _AnswerPart;
    final events = results[3] as _EventPart;

    return CommunityContribution(
      memberUid: memberUid,
      resourcesShared: resources.count,
      recentResources: resources.recent,
      questionsAnswered: answers.answered,
      answersOnSolved: answers.onSolved,
      answersScanCapped: answers.capped,
      eventsAttended: events.count,
      recentEvents: events.recent,
      achievementsCount: achievements.count,
      recentAchievements: achievements.recent,
      fromCache: fromCache,
      failedSections: failed,
    );
  }

  // ==========================================================
  // ANSWERS
  // ==========================================================

  static Future<_AnswerPart> _loadAnswers({
    required String communityDocId,
    required String memberUid,
    required String viewerUid,
    required bool Function(dynamic tagged) owns,
    required void Function() onCache,
  }) async {
    final snap = await CommunityFeedService.posts
        .where('communityDocId', isEqualTo: communityDocId)
        .where('type', whereIn: const ['question', 'help'])
        .orderBy('createdAt', descending: true)
        .limit(answerScanLimit)
        .get();
    if (snap.metadata.isFromCache) onCache();

    final candidates = snap.docs.where((d) {
      final p = d.data();
      // Own question (asked by this same profile) is not an "answer".
      if ((p['authorUid'] ?? '').toString() == memberUid &&
          owns(p['authorProfileId'])) {
        return false;
      }
      if (CommunityFeedService.isReported({...p}, viewerUid)) return false;
      return true;
    }).toList();

    var answered = 0;
    var solved = 0;
    for (var i = 0; i < candidates.length; i += 10) {
      final chunk = candidates.sublist(
          i, i + 10 > candidates.length ? candidates.length : i + 10);
      final checks = await Future.wait(chunk.map((d) => d.reference
          .collection('comments')
          .where('authorUid', isEqualTo: memberUid)
          .limit(20)
          .get()));
      for (var j = 0; j < chunk.length; j++) {
        if (checks[j].metadata.isFromCache) onCache();
        // Only comments written by THIS profile count.
        if (!checks[j].docs.any((c) => owns(c.data()['authorProfileId']))) {
          continue;
        }
        answered++;
        if (chunk[j].data()['isResolved'] == true) solved++;
      }
    }

    return _AnswerPart(
      answered: answered,
      onSolved: solved,
      capped: snap.docs.length >= answerScanLimit,
    );
  }

  // ==========================================================
  // HELPERS
  // ==========================================================

  static final DateTime _epoch = DateTime.fromMillisecondsSinceEpoch(0);

  static DateTime? _date(dynamic v) => v is Timestamp ? v.toDate() : null;

  static String _firstNonEmpty(List<dynamic> values, String fallback) {
    for (final v in values) {
      final s = (v ?? '').toString().trim();
      if (s.isNotEmpty) return s;
    }
    return fallback;
  }

  static List<String> _asStringList(dynamic v) =>
      v is List ? v.map((e) => e.toString()).toList() : <String>[];
}

class _ResourcePart {
  final int count;
  final List<ContributionEntry> recent;
  const _ResourcePart({required this.count, required this.recent});
  static const _ResourcePart empty = _ResourcePart(count: 0, recent: []);
}

class _AchievementPart {
  final int count;
  final List<ContributionEntry> recent;
  const _AchievementPart({required this.count, required this.recent});
  static const _AchievementPart empty = _AchievementPart(count: 0, recent: []);
}

class _EventPart {
  final int count;
  final List<ContributionEntry> recent;
  const _EventPart({required this.count, required this.recent});
  static const _EventPart empty = _EventPart(count: 0, recent: []);
}

class _AnswerPart {
  final int answered;
  final int onSolved;
  final bool capped;
  const _AnswerPart({
    required this.answered,
    required this.onSolved,
    required this.capped,
  });
  static const _AnswerPart empty =
      _AnswerPart(answered: 0, onSolved: 0, capped: false);
}
