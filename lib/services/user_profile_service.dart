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
  // CREATE USER PROFILE
  // ==========================================================

  static Future<String> createUserProfile({
    required User user,
  }) async {
    final userRef = _firestore
        .collection('users')
        .doc(user.uid);

    final existing = await userRef.get();

    // ========================================================
    // PROFILE ALREADY EXISTS
    // ========================================================

    if (existing.exists) {
      final data = existing.data();

      if (data != null &&
          data['userId'] != null &&
          data['userId'].toString().isNotEmpty) {
        return data['userId'].toString();
      }

      // Existing profile but userId missing
      final newUserId = await _generateUniqueUserId();

      await userRef.update({
        'userId': newUserId,
      });

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
}