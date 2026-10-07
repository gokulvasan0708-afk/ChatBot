// import 'dart:convert';
// import 'package:http/http.dart' as http;

// class ApiService {
//   static const String baseUrl = 'https://chatbot-worker.gokulmi56cro.workers.dev';

//   static Future<Map<String, dynamic>> login(
//     String email,
//     String password,
//   ) async {
//     final response = await http.post(
//       Uri.parse('$baseUrl/api/login'),
//       headers: {
//         'Content-Type': 'application/json',
//       },
//       body: jsonEncode({
//         'email': email,
//         'password': password,
//       }),
//     );

//     return jsonDecode(response.body);
//   }

//   /// "Delete Account" (Account Switching Menu). Permanently deletes the
//   /// given Firebase Auth account and its Firestore data.
//   ///
//   /// This has to go through the backend, not the Firestore/Auth client
//   /// SDK directly: the Firebase client SDK can only ever delete the
//   /// *currently signed-in* user, and a saved account in the switcher is
//   /// by definition not the one currently signed in. The backend already
//   /// holds the Firebase Admin service account (see server.js), which can
//   /// delete any uid's Auth account and data without disturbing the
//   /// caller's active session or requiring that account's password.
//   static Future<Map<String, dynamic>> deleteAccount(String uid) async {
//     final response = await http.post(
//       Uri.parse('$baseUrl/api/delete-account'),
//       headers: {
//         'Content-Type': 'application/json',
//       },
//       body: jsonEncode({
//         'uid': uid,
//       }),
//     );

//     return jsonDecode(response.body);
//   }

//   /// "Create Group" (Hubs -> Groups tab). Creates a new group.
//   ///
//   /// Goes through the backend rather than a direct Firestore write
//   /// (unlike chats/connections, which the client writes directly)
//   /// because of the group password: it has to be hashed server-side,
//   /// with the backend's Admin SDK, so the plain password is never
//   /// stored anywhere -- see the `/api/create-group` handler in
//   /// server.js.
//   static Future<Map<String, dynamic>> createGroup({
//     required String groupId,
//     required String groupName,
//     required String groupProfileImage,
//     required String adminUid,
//     required String adminAccountId,
//     required List<String> members,
//     required String password,
//   }) async {
//     final response = await http.post(
//       Uri.parse('$baseUrl/api/create-group'),
//       headers: {
//         'Content-Type': 'application/json',
//       },
//       body: jsonEncode({
//         'groupId': groupId,
//         'groupName': groupName,
//         'groupProfileImage': groupProfileImage,
//         'adminUid': adminUid,
//         'adminAccountId': adminAccountId,
//         'members': members,
//         'password': password,
//       }),
//     );

//     return jsonDecode(response.body);
//   }

//   /// "Join Group" (Hubs -> Groups tab). Joins an existing group by
//   /// Group ID + Group Password.
//   ///
//   /// Goes through the backend rather than a direct Firestore write
//   /// for the same reason `createGroup` above does: the password
//   /// check needs the group's passwordHash/passwordSalt, which the
//   /// client never reads directly -- see the `/api/join-group`
//   /// handler in server.js.
//   static Future<Map<String, dynamic>> joinGroup({
//     required String groupId,
//     required String password,
//     required String uid,
//   }) async {
//     final response = await http.post(
//       Uri.parse('$baseUrl/api/join-group'),
//       headers: {
//         'Content-Type': 'application/json',
//       },
//       body: jsonEncode({
//         'groupId': groupId,
//         'password': password,
//         'uid': uid,
//       }),
//     );

//     return jsonDecode(response.body);
//   }
// }












import 'dart:convert';
import 'package:http/http.dart' as http;

class ApiService {
  // Local Node: --dart-define=NODE_BASE_URL=http://<PC IP>:<PORT>
  // Not set -> falls back to the Cloudflare worker (release-safe).
  static const String _nodeOverride = String.fromEnvironment('NODE_BASE_URL');
  static const String baseUrl = _nodeOverride != ''
      ? _nodeOverride
      : 'https://chatbot-worker.gokulmi56cro.workers.dev';

  static Future<Map<String, dynamic>> login(
    String email,
    String password,
  ) async {
    final response = await http.post(
      Uri.parse('$baseUrl/api/login'),
      headers: {
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'email': email,
        'password': password,
      }),
    );

    return jsonDecode(response.body);
  }

  /// "Delete Account" (Account Switching Menu). Permanently deletes the
  /// given Firebase Auth account and its Firestore data.
  ///
  /// This has to go through the backend, not the Firestore/Auth client
  /// SDK directly: the Firebase client SDK can only ever delete the
  /// *currently signed-in* user, and a saved account in the switcher is
  /// by definition not the one currently signed in. The backend already
  /// holds the Firebase Admin service account (see server.js), which can
  /// delete any uid's Auth account and data without disturbing the
  /// caller's active session or requiring that account's password.
  static Future<Map<String, dynamic>> deleteAccount(String uid) async {
    final response = await http.post(
      Uri.parse('$baseUrl/api/delete-account'),
      headers: {
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'uid': uid,
      }),
    );

    return jsonDecode(response.body);
  }

  /// "Create Group" (Hubs -> Groups tab). Creates a new group.
  ///
  /// Goes through the backend rather than a direct Firestore write
  /// (unlike chats/connections, which the client writes directly)
  /// because of the group password: it has to be hashed server-side,
  /// with the backend's Admin SDK, so the plain password is never
  /// stored anywhere -- see the `/api/create-group` handler in
  /// server.js.
  static Future<Map<String, dynamic>> createGroup({
    required String groupId,
    required String groupName,
    required String groupProfileImage,
    required String adminUid,
    required String adminAccountId,
    required List<String> members,
    required String password,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/api/create-group'),
      headers: {
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'groupId': groupId,
        'groupName': groupName,
        'groupProfileImage': groupProfileImage,
        'adminUid': adminUid,
        'adminAccountId': adminAccountId,
        'members': members,
        'password': password,
      }),
    );

    return jsonDecode(response.body);
  }

  /// "Join Group" (Hubs -> Groups tab). Joins an existing group by
  /// Group ID + Group Password.
  ///
  /// Goes through the backend rather than a direct Firestore write
  /// for the same reason `createGroup` above does: the password
  /// check needs the group's passwordHash/passwordSalt, which the
  /// client never reads directly -- see the `/api/join-group`
  /// handler in server.js.
  static Future<Map<String, dynamic>> joinGroup({
    required String groupId,
    required String password,
    required String uid,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/api/join-group'),
      headers: {
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'groupId': groupId,
        'password': password,
        'uid': uid,
      }),
    );

    return jsonDecode(response.body);
  }
}