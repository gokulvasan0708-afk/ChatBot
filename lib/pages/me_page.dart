import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:google_sign_in/google_sign_in.dart';

import 'login_page.dart';
import 'chat_page.dart';
import 'community_page.dart';
import 'chat_screen.dart';
import 'private_chat_screen.dart';
import 'app_theme.dart';
import '../services/chat_settings_service.dart';
import '../services/account_switch_service.dart';
import '../services/api_service.dart';
import 'nexus_bottom_nav.dart';
import 'nexus_toggle.dart';
import 'nexus_notify_settings_page.dart';

import '../widgets/top_alert.dart';
import '../widgets/incoming_message_alert.dart';
import '../widgets/nexus_notify.dart';
class MePage extends StatefulWidget {
  // ==============================================================
  // HOME-SHELL INTEGRATION (Chats <-> Me instant switching)
  // --------------------------------------------------------------
  // See the matching comment on ChatPage in chat_page.dart.
  // `onSwitchToChats` is a plain tab switch (bottom-nav "Chats" tap):
  // it must NOT force Public mode, it just returns to whatever the
  // already-alive ChatPage was showing. `onRequestPublicChats` is the
  // stronger swipe gesture, which has always meant "take me to Public
  // Chats specifically" -- that distinction existed before this
  // change (fresh ChatPage() vs pop/push) and is preserved here.
  // Both default to null so `const MePage()` continues to work if
  // this widget is ever used outside the shell.
  // ==============================================================
  final VoidCallback? onSwitchToChats;
  final VoidCallback? onSwitchToCommunity;
  final VoidCallback? onRequestPublicChats;

  const MePage({
    super.key,
    this.onSwitchToChats,
    this.onSwitchToCommunity,
    this.onRequestPublicChats,
  });

  @override
  State<MePage> createState() => _MePageState();
}

class _MePageState extends State<MePage> with WidgetsBindingObserver {

   // ==========================================================
  // MEMBERS
  // ==========================================================

  int membersCount = 0;

  List<Map<String, dynamic>> members = [];

  // ==========================================================
  // PUBLIC / PRIVATE
  // ==========================================================

  bool isPublic = true;

  // ==========================================================
  // PUBLIC PROFILE
  // ==========================================================

  String? profileName;
  String? profileImagePath;

  // ==========================================================
  // PRIVATE PROFILE
  // ==========================================================

  static const String cloudName = 'db4zevmud';

  static const String privateUploadPreset =
      'nexus_profile_images';

  final ImagePicker _imagePicker = ImagePicker();

  String? privateName;
  String? privateImage;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _profileSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _membersSub;
  StreamSubscription<User?>? _authSub;

Future<String> _getConnectionStatus(
  String otherUid,
) async {
  final user =
      FirebaseAuth.instance.currentUser;

  if (user == null) {
    return 'none';
  }

  final snapshot =
      await FirebaseFirestore.instance
          .collection('connections')
          .where(
            'users',
            arrayContains: user.uid,
          )
          .get();

  for (final doc in snapshot.docs) {
    final data = doc.data();

    final List<dynamic> users =
        data['users'] ?? [];

    if (!users.contains(otherUid)) {
      continue;
    }

    final status =
        (data['status'] ?? 'none').toString();

    final senderUid =
        (data['senderUid'] ?? '').toString();

    final receiverUid =
        (data['receiverUid'] ?? '').toString();

    if (status == 'pending') {
      if (senderUid == user.uid) {
        return 'sent';
      }

      if (receiverUid == user.uid) {
        return 'received';
      }
    }

    if (status == 'connected') {
      return 'connected';
    }
  }

  return 'none';
}

Future<void> _unconnect(
  String otherUid,
) async {
  final user =
      FirebaseAuth.instance.currentUser;

  if (user == null) return;

  try {
    final snapshot =
        await FirebaseFirestore.instance
            .collection('connections')
            .where(
              'users',
              arrayContains: user.uid,
            )
            .get();

    for (final doc in snapshot.docs) {
      final data = doc.data();

      final List<dynamic> users =
          data['users'] ?? [];

      if (users.contains(otherUid)) {
        await doc.reference.delete();
        break;
      }
    }

    if (!mounted) return;

    showTopAlert(context, 'Connection removed.');

    setState(() {});
  } catch (e) {
    debugPrint(
      'Unconnect error: $e',
    );
  }
}

void _showUnconnectDialog(
  String otherUid,
  String otherName,
) {
  showDialog(
    context: context,

    builder: (dialogContext) {
      return AlertDialog(
        backgroundColor:
            const Color(0xFF1B120A),

        title: const Text(
          'Unconnect',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),

        content: Text(
          'Do you want to disconnect from $otherName?',
          style: const TextStyle(
            color: Colors.white70,
          ),
        ),

        actions: [

          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
            },

            child: const Text(
              'CANCEL',
            ),
          ),

          TextButton(
            onPressed: () async {
              Navigator.pop(dialogContext);

              await _unconnect(
                otherUid,
              );
            },

            child: const Text(
              'UNCONNECT',
              style: TextStyle(
                color: Colors.redAccent,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      );
    },
  );
}

  // ==========================================================
  // LOAD PROFILE
  // ==========================================================

Future<void> _loadProfile() async {
  final user = FirebaseAuth.instance.currentUser;

  if (user == null) return;

  try {
    // ======================================================
    // LOAD USER PROFILE
    // ======================================================

    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();

    if (!doc.exists) return;

    final data = doc.data();

// ======================================================
// LOAD MEMBERS FROM CONNECTIONS
// ======================================================

final membersSnapshot = await FirebaseFirestore.instance
    .collection('connections')
    .where(
      'users',
      arrayContains: user.uid,
    )
    .where(
      'status',
      isEqualTo: 'connected',
    )
    .get();

final newMembersCount = membersSnapshot.docs.length;

final List<Map<String, dynamic>> newMembers = [];

for (final connectionDoc in membersSnapshot.docs) {
  final connectionData = connectionDoc.data();

  final List<dynamic> connectionUsers =
      connectionData['users'] ?? [];

  String memberUid = '';

  for (final uid in connectionUsers) {
    if (uid.toString() != user.uid) {
      memberUid = uid.toString();
      break;
    }
  }

  if (memberUid.isEmpty) continue;

  final memberDoc = await FirebaseFirestore.instance
      .collection('users')
      .doc(memberUid)
      .get();

  if (memberDoc.exists) {
    final memberData = memberDoc.data() ?? {};

    // ==================================================
    // CONNECTED MEMBER
    // SHOW PRIVATE PROFILE ONLY
    // ==================================================

    newMembers.add({
      'uid': memberUid,
      'name': memberData['privateName'] ?? 'Private User',
      'image': memberData['privateImage'] ?? '',
    });
  }
}  

    if (!mounted) return;

    setState(() {
      // PUBLIC
      profileName = data?['publicName'];
      profileImagePath = data?['publicImage'];

      // PRIVATE
      privateName = data?['privateName'];
      privateImage = data?['privateImage'];

      // MEMBERS
      membersCount = newMembersCount;
      members = newMembers;
    });
  } catch (e) {
    debugPrint(
      'Profile load error: $e',
    );
  }
}

  // ==========================================================
  // SAVE PRIVATE NAME
  // ==========================================================

  Future<void> _savePrivateName(
    String name,
  ) async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) return;

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .set(
        {
          'privateName': name,
        },
        SetOptions(merge: true),
      );

      if (!mounted) return;

      setState(() {
        privateName =
            name.trim().isEmpty ? null : name.trim();
      });
    } catch (e) {
      debugPrint(
        'Private name save error: $e',
      );

      if (!mounted) return;

      showTopAlert(context, 'Failed to save private name.', isError: true);
    }
  }

  // ==========================================================
  // PICK + UPLOAD PRIVATE PROFILE IMAGE
  // ==========================================================

  Future<void> _pickPrivateProfileImage() async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) return;

    try {
      final XFile? image =
          await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 80,
        maxWidth: 800,
        maxHeight: 800,
      );

      if (image == null) return;

      if (!mounted) return;

      // ------------------------------------------------------
      // LOADING
      // ------------------------------------------------------

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) {
          return const Center(
            child: CircularProgressIndicator(
              color: Color(0xFFD2B48C),
            ),
          );
        },
      );

      // ------------------------------------------------------
      // CLOUDINARY REQUEST
      // ------------------------------------------------------

      final request = http.MultipartRequest(
        'POST',
        Uri.parse(
          'https://api.cloudinary.com/v1_1/'
          '$cloudName/image/upload',
        ),
      );

      request.fields['upload_preset'] =
          privateUploadPreset;

      request.files.add(
        await http.MultipartFile.fromPath(
          'file',
          image.path,
        ),
      );

      final response = await request.send();

      final responseBody =
          await response.stream.bytesToString();

      // ------------------------------------------------------
      // CLOSE LOADING
      // ------------------------------------------------------

      if (!mounted) return;

      Navigator.of(context).pop();

      // ------------------------------------------------------
      // CHECK CLOUDINARY RESPONSE
      // ------------------------------------------------------

      if (response.statusCode != 200) {
        debugPrint(
          'Cloudinary upload failed: $responseBody',
        );

        showTopAlert(context, 'Private profile image upload failed.', isError: true);

        return;
      }

      // ------------------------------------------------------
      // GET CLOUDINARY URL
      // ------------------------------------------------------

      final Map<String, dynamic> data =
          jsonDecode(responseBody);

      final String imageUrl =
          (data['secure_url'] ?? '').toString();

      if (imageUrl.isEmpty) {
        throw Exception(
          'Cloudinary URL not received.',
        );
      }

      // ------------------------------------------------------
      // SAVE URL TO FIRESTORE
      // ------------------------------------------------------

      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .set(
        {
          'privateImage': imageUrl,
        },
        SetOptions(merge: true),
      );

      // ------------------------------------------------------
      // UPDATE UI
      // ------------------------------------------------------

      if (!mounted) return;

      setState(() {
        privateImage = imageUrl;
      });

      showTopAlert(context, 'Private profile image updated.');
    } catch (e) {
      debugPrint(
        'Private image upload error: $e',
      );

      if (!mounted) return;

      // If loading dialog is still open,
      // safely close it.
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }

      showTopAlert(context, 'Failed to upload private profile image.', isError: true);
    }
  }

  // ==========================================================
  // LOGOUT
  // ==========================================================

  Future<void> _logout() async {
    try {
      // These are static, app-wide singleton listeners (the in-app
      // heads-up bar, the hourly unseen-messages reminder, the
      // profile-completion nudge) -- nothing disposes them just
      // because MePage (or even HomeShell) is mid-navigation, so
      // stop them explicitly, and BEFORE signing out. If they're
      // still attached to Firestore the instant the auth token goes
      // null, every one of their connections/chats/groups listeners
      // throws a PERMISSION_DENIED straight into the console.
      IncomingMessageAlert.stop();
      NexusUnseenNotify.stop();
      NexusProfileNotify.stop();

      if (!mounted) return;

      // Navigate away first, THEN sign out -- not the other way
      // around. HomeShell (and everything still mounted underneath
      // it -- ChatPage's own connections/chats listeners, an open
      // chat or group screen's profile stream, etc.) only cancels
      // its Firestore listeners in dispose(), which doesn't run
      // until this route is actually removed from the tree. Signing
      // out first leaves all of that attached with the old token for
      // at least a frame, which is exactly when Firestore fires
      // PERMISSION_DENIED on each of them.
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(
          builder: (_) => const LoginPage(),
        ),
        (route) => false,
      );

      // Give the old route tree a frame to finish disposing (and so
      // cancel its own listeners) before actually revoking the
      // session.
      await WidgetsBinding.instance.endOfFrame;

      await FirebaseAuth.instance.signOut();
    } catch (e) {
      if (!mounted) return;

      showTopAlert(context, 'Logout failed. Please try again.', isError: true);
    }
  }

  // ==========================================================
  // INIT STATE
  // ==========================================================

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(ChatSettingsService.instance.updatePresence(active: true));
    _bindCurrentAccount();
    _authSub = FirebaseAuth.instance.userChanges().listen((_) {
      if (!mounted) return;
      _bindCurrentAccount();
    });
  }

  Future<void> _bindCurrentAccount() async {
    await _profileSub?.cancel();
    await _membersSub?.cancel();
    _profileSub = null;
    _membersSub = null;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    await _loadProfile();

    _profileSub = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .snapshots()
        .listen((doc) {
      final d = doc.data() ?? {};
      if (!mounted) return;
      setState(() {
        profileName = (d['publicName'] ?? '').toString();
        profileImagePath = (d['publicImage'] ?? '').toString();
        privateName = (d['privateName'] ?? '').toString();
        privateImage = (d['privateImage'] ?? '').toString();
      });
    });

    _membersSub = FirebaseFirestore.instance
        .collection('connections')
        .where('users', arrayContains: user.uid)
        .where('status', isEqualTo: 'connected')
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      setState(() => membersCount = snap.docs.length);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(ChatSettingsService.instance.updatePresence(active: false));
    _profileSub?.cancel();
    _membersSub?.cancel();
    _authSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      unawaited(ChatSettingsService.instance.updatePresence(active: false));
    } else if (state == AppLifecycleState.resumed) {
      unawaited(ChatSettingsService.instance.updatePresence(active: true));
    }
  }

  // ==========================================================
  // BUILD
  // ==========================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,

      body: SafeArea(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () {
              FocusScope.of(context).unfocus();
            },
            onHorizontalDragEnd: _handleProfileSwipe,
            child: _buildMePage(),
          ),
        ),

      bottomNavigationBar: NexusBottomNav(
        selectedIndex: 2,
        onChats: () {
          // Inside HomeShell this just flips the IndexedStack index --
          // the already-alive ChatPage is shown exactly as it was left
          // (whatever Public/Private mode, scroll position, etc. it
          // was in), nothing is popped, pushed or rebuilt. Falls back
          // to the old push/pop navigation if MePage is ever used
          // standalone.
          if (widget.onSwitchToChats != null) {
            widget.onSwitchToChats!();
            return;
          }

          if (Navigator.of(context).canPop()) {
            Navigator.of(context).pop();
          } else {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ChatPage()),
            );
          }
        },
        onCommunity: () {
          if (widget.onSwitchToCommunity != null) {
            widget.onSwitchToCommunity!();
            return;
          }
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const CommunityPage()),
          );
        },
        onMe: () {},
      ),
    );
  }

  // ==========================================================
  // SWIPE: PROFILE -> PUBLIC CHATS
  // ----------------------------------------------------------
  // A right-to-left horizontal swipe anywhere on the profile
  // (Me) page jumps straight to the Chats page in Public mode.
  // primaryVelocity is negative when the drag ends moving in
  // the negative x direction, i.e. a right-to-left swipe.
  // A fresh ChatPage() used to be created here (rather than popping
  // back to whatever instance may already be on the stack) so the
  // destination is always Public Chats specifically -- ChatPage
  // already defaults `showPrivate` to false ("starts on Public
  // per spec"). Now that Chats/Me live inside HomeShell's
  // IndexedStack (see home_shell.dart), the same guarantee is made
  // via `onRequestPublicChats`, which pings the single already-alive
  // ChatPage instance to reset itself to Public instead of
  // constructing a second one.
  // ==========================================================

  void _handleProfileSwipe(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;

    // Ignore small/noisy drags -- only react to a deliberate
    // right-to-left swipe.
    if (velocity > -200) return;

    _goToPublicChats();
  }

  void _goToPublicChats() {
    if (!mounted) return;

    FocusScope.of(context).unfocus();

    // Inside HomeShell this signals the already-alive ChatPage to snap
    // back to Public (via publicResetSignal) and flips the IndexedStack
    // index -- no new ChatPage instance is created, but the result is
    // the same guarantee this swipe has always had: landing on Public
    // Chats specifically. Falls back to the old pushAndRemoveUntil if
    // MePage is ever used standalone.
    if (widget.onRequestPublicChats != null) {
      widget.onRequestPublicChats!();
      return;
    }

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const ChatPage()),
      (route) => false,
    );
  }

  // ==========================================================
  // ME PAGE
  // ==========================================================

  Widget _buildMePage() {
    final user =
        FirebaseAuth.instance.currentUser;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,

        children: [

          // ======================================================
          // ME HEADER
          // ======================================================

          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 10,
            ),

            child: Row(
              children: [
Expanded(
  child: Text(
    isPublic
        ? (profileName != null &&
                profileName!.trim().isNotEmpty
            ? profileName!
            : 'Profile')
        : (privateName != null &&
                privateName!.trim().isNotEmpty
            ? privateName!
            : 'Profile'),
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: const TextStyle(
      color: Colors.white,
      fontSize: 28,
      fontWeight: FontWeight.bold,
    ),
  ),
),
                
// EDIT PROFILE

IconButton(
  padding: EdgeInsets.zero,
  constraints: const BoxConstraints(),
  onPressed: _showAccountSwitcher,
  tooltip: 'Switch User',
  icon: const Icon(Icons.swap_horiz_rounded, color: Colors.white, size: 25),
),
const SizedBox(width: 4),
IconButton(
  padding: EdgeInsets.zero,
  constraints: const BoxConstraints(),
  onPressed: _showEditProfile,
  tooltip: 'Edit Profile',
  icon: const Icon(Icons.edit_rounded, color: Colors.white, size: 25),
),
                const SizedBox(width: 4),
                // ACCOUNT ID

                IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: _showAccountId,
                  icon: const Icon(
                    Icons.link_rounded,
                    color: Colors.white,
                    size: 25,
                  ),
                ),
                const SizedBox(width: 4),
                // SETTINGS

                IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: _showSettings,
                  icon: const Icon(
                    Icons.settings_rounded,
                    color: Colors.white,
                    size: 27,
                  ),
                ),
              ],
            ),
          ),

          // ======================================================
          // PUBLIC / PRIVATE TOGGLE
          // ======================================================

          Padding(
            padding: const EdgeInsets.only(left: 20, top: 5),
            child: NexusToggleButton(
              isPrivate: !isPublic,
              onTap: () => setState(() => isPublic = !isPublic),
            ),
          ),

          // ======================================================
          // PROFILE
          // ======================================================

          const SizedBox(height: 35),

if (isPublic)

  Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: 20,
    ),
    child: Row(
      children: [

        Container(
          width: 75,
          height: 75,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFF1B120A),
            border: Border.all(
              color: const Color(0xFFD2B48C),
              width: 2,
            ),
          ),
          child: profileImagePath != null &&
                  profileImagePath!.isNotEmpty
              ? ClipOval(
                  child: Image.asset(
                    profileImagePath!,
                    fit: BoxFit.cover,
                  ),
                )
              : const Icon(
                  Icons.person_rounded,
                  color: Colors.white70,
                  size: 42,
                ),
        ),

        const SizedBox(width: 15),

        Expanded(
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [

              if (profileName != null &&
                  profileName!.trim().isNotEmpty)
                Text(
                  profileName!,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),

              if (user?.email != null) ...[
                const SizedBox(height: 5),

                Text(
                  user!.email!,
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 13,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    ),
  )

else

  _buildPrivateProfile(),

const SizedBox(height: 30),

// ======================================================
// MEMBERS
// ======================================================

_buildMembersSection(),
        ],
      ),
    );
  }

// ==========================================================
// MEMBERS UI
// ==========================================================

Widget _buildMembersSection() {
  return Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: 20,
    ),
    child: GestureDetector(
      onTap: _showMembers,

      child: Container(
        width: double.infinity,
        height: 65,

        padding: const EdgeInsets.symmetric(
          horizontal: 18,
        ),

        decoration: BoxDecoration(
          color: const Color(0xFF1B120A),

          borderRadius: BorderRadius.circular(18),

          border: Border.all(
            color: const Color(0xFFD2B48C).withValues(
              alpha: 0.30,
            ),
            width: 1,
          ),
        ),

        child: Row(
          children: [

            // MEMBERS ICON
            const Icon(
              Icons.people_rounded,
              color: Color(0xFFD2B48C),
              size: 25,
            ),

            const SizedBox(width: 12),

            // MEMBERS
            const Text(
              'Members',
              style: TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),

            const Spacer(),

            // COUNT
            Text(
              '$membersCount',
              style: const TextStyle(
                color: Color(0xFFD2B48C),
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

void _showMembers() {
  showModalBottomSheet(
    context: context,
    backgroundColor: const Color(0xFF1B120A),
    isScrollControlled: true,

    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(25),
      ),
    ),

    builder: (context) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),

          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,

            children: [
              const Center(
                child: Text(
                  'Members',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),

              const SizedBox(height: 20),

              if (members.isEmpty)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      vertical: 30,
                    ),
                    child: Text(
                      'No members yet',
                      style: TextStyle(
                        color: Colors.white54,
                        fontSize: 15,
                      ),
                    ),
                  ),
                ),

              if (members.isNotEmpty)
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,

                    itemCount: members.length,

                    separatorBuilder: (_, _) {
                      return const SizedBox(height: 10);
                    },

                    itemBuilder: (context, index) {
                      final member = members[index];

                      final String name =
                          (member['name'] ?? 'User')
                              .toString();

                      final String image =
                          (member['image'] ?? '')
                              .toString();

                      return InkWell(
                        onTap: () async {
                          final pageContext = this.context;
                          Navigator.pop(context);
                          final me = FirebaseAuth.instance.currentUser;
                          if (me == null) return;
                          final memberUid = (member['uid'] ?? '').toString();
                          final ids = [me.uid, memberUid]..sort();
                          final connection = await FirebaseFirestore.instance.collection('connections').doc(ids.join('_')).get();
                          if (!mounted) return;
                          if ((connection.data()?['status'] ?? '') == 'connected') {
                            Navigator.push(pageContext, MaterialPageRoute(builder: (_) => PrivateMemberProfilePage(uid: memberUid, initialData: member)));
                          } else {
                            Navigator.push(pageContext, MaterialPageRoute(builder: (_) => PublicMemberProfilePage(uid: memberUid, initialData: member)));
                          }
                        },
                        borderRadius: BorderRadius.circular(15),
                        child: Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: const Color(0xFF2A1B0E),
                            borderRadius: BorderRadius.circular(15),
                          ),
                          child: Row(
                          children: [
                            Container(
                              width: 50,
                              height: 50,

                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color:
                                      const Color(0xFFD2B48C),
                                ),
                              ),

                              child: ClipOval(
                                child: image.isNotEmpty
                                    ? Image.network(
        image,
        fit: BoxFit.cover,
        errorBuilder: (
          context,
          error,
          stackTrace,
        ) {
          return const Icon(
            Icons.person_rounded,
            color: Colors.white70,
          );
        },
      )
    : const Icon(
        Icons.person_rounded,
        color: Colors.white70,
      ),
                              ),
                            ),

                            const SizedBox(width: 15),

                            Expanded(
                              child: Text(
                                name.isNotEmpty
                                    ? name
                                    : 'User',

                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight:
                                      FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}

  // ==========================================================
  // PRIVATE PROFILE UI
  // ==========================================================

Widget _buildPrivateProfile() {
  return Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: 20,
    ),

    child: Row(
      children: [

        // ==============================================
        // PRIVATE PROFILE IMAGE
        // ==============================================

        GestureDetector(
          onTap: _pickPrivateProfileImage,

          child: Container(
            width: 75,
            height: 75,

            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF1B120A),
              border: Border.all(
                color: const Color(0xFFD2B48C),
                width: 2,
              ),
            ),

            child: privateImage != null &&
                    privateImage!.isNotEmpty

                ? ClipOval(
                    child: Image.network(
                      privateImage!,
                      width: 75,
                      height: 75,
                      fit: BoxFit.cover,

                      errorBuilder: (
                        context,
                        error,
                        stackTrace,
                      ) {
                        return const Icon(
                          Icons.person_rounded,
                          color: Colors.white70,
                          size: 42,
                        );
                      },
                    ),
                  )

                : const Icon(
                    Icons.person_rounded,
                    color: Colors.white70,
                    size: 42,
                  ),
          ),
        ),

        const SizedBox(width: 15),

        // ==============================================
        // PRIVATE NAME
        // ==============================================

        Expanded(
          child: Text(
            privateName != null &&
                    privateName!.trim().isNotEmpty
                ? privateName!
                : 'Private Profile',

            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    ),
  );
}

  // ==========================================================
  // PRIVATE NAME DIALOG
  // ==========================================================

  void _showPrivateNameDialog(
    TextEditingController controller,
  ) {
    showDialog(
      context: context,

      builder: (context) {
        return AlertDialog(
          backgroundColor:
              const Color(0xFF1B120A),

          title: const Text(
            'Private Name',
            style: TextStyle(
              color: Colors.white,
              fontWeight:
                  FontWeight.bold,
            ),
          ),

          content: TextField(
            controller: controller,

            style: const TextStyle(
              color: Colors.white,
            ),

            decoration:
                InputDecoration(
              hintText:
                  'Enter private name',

              hintStyle:
                  const TextStyle(
                color: Colors.white54,
              ),

              enabledBorder:
                  OutlineInputBorder(
                borderSide:
                    const BorderSide(
                  color:
                      Color(0xFFD2B48C),
                ),
                borderRadius:
                    BorderRadius.circular(
                  12,
                ),
              ),

              focusedBorder:
                  OutlineInputBorder(
                borderSide:
                    const BorderSide(
                  color:
                      Color(0xFFD2B48C),
                  width: 2,
                ),
                borderRadius:
                    BorderRadius.circular(
                  12,
                ),
              ),
            ),
          ),

          actions: [

            TextButton(
              onPressed: () {
                Navigator.pop(context);
              },

              child: const Text(
                'CANCEL',
              ),
            ),

            TextButton(
              onPressed: () async {
                final name =
                    controller.text.trim();

                await _savePrivateName(
                  name,
                );

                if (!context.mounted) {
                  return;
                }

                Navigator.pop(context);
              },

              child: const Text(
                'SAVE',

                style: TextStyle(
                  color:
                      Color(0xFFD2B48C),
                  fontWeight:
                      FontWeight.bold,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  // ==========================================================
  // ACCOUNT ID
  // ==========================================================

  Future<void> _showAccountId() async {
    final user =
        FirebaseAuth.instance.currentUser;

    if (user == null) return;

    try {
      final doc =
          await FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .get();

      if (!doc.exists) return;

      final data = doc.data();

      final String userId =
          (data?['userId'] ?? '')
              .toString();

      if (!mounted) return;

      showDialog(
        context: context,

        builder: (context) {
          return AlertDialog(
            backgroundColor:
                const Color(0xFF1B120A),

            title: const Text(
              'Your Account ID',
              style: TextStyle(
                color: Colors.white,
                fontWeight:
                    FontWeight.bold,
              ),
            ),

            content: Container(
              width: double.infinity,

              padding:
                  const EdgeInsets.all(15),

              decoration: BoxDecoration(
                color:
                    const Color(0xFF2A1B0E),
                borderRadius:
                    BorderRadius.circular(12),
                border: Border.all(
                  color:
                      const Color(0xFFD2B48C),
                ),
              ),

              child: SelectableText(
                userId,

                textAlign:
                    TextAlign.center,

                style: const TextStyle(
                  color:
                      Color(0xFFD2B48C),
                  fontSize: 18,
                  fontWeight:
                      FontWeight.bold,
                  letterSpacing: 1.5,
                ),
              ),
            ),

            actions: [

              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                },

                child: const Text(
                  'CLOSE',

                  style: TextStyle(
                    color:
                        Color(0xFFD2B48C),
                  ),
                ),
              ),
            ],
          );
        },
      );
    } catch (e) {
      debugPrint(
        'Account ID error: $e',
      );
    }
  }

// ==========================================================
// EDIT PROFILE
// PUBLIC + PRIVATE
// ==========================================================

void _showAccountSwitcher() async {
  final current = FirebaseAuth.instance.currentUser;
  if (current == null) return;

  // Every row below used to call Navigator.pop(sheetContext) and then,
  // in that same synchronous callback, immediately perform another UI
  // operation (showDialog for switch/delete, or Navigator.push for Add
  // Nexus Account) on the same context. That races the bottom sheet's
  // closing teardown against the new route being opened, which is the
  // same lifecycle bug already fixed for the nickname Save flow
  // elsewhere in this app (Flutter's own "'_dependents.isEmpty': is not
  // true" assertion). The fix here is the same: each row only reports
  // *which* account/action was tapped, and we wait for
  // showModalBottomSheet's own Future -- which only completes once the
  // sheet has fully finished closing -- before opening anything else.
  final result = await showModalBottomSheet<Map<String, String>>(
    context: context,
    backgroundColor: const Color(0xFF1B120A),
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
    ),
    builder: (sheetContext) {
      return SafeArea(
        child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: AccountSwitchService.instance.watchAccounts(current.uid),
          builder: (context, snapshot) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(width: 42, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(4))),
                  const SizedBox(height: 18),
                  _switchAccountTile(
                    uid: current.uid,
                    name: privateName?.trim().isNotEmpty == true ? privateName! : (profileName ?? 'Current account'),
                    email: current.email ?? '',
                    image: privateImage?.trim().isNotEmpty == true ? privateImage! : (profileImagePath ?? ''),
                    current: true,
                    onTap: () {},
                  ),
                  if (snapshot.hasData) ...snapshot.data!.docs.map((doc) {
                    final d = doc.data();
                    final uid = (d['uid'] ?? doc.id).toString();
                    if (uid == current.uid) return const SizedBox.shrink();
                    final name = (d['privateName'] ?? d['publicName'] ?? 'Nexus account').toString();
                    final image = (d['privateImage'] ?? d['publicImage'] ?? '').toString();
                    final email = (d['email'] ?? '').toString();
                    final provider = (d['provider'] ?? 'password').toString();
                    return _switchAccountTile(
                      uid: uid,
                      name: name,
                      email: email,
                      image: image,
                      current: false,
                      onTap: () => Navigator.pop(sheetContext, {
                        'action': 'switch',
                        'uid': uid,
                        'email': email,
                        'provider': provider,
                      }),
                      onRemove: () => Navigator.pop(sheetContext, {
                        'action': 'remove',
                        'uid': uid,
                        'name': name,
                      }),
                      onDelete: () => Navigator.pop(sheetContext, {
                        'action': 'delete',
                        'uid': uid,
                        'email': email,
                        'name': name,
                      }),
                    );
                  }),
                  const Divider(color: Colors.white12),
                  ListTile(
                    leading: const CircleAvatar(backgroundColor: Color(0xFF8B4513), child: Icon(Icons.add, color: Colors.white)),
                    title: const Text('Add Nexus Account', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    onTap: () => Navigator.pop(sheetContext, {'action': 'add'}),
                  ),
                ],
              ),
            );
          },
        ),
      );
    },
  );

  if (!mounted || result == null) return;
  switch (result['action']) {
    case 'switch':
      await _switchToSavedAccount(
        result['uid']!,
        result['email'] ?? '',
        result['provider'] ?? 'password',
      );
      break;
    case 'remove':
      await _removeSavedAccount(result['uid']!, result['name'] ?? '');
      break;
    case 'delete':
      await _deleteSavedAccount(result['uid']!, result['email'] ?? '', result['name'] ?? '');
      break;
    case 'add':
      final oldUid = FirebaseAuth.instance.currentUser?.uid;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => LoginPage(
            accountToLinkUid: oldUid,
            returnToPreviousPage: true,
          ),
        ),
      );
      if (mounted) await _bindCurrentAccount();
      break;
  }
}

Widget _switchAccountTile({
  required String uid,
  required String name,
  required String email,
  required String image,
  required bool current,
  required VoidCallback onTap,
  VoidCallback? onRemove,
  VoidCallback? onDelete,
}) {
  ImageProvider? provider;
  if (image.startsWith('http://') || image.startsWith('https://')) {
    provider = NetworkImage(image);
  } else if (image.trim().isNotEmpty) {
    provider = AssetImage(image);
  }

  final statusIcon = current
      ? const Icon(Icons.check_circle_rounded, color: Color(0xFFD2B48C))
      : const Icon(Icons.chevron_right_rounded, color: Colors.white54);

  // The current (already-signed-in) account has no Remove/Delete menu --
  // this menu only applies to the *other* saved accounts in the switcher.
  final hasMenu = onRemove != null || onDelete != null;

  return ListTile(
    onTap: onTap,
    leading: CircleAvatar(radius: 25, backgroundColor: const Color(0xFF2A1B0E), backgroundImage: provider, child: provider == null ? const Icon(Icons.person, color: Colors.white70) : null),
    title: Text(name.isEmpty ? 'Nexus account' : name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
    subtitle: Text(email, style: const TextStyle(color: Colors.white54)),
    trailing: !hasMenu
        ? statusIcon
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              statusIcon,
              PopupMenuButton<String>(
                tooltip: 'Account options',
                icon: const Icon(Icons.menu, color: Colors.white54),
                color: const Color(0xFF1B120A),
                onSelected: (value) {
                  if (value == 'remove') {
                    onRemove?.call();
                  } else if (value == 'delete') {
                    onDelete?.call();
                  }
                },
                itemBuilder: (menuContext) => [
                  const PopupMenuItem<String>(
                    value: 'remove',
                    child: Text('Remove Account', style: TextStyle(color: Colors.white)),
                  ),
                  const PopupMenuItem<String>(
                    value: 'delete',
                    child: Text('Delete Account', style: TextStyle(color: Colors.redAccent)),
                  ),
                ],
              ),
            ],
          ),
  );
}

// ==========================================================
// ACCOUNT SWITCHING MENU
// "REMOVE ACCOUNT" vs "DELETE ACCOUNT"
// ----------------------------------------------------------
// Remove Account: unlinks the saved account from this device's
// switcher only (AccountSwitchService.removeSavedAccount). It
// never touches Firebase Auth or that account's Firestore data.
//
// Delete Account: after explicit confirmation, permanently
// deletes the Firebase Auth account and its Firestore data via
// the backend's Admin-SDK-backed /api/delete-account endpoint
// (see server.js). These two are intentionally kept as separate
// functions below so they can never be confused with one
// another.
// ==========================================================

Future<void> _removeSavedAccount(String uid, String name) async {
  final current = FirebaseAuth.instance.currentUser;
  if (current == null) return;

  try {
    await AccountSwitchService.instance.removeSavedAccount(current.uid, uid);
    if (mounted) {
      showTopAlert(context, '${name.isEmpty ? 'Account' : name} removed from your switcher.');
    }
  } catch (e) {
    if (mounted) {
      showTopAlert(context, 'Could not remove that account. Please try again.');
    }
  }
}

Future<void> _deleteSavedAccount(String uid, String email, String name) async {
  final displayName = name.isEmpty ? 'this account' : name;

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: const Color(0xFF1B120A),
      title: const Text('Delete Account', style: TextStyle(color: Colors.white)),
      content: Text(
        'This will permanently delete $displayName${email.isNotEmpty ? ' ($email)' : ''} and all of its data. '
        'This cannot be undone.',
        style: const TextStyle(color: Colors.white70),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('CANCEL'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('DELETE', style: TextStyle(color: Colors.redAccent)),
        ),
      ],
    ),
  );

  // Only an explicit confirmation may proceed -- dismissing the dialog
  // any other way must leave the account untouched.
  if (confirmed != true) return;

  try {
    final result = await ApiService.deleteAccount(uid);
    if (result['success'] != true) {
      throw Exception((result['message'] ?? 'Delete failed').toString());
    }
    // The backend also deletes every switchAccounts pointer to this uid
    // (including this device's own entry), so the switcher sheet's live
    // Firestore stream drops the tile automatically -- no local list
    // bookkeeping needed here.
    if (mounted) {
      showTopAlert(context, '$displayName was permanently deleted.');
    }
  } catch (e) {
    if (mounted) {
      showTopAlert(context, 'Could not delete that account. Please try again.');
    }
  }
}

Future<void> _switchToSavedAccount(String uid, String email, String cachedProvider) async {
  // The switcher's cached 'provider' (stored on the switchAccounts
  // metadata doc at the moment that account was added) can be stale for
  // accounts that were added to the switcher before their own profile
  // doc had a 'provider' value at all -- they were silently written as
  // 'password' by the old fallback. Re-check the target account's own
  // users/{uid} doc -- the actual source of truth, refreshed on every
  // login -- before deciding which flow to use, and if it disagrees,
  // self-heal the cached metadata for both accounts so future switches
  // don't need to do this again.
  var provider = cachedProvider;
  try {
    final targetDoc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
    final liveProvider = (targetDoc.data()?['provider'] ?? '').toString();
    if (liveProvider.isNotEmpty && liveProvider != provider) {
      provider = liveProvider;
      final current = FirebaseAuth.instance.currentUser;
      if (current != null) {
        await AccountSwitchService.instance.linkAccounts(current.uid, uid);
      }
    }
  } catch (_) {
    // If this lookup fails for any reason, fall back to the cached
    // provider value below rather than blocking the switch entirely.
  }

  // A Google-authenticated account has no email/password credential on
  // Firebase Auth at all, so signInWithEmailAndPassword() below can never
  // verify it -- that mismatch is exactly what produced Firebase's
  // "supplied auth credential is incorrect, malformed or has expired"
  // error. Route Google accounts to the existing Google Sign-In flow
  // instead, and leave the password flow below completely untouched for
  // everything else.
  if (provider == 'google') {
    await _switchToGoogleAccount(uid);
    return;
  }

  if (email.isEmpty) {
    if (mounted) {
      showTopAlert(context, 'This saved account has no email on file.');
    }
    return;
  }

  final passwordController = TextEditingController();
  try {
    final password = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF1B120A),
        title: const Text('Switch Account', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: passwordController,
          obscureText: true,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(hintText: 'Enter password', hintStyle: TextStyle(color: Colors.white54)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('CANCEL')),
          TextButton(onPressed: () => Navigator.pop(dialogContext, passwordController.text), child: const Text('SWITCH')),
        ],
      ),
    );

    // Require a non-empty password for the target account -- cancelling
    // the dialog or submitting blank input must never trigger a switch.
    final enteredPassword = password?.trim() ?? '';
    if (password == null) return;
    if (enteredPassword.isEmpty) {
      if (mounted) {
        showTopAlert(context, 'Password is required to switch accounts.', isError: true);
      }
      return;
    }

    // Remember which account we're switching away from *before* signing
    // in below. signInWithEmailAndPassword() replaces
    // FirebaseAuth.instance.currentUser with the target account the
    // instant it succeeds, and ChatSettingsService.updatePresence()
    // always writes to whichever uid is currently signed in -- so the
    // outgoing account's uid has to be captured now or it's lost.
    final previousUid = FirebaseAuth.instance.currentUser?.uid;

    // This call is the actual password check: Firebase Auth verifies
    // `password` against the target account's real credentials on its
    // servers and throws a FirebaseAuthException (e.g. 'wrong-password' /
    // 'invalid-credential') on any mismatch. On a wrong password nothing
    // below runs and the currently active account is left untouched --
    // only the correct password ever reaches the switch logic.
    final credential = await FirebaseAuth.instance.signInWithEmailAndPassword(
      email: email,
      password: enteredPassword,
    );

    final signedInUser = credential.user;
    if (signedInUser == null || signedInUser.uid != uid) {
      // Defensive guard: the credentials that were entered authenticated
      // successfully but resolved to a different account than the one the
      // user tapped (e.g. stale saved metadata). Don't treat this as a
      // successful switch.
      if (mounted) {
        showTopAlert(context, 'Unable to switch account. Please try again.');
      }
      return;
    }

    // Flip presence for both accounts right away instead of waiting on
    // the next app-lifecycle resume/pause event -- otherwise the account
    // that was just left behind would keep showing as "Active now"
    // indefinitely, and the newly active account wouldn't show as active
    // until the app happened to background/foreground again.
    if (previousUid != null && previousUid != uid) {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(previousUid)
          .set({
            'isActive': false,
            'lastActiveAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
    }
    await ChatSettingsService.instance.updatePresence(active: true);

    if (mounted) {
      await _bindCurrentAccount();
      setState(() {});
    }
  } on FirebaseAuthException catch (e) {
    if (mounted) showTopAlert(context, e.message ?? 'Unable to switch account');
  } finally {
    passwordController.dispose();
  }
}

// Switches to a saved account that was created/authenticated with
// Google. There is no password to verify here -- the correct
// re-authentication is Google's own sign-in flow (the same one used at
// login in login_page.dart): the account picker lets the user pick/
// re-authenticate the Google account for the profile they tapped, then
// Firebase verifies that Google ID token itself. EmailAuthProvider
// credentials are never used for this branch.
Future<void> _switchToGoogleAccount(String uid) async {
  final googleSignIn = GoogleSignIn.instance;

  try {
    await googleSignIn.initialize();
  } catch (_) {
    // Already initialized elsewhere in the app session (e.g. login_page.dart
    // already called this) -- safe to ignore, same as login_page.dart does.
  }

  // Remember which account we're switching away from *before* signing in
  // below, for the same reason as the password flow: signInWithCredential()
  // replaces FirebaseAuth.instance.currentUser the instant it succeeds.
  final previousUid = FirebaseAuth.instance.currentUser?.uid;

  try {
    final googleUser = await googleSignIn.authenticate();
    final googleAuth = googleUser.authentication;
    final idToken = googleAuth.idToken;

    if (idToken == null) {
      throw Exception('Google ID token is null');
    }

    final credential = GoogleAuthProvider.credential(idToken: idToken);

    // This is the actual verification for a Google account: Firebase
    // checks the Google ID token itself, not a password. On any mismatch
    // it throws a FirebaseAuthException and the currently active account
    // is left untouched -- only a successful Google sign-in reaches the
    // switch logic below.
    final userCredential = await FirebaseAuth.instance.signInWithCredential(credential);

    final signedInUser = userCredential.user;
    if (signedInUser == null || signedInUser.uid != uid) {
      // Defensive guard: the Google account that was actually picked
      // doesn't match the saved account that was tapped (e.g. the
      // account picker resolved a different Google account). Don't
      // treat this as a successful switch.
      if (mounted) {
        showTopAlert(context, 'Unable to switch account. Please try again.');
      }
      return;
    }

    // Flip presence for both accounts right away, same as the password flow.
    if (previousUid != null && previousUid != uid) {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(previousUid)
          .set({
            'isActive': false,
            'lastActiveAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
    }
    await ChatSettingsService.instance.updatePresence(active: true);

    if (mounted) {
      await _bindCurrentAccount();
      setState(() {});
    }
  } on GoogleSignInException catch (e) {
    if (mounted) {
      showTopAlert(context, 'Google Sign-In failed: ${e.code}', isError: true);
    }
  } on FirebaseAuthException catch (e) {
    if (mounted) {
      showTopAlert(context, e.message ?? 'Unable to switch account');
    }
  } catch (e) {
    if (mounted) {
      showTopAlert(context, 'Google Sign-In failed', isError: true);
    }
  }
}

void _showEditProfile() {
  final nameController = TextEditingController(
    text: isPublic
        ? (profileName ?? '')
        : (privateName ?? ''),
  );

  showModalBottomSheet(
    context: context,

    backgroundColor:
        const Color(0xFF1B120A),

    shape:
        const RoundedRectangleBorder(
      borderRadius:
          BorderRadius.vertical(
        top: Radius.circular(25),
      ),
    ),

    builder: (context) {
      return SafeArea(
        child: Padding(
          padding:
              const EdgeInsets.all(20),

          child: Column(
            mainAxisSize:
                MainAxisSize.min,

            children: [

              // ==================================================
              // TITLE
              // ==================================================

              Text(
                isPublic
                    ? 'Edit Profile'
                    : 'Edit Private Profile',

                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight:
                      FontWeight.bold,
                ),
              ),

              const SizedBox(height: 20),

              // ==================================================
              // PROFILE IMAGE
              // ==================================================

              Row(
                children: [

                  Expanded(
                    child: ListTile(
                      contentPadding:
                          EdgeInsets.zero,

                      leading:
                          const Icon(
                        Icons.image_rounded,
                        color:
                            Color(0xFFD2B48C),
                      ),

                      title: Text(
                        isPublic
                            ? 'Set Profile Image'
                            : 'Set Private Profile Image',

                        style:
                            const TextStyle(
                          color:
                              Colors.white,
                        ),
                      ),

                      onTap: () {
                        Navigator.pop(
                          context,
                        );

                        if (isPublic) {
                          _showProfileImageOptions();
                        } else {
                          _pickPrivateProfileImage();
                        }
                      },
                    ),
                  ),

                  // ==================================================
                  // REMOVE IMAGE
                  // ==================================================

                  if (
                    isPublic
                        ? profileImagePath != null &&
                          profileImagePath!
                              .trim()
                              .isNotEmpty
                        : privateImage != null &&
                          privateImage!
                              .trim()
                              .isNotEmpty
                  )

                    IconButton(
                      onPressed: () async {

                        final user =
                            FirebaseAuth
                                .instance
                                .currentUser;

                        if (user == null) {
                          return;
                        }

                        try {

                          if (isPublic) {

                            // ========================================
                            // REMOVE PUBLIC IMAGE
                            // ========================================

                            await FirebaseFirestore
                                .instance
                                .collection(
                                  'users',
                                )
                                .doc(user.uid)
                                .update({
                              'publicImage': '',
                            });

                            if (!mounted) {
                              return;
                            }

                            setState(() {
                              profileImagePath =
                                  null;
                            });

                          } else {

                            // ========================================
                            // REMOVE PRIVATE IMAGE
                            // ========================================

                            await FirebaseFirestore
                                .instance
                                .collection(
                                  'users',
                                )
                                .doc(user.uid)
                                .update({
                              'privateImage': '',
                            });

                            if (!mounted) {
                              return;
                            }

                            setState(() {
                              privateImage =
                                  null;
                            });
                          }

                          Navigator.pop(
                            context,
                          );

                          showTopAlert(context, isPublic
                                    ? 'Profile image removed.'
                                    : 'Private profile image removed.');

                        } catch (e) {

                          debugPrint(
                            'Remove image error: $e',
                          );

                          if (!mounted) {
                            return;
                          }

                          showTopAlert(context, 'Failed to remove profile image.', isError: true);
                        }
                      },

                      icon:
                          const Icon(
                        Icons
                            .remove_circle_rounded,

                        color:
                            Colors.redAccent,

                        size: 28,
                      ),
                    ),
                ],
              ),

              // ==================================================
              // NAME
              // ==================================================

              Row(
                children: [

                  Expanded(
                    child: ListTile(
                      contentPadding:
                          EdgeInsets.zero,

                      leading:
                          const Icon(
                        Icons.person_rounded,
                        color:
                            Color(0xFFD2B48C),
                      ),

                      title: Text(
                        isPublic
                            ? 'Set / Change Name'
                            : 'Set / Change Private Name',

                        style:
                            const TextStyle(
                          color:
                              Colors.white,
                        ),
                      ),

                      onTap: () {
                        Navigator.pop(
                          context,
                        );

                        if (isPublic) {

                          _showNameDialog(
                            nameController,
                          );

                        } else {

                          _showPrivateNameDialog(
                            nameController,
                          );
                        }
                      },
                    ),
                  ),

                  // ==================================================
                  // REMOVE NAME
                  // ==================================================

                  if (
                    isPublic
                        ? profileName != null &&
                          profileName!
                              .trim()
                              .isNotEmpty
                        : privateName != null &&
                          privateName!
                              .trim()
                              .isNotEmpty
                  )

                    IconButton(
                      onPressed: () async {

                        final user =
                            FirebaseAuth
                                .instance
                                .currentUser;

                        if (user == null) {
                          return;
                        }

                        try {

                          if (isPublic) {

                            // ========================================
                            // REMOVE PUBLIC NAME
                            // ========================================

                            await FirebaseFirestore
                                .instance
                                .collection(
                                  'users',
                                )
                                .doc(user.uid)
                                .update({
                              'publicName': '',
                            });

                            if (!mounted) {
                              return;
                            }

                            setState(() {
                              profileName =
                                  null;
                            });

                          } else {

                            // ========================================
                            // REMOVE PRIVATE NAME
                            // ========================================

                            await FirebaseFirestore
                                .instance
                                .collection(
                                  'users',
                                )
                                .doc(user.uid)
                                .update({
                              'privateName': '',
                            });

                            if (!mounted) {
                              return;
                            }

                            setState(() {
                              privateName =
                                  null;
                            });
                          }

                          Navigator.pop(
                            context,
                          );

                          showTopAlert(context, isPublic
                                    ? 'Name removed.'
                                    : 'Private name removed.');

                        } catch (e) {

                          debugPrint(
                            'Remove name error: $e',
                          );

                          if (!mounted) {
                            return;
                          }

                          showTopAlert(context, 'Failed to remove name.', isError: true);
                        }
                      },

                      icon:
                          const Icon(
                        Icons
                            .remove_circle_rounded,

                        color:
                            Colors.redAccent,

                        size: 28,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}

  // ==========================================================
  // PUBLIC PROFILE IMAGE OPTIONS
  // ==========================================================

  void _showProfileImageOptions() {
    final List<String> profileImages = [
      'assets/images/profile/profile1.jpg',
      'assets/images/profile/profile2.jpg',
      'assets/images/profile/profile3.png',
      'assets/images/profile/profile4.png',
      'assets/images/profile/profile5.png',
      'assets/images/profile/profile6.png',
      'assets/images/profile/profile7.png',
      'assets/images/profile/profile8.png',
      'assets/images/profile/profile9.png',
      'assets/images/profile/profile10.png',
    ];

    showModalBottomSheet(
      context: context,

      backgroundColor:
          const Color(0xFF1B120A),

      shape:
          const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(
          top: Radius.circular(25),
        ),
      ),

      builder: (context) {
        return SafeArea(
          child: Padding(
            padding:
                const EdgeInsets.all(20),

            child: Column(
              mainAxisSize:
                  MainAxisSize.min,

              children: [

                const Text(
                  'Choose Profile Image',

                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),

                const SizedBox(height: 20),

                SizedBox(
                  height: 110,

                  child:
                      ListView.separated(
                    scrollDirection:
                        Axis.horizontal,

                    itemCount:
                        profileImages.length,

                    separatorBuilder:
                        (_, _) =>
                            const SizedBox(
                      width: 15,
                    ),

                    itemBuilder:
                        (context, index) {
                      final imagePath =
                          profileImages[index];

                      return GestureDetector(
                        onTap: () async {
                          final user =
                              FirebaseAuth
                                  .instance
                                  .currentUser;

                          if (user == null) {
                            return;
                          }

                          try {
                            await FirebaseFirestore
                                .instance
                                .collection(
                                  'users',
                                )
                                .doc(user.uid)
                                .update({
                              'publicImage':
                                  imagePath,
                            });

                            if (!mounted) {
                              return;
                            }

                            setState(() {
                              profileImagePath =
                                  imagePath;
                            });

                            Navigator.pop(
                              context,
                            );
                          } catch (e) {
                            debugPrint(
                              'Profile image save error: $e',
                            );

                            if (!mounted) {
                              return;
                            }

                            showTopAlert(context, 'Failed to save profile image', isError: true);
                          }
                        },

                        child: Container(
                          width: 90,
                          height: 90,

                          decoration:
                              BoxDecoration(
                            shape:
                                BoxShape.circle,

                            border:
                                Border.all(
                              color:
                                  const Color(0xFFD2B48C),
                              width: 2,
                            ),
                          ),

                          child: ClipOval(
                            child:
                                Image.asset(
                              imagePath,
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),

                const SizedBox(height: 15),

                if (profileImagePath != null)

                  ListTile(
                    leading: const Icon(
                      Icons.delete_rounded,
                      color:
                          Colors.redAccent,
                    ),

                    title: const Text(
                      'Remove Profile Image',

                      style: TextStyle(
                        color: Colors.white,
                      ),
                    ),

                    onTap: () async {
                      final user =
                          FirebaseAuth
                              .instance
                              .currentUser;

                      if (user == null) {
                        return;
                      }

                      try {
                        await FirebaseFirestore
                            .instance
                            .collection(
                              'users',
                            )
                            .doc(user.uid)
                            .update({
                          'publicImage': '',
                        });

                        if (!mounted) {
                          return;
                        }

                        setState(() {
                          profileImagePath =
                              null;
                        });

                        Navigator.pop(
                          context,
                        );
                      } catch (e) {
                        debugPrint(
                          'Remove public image error: $e',
                        );
                      }
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ==========================================================
  // PUBLIC NAME DIALOG
  // ==========================================================

  void _showNameDialog(
    TextEditingController controller,
  ) {
    showDialog(
      context: context,

      builder: (context) {
        return AlertDialog(
          backgroundColor:
              const Color(0xFF1B120A),

          title: const Text(
            'Set Name',

            style: TextStyle(
              color: Colors.white,
              fontWeight:
                  FontWeight.bold,
            ),
          ),

          content: TextField(
            controller: controller,

            style: const TextStyle(
              color: Colors.white,
            ),

            decoration:
                InputDecoration(
              hintText:
                  'Enter your name',

              hintStyle:
                  const TextStyle(
                color: Colors.white54,
              ),

              enabledBorder:
                  OutlineInputBorder(
                borderSide:
                    const BorderSide(
                  color:
                      Color(0xFFD2B48C),
                ),

                borderRadius:
                    BorderRadius.circular(
                  12,
                ),
              ),

              focusedBorder:
                  OutlineInputBorder(
                borderSide:
                    const BorderSide(
                  color:
                      Color(0xFFD2B48C),
                  width: 2,
                ),

                borderRadius:
                    BorderRadius.circular(
                  12,
                ),
              ),
            ),
          ),

          actions: [

            TextButton(
              onPressed: () {
                Navigator.pop(context);
              },

              child:
                  const Text('CANCEL'),
            ),

            TextButton(
              onPressed: () async {
                final name =
                    controller.text.trim();

                final user =
                    FirebaseAuth
                        .instance
                        .currentUser;

                if (user == null) {
                  return;
                }

                try {
                  await FirebaseFirestore
                      .instance
                      .collection('users')
                      .doc(user.uid)
                      .update({
                    'publicName': name,
                  });

                  if (!mounted) {
                    return;
                  }

                  setState(() {
                    profileName =
                        name.isEmpty
                            ? null
                            : name;
                  });

                  Navigator.pop(context);
                } catch (e) {
                  debugPrint(
                    'Name save error: $e',
                  );

                  if (!mounted) {
                    return;
                  }

                  showTopAlert(context, 'Failed to save name', isError: true);
                }
              },

              child: const Text(
                'SAVE',

                style: TextStyle(
                  color:
                      Color(0xFFD2B48C),
                  fontWeight:
                      FontWeight.bold,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  // ==========================================================
  // SETTINGS
  // ==========================================================

  void _showSettings() {
    showModalBottomSheet(
      context: context,

      backgroundColor:
          const Color(0xFF1B120A),

      shape:
          const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(
          top: Radius.circular(25),
        ),
      ),

      builder: (context) {
        return SafeArea(
          child: Padding(
            padding:
                const EdgeInsets.all(20),

            child: Column(
              mainAxisSize:
                  MainAxisSize.min,

              children: [

                const Text(
                  'Settings',

                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),

                const SizedBox(height: 20),

                // ==================================================
                // MODE (DARK / LIGHT)
                // ==================================================

                ValueListenableBuilder<ThemeMode>(
                  valueListenable: ThemeController.instance,
                  builder: (context, mode, _) {
                    final isDark = mode == ThemeMode.dark;

                    return ListTile(
                      leading: Icon(
                        isDark
                            ? Icons.dark_mode_rounded
                            : Icons.light_mode_rounded,
                        color: const Color(0xFFD2B48C),
                      ),

                      title: const Text(
                        'Mode',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),

                      subtitle: Text(
                        isDark ? 'Dark Mode' : 'Light Mode',
                        style: const TextStyle(
                          color: Color(0xFFAB8A63),
                        ),
                      ),

                      trailing: Switch(
                        value: isDark,
                        activeThumbColor: const Color(0xFFD2B48C),
                        onChanged: (value) {
                          ThemeController.instance.setMode(
                            value ? ThemeMode.dark : ThemeMode.light,
                          );
                        },
                      ),

                      onTap: () {
                        ThemeController.instance.toggle();
                      },
                    );
                  },
                ),

                // ==================================================
                // NEXUS NOTIFY -- Notify on/off + greeting Name
                // (see pages/nexus_notify_settings_page.dart)
                // ==================================================

                ListTile(
                  leading: const Icon(
                    Icons.notifications_active_rounded,
                    color: Color(0xFFD2B48C),
                  ),

                  title: const Text(
                    'Nexus Notify',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),

                  trailing: const Icon(
                    Icons.chevron_right_rounded,
                    color: Color(0xFFAB8A63),
                  ),

                  onTap: () {
                    Navigator.pop(context);

                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const NexusNotifySettingsPage(),
                      ),
                    );
                  },
                ),

                // ==================================================
                // ACCOUNT SECTION
                // Account ID / Delete this account / Logout
                // ==================================================

                const Padding(
                  padding: EdgeInsets.only(top: 8, bottom: 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Account',
                      style: TextStyle(
                        color: Color(0xFFAB8A63),
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        letterSpacing: 1.1,
                      ),
                    ),
                  ),
                ),

                ListTile(
                  leading: const Icon(
                    Icons.badge_outlined,
                    color: Color(0xFFD2B48C),
                  ),

                  title: const Text(
                    'Account ID',

                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),

                  onTap: () {
                    Navigator.pop(context);

                    _showAccountId();
                  },
                ),

                ListTile(
                  leading: const Icon(
                    Icons.delete_forever_rounded,
                    color: Colors.redAccent,
                  ),

                  title: const Text(
                    'Delete this account',

                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),

                  onTap: () {
                    Navigator.pop(context);

                    _showDeleteAccountDialog();
                  },
                ),

                ListTile(
                  leading: const Icon(
                    Icons.logout_rounded,
                    color:
                        Colors.redAccent,
                  ),

                  title: const Text(
                    'Logout',

                    style: TextStyle(
                      color: Colors.white,
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),

                  onTap: () {
                    Navigator.pop(context);

                    _showLogoutDialog();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ==========================================================
  // LOGOUT CONFIRMATION
  // ==========================================================

  void _showLogoutDialog() {
    showDialog(
      context: context,

      builder: (context) {
        return AlertDialog(
          backgroundColor:
              const Color(0xFF1B120A),

          title: const Text(
            'Logout',

            style: TextStyle(
              color: Colors.white,
              fontWeight:
                  FontWeight.bold,
            ),
          ),

          content: const Text(
            'Are you sure you want to logout?',

            style: TextStyle(
              color: Colors.white70,
            ),
          ),

          actions: [

            TextButton(
              onPressed: () {
                Navigator.pop(context);
              },

              child:
                  const Text('CANCEL'),
            ),

            TextButton(
              onPressed: () {
                Navigator.pop(context);

                _logout();
              },

              child: const Text(
                'LOGOUT',

                style: TextStyle(
                  color:
                      Colors.redAccent,
                  fontWeight:
                      FontWeight.bold,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  // ==========================================================
  // DELETE THIS ACCOUNT
  // SETTINGS -> ACCOUNT SECTION
  // ----------------------------------------------------------
  // Deletes the account that is CURRENTLY signed in -- distinct
  // from the "Delete Account" menu item on a *saved* (non-active)
  // account in the account switcher (see _deleteSavedAccount).
  // Both ultimately call the same backend endpoint
  // (ApiService.deleteAccount -> /api/delete-account), which:
  //   1. permanently deletes the Firebase Authentication account,
  //   2. deletes that account's Firestore user data, and
  //   3. removes every switchAccounts pointer to that uid from
  //      every account's local account-switching list.
  // Reusing that endpoint here also avoids Firebase's
  // "requires-recent-login" restriction on self-deletion, since
  // the Admin SDK on the backend doesn't need a fresh sign-in to
  // delete a uid.
  // ==========================================================

  void _showDeleteAccountDialog() {
    showDialog(
      context: context,

      builder: (context) {
        return AlertDialog(
          backgroundColor:
              const Color(0xFF1B120A),

          title: const Text(
            'Delete this account',

            style: TextStyle(
              color: Colors.white,
              fontWeight:
                  FontWeight.bold,
            ),
          ),

          content: const Text(
            'This will permanently delete your account and all of its data. '
            'This cannot be undone.',

            style: TextStyle(
              color: Colors.white70,
            ),
          ),

          actions: [

            TextButton(
              onPressed: () {
                Navigator.pop(context);
              },

              child:
                  const Text('CANCEL'),
            ),

            TextButton(
              onPressed: () {
                Navigator.pop(context);

                _deleteCurrentAccount();
              },

              child: const Text(
                'DELETE',

                style: TextStyle(
                  color:
                      Colors.redAccent,
                  fontWeight:
                      FontWeight.bold,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _deleteCurrentAccount() async {
    final current = FirebaseAuth.instance.currentUser;
    if (current == null) return;

    final uid = current.uid;

    try {
      final result = await ApiService.deleteAccount(uid);
      if (result['success'] != true) {
        throw Exception((result['message'] ?? 'Delete failed').toString());
      }

      // The account no longer exists server-side, but this device's
      // FirebaseAuth session still holds a locally-cached ID token for
      // it. Sign out explicitly so nothing in the app keeps treating a
      // deleted account as the active one, then return to the login
      // screen the same way _logout() does.
      //
      // Same ordering fix as _logout(): stop the static background
      // listeners and navigate away BEFORE signOut(), not after --
      // otherwise they're still attached with the old token the
      // instant it goes null and each one throws a PERMISSION_DENIED.
      IncomingMessageAlert.stop();
      NexusUnseenNotify.stop();
      NexusProfileNotify.stop();

      if (!mounted) return;

      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(
          builder: (_) => const LoginPage(),
        ),
        (route) => false,
      );

      await WidgetsBinding.instance.endOfFrame;

      await FirebaseAuth.instance.signOut();
    } catch (e) {
      if (mounted) {
        showTopAlert(context, 'Could not delete your account. Please try again.');
      }
    }
  }
}