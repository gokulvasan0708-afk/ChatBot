import 'package:cloud_firestore/cloud_firestore.dart';

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

  Future<void> linkAccounts(String firstUid, String secondUid) async {
    if (firstUid.isEmpty || secondUid.isEmpty || firstUid == secondUid) return;

    final first = await _db.collection('users').doc(firstUid).get();
    final second = await _db.collection('users').doc(secondUid).get();
    final firstData = first.data() ?? {};
    final secondData = second.data() ?? {};

    final batch = _db.batch();
    batch.set(
      _accounts(firstUid).doc(secondUid),
      _metadata(secondUid, secondData),
      SetOptions(merge: true),
    );
    batch.set(
      _accounts(secondUid).doc(firstUid),
      _metadata(firstUid, firstData),
      SetOptions(merge: true),
    );
    await batch.commit();
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