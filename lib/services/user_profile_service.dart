import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class UserProfileService {
  static final FirebaseFirestore _firestore =
      FirebaseFirestore.instance;

  static final FirebaseAuth _auth =
      FirebaseAuth.instance;

  // ==========================================================
  // ACCOUNT ID  ==  PUBLIC NAME
  // ----------------------------------------------------------
  // The Account ID is no longer randomly generated. It is the
  // user's PUBLIC NAME (stored in `users/{uid}.publicName` and
  // mirrored into `users/{uid}.userId` so every existing feature
  // that reads `userId` keeps working).
  //
  // Public name rules (so it is a usable, unique ID):
  //   * compulsory -- an account has no Account ID until it is set
  //   * 4 to 30 characters, no spaces
  //   * must contain AT LEAST 2 of these 3 kinds of characters:
  //       - letters           (a-z, A-Z)
  //       - numbers           (0-9)
  //       - special characters (@ # $ % _ . - etc.)
  //   * unique (case-insensitive) across all accounts
  // ==========================================================

  static const int minPublicNameLength = 4;
  static const int maxPublicNameLength = 30;

  static final RegExp _letterRe = RegExp(r'[A-Za-z]');
  static final RegExp _digitRe = RegExp(r'[0-9]');
  static final RegExp _specialRe = RegExp(r'[^A-Za-z0-9\s]');

  /// Returns null when [name] is valid, otherwise a short message
  /// that can be shown to the user.
  static String? validatePublicName(String name) {
    final value = name.trim();

    if (value.isEmpty) {
      return 'Public name is required.';
    }

    if (RegExp(r'\s').hasMatch(value)) {
      return 'Spaces are not allowed.';
    }

    if (value.length < minPublicNameLength) {
      return 'Use at least $minPublicNameLength characters.';
    }

    if (value.length > maxPublicNameLength) {
      return 'Use at most $maxPublicNameLength characters.';
    }

    final kinds = (_letterRe.hasMatch(value) ? 1 : 0) +
        (_digitRe.hasMatch(value) ? 1 : 0) +
        (_specialRe.hasMatch(value) ? 1 : 0);

    if (kinds < 2) {
      return 'Mix at least 2 of: letters, numbers, special characters.';
    }

    return null;
  }

  /// True when another account already uses [name] as its Account ID.
  static Future<bool> isAccountIdTaken(
    String name, {
    String? exceptUid,
  }) async {
    final value = name.trim();
    final lower = value.toLowerCase();

    Future<bool> check(String field, String wanted) async {
      final q = await _firestore
          .collection('users')
          .where(field, isEqualTo: wanted)
          .limit(5)
          .get();
      return q.docs.any((d) => d.id != exceptUid);
    }

    if (await check('userId', value)) return true;
    if (await check('userIdLower', lower)) return true;
    return false;
  }

  /// Saves [name] as the public name AND the Account ID in one write.
  /// Throws a [String] message (validation / "already taken") that the
  /// UI can show directly.
  static Future<void> setPublicNameAsAccountId(String name) async {
    final user = _auth.currentUser;

    if (user == null) {
      throw 'Please sign in again.';
    }

    final value = name.trim();

    final error = validatePublicName(value);
    if (error != null) throw error;

    if (await isAccountIdTaken(value, exceptUid: user.uid)) {
      throw 'This name is already taken. Try another one.';
    }

    await _firestore.collection('users').doc(user.uid).update({
      'publicName': value,
      'userId': value,
      'userIdLower': value.toLowerCase(),
    });
  }

  /// True when this profile still needs the (compulsory) public name:
  /// no public name yet, or an old profile whose Account ID is still
  /// the previous random one and not its public name.
  static bool needsPublicName(Map<String, dynamic>? data) {
    if (data == null) return true;
    final publicName = (data['publicName'] ?? '').toString().trim();
    final userId = (data['userId'] ?? '').toString().trim();
    if (publicName.isEmpty) return true;
    if (validatePublicName(publicName) != null) return true;
    return userId != publicName;
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

      // Existing profile but userId missing. The Account ID is the
      // public name now, so there is nothing to generate: copy the
      // public name if it is already set and valid, else leave empty
      // (the app asks for the public name right after login).
      final existingName = (data?['publicName'] ?? '').toString().trim();
      final canUse = existingName.isNotEmpty &&
          validatePublicName(existingName) == null &&
          !await isAccountIdTaken(existingName, exceptUid: user.uid);

      final updates = <String, dynamic>{
        'userId': canUse ? existingName : '',
        if (canUse) 'userIdLower': existingName.toLowerCase(),
      };
      if (data == null ||
          data['provider'] == null ||
          data['provider'].toString().isEmpty) {
        updates['provider'] = provider;
      }

      await userRef.update(updates);

      return updates['userId'].toString();
    }

    // ========================================================
    // NEW USER
    // ========================================================

    await userRef.set({
      'uid': user.uid,

      // Account ID == public name. Empty until the user picks their
      // (compulsory) public name.
      'userId': '',
      'userIdLower': '',
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

    return '';
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
    // Public name is also the Account ID, so it goes through the
    // validated + unique-checked path.
    await setPublicNameAsAccountId(name);
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
      // Public name == Account ID: validate, check uniqueness, and
      // keep `userId` in sync.
      await setPublicNameAsAccountId(name);
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