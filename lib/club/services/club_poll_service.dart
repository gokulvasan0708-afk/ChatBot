import 'package:cloud_firestore/cloud_firestore.dart';

import '../club_paths.dart';

class ClubPollService {
  ClubPollService._();
  static final _db = FirebaseFirestore.instance;

  static Stream<QuerySnapshot<Map<String,dynamic>>> watchPolls(String clubId) =>
      ClubPaths.club(clubId).collection('polls').orderBy('createdAt', descending: true).snapshots();

  static Future<String> createPoll({required String clubId, required String uid, required String question, required List<String> options}) async {
    final cleaned = options.map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    if (question.trim().isEmpty) throw Exception('Enter a poll question.');
    if (cleaned.length < 2) throw Exception('Add at least 2 options.');
    if (cleaned.length > 10) throw Exception('Maximum 10 options.');
    final ref = ClubPaths.club(clubId).collection('polls').doc();
    await ref.set({
      'question': question.trim(),
      'options': cleaned.map((text) => {'text': text, 'votes': 0}).toList(),
      'voters': <String>[],
      'totalVotes': 0,
      'createdBy': uid,
      'createdAt': FieldValue.serverTimestamp(),
      'closed': false,
    });
    return ref.id;
  }

  static Future<void> vote({required String clubId, required String pollId, required String uid, required int optionIndex}) async {
    final ref = ClubPaths.club(clubId).collection('polls').doc(pollId);
    await _db.runTransaction((tx) async {
      final snap = await tx.get(ref);
      final data = snap.data();
      if (data == null) throw Exception('Poll not found.');
      if (data['closed'] == true) throw Exception('This poll has ended.');
      final voters = List<String>.from(data['voters'] ?? const []);
      if (voters.contains(uid)) throw Exception('You already voted.');
      final options = (data['options'] as List? ?? const []).map((e) => Map<String,dynamic>.from(e as Map)).toList();
      if (optionIndex < 0 || optionIndex >= options.length) throw Exception('Invalid option.');
      options[optionIndex]['votes'] = ((options[optionIndex]['votes'] as num?)?.toInt() ?? 0) + 1;
      voters.add(uid);
      tx.update(ref, {'options': options, 'voters': voters, 'totalVotes': voters.length});
    });
  }

  static Future<void> closePoll({required String clubId, required String pollId}) =>
      ClubPaths.club(clubId).collection('polls').doc(pollId).update({'closed': true});
}
