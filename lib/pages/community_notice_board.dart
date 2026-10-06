import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'college_notice_sheet.dart';
import 'community_announcements_page.dart';
import 'create_notice_post_sheet.dart';
import 'community_polls_page.dart';
import 'community_post_detail_page.dart';
import 'event_detail_page.dart';
import '../services/college_notice_service.dart';
import '../services/community_feed_service.dart';
import '../services/community_media_service.dart';
import '../services/community_poll_service.dart';
import '../services/community_service.dart';
import '../services/event_service.dart';
import '../services/notice_post_service.dart';
import '../widgets/community_widgets.dart';
import '../widgets/top_alert.dart';

// ================================================================
// COMMUNITY NOTICE BOARD
// ----------------------------------------------------------------
// Shown on the Community home, right under the community name.
//
// STAYS while it is live (persistent):
//   Live event      -> an Event whose start time has arrived and whose
//                      end time has not (communityEvents), or an
//                      "Event" feed post whose date/time has arrived
//                      (stays for kEventPostLiveHours).
//   Poll            -> community polls that are still open
//                      (not closed, deadline not passed).
//   Important       -> announcements marked urgent / important.
//   Question / Help / Request / Lost & Found
//                   -> feed posts of those types, until resolved.
//
// SHOWN ONE TIME ONLY (gone once the member has seen it):
//   Announcement    -> a normal (not important) announcement.
//   New event       -> an event / event post when it is first posted,
//                      before its time. It shows once; when the set
//                      time arrives it comes back as a LIVE EVENT and
//                      stays until the event ends.
//   "Seen" = it was on the board when the member opened the Community
//   home. It stays for that visit (or until the member opens it and
//   comes back) and is gone the next time. Stored per member in
//   users/{uid}.noticeSeen.{communityDocId} (list of notice keys).
//
// NOTICE POSTS (post icon in the header):
//   Posts written straight onto the board (text / text + image /
//   image / video / video + text). They stay until the end time set
//   by the poster and are only shown to the chosen audience
//   (see notice_post_service.dart).
//
// EYE ICON (header, top-right):
//   tap         -> hides every notice that is visible right now
//   long-press  -> shows the hidden notices; tap a hidden notice to
//                  bring it back. Long-press (or tap) again to leave.
//   Hidden notices are stored per member in
//   users/{uid}.noticeHidden.{communityDocId}.
//
// OTHER COLLEGE ICON (header, next to the eye; college communities):
//   tap         -> shows the notices other colleges posted with
//                  "Show to all College" (they are added after this
//                  community's own notices and the board jumps to them)
//   tap again   -> hides them again. They are NOT shown by default.
//   A red dot on the icon = a new notice from another college that the
//   member has not looked at yet. Opening the icon clears the dot; the
//   notices stay under the icon until they end or are deleted.
//   (seen keys are stored in users/{uid}.noticeSeen.{communityDocId})
//
// Never shown: expired polls / events, resolved posts, cancelled
// events, posts the viewer has reported.
//
// Items with no end time of their own (important announcements,
// questions, help requests, lost & found, polls without a deadline,
// new-event / announcement notices) drop off after kNoticeMaxAgeDays.
//
// The widget is fed the lists the Community home already streams. The
// home page re-builds every minute, which is what makes events appear
// / expire on time.
// ================================================================

/// Items without their own end time leave the board after this many days.
const int kNoticeMaxAgeDays = 7;

/// An "Event" feed post only stores a start time; it counts as live for
/// this many hours after it.
const int kEventPostLiveHours = 3;

/// The board moves to the next notice by itself after this many seconds
/// (and starts again from the first one after the last).
const int kNoticeAutoSlideSeconds = 5;

/// Height of one notice card (full width of the page).
const double kNoticeBoardHeight = 224;

const Color _tan = Color(0xFFD2B48C);

class _Notice {
  /// Stable id of this notice (used for hide / unhide).
  final String key;
  final String label;
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final int priority; // lower = shown first
  final DateTime sortTime; // newer first inside a priority
  final Future<void> Function() onTap;

  /// Non-null = shown one time only; the key is what gets stored as seen.
  final String? onceKey;

  /// Cover image of the post / event / announcement ('' = none).
  final String imageUrl;

  /// Shows a play button over the cover (video notice posts).
  final bool isVideo;

  /// "College name · Location" of another college's notice
  /// (Show to all College). '' for this community's own notices.
  final String sourceLine;

  /// Profile image (logo) of the college that posted it. Shown in the
  /// top-right corner of the card. '' for this community's own notices.
  final String sourceLogoUrl;

  /// Cover image of the college that posted it (used as the background
  /// when the shared notice has no image of its own).
  final String sourceCoverUrl;

  /// True when imageUrl is the college cover (not the notice's own image):
  /// it is drawn softer so the text stays readable.
  final bool coverBg;

  /// True for a notice shared by another college.
  bool get isExternal => sourceLine.isNotEmpty || sourceLogoUrl.isNotEmpty;

  const _Notice({
    required this.key,
    required this.label,
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.priority,
    required this.sortTime,
    required this.onTap,
    this.onceKey,
    this.imageUrl = '',
    this.isVideo = false,
    this.sourceLine = '',
    this.sourceLogoUrl = '',
    this.sourceCoverUrl = '',
    this.coverBg = false,
  });

  /// Same notice with a different cover image.
  _Notice withImage(String url) => _Notice(
        key: key,
        label: label,
        icon: icon,
        color: color,
        title: title,
        subtitle: subtitle,
        priority: priority,
        sortTime: sortTime,
        onTap: onTap,
        onceKey: onceKey,
        imageUrl: url,
        isVideo: isVideo,
        sourceLine: sourceLine,
        sourceLogoUrl: sourceLogoUrl,
        sourceCoverUrl: sourceCoverUrl,
        coverBg: true,
      );
}

class CommunityNoticeBoard extends StatefulWidget {
  final String communityDocId;
  final String uid;
  final List<Map<String, dynamic>> announcements;
  final List<Map<String, dynamic>> events;
  final List<Map<String, dynamic>> posts;
  final List<Map<String, dynamic>> polls;

  /// The community document (roles, departments, admins ...). Used for
  /// "who can post" and for the audience of notice posts.
  final Map<String, dynamic> community;

  const CommunityNoticeBoard({
    super.key,
    required this.communityDocId,
    required this.uid,
    required this.announcements,
    required this.events,
    required this.posts,
    required this.polls,
    this.community = const <String, dynamic>{},
  });

  @override
  State<CommunityNoticeBoard> createState() => _CommunityNoticeBoardState();
}

class _CommunityNoticeBoardState extends State<CommunityNoticeBoard> {
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _sub;
  Set<String> _seen = {};
  bool _seenLoaded = false;

  /// One-time notices that were put on the board during this visit.
  /// They stay until the member leaves the home page (or opens one).
  final Set<String> _session = {};

  // ---- hide / unhide ----
  Set<String> _hidden = {};
  bool _showHidden = false;

  // ---- other colleges' notices: only shown after the "other" icon is tapped ----
  bool _showOthers = false;
  bool _jumpToOthers = false;

  // ---- notice posts ----
  StreamSubscription<List<Map<String, dynamic>>>? _postSub;
  List<Map<String, dynamic>> _noticePosts = [];
  NoticeViewer _viewer = NoticeViewer.unknown;
  bool _viewerLoaded = false;
  Timer? _tick;

  // ---- notices other colleges shared (Show to all College) ----
  StreamSubscription<List<Map<String, dynamic>>>? _sharedSub;
  List<Map<String, dynamic>> _shared = [];

  final PageController _pager = PageController();
  int _page = 0;

  // ---- auto slide (next notice every kNoticeAutoSlideSeconds, looping) ----
  Timer? _auto;
  int _itemCount = 0;

  void _startAuto() {
    _auto?.cancel();
    _auto = Timer.periodic(const Duration(seconds: kNoticeAutoSlideSeconds),
        (_) {
      if (!mounted || _itemCount < 2 || !_pager.hasClients) return;
      final next = _page + 1;
      if (next >= _itemCount) {
        // Last notice -> start again from the first.
        _pager.jumpToPage(0);
      } else {
        _pager.animateToPage(
          next,
          duration: const Duration(milliseconds: 450),
          curve: Curves.easeInOut,
        );
      }
    });
  }

  String get _id => widget.communityDocId;
  String get _uid => widget.uid;

  bool get _canPost => NoticePostService.canPost(widget.community, _uid);

  bool get _isManager =>
      CommunityService.isPrivileged(widget.community, _uid);

  bool get _isCollege => (widget.community['type'] ?? '').toString() == 'college';

  /// This college's cover image ('' = none / not a college).
  String get _ownCover =>
      _isCollege ? (widget.community['coverUrl'] ?? '').toString() : '';

  /// College communities also list what other colleges shared with
  /// "Show to all College". Started / stopped as the community loads.
  void _syncShared() {
    if (_isCollege && _sharedSub == null) {
      _sharedSub =
          CollegeNoticeService.watchShared(excludeCommunityDocId: _id).listen(
        (list) {
          if (mounted) setState(() => _shared = list);
        },
        onError: (Object e) => debugPrint('Shared notices error: $e'),
      );
    } else if (!_isCollege && _sharedSub != null) {
      _sharedSub?.cancel();
      _sharedSub = null;
      _shared = [];
    }
  }

  @override
  void didUpdateWidget(covariant CommunityNoticeBoard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncShared();
  }

  @override
  void initState() {
    super.initState();
    _syncShared();
    _startAuto();

    // Notice posts (own stream) + who I am in this community.
    _postSub = NoticePostService.watchPosts(_id).listen((list) {
      if (mounted) setState(() => _noticePosts = list);
    }, onError: (Object e) {
      debugPrint('Notice posts error: $e');
    });
    NoticePostService.loadViewer(_id, widget.community, _uid).then((v) {
      if (!mounted) return;
      setState(() {
        _viewer = v;
        _viewerLoaded = true;
      });
    });
    // Posts expire on their own; re-check regularly.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });

    if (_uid.isEmpty) {
      _seenLoaded = true;
      return;
    }
    _sub = FirebaseFirestore.instance
        .collection('users')
        .doc(_uid)
        .snapshots()
        .listen((snap) {
      final root = snap.data()?['noticeSeen'];
      final mine = root is Map ? root[_id] : null;
      final next = mine is List
          ? mine.map((e) => e.toString()).toSet()
          : <String>{};
      final hiddenRoot = snap.data()?['noticeHidden'];
      final hiddenMine = hiddenRoot is Map ? hiddenRoot[_id] : null;
      final nextHidden = hiddenMine is List
          ? hiddenMine.map((e) => e.toString()).toSet()
          : <String>{};
      if (!mounted) return;
      setState(() {
        _seen = {..._seen, ...next};
        _hidden = nextHidden;
        _seenLoaded = true;
      });
    }, onError: (Object e) {
      debugPrint('Notice board seen error: $e');
      if (mounted) setState(() => _seenLoaded = true);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _postSub?.cancel();
    _sharedSub?.cancel();
    _tick?.cancel();
    _auto?.cancel();
    _pager.dispose();
    super.dispose();
  }

  Future<void> _markSeen(List<String> keys) async {
    if (_uid.isEmpty || keys.isEmpty) return;
    try {
      await FirebaseFirestore.instance.collection('users').doc(_uid).set(
        {
          'noticeSeen': {_id: FieldValue.arrayUnion(keys)},
        },
        SetOptions(merge: true),
      );
    } catch (e) {
      debugPrint('Notice board markSeen error: $e');
    }
  }

  Future<void> _setHidden(List<String> keys, {required bool hide}) async {
    if (keys.isEmpty) return;
    setState(() {
      if (hide) {
        _hidden = {..._hidden, ...keys};
      } else {
        _hidden = _hidden.where((k) => !keys.contains(k)).toSet();
      }
    });
    if (_uid.isEmpty) return;
    try {
      await FirebaseFirestore.instance.collection('users').doc(_uid).set(
        {
          'noticeHidden': {
            _id: hide
                ? FieldValue.arrayUnion(keys)
                : FieldValue.arrayRemove(keys),
          },
        },
        SetOptions(merge: true),
      );
    } catch (e) {
      debugPrint('Notice board hide error: $e');
    }
  }

  /// Eye icon, tap: hide everything visible. While the hidden list is
  /// open, a tap just closes it again.
  void _onEyeTap(List<_Notice> visible) {
    if (_showHidden) {
      setState(() {
        _showHidden = false;
        _page = 0;
      });
      return;
    }
    if (visible.isEmpty) {
      showTopAlert(context, 'No notices to hide');
      return;
    }
    _setHidden([for (final n in visible) n.key], hide: true);
    _page = 0;
    showTopAlert(context, 'Notices hidden. Press and hold the eye to see them.');
  }

  /// Eye icon, long-press: show / close the hidden notices.
  void _onEyeLongPress(List<_Notice> hidden) {
    if (_showHidden) {
      setState(() {
        _showHidden = false;
        _page = 0;
      });
      return;
    }
    if (hidden.isEmpty) {
      showTopAlert(context, 'No hidden notices');
      return;
    }
    setState(() {
      _showHidden = true;
      _page = 0;
    });
  }

  void _restore(_Notice n) {
    final k = n.onceKey;
    // A one-time notice that was already seen would vanish again
    // straight away; keep it on the board for this visit.
    if (k != null) _session.add(k);
    _setHidden([n.key], hide: false);
    showTopAlert(context, 'Notice restored');
  }

  /// Keys of the live notices other colleges shared. A key leaves this
  /// list when the notice ends or is deleted.
  List<String> _otherKeys() {
    if (!_isCollege) return const <String>[];
    final now = DateTime.now();
    final out = <String>[];
    for (final item in _shared) {
      if ((item['sourceId'] ?? '').toString() == _id) continue;
      final id = (item['id'] ?? '').toString();
      if (id.isEmpty) continue;
      if (!CollegeNoticeService.isLive(item, now)) continue;
      out.add('ext_${(item['kind'] ?? '').toString()}_$id');
    }
    return out;
  }

  int _otherCount() => _otherKeys().length;

  /// Marks every other-college notice as seen (the dot on the icon goes).
  void _markOthersSeen() {
    final fresh = _otherKeys().where((k) => !_seen.contains(k)).toList();
    if (fresh.isEmpty) return;
    _seen = {..._seen, ...fresh};
    _markSeen(fresh);
  }

  /// "Other" icon: show / hide the notices of other colleges.
  void _onOthersTap() {
    if (!_showOthers && _otherCount() == 0) {
      showTopAlert(context, 'No notices from other colleges');
      return;
    }
    setState(() {
      _showOthers = !_showOthers;
      _showHidden = false;
      _page = 0;
      _jumpToOthers = _showOthers;
    });
    if (_showOthers) _markOthersSeen();
    if (!_showOthers && _pager.hasClients) _pager.jumpToPage(0);
  }

  Future<void> _openPostSheet() async {
    await CreateNoticePostSheet.show(
      context,
      communityDocId: _id,
      community: widget.community,
    );
  }

  // ----------------------------------------------------------
  // helpers
  // ----------------------------------------------------------
  static DateTime? _dt(dynamic v) {
    if (v is Timestamp) return v.toDate();
    if (v is DateTime) return v;
    return null;
  }

  static bool _isFresh(DateTime now, DateTime? created) {
    // A just-written doc has no server time yet -> it is brand new.
    if (created == null) return true;
    return now.difference(created) < const Duration(days: kNoticeMaxAgeDays);
  }

  static String _left(Duration d) {
    if (d.inMinutes < 1) return 'less than a minute';
    if (d.inHours < 1) return '${d.inMinutes}m';
    if (d.inDays < 1) return '${d.inHours}h ${d.inMinutes % 60}m';
    return '${d.inDays}d ${d.inHours % 24}h';
  }

  /// First image of a feed post ('' when it has none / is a video).
  static String _postImage(Map<String, dynamic> p) {
    if ((p['mediaType'] ?? '').toString() == 'video') return '';
    final m = p['mediaUrls'];
    if (m is List && m.isNotEmpty) {
      final u = m.first.toString();
      if (u.startsWith('http')) return u;
    }
    return '';
  }

  static String _clip(String s, [int max = 140]) {
    final t = s.trim().replaceAll(RegExp(r'\s+'), ' ');
    return t.length <= max ? t : '${t.substring(0, max)}…';
  }

  Future<void> _openNoticePost(Map<String, dynamic> p) async {
    final id = (p['id'] ?? '').toString();
    // Only the member who posted it can edit / delete it.
    final isAuthor = _uid.isNotEmpty && (p['authorUid'] ?? '').toString() == _uid;
    var wantsEdit = false;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _NoticePostSheet(
        post: p,
        isAuthor: isAuthor,
        onEdit: () => wantsEdit = true,
        onDelete: () => NoticePostService.deletePost(
          id: id,
          requesterUid: _uid,
        ),
      ),
    );
    if (wantsEdit && mounted) {
      await CreateNoticePostSheet.show(
        context,
        communityDocId: _id,
        community: widget.community,
        existing: p,
      );
    }
  }

  // ----------------------------------------------------------
  // build the list of live notices
  // ----------------------------------------------------------
  List<_Notice> _collect(BuildContext context) {
    final now = DateTime.now();
    final out = <_Notice>[];

    Future<void> open(Widget page) async {
      await Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => page));
    }

    final communityDocId = _id;
    final uid = _uid;
    final events = widget.events;
    final polls = widget.polls;
    final announcements = widget.announcements;
    final posts = widget.posts;

    // ---- Events (communityEvents) ----
    for (final e in events) {
      final status = EventService.statusFor(e);
      final end = _dt(e['endAt']);
      final id = (e['id'] ?? '').toString();
      if (id.isEmpty) continue;

      // Just posted, not started yet -> shown ONE time only.
      if (status == 'upcoming') {
        final created = _dt(e['createdAt']);
        if (!_isFresh(now, created)) continue;
        final start = _dt(e['startAt']);
        out.add(_Notice(
          key: 'event_$id',
          label: 'NEW EVENT',
          icon: Icons.event_rounded,
          color: const Color(0xFF66BB6A),
          title: _clip((e['title'] ?? 'Event').toString()),
          subtitle: start == null
              ? 'Tap to view'
              : 'Starts ${communityFormatDateTime(start)}',
          priority: 3,
          sortTime: created ?? now,
          onTap: () => open(EventDetailPage(eventDocId: id)),
          onceKey: 'event_$id',
          imageUrl: (e['coverImageUrl'] ?? '').toString(),
        ));
        continue;
      }

      // Live right now -> stays until the end time.
      if (status != 'live') continue;
      out.add(_Notice(
        key: 'live_event_$id',
        label: 'LIVE EVENT',
        icon: Icons.sensors_rounded,
        color: const Color(0xFFFF5252),
        title: _clip((e['title'] ?? 'Event').toString()),
        subtitle: end == null ? 'Happening now' : 'Ends in ${_left(end.difference(now))}',
        priority: 0,
        sortTime: _dt(e['startAt']) ?? now,
        onTap: () => open(EventDetailPage(eventDocId: id)),
        imageUrl: (e['coverImageUrl'] ?? '').toString(),
      ));
    }

    // ---- Polls (open, community-wide) ----
    for (final p in polls) {
      if ((p['scope'] ?? 'community').toString() != 'community') continue;
      if (CommunityPollService.isEnded(p)) continue;
      final deadline = CommunityPollService.deadlineOf(p);
      final created = _dt(p['createdAt']);
      // No deadline of its own -> same age cap as other notices.
      if (deadline == null && !_isFresh(now, created)) continue;

      final voted = CommunityPollService.hasVoted(p, uid);
      final left = deadline == null
          ? 'Open'
          : 'Closes in ${_left(deadline.difference(now))}';
      final pollId = (p['id'] ?? '').toString();
      out.add(_Notice(
        key: 'poll_${pollId.isEmpty ? (p['question'] ?? '').toString().hashCode : pollId}',
        label: 'POLL',
        icon: Icons.poll_rounded,
        color: const Color(0xFF4FA3FF),
        title: _clip((p['question'] ?? 'Poll').toString()),
        subtitle: voted ? '$left · You voted' : '$left · Vote now',
        priority: 2,
        sortTime: created ?? now,
        onTap: () => open(CommunityPollsPage(communityDocId: communityDocId)),
      ));
    }

    // ---- Announcements ----
    //   important (urgent) -> stays on the board
    //   normal             -> shown one time only
    for (final a in announcements) {
      final urgent = a['isUrgent'] == true;
      final id = (a['id'] ?? '').toString();
      final created = _dt(a['publishedAt']) ?? _dt(a['createdAt']);
      if (!_isFresh(now, created)) continue;
      if (!urgent && id.isEmpty) continue;
      out.add(_Notice(
        key: 'ann_${id.isEmpty ? (a['title'] ?? '').toString().hashCode : id}',
        label: urgent ? 'IMPORTANT' : 'ANNOUNCEMENT',
        icon: urgent ? Icons.priority_high_rounded : Icons.campaign_rounded,
        color: const Color(0xFFFFB300),
        title: _clip((a['title'] ?? 'Announcement').toString()),
        subtitle: _clip((a['body'] ?? '').toString(), 60),
        priority: urgent ? 1 : 3,
        sortTime: created ?? now,
        onTap: () =>
            open(CommunityAnnouncementsPage(communityDocId: communityDocId)),
        onceKey: urgent ? null : 'ann_$id',
        imageUrl: (a['type'] ?? '').toString() == 'image'
            ? (a['mediaUrl'] ?? '').toString()
            : '',
      ));
    }

    // ---- Feed posts ----
    for (final p in posts) {
      if (CommunityFeedService.isReported(p, uid)) continue;
      final type = (p['type'] ?? '').toString();
      final id = (p['id'] ?? '').toString();
      if (id.isEmpty) continue;
      final created = _dt(p['createdAt']);
      Future<void> openPost() => open(CommunityPostDetailPage(
            postId: id,
            communityDocId: communityDocId,
          ));

      switch (type) {
        case 'event':
          final at = _dt(
              (p['event'] is Map) ? (p['event'] as Map)['dateTime'] : null);
          if (at == null) continue;

          // Just posted, time not reached -> shown ONE time only.
          if (now.isBefore(at)) {
            if (!_isFresh(now, created)) continue;
            out.add(_Notice(
              key: 'post_$id',
              label: 'NEW EVENT',
              icon: Icons.event_rounded,
              color: const Color(0xFF66BB6A),
              title: _clip((p['title'] ?? 'Event').toString()),
              subtitle: 'Starts ${communityFormatDateTime(at)}',
              priority: 3,
              sortTime: created ?? now,
              onTap: openPost,
              onceKey: 'post_$id',
              imageUrl: _postImage(p),
            ));
            continue;
          }

          // Live from the set time (stays kEventPostLiveHours).
          if (now.isAfter(at.add(const Duration(hours: kEventPostLiveHours)))) {
            continue;
          }
          out.add(_Notice(
            key: 'live_post_$id',
            label: 'LIVE EVENT',
            icon: Icons.sensors_rounded,
            color: const Color(0xFFFF5252),
            title: _clip((p['title'] ?? 'Event').toString()),
            subtitle: 'Happening now',
            priority: 0,
            sortTime: at,
            onTap: openPost,
            imageUrl: _postImage(p),
          ));
          break;

        case 'question':
        case 'help':
        case 'lostfound':
          if (p['isResolved'] == true) continue;
          if (!_isFresh(now, created)) continue;

          if (type == 'lostfound') {
            final lf = p['lostFound'] is Map
                ? Map<String, dynamic>.from(p['lostFound'] as Map)
                : <String, dynamic>{};
            final status = (lf['status'] ?? '').toString().toLowerCase();
            final item = (lf['item'] ?? '').toString();
            final where = (lf['location'] ?? '').toString().trim();
            out.add(_Notice(
              key: 'post_$id',
              label: 'LOST & FOUND',
              icon: Icons.search_rounded,
              color: const Color(0xFF26C6DA),
              title: _clip(status == 'found' ? 'Found: $item' : 'Lost: $item'),
              subtitle: where.isEmpty ? 'Tap to view' : 'At $where',
              priority: 4,
              sortTime: created ?? now,
              onTap: openPost,
              imageUrl: _postImage(p),
            ));
          } else if (type == 'help') {
            out.add(_Notice(
              key: 'post_$id',
              label: 'HELP / REQUEST',
              icon: Icons.volunteer_activism_rounded,
              color: const Color(0xFFFF8A50),
              title: _clip((p['title'] ?? '').toString().trim().isNotEmpty
                  ? p['title'].toString()
                  : (p['text'] ?? '').toString()),
              subtitle: 'Needs help',
              priority: 4,
              sortTime: created ?? now,
              onTap: openPost,
              imageUrl: _postImage(p),
            ));
          } else {
            out.add(_Notice(
              key: 'post_$id',
              label: 'QUESTION',
              icon: Icons.help_outline_rounded,
              color: const Color(0xFFB57BFF),
              title: _clip((p['title'] ?? '').toString().trim().isNotEmpty
                  ? p['title'].toString()
                  : (p['text'] ?? '').toString()),
              subtitle: 'Unanswered · tap to reply',
              priority: 4,
              sortTime: created ?? now,
              onTap: openPost,
              imageUrl: _postImage(p),
            ));
          }
          break;

        default:
          // text / image / video / achievement / poll posts are not
          // notices (polls come from the polls list above).
          break;
      }
    }

    // ---- Notice posts (written straight onto the board) ----
    // Shown until their end time, and only to the chosen audience.
    // The author and community admins always see them.
    for (final p in _noticePosts) {
      final id = (p['id'] ?? '').toString();
      if (id.isEmpty) continue;
      if (!NoticePostService.isActive(p, now)) continue;

      final isAuthor = (p['authorUid'] ?? '').toString() == uid;
      if (!isAuthor && !_isManager) {
        if (!_viewerLoaded) continue;
        if (!NoticePostService.isVisibleTo(p, _viewer)) continue;
      }

      final title = (p['title'] ?? '').toString().trim();
      final text = (p['text'] ?? '').toString().trim();
      final mediaUrl = (p['mediaUrl'] ?? '').toString();
      final isVideo = (p['mediaType'] ?? '').toString() == 'video';
      final end = NoticePostService.endOf(p);
      final created = _dt(p['createdAt']);

      var cover = '';
      if (mediaUrl.startsWith('http')) {
        cover = isVideo
            ? CommunityMediaService.videoThumbnailUrl(mediaUrl)
            : mediaUrl;
      }

      final headline = title.isNotEmpty
          ? title
          : (text.isNotEmpty ? text : (isVideo ? 'Video notice' : 'Photo notice'));
      final sub = <String>[
        if (title.isNotEmpty && text.isNotEmpty) _clip(text, 70),
        if (end != null) 'Ends in ${_left(end.difference(now))}',
      ];

      out.add(_Notice(
        key: 'np_$id',
        label: 'NOTICE',
        icon: Icons.push_pin_rounded,
        color: const Color(0xFFE0A96D),
        title: _clip(headline),
        subtitle: sub.join(' · '),
        priority: 1,
        sortTime: created ?? now,
        onTap: () => _openNoticePost(p),
        imageUrl: cover,
        isVideo: isVideo,
      ));
    }

    // ---- Shared by other colleges (Show to all College) ----
    // Listed after this community's own notices; tapping one opens a
    // read-only detail with the posting community's logo + name.
    if (_isCollege && _showOthers) {
      for (final item in _shared) {
        if ((item['sourceId'] ?? '').toString() == communityDocId) continue;
        if (!CollegeNoticeService.isLive(item, now)) continue;

        final kind = (item['kind'] ?? '').toString();
        final d = item['data'] is Map
            ? Map<String, dynamic>.from(item['data'] as Map)
            : <String, dynamic>{};
        final src = item['source'] is Map
            ? Map<String, dynamic>.from(item['source'] as Map)
            : <String, dynamic>{};
        final id = (item['id'] ?? '').toString();
        if (id.isEmpty) continue;

        final sourceLine = [
          (src['collegeName'] ?? '').toString().trim(),
          (src['location'] ?? '').toString().trim(),
        ].where((s) => s.isNotEmpty).join(' · ');

        String label;
        IconData icon;
        Color color;
        String title;
        String subtitle;
        String cover = '';
        var isVideo = false;
        DateTime sortTime;

        switch (kind) {
          case 'announcement':
            label = 'COLLEGE ANNOUNCEMENT';
            icon = Icons.campaign_rounded;
            color = const Color(0xFFFFB300);
            title = _clip((d['title'] ?? 'Announcement').toString());
            subtitle = _clip((d['body'] ?? '').toString(), 60);
            if ((d['type'] ?? '').toString() == 'image') {
              cover = (d['mediaUrl'] ?? '').toString();
            }
            sortTime = _dt(d['publishedAt']) ?? _dt(d['createdAt']) ?? now;
            break;
          case 'event':
            final evStart = _dt(d['startAt']);
            final evEnd = _dt(d['endAt']);
            final live = evStart != null && !now.isBefore(evStart);
            label = live ? 'COLLEGE LIVE EVENT' : 'COLLEGE EVENT';
            icon = live ? Icons.sensors_rounded : Icons.event_rounded;
            color = live ? const Color(0xFFFF5252) : const Color(0xFF66BB6A);
            title = _clip((d['title'] ?? 'Event').toString());
            subtitle = live
                ? (evEnd == null ? 'Happening now' : 'Ends in ${_left(evEnd.difference(now))}')
                : (evStart == null ? 'Tap to view' : 'Starts ${communityFormatDateTime(evStart)}');
            cover = (d['coverImageUrl'] ?? '').toString();
            sortTime = evStart ?? _dt(d['createdAt']) ?? now;
            break;
          default:
            final t = (d['title'] ?? '').toString().trim();
            final x = (d['text'] ?? '').toString().trim();
            final mediaUrl = (d['mediaUrl'] ?? '').toString();
            isVideo = (d['mediaType'] ?? '').toString() == 'video';
            if (mediaUrl.startsWith('http')) {
              cover = isVideo
                  ? CommunityMediaService.videoThumbnailUrl(mediaUrl)
                  : mediaUrl;
            }
            label = 'COLLEGE NOTICE';
            icon = Icons.push_pin_rounded;
            color = const Color(0xFFE0A96D);
            title = _clip(t.isNotEmpty
                ? t
                : (x.isNotEmpty ? x : (isVideo ? 'Video notice' : 'Photo notice')));
            final noticeEnd = NoticePostService.endOf(d);
            subtitle = [
              if (t.isNotEmpty && x.isNotEmpty) _clip(x, 70),
              if (noticeEnd != null) 'Ends in ${_left(noticeEnd.difference(now))}',
            ].join(' · ');
            sortTime = _dt(d['createdAt']) ?? now;
        }

        out.add(_Notice(
          key: 'ext_${kind}_$id',
          label: label,
          icon: icon,
          color: color,
          title: title,
          subtitle: subtitle,
          priority: 5,
          sortTime: sortTime,
          onTap: () => CollegeNoticeSheet.show(context, item),
          imageUrl: cover,
          isVideo: isVideo,
          sourceLine: sourceLine,
          sourceLogoUrl: (src['logoUrl'] ?? '').toString(),
          sourceCoverUrl: (src['coverUrl'] ?? '').toString(),
        ));
      }
    }

    // A notice that has no image of its own gets the college cover image
    // as its background (this college's own cover; for a notice shared
    // by another college, that college's cover).
    final ownCover = _ownCover;
    for (var i = 0; i < out.length; i++) {
      final n = out[i];
      if (n.imageUrl.startsWith('http')) continue;
      final fallback = n.isExternal ? n.sourceCoverUrl : ownCover;
      if (fallback.startsWith('http')) out[i] = n.withImage(fallback);
    }

    out.sort((a, b) {
      final r = a.priority.compareTo(b.priority);
      return r != 0 ? r : b.sortTime.compareTo(a.sortTime);
    });
    return out;
  }

  Widget _headerIconButton({
    required IconData icon,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
    bool active = false,
    int badge = 0,
    bool dot = false,
    String? semanticLabel,
  }) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: Material(
        color: active ? _tan.withValues(alpha: .22) : Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(icon, color: _tan, size: 22),
                if (dot)
                  Positioned(
                    right: -2,
                    top: -2,
                    child: Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF5252),
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: const Color(0xFF1B120A), width: 1.2),
                      ),
                    ),
                  ),
                if (badge > 0)
                  Positioned(
                    right: -6,
                    top: -6,
                    child: Container(
                      constraints:
                          const BoxConstraints(minWidth: 15, minHeight: 15),
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        color: const Color(0xFF8B4513),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Center(
                        child: Text(
                          '$badge',
                          style: const TextStyle(
                            color: Color(0xFFFFE9B0),
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final all = _collect(context);

    // Notices the member hid (shown by long-pressing the eye).
    final hiddenItems = all.where((n) => _hidden.contains(n.key)).toList();

    // One-time notices: unseen ones show now; ones already shown during
    // this visit stay until the member leaves the home page.
    final visible = !_seenLoaded
        ? <_Notice>[]
        : all.where((n) {
            if (_hidden.contains(n.key)) return false;
            final k = n.onceKey;
            if (k == null) return true;
            return _session.contains(k) || !_seen.contains(k);
          }).toList();

    final fresh = <String>[
      for (final n in visible)
        if (n.onceKey != null && !_session.contains(n.onceKey)) n.onceKey!,
    ];
    if (fresh.isNotEmpty) {
      _session.addAll(fresh);
      WidgetsBinding.instance.addPostFrameCallback((_) => _markSeen(fresh));
    }

    // Nothing left to look at in the hidden list -> back to the board.
    if (_showHidden && hiddenItems.isEmpty) _showHidden = false;

    final items = _showHidden ? hiddenItems : visible;
    _itemCount = items.length;
    final canPost = _canPost;

    // New notice from another college that the member has not looked at.
    final otherHasNew = _seenLoaded &&
        !_showOthers &&
        _otherKeys().any((k) => !_seen.contains(k));
    // Other notices are on screen -> they count as seen (also new ones
    // that arrive while the member is looking).
    if (_showOthers) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _showOthers) _markOthersSeen();
      });
    }
    // Always there in a college community (even when nothing is shared).
    final showOthersIcon = _isCollege;

    if (items.isEmpty &&
        hiddenItems.isEmpty &&
        !canPost &&
        !showOthersIcon) {
      return const SizedBox.shrink();
    }

    // "Other" icon was just turned on -> jump to the first other
    // college notice.
    if (_jumpToOthers) {
      _jumpToOthers = false;
      final idx = items.indexWhere((n) => n.isExternal);
      final target = idx < 0 ? 0 : idx;
      _page = target;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_pager.hasClients) _pager.jumpToPage(target);
      });
    }

    // Keep the page index valid when notices disappear.
    final current = items.isEmpty ? 0 : _page.clamp(0, items.length - 1);
    if (current != _page) {
      _page = current;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_pager.hasClients) _pager.jumpToPage(current);
      });
    }

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 20, right: 12),
            child: Row(
              children: [
                Icon(
                  _showHidden
                      ? Icons.visibility_off_rounded
                      : Icons.push_pin_rounded,
                  color: _tan,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    _showHidden ? 'Hidden Notices' : 'Notice Board',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFF8B4513).withValues(alpha: .45),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${items.length}',
                    style: const TextStyle(
                      color: Color(0xFFFFE9B0),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const Spacer(),
                // Eye: tap = hide the visible notices,
                //      long-press = show the hidden ones.
                _headerIconButton(
                  icon: _showHidden
                      ? Icons.visibility_rounded
                      : Icons.visibility_outlined,
                  active: _showHidden,
                  badge: _showHidden ? 0 : hiddenItems.length,
                  semanticLabel:
                      'Tap to hide notices, press and hold to show hidden notices',
                  onTap: () => _onEyeTap(visible),
                  onLongPress: () => _onEyeLongPress(hiddenItems),
                ),
                // Other colleges' notices: tap = show, tap again = hide.
                if (showOthersIcon)
                  _headerIconButton(
                    icon: _showOthers
                        ? Icons.school_rounded
                        : Icons.school_outlined,
                    active: _showOthers,
                    dot: otherHasNew,
                    semanticLabel: _showOthers
                        ? 'Hide notices from other colleges'
                        : 'Show notices from other colleges',
                    onTap: _onOthersTap,
                  ),
                if (canPost)
                  _headerIconButton(
                    icon: Icons.post_add_rounded,
                    semanticLabel: 'Post a notice',
                    onTap: _openPostSheet,
                  ),
              ],
            ),
          ),
          if (_showHidden)
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 2, 20, 0),
              child: Text(
                'Tap a hidden notice to bring it back.',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ),
          const SizedBox(height: 10),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: _isCollege
                  ? _CollegeCoverCard(
                      coverUrl: _ownCover,
                      logoUrl: (widget.community['logoUrl'] ?? '').toString(),
                      collegeName: ((widget.community['collegeName'] ?? '')
                                  .toString()
                                  .trim()
                                  .isNotEmpty
                              ? widget.community['collegeName']
                              : widget.community['name'] ?? '')
                          .toString(),
                      note: hiddenItems.isNotEmpty
                          ? 'All notices are hidden. Press and hold the eye to see them.'
                          : '',
                    )
                  : Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
                decoration: BoxDecoration(
                  color: const Color(0xFF1B120A),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: _tan.withValues(alpha: .25)),
                ),
                child: Text(
                  hiddenItems.isNotEmpty
                      ? 'All notices are hidden. Press and hold the eye to see them.'
                      : 'No notices right now.',
                  style: const TextStyle(color: Colors.white60, fontSize: 13),
                ),
              ),
            )
          else ...[
            // One card per page, full width (left edge to right edge of the
            // page content). Swipe sideways for the next notice.
            SizedBox(
              height: kNoticeBoardHeight,
              child: PageView.builder(
                key: ValueKey(_showHidden),
                controller: _pager,
                itemCount: items.length,
                onPageChanged: (i) {
                  setState(() => _page = i);
                  // Swiped by hand (or slid) -> wait a full interval again.
                  _startAuto();
                },
                itemBuilder: (context, i) {
                  final n = items[i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: _NoticeCard(
                      notice: n,
                      hiddenMode: _showHidden,
                      onOpen: () async {
                        // A hidden notice: tapping it brings it back.
                        if (_showHidden) {
                          _restore(n);
                          return;
                        }
                        await n.onTap();
                        // Opened it -> a one-time notice is done.
                        final k = n.onceKey;
                        if (k != null && mounted) {
                          setState(() {
                            _seen.add(k);
                            _session.remove(k);
                          });
                        }
                      },
                    ),
                  );
                },
              ),
            ),
            if (items.length > 1) ...[
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < items.length; i++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      width: i == current ? 16 : 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: i == current ? _tan : Colors.white24,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _NoticeCard extends StatelessWidget {
  final _Notice notice;
  final VoidCallback onOpen;

  /// True while the hidden notices are listed (tap = restore).
  final bool hiddenMode;

  const _NoticeCard({
    required this.notice,
    required this.onOpen,
    this.hiddenMode = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = notice.color;
    final hasImage = notice.imageUrl.startsWith('http');

    return GestureDetector(
      onTap: onOpen,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1B120A),
          borderRadius: BorderRadius.circular(18),
        ),
        // Border is painted ABOVE the cover image, so the image can
        // never cover it and the line stays even on all four sides.
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: c.withValues(alpha: .75), width: 1.5),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Cover image (when the post / event has one).
            if (hasImage && notice.coverBg)
              _SoftCoverImage(url: notice.imageUrl)
            else if (hasImage)
              Image.network(
                notice.imageUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),

            // Shade so the text is readable on top of the image.
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: hasImage
                        ? [
                            Colors.black.withValues(
                                alpha: notice.coverBg ? .45 : .20),
                            Colors.black.withValues(
                                alpha: notice.coverBg ? .90 : .88),
                          ]
                        : [
                            c.withValues(alpha: .14),
                            Colors.transparent,
                          ],
                  ),
                ),
              ),
            ),

            if (notice.isVideo)
              const Center(
                child: Icon(Icons.play_circle_fill_rounded,
                    color: Colors.white70, size: 54),
              ),

            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: .55),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: c.withValues(alpha: .8)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(notice.icon, color: c, size: 14),
                        const SizedBox(width: 6),
                        Text(
                          notice.label,
                          style: TextStyle(
                            color: c,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: .6,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  Text(
                    notice.title,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      height: 1.25,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    notice.subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  // Another college's notice: college name + location.
                  if (notice.sourceLine.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        const Icon(Icons.school_rounded,
                            color: _tan, size: 14),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            notice.sourceLine,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xFFFFE9B0),
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),

            // Another college's notice: that college's profile image,
            // top-right corner.
            if (notice.isExternal)
              Positioned(
                top: 12,
                right: 12,
                child: _CollegeLogo(url: notice.sourceLogoUrl),
              ),

            if (hiddenMode)
              Positioned(
                top: 14,
                right: notice.isExternal ? 62 : 14,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: .65),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: _tan.withValues(alpha: .8)),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.visibility_rounded, color: _tan, size: 13),
                      SizedBox(width: 5),
                      Text(
                        'TAP TO RESTORE',
                        style: TextStyle(
                          color: _tan,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: .5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// College cover image drawn with LOW contrast (flatter, darker) so the
/// card text and logo are easy to read on top of it.
class _SoftCoverImage extends StatelessWidget {
  final String url;
  const _SoftCoverImage({required this.url});

  // Contrast 0.55 (+ a little less brightness), and slightly desaturated.
  static const List<double> _matrix = <double>[
    0.50, 0.12, 0.02, 0, 40, //
    0.06, 0.55, 0.02, 0, 40, //
    0.06, 0.12, 0.46, 0, 40, //
    0, 0, 0, 1, 0,
  ];

  @override
  Widget build(BuildContext context) {
    return ColorFiltered(
      colorFilter: const ColorFilter.matrix(_matrix),
      child: Image.network(
        url,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      ),
    );
  }
}

/// Shown on the board when there is no notice (college communities):
/// the college cover image, the college profile image (round, centre)
/// and the institution name under it.
class _CollegeCoverCard extends StatelessWidget {
  final String coverUrl;
  final String logoUrl;
  final String collegeName;
  final String note;

  const _CollegeCoverCard({
    required this.coverUrl,
    required this.logoUrl,
    required this.collegeName,
    this.note = '',
  });

  @override
  Widget build(BuildContext context) {
    final hasCover = coverUrl.startsWith('http');
    final hasLogo = logoUrl.startsWith('http');
    return Container(
      height: kNoticeBoardHeight,
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF1B120A),
        borderRadius: BorderRadius.circular(18),
      ),
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _tan.withValues(alpha: .6), width: 1.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (hasCover) _SoftCoverImage(url: coverUrl),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: hasCover
                    ? [
                        Colors.black.withValues(alpha: .50),
                        Colors.black.withValues(alpha: .86),
                      ]
                    : [
                        _tan.withValues(alpha: .10),
                        Colors.transparent,
                      ],
              ),
            ),
          ),
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 76,
                    height: 76,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFF2A1B0E),
                      border: Border.all(color: _tan, width: 2),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: .5),
                          blurRadius: 10,
                        ),
                      ],
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: hasLogo
                        ? Image.network(
                            logoUrl,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => const Icon(
                                Icons.school_rounded,
                                color: _tan,
                                size: 34),
                          )
                        : const Icon(Icons.school_rounded,
                            color: _tan, size: 34),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    collegeName,
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      shadows: [Shadow(color: Colors.black87, blurRadius: 6)],
                    ),
                  ),
                  if (note.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      note,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 11.5),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Round profile image of the college that posted a shared notice.
class _CollegeLogo extends StatelessWidget {
  final String url;
  const _CollegeLogo({required this.url});

  @override
  Widget build(BuildContext context) {
    const size = 40.0;
    Widget fallback() => const Center(
          child: Icon(Icons.school_rounded, color: _tan, size: 22),
        );
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFF1B120A),
        border: Border.all(color: _tan.withValues(alpha: .9), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .45),
            blurRadius: 6,
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: url.startsWith('http')
          ? Image.network(
              url,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => fallback(),
            )
          : fallback(),
    );
  }
}

// ================================================================
// NOTICE POST DETAIL (opened by tapping a notice post)
// ================================================================
class _NoticePostSheet extends StatelessWidget {
  final Map<String, dynamic> post;
  /// True only for the member who posted it (edit + delete shown).
  final bool isAuthor;
  final VoidCallback onEdit;
  final Future<void> Function() onDelete;

  const _NoticePostSheet({
    required this.post,
    required this.isAuthor,
    required this.onEdit,
    required this.onDelete,
  });

  Future<void> _play(BuildContext context, String url) async {
    try {
      final ok =
          await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      if (!ok && context.mounted) {
        showTopAlert(context, 'Couldn\'t open this video.', isError: true);
      }
    } catch (_) {
      if (context.mounted) {
        showTopAlert(context, 'Couldn\'t open this video.', isError: true);
      }
    }
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1B120A),
        title: const Text('Delete notice?',
            style: TextStyle(color: Colors.white)),
        content: const Text('It will be removed for everyone.',
            style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child:
                const Text('Delete', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await onDelete();
      if (!context.mounted) return;
      Navigator.of(context).pop();
      showTopAlert(context, 'Notice deleted');
    } catch (e) {
      if (!context.mounted) return;
      showTopAlert(context, e.toString().replaceFirst('Exception: ', ''),
          isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = (post['title'] ?? '').toString().trim();
    final text = (post['text'] ?? '').toString().trim();
    final mediaUrl = (post['mediaUrl'] ?? '').toString();
    final mediaType = (post['mediaType'] ?? '').toString();
    final author = (post['authorName'] ?? '').toString().trim();
    final end = NoticePostService.endOf(post);
    final thumb = mediaType == 'video'
        ? CommunityMediaService.videoThumbnailUrl(mediaUrl)
        : '';

    return Container(
      constraints:
          BoxConstraints(maxHeight: MediaQuery.of(context).size.height * .9),
      decoration: const BoxDecoration(
        color: Color(0xFF1B120A),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (title.isNotEmpty)
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              if (mediaType == 'image' && mediaUrl.startsWith('http')) ...[
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Image.network(
                    mediaUrl,
                    fit: BoxFit.cover,
                    width: double.infinity,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
              ],
              if (mediaType == 'video' && mediaUrl.startsWith('http')) ...[
                const SizedBox(height: 12),
                GestureDetector(
                  onTap: () => _play(context, mediaUrl),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      height: 200,
                      width: double.infinity,
                      color: const Color(0xFF120C07),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (thumb.isNotEmpty)
                            Image.network(
                              thumb,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) =>
                                  const SizedBox.shrink(),
                            ),
                          const Center(
                            child: Icon(Icons.play_circle_fill_rounded,
                                color: Colors.white70, size: 60),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
              if (text.isNotEmpty) ...[
                const SizedBox(height: 14),
                SelectableText(
                  text,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 15, height: 1.4),
                ),
              ],
              const SizedBox(height: 16),
              if (author.isNotEmpty)
                _MetaRow(icon: Icons.person_outline_rounded, text: 'Posted by $author'),
              if (end != null)
                _MetaRow(
                    icon: Icons.schedule_rounded,
                    text: 'Ends ${communityFormatDateTime(end)}'),
              _MetaRow(
                  icon: Icons.groups_2_outlined,
                  text: 'For: ${NoticePostService.audienceSummary(post)}'),
              if (isAuthor) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          onEdit();
                          Navigator.of(context).pop();
                        },
                        icon: const Icon(Icons.edit_rounded,
                            color: _tan, size: 18),
                        label: const Text('Edit notice',
                            style: TextStyle(color: _tan)),
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(color: _tan.withValues(alpha: .6)),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _confirmDelete(context),
                        icon: const Icon(Icons.delete_outline_rounded,
                            color: Colors.redAccent, size: 18),
                        label: const Text('Delete notice',
                            style: TextStyle(color: Colors.redAccent)),
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(
                              color: Colors.redAccent.withValues(alpha: .6)),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  final IconData icon;
  final String text;
  const _MetaRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: _tan, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: Colors.white70, fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }
}