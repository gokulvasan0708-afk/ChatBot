import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Stores only account metadata for the device/account switcher.
/// Passwords are deliberately NOT stored in Firestore.
class AccountSwitchService {
  AccountSwitchService._();
  static final AccountSwitchService instance = AccountSwitchService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> _accounts(String uid) =>
      _db.collection('users').doc(uid).collection('switchAccounts');

  Stream<QuerySnapshot<Map<String, dynamic>>> watchAccounts(String uid) =>
      _accounts(uid).orderBy('addedAt', descending: true).snapshots();

  /// Links two accounts in the switcher.
  ///
  /// Firestore rules only let a signed-in user write inside their OWN
  /// `users/{uid}/switchAccounts`. The old version committed both sides
  /// in one atomic batch, so as soon as the second account was signed in
  /// the write into the first account's list was rejected
  /// (PERMISSION_DENIED) and the WHOLE batch -- including the allowed
  /// side -- failed, which surfaced as a login error. Now each side is
  /// written on its own: the signed-in user's own list always succeeds,
  /// and the other side is best-effort (it is normally already written
  /// by [preLinkByEmail] while that account was still signed in).
  /// This method never throws.
  Future<void> linkAccounts(String firstUid, String secondUid) async {
    if (firstUid.isEmpty || secondUid.isEmpty || firstUid == secondUid) return;

    Future<Map<String, dynamic>> read(String uid) async {
      try {
        final doc = await _db.collection('users').doc(uid).get();
        return doc.data() ?? {};
      } catch (e) {
        debugPrint('AccountSwitch: could not read users/$uid: $e');
        return {};
      }
    }

    final firstData = await read(firstUid);
    final secondData = await read(secondUid);

    Future<void> write(
        String owner, String other, Map<String, dynamic> otherData) async {
      try {
        await _accounts(owner)
            .doc(other)
            .set(_metadata(other, otherData), SetOptions(merge: true));
      } catch (e) {
        debugPrint('AccountSwitch: could not write '
            'users/$owner/switchAccounts/$other: $e');
      }
    }

    final me = FirebaseAuth.instance.currentUser?.uid;
    // Signed-in user's own list first (always permitted).
    if (me == secondUid) {
      await write(secondUid, firstUid, firstData);
      await write(firstUid, secondUid, secondData);
    } else {
      await write(firstUid, secondUid, secondData);
      await write(secondUid, firstUid, firstData);
    }
  }

  /// Call BEFORE signing in as the other account, while [ownerUid] is
  /// still the signed-in user: finds the account that owns [email] and
  /// writes it into [ownerUid]'s own switcher list (the one write the
  /// rules allow at that moment). Silent no-op if the account does not
  /// exist yet or the lookup fails.
  Future<void> preLinkByEmail(String ownerUid, String email) async {
    if (ownerUid.isEmpty || email.trim().isEmpty) return;
    if (FirebaseAuth.instance.currentUser?.uid != ownerUid) return;

    try {
      final snap = await _db
          .collection('users')
          .where('email', isEqualTo: email.trim())
          .limit(1)
          .get();
      if (snap.docs.isEmpty) return;

      final targetUid = (snap.docs.first.data()['uid'] ?? snap.docs.first.id)
          .toString();
      if (targetUid.isEmpty || targetUid == ownerUid) return;

      await _accounts(ownerUid)
          .doc(targetUid)
          .set(_metadata(targetUid, snap.docs.first.data()),
              SetOptions(merge: true));
    } catch (e) {
      debugPrint('AccountSwitch: preLinkByEmail skipped: $e');
    }
  }

  Map<String, dynamic> _metadata(String uid, Map<String, dynamic> data) => {
        'uid': uid,
        'email': (data['email'] ?? '').toString(),
        // Carries the target account's Firebase Auth provider ('password'
        // or 'google') into the switcher so Me Page can pick the correct
        // re-authentication flow for the account being switched to,
        // without having to guess or probe Firebase Auth at switch time.
        'provider': (data['provider'] ?? 'password').toString(),
        'publicName': (data['publicName'] ?? data['name'] ?? '').toString(),
        'privateName': (data['privateName'] ?? '').toString(),
        'publicImage': (data['publicImage'] ?? '').toString(),
        'privateImage': (data['privateImage'] ?? '').toString(),
        'addedAt': FieldValue.serverTimestamp(),
      };

  /// "Remove Account" -- unlinks [targetUid] from [ownerUid]'s own
  /// account-switching list only.
  ///
  /// This is deliberately one-directional and touches nothing but the
  /// metadata pointer: it deletes `users/{ownerUid}/switchAccounts/{targetUid}`
  /// and nothing else. It must NEVER touch `users/{targetUid}` (that
  /// account's own profile/data), the reciprocal
  /// `users/{targetUid}/switchAccounts/{ownerUid}` entry, or the target's
  /// Firebase Auth account -- removing an account from your own switcher
  /// has no effect on that account itself.
  Future<void> removeSavedAccount(String ownerUid, String targetUid) async {
    if (ownerUid.isEmpty || targetUid.isEmpty) return;
    await _accounts(ownerUid).doc(targetUid).delete();
  }
}