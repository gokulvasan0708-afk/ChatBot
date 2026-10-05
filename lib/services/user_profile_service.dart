import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class UserProfileService {
  static final FirebaseFirestore _firestore =
      FirebaseFirestore.instance;

  static final FirebaseAuth _auth =
      FirebaseAuth.instance;

  static const String _characters =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
      'abcdefghijklmnopqrstuvwxyz'
      '0123456789'
      '@#\$%';

  // ==========================================================
  // GENERATE RANDOM 10 CHARACTER USER ID
  // ==========================================================

  static String _generateUserId() {
    final random = Random();

    return List.generate(
      10,
      (_) => _characters[random.nextInt(_characters.length)],
    ).join();
  }

  // ==========================================================
  // DETECT AUTH PROVIDER ('password' or 'google')
  // ==========================================================
  //
  // Firebase exposes every credential linked to a user via
  // `user.providerData` (each entry's `providerId` is e.g. 'password'
  // or 'google.com'). Checking that instead of storing/guessing
  // anything new is the smallest safe way to know, later, whether an
  // account can be switched to with a password or must be
  // re-authenticated through Google -- this is what the account
  // switcher (account_switch_service.dart / me_page.dart) reads to
  // pick the correct flow for a saved account.
  static String _detectProvider(User user) {
    final isGoogle = user.providerData.any(
      (info) => info.providerId == 'google.com',
    );
    return isGoogle ? 'google' : 'password';
  }

  // ==========================================================
  // CREATE USER PROFILE
  // ==========================================================

  static Future<String> createUserProfile({
    required User user,
  }) async {
    final userRef = _firestore
        .collection('users')
        .doc(user.uid);

    final existing = await userRef.get();
    final provider = _detectProvider(user);

    // ========================================================
    // PROFILE ALREADY EXISTS
    // ========================================================

    if (existing.exists) {
      final data = existing.data();

      if (data != null &&
    data['userId'] != null &&
    data['userId'].toString().isNotEmpty) {

  final updates = <String, dynamic>{};

  // Make sure old profiles also have Firebase UID
  if (data['uid'] == null ||
      data['uid'].toString().isEmpty) {
    updates['uid'] = user.uid;
  }

  // Backfill provider for profiles created before this field
  // existed. Never overwrite a provider value that's already on
  // file -- it reflects how that account was actually created.
  if (data['provider'] == null ||
      data['provider'].toString().isEmpty) {
    updates['provider'] = provider;
  }

  if (updates.isNotEmpty) {
    await userRef.update(updates);
  }

  return data['userId'].toString();
}

      // Existing profile but userId missing
      final newUserId = await _generateUniqueUserId();

      final updates = <String, dynamic>{'userId': newUserId};
      if (data == null ||
          data['provider'] == null ||
          data['provider'].toString().isEmpty) {
        updates['provider'] = provider;
      }

      await userRef.update(updates);

      return newUserId;
    }

    // ========================================================
    // NEW USER
    // ========================================================

    final userId = await _generateUniqueUserId();

    await userRef.set({
      'uid': user.uid,
      'userId': userId,
      'email': user.email ?? '',

      // Auth provider this account was created/authenticated with --
      // read by the account switcher to choose password vs. Google
      // re-authentication when switching to this account.
      'provider': provider,

      // ======================================================
      // PUBLIC INFORMATION
      // ======================================================

      'publicName': '',
      'publicImage': '',

      // ======================================================
      // PRIVATE INFORMATION
      // ======================================================

      'privateName': '',
      'privateImage': '',
      'bio': '',

      // ======================================================
      // FRIENDS
      // ======================================================

      'friends': [],
      'membersCount': 0,

      // ======================================================
      // TIMESTAMP
      // ======================================================

      'createdAt': FieldValue.serverTimestamp(),
    });

    return userId;
  }

  // ==========================================================
  // GENERATE UNIQUE USER ID
  // ==========================================================

  static Future<String> _generateUniqueUserId() async {
    while (true) {
      final userId = _generateUserId();

      final query = await _firestore
          .collection('users')
          .where(
            'userId',
            isEqualTo: userId,
          )
          .limit(1)
          .get();

      if (query.docs.isEmpty) {
        return userId;
      }
    }
  }

  // ==========================================================
  // GET CURRENT USER PROFILE
  // ==========================================================

  static Future<Map<String, dynamic>?> getCurrentUserProfile() async {
    final user = _auth.currentUser;

    if (user == null) {
      return null;
    }

    final doc = await _firestore
        .collection('users')
        .doc(user.uid)
        .get();

    if (!doc.exists) {
      return null;
    }

    return doc.data();
  }

  // ==========================================================
  // UPDATE PUBLIC NAME
  // ==========================================================

  static Future<void> updatePublicName(String name) async {
    final user = _auth.currentUser;

    if (user == null) return;

    await _firestore
        .collection('users')
        .doc(user.uid)
        .update({
      'publicName': name.trim(),
    });
  }

  // ==========================================================
  // UPDATE PUBLIC IMAGE
  // ==========================================================

  static Future<void> updatePublicImage(String imageUrl) async {
    final user = _auth.currentUser;

    if (user == null) return;

    await _firestore
        .collection('users')
        .doc(user.uid)
        .update({
      'publicImage': imageUrl,
    });
  }

  // ==========================================================
  // UPDATE PRIVATE NAME
  // ==========================================================

  static Future<void> updatePrivateName(String name) async {
    final user = _auth.currentUser;

    if (user == null) return;

    await _firestore
        .collection('users')
        .doc(user.uid)
        .update({
      'privateName': name.trim(),
    });
  }

  // ==========================================================
  // UPDATE PRIVATE IMAGE
  // ==========================================================

  static Future<void> updatePrivateImage(String imageUrl) async {
    final user = _auth.currentUser;

    if (user == null) return;

    await _firestore
        .collection('users')
        .doc(user.uid)
        .update({
      'privateImage': imageUrl,
    });
  }

  // ==========================================================
  // UPDATE BIO
  // ==========================================================

  static Future<void> updateBio(String bio) async {
    final user = _auth.currentUser;

    if (user == null) return;

    await _firestore
        .collection('users')
        .doc(user.uid)
        .update({
      'bio': bio.trim(),
    });
  }

  // ==========================================================
  // UPDATE PUBLIC PROFILE
  // ==========================================================

  static Future<void> updatePublicProfile({
    String? name,
    String? imageUrl,
  }) async {
    final user = _auth.currentUser;

    if (user == null) return;

    final data = <String, dynamic>{};

    if (name != null) {
      data['publicName'] = name.trim();
    }

    if (imageUrl != null) {
      data['publicImage'] = imageUrl;
    }

    if (data.isEmpty) return;

    await _firestore
        .collection('users')
        .doc(user.uid)
        .update(data);
  }

  // ==========================================================
  // PUBLIC SKILLS  (Community Search -- Section 11)
  // ----------------------------------------------------------
  // A short, user-controlled list ("Flutter", "UI design") stored
  // on the user's own doc as 'publicSkills'. It is the ONLY profile
  // field Community Search reads besides the public name/image, so
  // nothing private is ever matched or shown.
  // ==========================================================

  static const int maxPublicSkills = 10;
  static const int maxPublicSkillLength = 30;

  /// Trims, strips '#', collapses spaces, removes duplicates
  /// (case-insensitive, first spelling wins) and applies the limits.
  static List<String> normalizeSkills(Iterable<String> raw) {
    final seen = <String>{};
    final out = <String>[];
    for (final item in raw) {
      var t = item.replaceAll('#', '').replaceAll(RegExp(r'\s+'), ' ').trim();
      if (t.isEmpty) continue;
      if (t.length > maxPublicSkillLength) {
        t = t.substring(0, maxPublicSkillLength).trim();
      }
      if (seen.add(t.toLowerCase())) out.add(t);
      if (out.length >= maxPublicSkills) break;
    }
    return out;
  }

  static Future<List<String>> getPublicSkills() async {
    final user = _auth.currentUser;

    if (user == null) return <String>[];

    final doc = await _firestore.collection('users').doc(user.uid).get();
    final raw = doc.data()?['publicSkills'];

    return raw is List
        ? normalizeSkills(raw.map((e) => e.toString()))
        : <String>[];
  }

  static Future<List<String>> updatePublicSkills(List<String> skills) async {
    final user = _auth.currentUser;

    if (user == null) {
      throw Exception('Please sign in again.');
    }

    final clean = normalizeSkills(skills);

    await _firestore.collection('users').doc(user.uid).update({
      'publicSkills': clean,
    });

    return clean;
  }
}