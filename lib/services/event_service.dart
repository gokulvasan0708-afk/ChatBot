import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';

import 'community_member_profile_service.dart';

// ================================================================
// EVENT SERVICE  (Community spec — Section 5)
// ----------------------------------------------------------------
// Same architecture as ClubService/AnnouncementService: one
// top-level 'communityEvents' collection, every event scoped to a
// communityDocId, direct client-side Firestore writes, uid arrays
// for RSVP state ('going' / 'interested').
//
// STATUS is never stored as a fixed string that can go stale --
// it's derived on read from startAt/endAt vs "now" (statusFor
// below), with a single 'cancelled' flag as the only override an
// organizer can set. That also gives "Completed" events for free
// once their end time passes, which is what spec section 5's
// "after an event ends, allow it to become archived while
// preserving its information" asks for: nothing is ever deleted,
// completed events just stop showing under Upcoming/Live.
//
// CHECK-IN: the spec asks for "QR-based event attendance where
// practical". This project has no QR-scanning package in its
// pubspec yet, so rather than add a new dependency for one screen,
// attendance uses the same idea in a camera-free form: the
// organizer is shown a short check-in code (regenerable), and a
// participant who RSVP'd "Going" marks themselves present by
// entering that code. The code could be rendered as an actual QR
// image and scanned later without changing this data model at all.
// ================================================================
class EventService {
  EventService._();

  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  static CollectionReference<Map<String, dynamic>> get _events =>
      _firestore.collection('communityEvents');

  static final Random _random = Random();

  // ==========================================================
  // CREATE
  // ==========================================================

  static Future<String> createEvent({
    required String communityDocId,
    required String title,
    required String description,
    required String coverImageUrl,
    required String category,
    required bool isOnline,
    required String location,
    required String onlineLink,
    required DateTime startAt,
    required DateTime endAt,
    required int maxParticipants, // 0 = unlimited
    required String organizerUid,
    required String organizerName,
    required String organizerAvatarUrl,
    // "Show to all College": also listed on other colleges' Notice Boards.
    bool showToAllColleges = false,
    // Offline events only: optional map / location link.
    String locationLink = '',
  }) async {
    final trimmedTitle = title.trim();
    if (trimmedTitle.isEmpty) {
      throw Exception('Event title is required');
    }
    if (!endAt.isAfter(startAt)) {
      throw Exception('End time must be after start time');
    }

    final ref = _events.doc();
    await ref.set({
      'communityDocId': communityDocId,
      'title': trimmedTitle,
      'description': description.trim(),
      'coverImageUrl': coverImageUrl,
      'category': category.trim(),
      'isOnline': isOnline,
      'location': isOnline ? '' : location.trim(),
      'locationLink': isOnline ? '' : locationLink.trim(),
      'onlineLink': isOnline ? onlineLink.trim() : '',
      'startAt': Timestamp.fromDate(startAt),
      'endAt': Timestamp.fromDate(endAt),
      'maxParticipants': maxParticipants < 0 ? 0 : maxParticipants,
      'organizerUid': organizerUid,
      'organizerName': organizerName,
      'organizerAvatarUrl': organizerAvatarUrl,
      'goingUids': <String>[],
      'interestedUids': <String>[],
      'remindUids': <String>[],
      'checkedInUids': <String>[],
      'checkInCode': _newCheckInCode(),
      'cancelled': false,
      'showToAllColleges': showToAllColleges,
      'createdAt': FieldValue.serverTimestamp(),
    });
    return ref.id;
  }

  static String _newCheckInCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    return List.generate(6, (_) => chars[_random.nextInt(chars.length)]).join();
  }

  // ==========================================================
  // READ
  // ==========================================================

  static Stream<List<Map<String, dynamic>>> watchEvents(String communityDocId) {
    return _events
        .where('communityDocId', isEqualTo: communityDocId)
        .snapshots()
        .map((snap) {
      final list = snap.docs.map((d) => {...d.data(), 'id': d.id}).toList();
      int ms(dynamic v) => v is Timestamp ? v.millisecondsSinceEpoch : 0;
      list.sort((a, b) => ms(a['startAt']).compareTo(ms(b['startAt'])));
      return list;
    });
  }

  static Stream<DocumentSnapshot<Map<String, dynamic>>> watchEvent(String eventDocId) {
    return _events.doc(eventDocId).snapshots();
  }

  /// Upcoming, Live, Completed or Cancelled -- derived, never stored
  /// (see file header). Anything already 'cancelled' short-circuits.
  static String statusFor(Map<String, dynamic> event) {
    if (event['cancelled'] == true) return 'cancelled';
    final start = (event['startAt'] as Timestamp?)?.toDate();
    final end = (event['endAt'] as Timestamp?)?.toDate();
    if (start == null || end == null) return 'upcoming';

    final now = DateTime.now();
    if (now.isBefore(start)) return 'upcoming';
    if (now.isAfter(end)) return 'completed';
    return 'live';
  }

  static bool isPast(Map<String, dynamic> event) {
    final status = statusFor(event);
    return status == 'completed' || status == 'cancelled';
  }

  // ==========================================================
  // RSVP
  // ==========================================================

  static Future<void> setInterested({
    required String eventDocId,
    required String uid,
    required bool interested,
  }) async {
    await _events.doc(eventDocId).update({
      'interestedUids': interested
          ? FieldValue.arrayUnion([uid])
          : FieldValue.arrayRemove([uid]),
    });
  }

  /// Throws if the event is full or already cancelled/completed.
  static Future<void> rsvpGoing({
    required String eventDocId,
    required String uid,
    required Map<String, dynamic> event,
  }) async {
    final status = statusFor(event);
    if (status == 'cancelled') throw Exception('This event was cancelled.');
    if (status == 'completed') throw Exception('This event has already ended.');

    final going = _asStringList(event['goingUids']);
    if (going.contains(uid)) return;

    final max = (event['maxParticipants'] is int) ? event['maxParticipants'] as int : 0;
    if (max > 0 && going.length >= max) {
      throw Exception('This event is full.');
    }

    await _events.doc(eventDocId).update({
      'goingUids': FieldValue.arrayUnion([uid]),
      'interestedUids': FieldValue.arrayRemove([uid]),
    });
  }

  static Future<void> cancelRsvp({
    required String eventDocId,
    required String uid,
  }) async {
    var profileId = '';
    try {
      final snap = await _events.doc(eventDocId).get();
      profileId = await CommunityMemberProfileService.currentProfileId(
          (snap.data()?['communityDocId'] ?? '').toString());
    } catch (_) {}
    await _events.doc(eventDocId).update({
      'goingUids': FieldValue.arrayRemove([uid]),
      'checkedInUids': FieldValue.arrayRemove([uid]),
      if (profileId.isNotEmpty)
        'checkedInProfileIds': FieldValue.arrayRemove([profileId]),
    });
  }

  static Future<void> setReminder({
    required String eventDocId,
    required String uid,
    required bool remind,
  }) async {
    await _events.doc(eventDocId).update({
      'remindUids':
          remind ? FieldValue.arrayUnion([uid]) : FieldValue.arrayRemove([uid]),
    });
  }

  // ==========================================================
  // CHECK-IN (camera-free stand-in for QR attendance -- see header)
  // ==========================================================

  static Future<void> checkIn({
    required String eventDocId,
    required String uid,
    required String enteredCode,
    required Map<String, dynamic> event,
  }) async {
    if (!_asStringList(event['goingUids']).contains(uid)) {
      throw Exception('RSVP as Going before checking in.');
    }
    final code = (event['checkInCode'] ?? '').toString();
    if (code.isEmpty || enteredCode.trim().toUpperCase() != code) {
      throw Exception('Incorrect check-in code.');
    }
    // Attendance is recorded for the PROFILE (Profile ID) that checked in,
    // so "Events attended" stays separate for each profile.
    final profileId = await CommunityMemberProfileService.currentProfileId(
        (event['communityDocId'] ?? '').toString());
    await _events.doc(eventDocId).update({
      'checkedInUids': FieldValue.arrayUnion([uid]),
      if (profileId.isNotEmpty)
        'checkedInProfileIds': FieldValue.arrayUnion([profileId]),
    });
  }

  static Future<void> regenerateCheckInCode({
    required String eventDocId,
    required String requesterUid,
    required Map<String, dynamic> event,
  }) async {
    _requireOrganizer(event, requesterUid);
    await _events.doc(eventDocId).update({'checkInCode': _newCheckInCode()});
  }

  // ==========================================================
  // ORGANIZER ACTIONS
  // ==========================================================

  static Future<void> cancelEvent({
    required String eventDocId,
    required String requesterUid,
    required Map<String, dynamic> event,
  }) async {
    _requireOrganizer(event, requesterUid);
    await _events.doc(eventDocId).update({'cancelled': true});
  }

  static Future<void> reopenEvent({
    required String eventDocId,
    required String requesterUid,
    required Map<String, dynamic> event,
  }) async {
    _requireOrganizer(event, requesterUid);
    await _events.doc(eventDocId).update({'cancelled': false});
  }

  static Future<void> deleteEvent({
    required String eventDocId,
    required String requesterUid,
    required Map<String, dynamic> event,
  }) async {
    _requireOrganizer(event, requesterUid);
    await _events.doc(eventDocId).delete();
  }

  static void _requireOrganizer(Map<String, dynamic> event, String uid) {
    if ((event['organizerUid'] ?? '').toString() != uid) {
      throw Exception('Only the organizer can do that.');
    }
  }

  // ==========================================================
  // HELPERS
  // ==========================================================

  static bool isGoing(Map<String, dynamic> event, String uid) =>
      _asStringList(event['goingUids']).contains(uid);

  static bool isInterested(Map<String, dynamic> event, String uid) =>
      _asStringList(event['interestedUids']).contains(uid);

  static bool isCheckedIn(Map<String, dynamic> event, String uid) =>
      _asStringList(event['checkedInUids']).contains(uid);

  static bool wantsReminder(Map<String, dynamic> event, String uid) =>
      _asStringList(event['remindUids']).contains(uid);

  static List<String> _asStringList(dynamic v) =>
      v is List ? List<String>.from(v) : <String>[];
}