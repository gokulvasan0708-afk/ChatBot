import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'community_announcements_page.dart';
import 'community_polls_page.dart';
import 'community_post_detail_page.dart';
import 'event_detail_page.dart';
import '../services/community_feed_service.dart';
import '../services/community_poll_service.dart';
import '../services/event_service.dart';
import '../widgets/community_widgets.dart';

// ================================================================
// COMMUNITY "THIS WEEK" CARD
// ----------------------------------------------------------------
// Sits right under the Notice Board on the Community home.
//
// It is built from the SAME live streams the home page already
// listens to (events, polls, announcements, feed posts), so anything
// that is posted shows up straight away and anything that is deleted
// or ends disappears -- there is no cache and no manual refresh.
//
//   Events        -> upcoming + live events (Events section and
//                    "Event" feed posts) until they end / are
//                    cancelled / deleted.
//   Polls         -> open polls until they close, hit their deadline
//                    or are deleted.
//   Announcements -> posted in the last 7 days (pinned ones stay
//                    until unpinned / deleted).
//   Posts         -> feed posts of the last 7 days (questions, help
//                    requests and lost & found also leave once marked
//                    resolved).
//
// Tap the card to see the full list; tap an item to open it.
// ================================================================

const int _kWeekDays = 7;

/// An "Event" feed post only stores a start time; it counts as live for
/// this many hours after it.
const int _kEventPostLiveHours = 3;

class _WeekRow {
  final String title;
  final String detail;
  final DateTime sortTime;
  final Future<void> Function(BuildContext context) open;

  const _WeekRow({
    required this.title,
    required this.detail,
    required this.sortTime,
    required this.open,
  });
}

class _WeekGroup {
  final String title;
  final String one;
  final String many;
  final IconData icon;
  final List<_WeekRow> rows;

  const _WeekGroup({
    required this.title,
    required this.one,
    required this.many,
    required this.icon,
    required this.rows,
  });
}

class CommunityThisWeekCard extends StatelessWidget {
  final String communityDocId;
  final String uid;
  final List<Map<String, dynamic>> announcements;
  final List<Map<String, dynamic>> events;
  final List<Map<String, dynamic>> posts;
  final List<Map<String, dynamic>> polls;

  const CommunityThisWeekCard({
    super.key,
    required this.communityDocId,
    required this.uid,
    required this.announcements,
    required this.events,
    required this.posts,
    required this.polls,
  });

  // ----------------------------------------------------------
  // helpers
  // ----------------------------------------------------------
  static DateTime? _dt(dynamic v) => v is Timestamp ? v.toDate() : null;

  static String _clip(String s, [int max = 80]) {
    final t = s.trim().replaceAll(RegExp(r'\s+'), ' ');
    return t.length <= max ? t : '${t.substring(0, max)}…';
  }

  static String _left(Duration d) {
    if (d.inMinutes < 1) return 'less than a minute';
    if (d.inHours < 1) return '${d.inMinutes}m';
    if (d.inDays < 1) return '${d.inHours}h ${d.inMinutes % 60}m';
    return '${d.inDays}d ${d.inHours % 24}h';
  }

  static Future<void> _push(BuildContext c, Widget page) async {
    await Navigator.of(c).push(MaterialPageRoute(builder: (_) => page));
  }

  // ----------------------------------------------------------
  // build the groups
  // ----------------------------------------------------------
  List<_WeekGroup> _groups() {
    final now = DateTime.now();
    bool fresh(DateTime? created) =>
        created == null ||
        now.difference(created) < const Duration(days: _kWeekDays);

    final eventRows = <_WeekRow>[];
    final pollRows = <_WeekRow>[];
    final annRows = <_WeekRow>[];
    final postRows = <_WeekRow>[];

    // ---- Events section: upcoming + live ----
    for (final e in events) {
      final status = EventService.statusFor(e);
      if (status != 'upcoming' && status != 'live') continue;
      final id = (e['id'] ?? '').toString();
      if (id.isEmpty) continue;
      final start = _dt(e['startAt']);
      final end = _dt(e['endAt']);
      final live = status == 'live';
      eventRows.add(_WeekRow(
        title: _clip((e['title'] ?? 'Event').toString()),
        detail: live
            ? (end == null
                ? 'Live now'
                : 'Live now · ends in ${_left(end.difference(now))}')
            : (start == null ? '' : 'Starts ${communityFormatDateTime(start)}'),
        // Live events first, then the soonest upcoming.
        sortTime: live
            ? DateTime.fromMillisecondsSinceEpoch(0)
            : (start ?? now),
        open: (c) => _push(c, EventDetailPage(eventDocId: id)),
      ));
    }

    // ---- Polls: open ones ----
    for (final p in polls) {
      if (CommunityPollService.isEnded(p)) continue;
      final deadline = CommunityPollService.deadlineOf(p);
      final created = _dt(p['createdAt']);
      // A poll without a deadline follows the same 7-day rule as posts.
      if (deadline == null && !fresh(created)) continue;
      final voted = CommunityPollService.hasVoted(p, uid);
      final left = deadline == null
          ? 'Open'
          : 'Closes in ${_left(deadline.difference(now))}';
      pollRows.add(_WeekRow(
        title: _clip((p['question'] ?? 'Poll').toString()),
        detail: voted ? '$left · You voted' : left,
        sortTime: deadline ?? DateTime(2100),
        open: (c) => _push(c, CommunityPollsPage(communityDocId: communityDocId)),
      ));
    }

    // ---- Announcements ----
    for (final a in announcements) {
      final urgent = a['isUrgent'] == true;
      final pinned = a['isPinned'] == true;
      final created = _dt(a['publishedAt']) ?? _dt(a['createdAt']);
      if (!pinned && !fresh(created)) continue;
      annRows.add(_WeekRow(
        title: _clip((a['title'] ?? 'Announcement').toString()),
        detail: [
          if (urgent) 'Important',
          if (pinned) 'Pinned',
          communityTimeAgo(created),
        ].join(' · '),
        // Newest first (negated so the common ascending sort works).
        sortTime: DateTime.fromMillisecondsSinceEpoch(
            -(created ?? now).millisecondsSinceEpoch),
        open: (c) =>
            _push(c, CommunityAnnouncementsPage(communityDocId: communityDocId)),
      ));
    }

    // ---- Feed posts ----
    for (final p in posts) {
      if (CommunityFeedService.isReported(p, uid)) continue;
      final type = (p['type'] ?? '').toString();
      final id = (p['id'] ?? '').toString();
      if (id.isEmpty || type == 'poll') continue; // polls: see above
      final created = _dt(p['createdAt']);
      Future<void> openPost(BuildContext c) => _push(
            c,
            CommunityPostDetailPage(
              postId: id,
              communityDocId: communityDocId,
            ),
          );

      if (type == 'event') {
        final at = _dt(
            (p['event'] is Map) ? (p['event'] as Map)['dateTime'] : null);
        if (at == null) continue;
        if (now.isAfter(at.add(const Duration(hours: _kEventPostLiveHours)))) {
          continue; // over
        }
        final live = !now.isBefore(at);
        eventRows.add(_WeekRow(
          title: _clip((p['title'] ?? 'Event').toString()),
          detail: live ? 'Live now' : 'Starts ${communityFormatDateTime(at)}',
          sortTime: live ? DateTime.fromMillisecondsSinceEpoch(0) : at,
          open: openPost,
        ));
        continue;
      }

      if (!fresh(created)) continue;
      if ((type == 'question' || type == 'help' || type == 'lostfound') &&
          p['isResolved'] == true) {
        continue;
      }

      final label = CommunityFeedService.typeLabels[type] ?? 'Post';
      var title = (p['title'] ?? '').toString().trim();
      if (type == 'lostfound') {
        final lf = p['lostFound'] is Map
            ? Map<String, dynamic>.from(p['lostFound'] as Map)
            : <String, dynamic>{};
        final item = (lf['item'] ?? '').toString();
        final status = (lf['status'] ?? '').toString().toLowerCase();
        title = status == 'found' ? 'Found: $item' : 'Lost: $item';
      }
      if (title.isEmpty) title = (p['text'] ?? '').toString();
      if (title.trim().isEmpty) title = label;
      final author = (p['authorName'] ?? '').toString().trim();

      postRows.add(_WeekRow(
        title: _clip(title),
        detail: author.isEmpty ? label : '$label · $author',
        sortTime: DateTime.fromMillisecondsSinceEpoch(
            -(created ?? now).millisecondsSinceEpoch),
        open: openPost,
      ));
    }

    for (final l in [eventRows, pollRows, annRows, postRows]) {
      l.sort((a, b) => a.sortTime.compareTo(b.sortTime));
    }

    return [
      _WeekGroup(
        title: 'Events',
        one: 'event',
        many: 'events',
        icon: Icons.event_rounded,
        rows: eventRows,
      ),
      _WeekGroup(
        title: 'Polls',
        one: 'poll',
        many: 'polls',
        icon: Icons.poll_rounded,
        rows: pollRows,
      ),
      _WeekGroup(
        title: 'Announcements',
        one: 'announcement',
        many: 'announcements',
        icon: Icons.campaign_rounded,
        rows: annRows,
      ),
      _WeekGroup(
        title: 'Posts',
        one: 'post',
        many: 'posts',
        icon: Icons.dynamic_feed_rounded,
        rows: postRows,
      ),
    ].where((g) => g.rows.isNotEmpty).toList();
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups();
    final isEmpty = groups.isEmpty;
    final summary = isEmpty
        ? 'Nothing scheduled this week'
        : groups
            .map((g) =>
                '${g.rows.length} ${g.rows.length == 1 ? g.one : g.many}')
            .join(' · ');

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
      child: Material(
        color: CommunityColors.card,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: isEmpty ? null : () => _openDetails(context, groups),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            constraints: const BoxConstraints(minHeight: 58),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border:
                  Border.all(color: CommunityColors.tan.withValues(alpha: .3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.today_rounded,
                    color: CommunityColors.glow, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'This week',
                        style: TextStyle(color: Colors.white38, fontSize: 10.5),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        summary,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isEmpty ? Colors.white54 : Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                if (!isEmpty)
                  const Icon(Icons.chevron_right_rounded,
                      color: Colors.white38),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openDetails(BuildContext context, List<_WeekGroup> groups) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.88,
      ),
      builder: (sheetContext) => _WeekSheet(groups: groups),
    );
  }
}

class _WeekSheet extends StatelessWidget {
  final List<_WeekGroup> groups;

  const _WeekSheet({required this.groups});

  @override
  Widget build(BuildContext context) {
    return CommunitySheetShell(
      title: 'This week',
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        children: [
          for (final g in groups) _GroupView(group: g),
        ],
      ),
    );
  }
}

class _GroupView extends StatelessWidget {
  final _WeekGroup group;

  const _GroupView({required this.group});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(group.icon, color: CommunityColors.tan, size: 16),
              const SizedBox(width: 8),
              Text(
                '${group.title} (${group.rows.length})',
                style: TextStyle(
                  color: CommunityColors.tan.withValues(alpha: .9),
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final row in group.rows)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              onTap: () => row.open(context),
              title: Text(
                row.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 13.5),
              ),
              subtitle: row.detail.isEmpty
                  ? null
                  : Text(
                      row.detail,
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 11.5),
                    ),
              trailing: const Icon(Icons.chevron_right_rounded,
                  color: Colors.white24, size: 18),
            ),
        ],
      ),
    );
  }
}
