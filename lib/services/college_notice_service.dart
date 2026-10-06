import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

// ================================================================
// COLLEGE NOTICE SERVICE  ("Show to all College")
// ----------------------------------------------------------------
// Announcements ('announcements'), Events ('communityEvents') and
// Notice Board posts ('noticePosts') can carry
//
//     showToAllColleges: true
//
// Every OTHER college community streams those items here and lists
// them on its own Notice Board, together with the college name and
// location of the community that posted them.
//
// Each emitted item looks like:
//   {
//     'kind':     'announcement' | 'event' | 'notice',
//     'id':       <doc id>,
//     'sourceId': <communityDocId that posted it>,
//     'data':     <the original document, plus 'id'>,
//     'source':   { name, logoUrl, coverUrl, collegeName, location,
//                   locationLink, communityId },
//   }
//
// Only items from communities of type 'college' are emitted.
// NOTE: the Firestore rules must allow signed-in users to read these
// three collections (queried by showToAllColleges == true) and the
// 'communities' documents.
// ================================================================
class CollegeNoticeService {
  CollegeNoticeService._();

  static const String field = 'showToAllColleges';

  /// A shared announcement stays on other boards this long.
  static const int announcementDays = 7;

  static final FirebaseFirestore _fs = FirebaseFirestore.instance;

  // ---- tiny cache of source communities (name / logo / college) ----
  static final Map<String, _CachedCommunity> _cache = {};
  static const Duration _cacheTtl = Duration(minutes: 2);

  static Future<Map<String, dynamic>?> _community(String id) async {
    final hit = _cache[id];
    if (hit != null && DateTime.now().difference(hit.at) < _cacheTtl) {
      return hit.data;
    }
    try {
      final snap = await _fs.collection('communities').doc(id).get();
      final data = snap.exists ? <String, dynamic>{...?snap.data()} : null;
      _cache[id] = _CachedCommunity(data, DateTime.now());
      return data;
    } catch (e) {
      debugPrint('College notice: community read failed: $e');
      return null;
    }
  }

  static DateTime? _dt(dynamic v) => v is Timestamp ? v.toDate() : null;

  /// Whether a shared item should still be on the board right now.
  static bool isLive(Map<String, dynamic> item, DateTime now) {
    final kind = (item['kind'] ?? '').toString();
    final d = item['data'] is Map
        ? Map<String, dynamic>.from(item['data'] as Map)
        : <String, dynamic>{};

    switch (kind) {
      case 'announcement':
        if (d['isScheduled'] == true) {
          final at = _dt(d['scheduledFor']);
          if (at == null || at.isAfter(now)) return false;
        }
        final created = _dt(d['publishedAt']) ?? _dt(d['createdAt']);
        if (created == null) return true; // just written
        return now.difference(created) < const Duration(days: announcementDays);
      case 'event':
        if (d['cancelled'] == true) return false;
        final end = _dt(d['endAt']);
        return end != null && now.isBefore(end);
      case 'notice':
        final end = _dt(d['endAt']);
        return end != null && now.isBefore(end);
    }
    return false;
  }

  /// Live list of everything other colleges shared.
  static Stream<List<Map<String, dynamic>>> watchShared({
    required String excludeCommunityDocId,
  }) {
    late final StreamController<List<Map<String, dynamic>>> ctrl;
    final subs = <StreamSubscription<dynamic>>[];

    var announcements = <Map<String, dynamic>>[];
    var events = <Map<String, dynamic>>[];
    var notices = <Map<String, dynamic>>[];
    var version = 0;

    Future<void> emit() async {
      final mine = ++version;
      final now = DateTime.now();

      final raw = <Map<String, dynamic>>[];
      void add(String kind, List<Map<String, dynamic>> docs) {
        for (final d in docs) {
          final sid = (d['communityDocId'] ?? '').toString();
          if (sid.isEmpty || sid == excludeCommunityDocId) continue;
          final item = <String, dynamic>{
            'kind': kind,
            'id': (d['id'] ?? '').toString(),
            'sourceId': sid,
            'data': d,
          };
          if (isLive(item, now)) raw.add(item);
        }
      }

      add('announcement', announcements);
      add('event', events);
      add('notice', notices);

      final ids = raw.map((r) => r['sourceId'].toString()).toSet();
      final infos = <String, Map<String, dynamic>?>{};
      await Future.wait(ids.map((id) async => infos[id] = await _community(id)));

      // A newer snapshot arrived while we were reading communities.
      if (ctrl.isClosed || mine != version) return;

      final out = <Map<String, dynamic>>[];
      for (final r in raw) {
        final info = infos[r['sourceId']];
        if (info == null) continue;
        if ((info['type'] ?? '').toString() != 'college') continue;
        out.add({
          ...r,
          'source': {
            'name': (info['name'] ?? '').toString(),
            'logoUrl': (info['logoUrl'] ?? '').toString(),
            'coverUrl': (info['coverUrl'] ?? '').toString(),
            'collegeName': (info['collegeName'] ?? '').toString(),
            'location': (info['location'] ?? '').toString(),
            'locationLink': (info['locationLink'] ?? '').toString(),
            'communityId': (info['communityId'] ?? '').toString(),
          },
        });
      }
      ctrl.add(out);
    }

    void listen(
      String collection,
      void Function(List<Map<String, dynamic>>) store,
    ) {
      subs.add(
        _fs
            .collection(collection)
            .where(field, isEqualTo: true)
            .snapshots()
            .listen(
          (snap) {
            store(snap.docs.map((d) => {...d.data(), 'id': d.id}).toList());
            emit();
          },
          onError: (Object e) =>
              debugPrint('College notice ($collection) error: $e'),
        ),
      );
    }

    ctrl = StreamController<List<Map<String, dynamic>>>(
      onListen: () {
        listen('announcements', (l) => announcements = l);
        listen('communityEvents', (l) => events = l);
        listen('noticePosts', (l) => notices = l);
      },
      onCancel: () async {
        for (final s in subs) {
          await s.cancel();
        }
      },
    );
    return ctrl.stream;
  }
}

class _CachedCommunity {
  final Map<String, dynamic>? data;
  final DateTime at;
  const _CachedCommunity(this.data, this.at);
}
