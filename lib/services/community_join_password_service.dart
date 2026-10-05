import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

// ================================================================
// COMMUNITY JOIN PASSWORD
// ----------------------------------------------------------------
// A member PROFILE can set a password on its Community profile (under
// the name). Every profile has its own password -- an account that holds
// a Controller profile and a Student profile in the same community sets
// and changes them separately. It protects the identity the profile
// joined with:
//
//   * Student       -> the Register Number
//   * Principal / HOD / Faculty / Controller -> the name + role
//
// First join: no password is asked (nobody has set one yet).
// After a password is set, joining again with the same register
// number / name (the same person rejoining after leaving, or anybody
// else typing it) asks for that password first.
//
// Stored in  communities/{id}/joinLocks/{lockKey}  -- it stays there
// after the member leaves, which is what makes the rejoin check work.
//   kind       'reg' | 'name'
//   value      register number / name key (lower-case)
//   role       staff role ('' for students)
//   ownerProfileId  member profile (Profile ID) that owns the password
//   ownerUid   account of that profile (informational)
//   salt, hash salted + iterated SHA-256 (the password is never stored)
//   updatedAt
//
// Firestore rules: signed-in users need read + create/update on
// communities/{id}/joinLocks/{doc} (see the note in the reply).
// ================================================================

enum JoinLockStatus { none, needsPassword }

class CommunityJoinPasswordService {
  CommunityJoinPasswordService._();

  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  static const int minLength = 4;
  static const int _rounds = 3000;

  static CollectionReference<Map<String, dynamic>> _locks(String communityId) =>
      _firestore.collection('communities').doc(communityId).collection('joinLocks');

  // ---------------- keys ----------------

  static String _squash(String v) =>
      v.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  static String regKey(String registerNumber) =>
      'reg_${Uri.encodeComponent(_squash(registerNumber))}';

  static String nameKey(String role, String name) =>
      'name_${Uri.encodeComponent(role)}_${Uri.encodeComponent(_squash(name))}';

  // ---------------- hashing (pure Dart SHA-256) ----------------

  static String _newSalt() {
    final r = Random.secure();
    return base64UrlEncode(List<int>.generate(16, (_) => r.nextInt(256)));
  }

  static String _hash(String password, String salt) {
    var digest = _sha256(utf8.encode('$salt:$password'));
    for (var i = 0; i < _rounds; i++) {
      digest = _sha256([...digest, ...utf8.encode(salt)]);
    }
    return base64UrlEncode(digest);
  }

  static bool _matches(Map<String, dynamic> lock, String password) {
    final salt = (lock['salt'] ?? '').toString();
    final hash = (lock['hash'] ?? '').toString();
    if (salt.isEmpty || hash.isEmpty) return false;
    return _hash(password, salt) == hash;
  }

  // ---------------- join-time checks ----------------

  /// Is there a password on this identity?
  static Future<Map<String, dynamic>?> _lockFor(
      String communityId, String key) async {
    try {
      final doc = await _locks(communityId).doc(key).get();
      if (!doc.exists) return null;
      final d = doc.data();
      if (d == null || (d['hash'] ?? '').toString().isEmpty) return null;
      return d;
    } catch (_) {
      // rules / network: never block a join because the lock can't be read
      return null;
    }
  }

  static Future<JoinLockStatus> statusFor(
      String communityId, String key) async {
    return (await _lockFor(communityId, key)) == null
        ? JoinLockStatus.none
        : JoinLockStatus.needsPassword;
  }

  /// true when [password] opens the lock [key] (or there is no lock).
  static Future<bool> verify(
      String communityId, String key, String password) async {
    final lock = await _lockFor(communityId, key);
    if (lock == null) return true;
    return _matches(lock, password);
  }

  /// After a successful join with the password: the joining PROFILE
  /// becomes the owner of the lock (so it shows as "password set" on
  /// that profile).
  static Future<void> claim(
      String communityId, String key, String profileId) async {
    try {
      await _locks(communityId).doc(key).set({
        'ownerProfileId': profileId,
        'ownerUid': FirebaseAuth.instance.currentUser?.uid ?? '',
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {}
  }

  // ---------------- profile: set / change / remove ----------------

  static Future<Map<String, dynamic>?> _profile(
      String communityId, String profileId) async {
    if (profileId.isEmpty) return null;
    final d = await _firestore
        .collection('communities')
        .doc(communityId)
        .collection('memberProfiles')
        .doc(profileId)
        .get();
    return d.exists ? d.data() : null;
  }

  /// The identity of one PROFILE that can be protected: the register
  /// number of a Student profile, or the name + role of a staff profile.
  static List<Map<String, String>> _identitiesOf(Map<String, dynamic> p) {
    final out = <Map<String, String>>[];
    final role = (p['role'] ?? '').toString();

    final reg = (p['registerNumber'] ?? '').toString().trim();
    if (role == 'Student' && reg.isNotEmpty) {
      out.add({
        'key': regKey(reg),
        'kind': 'reg',
        'value': _squash(reg),
        'role': '',
      });
    }

    const staff = ['Principal', 'HOD', 'Faculty', 'Controller'];
    if (staff.contains(role)) {
      // The name matched when joining; the community creator's profile
      // has none, so its current profile name is used.
      var name = (p['identityName'] ?? '').toString();
      if (name.trim().isEmpty) name = (p['name'] ?? '').toString();
      if (name.trim().isNotEmpty) {
        out.add({
          'key': nameKey(role, name),
          'kind': 'name',
          'value': _squash(name),
          'role': role,
        });
      }
    }
    return out;
  }

  /// A lock belongs to this profile (locks made before Profile IDs only
  /// carry the account's uid).
  static bool _owns(
      Map<String, dynamic> lock, String profileId, String profileUid) {
    final owner = (lock['ownerProfileId'] ?? '').toString();
    if (owner.isNotEmpty) return owner == profileId;
    return (lock['ownerUid'] ?? '').toString() == profileUid;
  }

  /// Locks that belong to THIS profile only. A password belongs to one
  /// profile, not to the login account: the same account's other
  /// profiles (other roles) are never touched.
  static Future<List<DocumentSnapshot<Map<String, dynamic>>>> _mine(
      String communityId, String profileId) async {
    final p = await _profile(communityId, profileId);
    if (p == null) return [];
    final uid = (p['uid'] ?? '').toString();
    final out = <DocumentSnapshot<Map<String, dynamic>>>[];
    for (final i in _identitiesOf(p)) {
      try {
        final d = await _locks(communityId).doc(i['key']).get();
        final data = d.data();
        if (!d.exists || data == null) continue;
        if ((data['hash'] ?? '').toString().isEmpty) continue;
        if (_owns(data, profileId, uid)) out.add(d);
      } catch (_) {}
    }
    return out;
  }

  /// Does this profile have a join password?
  static Future<bool> hasPassword(String communityId, String profileId) async =>
      (await _mine(communityId, profileId)).isNotEmpty;

  /// Sets (first time) or changes the password of ONE profile. When one
  /// is already set, [currentPassword] must be right.
  static Future<void> setPassword({
    required String communityId,
    required String profileId,
    required String newPassword,
    String currentPassword = '',
  }) async {
    if (newPassword.length < minLength) {
      throw Exception('Password must be at least $minLength characters.');
    }

    final profile = await _profile(communityId, profileId);
    if (profile == null) throw Exception('This profile no longer exists.');
    final uid = (profile['uid'] ?? '').toString();
    if (uid != (FirebaseAuth.instance.currentUser?.uid ?? '')) {
      throw Exception('You can only change your own profile.');
    }

    final existing = await _mine(communityId, profileId);
    if (existing.isNotEmpty) {
      final ok = existing.any((d) => _matches(d.data()!, currentPassword));
      if (!ok) throw Exception('Current password is wrong.');
    }

    final identities = _identitiesOf(profile);
    if (identities.isEmpty) {
      throw Exception(
          'Set your name first (pencil icon on Name), then set a password.');
    }

    final salt = _newSalt();
    final hash = _hash(newPassword, salt);
    final batch = _firestore.batch();

    for (final i in identities) {
      batch.set(_locks(communityId).doc(i['key']), {
        'kind': i['kind'],
        'value': i['value'],
        'role': i['role'],
        'ownerProfileId': profileId,
        'ownerUid': uid,
        'salt': salt,
        'hash': hash,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }
    await batch.commit();
  }

  static Future<void> removePassword({
    required String communityId,
    required String profileId,
    required String currentPassword,
  }) async {
    final existing = await _mine(communityId, profileId);
    if (existing.isEmpty) return;
    if (!existing.any((d) => _matches(d.data()!, currentPassword))) {
      throw Exception('Current password is wrong.');
    }
    final batch = _firestore.batch();
    for (final d in existing) {
      batch.delete(d.reference);
    }
    await batch.commit();
  }
}

// ================================================================
// SHA-256 (no external package needed)
// ================================================================
const List<int> _k = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

List<int> _sha256(List<int> data) {
  const m = 0xFFFFFFFF;
  int rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & m;

  final h = <int>[
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ];

  final bitLen = data.length * 8;
  final padded = <int>[...data, 0x80];
  while (padded.length % 64 != 56) {
    padded.add(0);
  }
  for (var i = 7; i >= 0; i--) {
    padded.add((bitLen >> (i * 8)) & 0xFF);
  }

  final w = List<int>.filled(64, 0);
  for (var off = 0; off < padded.length; off += 64) {
    for (var i = 0; i < 16; i++) {
      final j = off + i * 4;
      w[i] = (padded[j] << 24) | (padded[j + 1] << 16) | (padded[j + 2] << 8) | padded[j + 3];
    }
    for (var i = 16; i < 64; i++) {
      final s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & m;
    }
    var a = h[0], b = h[1], c = h[2], d = h[3];
    var e = h[4], f = h[5], g = h[6], hh = h[7];
    for (var i = 0; i < 64; i++) {
      final s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      final ch = (e & f) ^ ((~e & m) & g);
      final t1 = (hh + s1 + ch + _k[i] + w[i]) & m;
      final s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & m;
      hh = g;
      g = f;
      f = e;
      e = (d + t1) & m;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & m;
    }
    h[0] = (h[0] + a) & m;
    h[1] = (h[1] + b) & m;
    h[2] = (h[2] + c) & m;
    h[3] = (h[3] + d) & m;
    h[4] = (h[4] + e) & m;
    h[5] = (h[5] + f) & m;
    h[6] = (h[6] + g) & m;
    h[7] = (h[7] + hh) & m;
  }

  final out = <int>[];
  for (final v in h) {
    out
      ..add((v >> 24) & 0xFF)
      ..add((v >> 16) & 0xFF)
      ..add((v >> 8) & 0xFF)
      ..add(v & 0xFF);
  }
  return out;
}