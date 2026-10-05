import 'package:cloud_firestore/cloud_firestore.dart';

import 'community_feed_service.dart';
import 'community_search_service.dart';

// ================================================================
// COMMUNITY AI CONTEXT SERVICE  (Community spec -- Section 19)
// ----------------------------------------------------------------
// The single, permission-aware doorway between Community data and
// the future Nexus AI assistant. No model is called here; this file
// only decides WHAT the assistant is allowed to know and hands it
// over in a compact, predictable shape.
//
// WHY THIS IS SAFE BY CONSTRUCTION
//   Everything is built on top of
//   CommunitySearchService.loadCorpus(), the same privacy gate the
//   Community Search screen uses. That gate:
//     - requires the signed-in user to be a Community member,
//     - hides private / expired groups from non-members,
//     - hides group-specific polls from outsiders,
//     - hides reported posts / resources and unpublished or
//       audience-targeted announcements,
//     - only ever loads public member fields.
//   So the assistant can never see more than the user could find
//   by hand. On top of that this file adds its own rules:
//     - user ids, emails, voters, votes and poll results are NEVER
//       put into the context;
//     - discussions are only readable for posts that are in the
//       (already filtered) corpus, and comment authors are shown by
//       their public display name only;
//     - every text block is length-capped.
//
// WHAT THE ASSISTANT CAN DO WITH IT (each is a plain method, so a
// backend / on-device model can call it as a "tool")
//   weekDigest()          "What's happening this week?"
//   upcomingEvents()      "Find upcoming events"
//   find()                "Find resources / groups / people"
//   aboutCommunity()      "Explain the Community rules"
//   loadDiscussion()      "Summarize this discussion"
//   contextFor(question)  picks the right pieces for a question
//                         and returns ready-to-send text
//
// PLUGGING IN THE MODEL LATER
//   Implement [CommunityAiProvider] (call your LLM backend with the
//   text from [CommunityAiContextBundle.text]) and pass it to
//   [CommunityAiAssistant.ask]. Until a provider exists,
//   [CommunityAiAssistant.ask] answers the questions it can
//   answer from data alone (this week, upcoming events) so the
//   architecture is exercised for real -- the "This week" card on
//   the Community home uses exactly the same digest.
//
// DATA NOT AVAILABLE TODAY (so it is not invented)
//   - Community "rules": the Community model has a description and
//     pinned announcements but no separate rules field, so
//     [aboutCommunity] returns those.
// ================================================================

/// Something the assistant can point the person to. Carries a
/// [CommunitySearchHit] so the UI can open it with the existing
/// CommunitySearchOpener (same permissions as everywhere else).
class CommunityDigestItem {
  final CommunitySearchHit hit;
  final DateTime? date;
  final String detail;

  const CommunityDigestItem({
    required this.hit,
    required this.detail,
    this.date,
  });

  String get title => hit.title;
}

class CommunityWeekDigest {
  final DateTime from;
  final DateTime to;
  final List<CommunityDigestItem> events;
  final List<CommunityDigestItem> announcements;
  final List<CommunityDigestItem> closingPolls;
  final bool fromCache;
  final List<String> failedSections;

  const CommunityWeekDigest({
    required this.from,
    required this.to,
    required this.events,
    required this.announcements,
    required this.closingPolls,
    required this.fromCache,
    required this.failedSections,
  });

  int get total =>
      events.length +
      announcements.length +
      closingPolls.length;

  bool get isEmpty => total == 0;

  /// "3 upcoming events · 2 important announcements · ..."
  String get summaryLine {
    String n(int c, String one, String many) => '$c ${c == 1 ? one : many}';
    final parts = <String>[
      if (events.isNotEmpty) n(events.length, 'upcoming event', 'upcoming events'),
      if (announcements.isNotEmpty)
        n(announcements.length, 'important announcement',
            'important announcements'),
      if (closingPolls.isNotEmpty)
        n(closingPolls.length, 'poll closing soon', 'polls closing soon'),
    ];
    return parts.isEmpty ? 'Nothing scheduled this week' : parts.join(' · ');
  }

  /// Plain text for an assistant / for sharing.
  String toPlainText() {
    final b = StringBuffer('This week in the Community: $summaryLine\n');
    void section(String title, List<CommunityDigestItem> items) {
      if (items.isEmpty) return;
      b.writeln('\n$title:');
      for (final i in items) {
        b.writeln('- ${i.title}${i.detail.isEmpty ? '' : ' (${i.detail})'}');
      }
    }

    section('Events', events);
    section('Important announcements', announcements);
    section('Polls closing soon', closingPolls);
    return b.toString().trim();
  }
}

class CommunityDiscussionComment {
  final String authorName;
  final String text;
  final bool isReply;

  const CommunityDiscussionComment({
    required this.authorName,
    required this.text,
    required this.isReply,
  });
}

class CommunityDiscussion {
  final String postId;
  final String title;
  final String text;
  final String authorName;
  final List<CommunityDiscussionComment> comments;

  const CommunityDiscussion({
    required this.postId,
    required this.title,
    required this.text,
    required this.authorName,
    required this.comments,
  });

  String toPlainText() {
    final b = StringBuffer();
    if (title.isNotEmpty) b.writeln('Post: $title');
    b.writeln('$authorName: $text');
    for (final c in comments) {
      b.writeln('${c.isReply ? '  ↳ ' : ''}${c.authorName}: ${c.text}');
    }
    return b.toString().trim();
  }
}

/// What the assistant is told for one question.
class CommunityAiContextBundle {
  /// 'week' | 'events' | 'about' | 'search' | 'general'
  final String intent;
  final String text;

  const CommunityAiContextBundle({required this.intent, required this.text});
}

/// Implement this with your LLM backend. [context] is already
/// permission-filtered and length-capped.
abstract class CommunityAiProvider {
  Future<String> answer({
    required String question,
    required CommunityAiContextBundle context,
  });
}

class CommunityAiContext {
  final CommunityCorpus corpus;
  final String uid;
  final DateTime builtAt;

  CommunityAiContext._(this.corpus, this.uid, this.builtAt);

  // ==========================================================
  // LOADING (cached briefly so the home card + assistant share
  // one read of the Community)
  // ==========================================================

  static const Duration cacheTtl = Duration(minutes: 5);
  static final Map<String, CommunityAiContext> _cache = {};

  static Future<CommunityAiContext> load({
    required String communityDocId,
    required String uid,
    bool forceRefresh = false,
  }) async {
    final key = '$communityDocId|$uid';
    final cached = _cache[key];
    if (!forceRefresh &&
        cached != null &&
        DateTime.now().difference(cached.builtAt) < cacheTtl) {
      return cached;
    }
    final corpus = await CommunitySearchService.loadCorpus(
      communityDocId: communityDocId,
      uid: uid,
    );
    final ctx = CommunityAiContext._(corpus, uid, DateTime.now());
    _cache[key] = ctx;
    return ctx;
  }

  /// Call on sign-out / account switch so nothing leaks between
  /// accounts on the same device.
  static void clearCache() => _cache.clear();

  // ==========================================================
  // THIS WEEK
  // ==========================================================

  static const int weekDays = 7;
  static const int maxItemsPerSection = 10;

  CommunityWeekDigest weekDigest({DateTime? now}) {
    final from = now ?? DateTime.now();
    final to = from.add(const Duration(days: weekDays));

    final events = <CommunityDigestItem>[];
    for (final e in corpus.events) {
      if (e['cancelled'] == true) continue;
      final start = _date(e['startAt']);
      if (start == null || start.isBefore(from) || start.isAfter(to)) continue;
      final where = (e['location'] ?? '').toString();
      events.add(CommunityDigestItem(
        hit: _hit(CommunitySearchKind.event, e, (e['title'] ?? 'Event')),
        date: start,
        detail: [
          _when(start),
          if (where.isNotEmpty) where,
        ].join(' · '),
      ));
    }
    events.sort(_byDateAsc);

    final announcements = <CommunityDigestItem>[];
    for (final a in corpus.announcements) {
      final urgent = a['isUrgent'] == true;
      final pinned = a['isPinned'] == true;
      final created = _date(a['createdAt']);
      final recent = created != null &&
          from.difference(created) <= const Duration(days: weekDays);
      if (!(urgent || pinned) || !(recent || pinned)) continue;
      announcements.add(CommunityDigestItem(
        hit: _hit(CommunitySearchKind.announcement, a,
            (a['title'] ?? 'Announcement')),
        date: created,
        detail: [
          if (urgent) 'Urgent',
          if (pinned) 'Pinned',
        ].join(' · '),
      ));
    }
    announcements.sort((a, b) => _byDateDesc(a, b));

    final polls = <CommunityDigestItem>[];
    for (final p in corpus.polls) {
      if (p['closed'] == true) continue;
      final deadline = _date(p['deadline']);
      if (deadline == null || !deadline.isAfter(from) || deadline.isAfter(to)) {
        continue;
      }
      // Question + deadline only. Votes / results are never read.
      polls.add(CommunityDigestItem(
        hit: _hit(CommunitySearchKind.poll, p, (p['question'] ?? 'Poll')),
        date: deadline,
        detail: 'closes ${_when(deadline)}',
      ));
    }
    polls.sort(_byDateAsc);

    List<CommunityDigestItem> cap(List<CommunityDigestItem> l) =>
        l.length > maxItemsPerSection ? l.sublist(0, maxItemsPerSection) : l;

    return CommunityWeekDigest(
      from: from,
      to: to,
      events: cap(events),
      announcements: cap(announcements),
      closingPolls: cap(polls),
      fromCache: corpus.fromCache,
      failedSections: corpus.failedSections,
    );
  }

  // ==========================================================
  // FIND
  // ==========================================================

  /// Upcoming (not cancelled) events, soonest first. [query]
  /// narrows by title / description / category / location.
  List<CommunityDigestItem> upcomingEvents({
    String query = '',
    int limit = 10,
    DateTime? now,
  }) {
    final from = now ?? DateTime.now();
    final words = CommunitySearchService.queryWords(query);
    final out = <CommunityDigestItem>[];
    for (final e in corpus.events) {
      if (e['cancelled'] == true) continue;
      final start = _date(e['startAt']);
      if (start == null || start.isBefore(from)) continue;
      if (words.isNotEmpty) {
        final hay = [
          e['title'],
          e['description'],
          e['category'],
          e['location'],
        ].map((v) => (v ?? '').toString().toLowerCase()).join(' ');
        if (!words.every(hay.contains)) continue;
      }
      out.add(CommunityDigestItem(
        hit: _hit(CommunitySearchKind.event, e, (e['title'] ?? 'Event')),
        date: start,
        detail: _when(start),
      ));
    }
    out.sort(_byDateAsc);
    return out.length > limit ? out.sublist(0, limit) : out;
  }

  /// Ranked search over what the user is allowed to see. Same
  /// ranking as the Community Search screen.
  List<CommunitySearchHit> find(
    String query, {
    Set<String>? kinds,
    int limit = 8,
  }) {
    final hits = CommunitySearchService.search(
      corpus,
      query,
      kinds: kinds,
      perKindLimit: limit,
    );
    return hits.length > limit * 3 ? hits.sublist(0, limit * 3) : hits;
  }

  // ==========================================================
  // ABOUT / RULES
  // ==========================================================

  String aboutCommunity({int maxChars = 1200}) {
    final c = corpus.community;
    final b = StringBuffer();
    final name = (c['name'] ?? '').toString();
    final type = (c['type'] ?? '').toString();
    final college = (c['collegeName'] ?? '').toString();
    final description = (c['description'] ?? '').toString().trim();
    if (name.isNotEmpty) b.writeln('Community: $name');
    if (type == 'college' && college.isNotEmpty) b.writeln('College: $college');
    if (description.isNotEmpty) b.writeln('About: $description');

    final pinned = corpus.announcements.where((a) => a['isPinned'] == true);
    if (pinned.isNotEmpty) {
      b.writeln('Pinned announcements (guidelines are usually posted here):');
      for (final a in pinned.take(5)) {
        final title = (a['title'] ?? '').toString();
        final body = (a['body'] ?? '').toString().trim();
        b.writeln('- $title${body.isEmpty ? '' : ': ${_clip(body, 300)}'}');
      }
    }
    return _clip(b.toString().trim(), maxChars);
  }

  // ==========================================================
  // DISCUSSIONS
  // ==========================================================

  /// Reads a post + its comments so the assistant can summarize the
  /// discussion. Only works for posts inside the filtered corpus
  /// (so reported / hidden posts are refused) and returns display
  /// names + text only -- no user ids.
  Future<CommunityDiscussion> loadDiscussion(
    String postId, {
    int maxComments = 40,
  }) async {
    final post = corpus.posts.cast<Map<String, dynamic>?>().firstWhere(
          (p) => (p?['id'] ?? '').toString() == postId,
          orElse: () => null,
        );
    if (post == null) {
      throw Exception('That discussion is not available to you.');
    }

    final snap = await CommunityFeedService.posts
        .doc(postId)
        .collection('comments')
        .orderBy('createdAt')
        .limit(maxComments)
        .get();

    return CommunityDiscussion(
      postId: postId,
      title: _clip((post['title'] ?? '').toString(), 200),
      text: _clip((post['text'] ?? '').toString(), 1500),
      authorName: (post['authorName'] ?? 'Member').toString(),
      comments: [
        for (final d in snap.docs)
          CommunityDiscussionComment(
            authorName: (d.data()['authorName'] ?? 'Member').toString(),
            text: _clip((d.data()['text'] ?? '').toString(), 400),
            isReply: (d.data()['parentId'] ?? '').toString().isNotEmpty,
          ),
      ],
    );
  }

  // ==========================================================
  // QUESTION -> CONTEXT
  // ==========================================================

  static const int maxContextChars = 6000;

  /// Chooses the right pieces of Community data for [question] and
  /// returns text ready to hand to a model. Never contains user
  /// ids, emails, votes or private member fields.
  CommunityAiContextBundle contextFor(String question, {DateTime? now}) {
    final q = question.toLowerCase();

    bool has(List<String> words) => words.any(q.contains);

    if (has(const ['this week', 'happening', 'today', 'tomorrow', 'coming up', 'important things'])) {
      return CommunityAiContextBundle(
        intent: 'week',
        text: _clip(weekDigest(now: now).toPlainText(), maxContextChars),
      );
    }

    if (has(const ['rule', 'guideline', 'policy', 'allowed', 'about this community'])) {
      return CommunityAiContextBundle(
        intent: 'about',
        text: aboutCommunity(),
      );
    }

    if (has(const ['upcoming event', 'events', 'event '])) {
      final items = upcomingEvents(limit: 10, now: now);
      final b = StringBuffer('Upcoming events:\n');
      for (final i in items) {
        b.writeln('- ${i.title} (${i.detail})');
      }
      if (items.isEmpty) b.writeln('None scheduled.');
      return CommunityAiContextBundle(
        intent: 'events',
        text: _clip(b.toString().trim(), maxContextChars),
      );
    }

    final hits = find(question, limit: 5);
    final b = StringBuffer();
    if (hits.isEmpty) {
      b.writeln('No matching Community items were found.');
    } else {
      b.writeln('Matching Community items:');
      for (final h in hits) {
        final kind = CommunitySearchKind.singular[h.kind] ?? h.kind;
        b.writeln('- [$kind] ${h.title}'
            '${h.subtitle.isEmpty ? '' : ' — ${h.subtitle}'}');
      }
    }
    return CommunityAiContextBundle(
      intent: hits.isEmpty ? 'general' : 'search',
      text: _clip(b.toString().trim(), maxContextChars),
    );
  }

  // ==========================================================
  // HELPERS
  // ==========================================================

  static CommunitySearchHit _hit(
    String kind,
    Map<String, dynamic> data,
    dynamic title,
  ) {
    return CommunitySearchHit(
      kind: kind,
      id: (data['id'] ?? '').toString(),
      title: title.toString().trim().isEmpty ? 'Untitled' : title.toString(),
      subtitle: '',
      imageUrl: '',
      score: 0,
      date: _date(data['createdAt']),
      data: data,
    );
  }

  static DateTime? _date(dynamic v) => v is Timestamp ? v.toDate() : null;

  static int _byDateAsc(CommunityDigestItem a, CommunityDigestItem b) =>
      (a.date ?? DateTime(9999)).compareTo(b.date ?? DateTime(9999));

  static int _byDateDesc(CommunityDigestItem a, CommunityDigestItem b) =>
      (b.date ?? DateTime.fromMillisecondsSinceEpoch(0))
          .compareTo(a.date ?? DateTime.fromMillisecondsSinceEpoch(0));

  static const List<String> _weekdays = [
    'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun',
  ];
  static const List<String> _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  static String _when(DateTime d) {
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final m = d.minute.toString().padLeft(2, '0');
    return '${_weekdays[d.weekday - 1]} ${d.day} ${_months[d.month - 1]}, '
        '$h:$m ${d.hour >= 12 ? 'PM' : 'AM'}';
  }

  static String _clip(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max - 1).trimRight()}…';
}

/// Entry point for the assistant UI / backend.
class CommunityAiAssistant {
  CommunityAiAssistant._();

  /// Answers [question] about [communityDocId] for [uid].
  ///
  /// With a [provider] the model gets the permission-filtered
  /// context. Without one, only questions that data alone can answer
  /// ("what's happening this week", "upcoming events") are answered;
  /// anything else says so plainly instead of guessing.
  static Future<String> ask({
    required String communityDocId,
    required String uid,
    required String question,
    CommunityAiProvider? provider,
  }) async {
    final ctx = await CommunityAiContext.load(
      communityDocId: communityDocId,
      uid: uid,
    );
    final bundle = ctx.contextFor(question);

    if (provider != null) {
      return provider.answer(question: question, context: bundle);
    }
    if (bundle.intent == 'week' ||
        bundle.intent == 'events' ||
        bundle.intent == 'about') {
      return bundle.text;
    }
    return 'The Nexus AI assistant is not connected yet, so I can only '
        'answer questions about this week, upcoming events and the '
        'Community itself.';
  }
}
