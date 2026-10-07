import '../features/ai_assistant/ai_launcher.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'chat_screen.dart';
import '../services/chat_settings_service.dart';

/// Connected/private conversation entry point.
/// It intentionally delegates message behaviour to the existing ChatScreen
/// so reply, reactions, saving, forwarding, edit/delete and search-target
/// scrolling remain identical instead of creating a second message engine.
ImageProvider? _profileImageProvider(String path) {
  final value = path.trim();
  if (value.isEmpty) return null;
  if (value.startsWith('http://') || value.startsWith('https://')) return NetworkImage(value);
  return AssetImage(value);
}

class PrivateChatScreen extends StatefulWidget {
  final String otherUserUid;
  final String? targetMessageId;

  const PrivateChatScreen({
    super.key,
    required this.otherUserUid,
    this.targetMessageId,
  });

  @override
  State<PrivateChatScreen> createState() => _PrivateChatScreenState();
}

class _PrivateChatScreenState extends State<PrivateChatScreen> with AiLauncherHide {
  @override
  void initState() {
    super.initState();
    _enablePrivateInfo();
  }

  Future<void> _enablePrivateInfo() async {
    final me = FirebaseAuth.instance.currentUser;
    if (me == null) return;
    final service = ChatSettingsService.instance;
    // In private conversations both visibility signals are mandatory.
    await service.setActiveInfo(widget.otherUserUid, true);
    await service.setTypingInfo(widget.otherUserUid, true);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(widget.otherUserUid)
          .snapshots(),
      builder: (context, snapshot) {
        final data = snapshot.data?.data() ?? {};
        final privateName = (data['privateName'] ?? '').toString().trim();
        final publicName = (data['publicName'] ?? 'User').toString();
        final privateImage = (data['privateImage'] ?? '').toString().trim();
        final publicImage = (data['publicImage'] ?? '').toString();

        return ChatScreen(
          otherUserUid: widget.otherUserUid,
          otherUserName: privateName.isNotEmpty ? privateName : publicName,
          otherUserImage: privateImage.isNotEmpty ? privateImage : publicImage,
          targetMessageId: widget.targetMessageId,
          usePrivateProfile: true,
          onProfileTap: (_) => _openPrivateProfile(context, data),
        );
      },
    );
  }

  void _openPrivateProfile(BuildContext context, Map<String, dynamic> data) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PrivateMemberProfilePage(
          uid: widget.otherUserUid,
          initialData: data,
        ),
      ),
    );
  }
}

class PrivateMemberProfilePage extends StatelessWidget {
  final String uid;
  final Map<String, dynamic> initialData;

  const PrivateMemberProfilePage({
    super.key,
    required this.uid,
    this.initialData = const {},
  });

  @override
  Widget build(BuildContext context) {
    final me = FirebaseAuth.instance.currentUser;
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('users').doc(uid).snapshots(),
      builder: (context, snapshot) {
        final data = snapshot.data?.data() ?? initialData;
        final name = (data['privateName'] ?? data['publicName'] ?? 'User').toString();
        final image = (data['privateImage'] ?? data['publicImage'] ?? '').toString();

        return Scaffold(
          backgroundColor: const Color(0xFF0F0F14),
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            title: const Text('Profile', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            actions: [
              IconButton(onPressed: () => _showMenu(context), icon: const Icon(Icons.more_vert_rounded, color: Colors.white)),
            ],
          ),
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
              child: Column(children: [
                CircleAvatar(
                  radius: 58,
                  backgroundColor: const Color(0xFF20202A),
                  backgroundImage: _profileImageProvider(image),
                  child: image.isEmpty ? const Icon(Icons.person_rounded, size: 55, color: Colors.white70) : null,
                ),
                const SizedBox(height: 14),
                Text(name, style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold)),
                const SizedBox(height: 20),
                Row(children: [
                  Expanded(child: ElevatedButton(onPressed: () => _showDisconnectDialog(context, name, image), style: _buttonStyle(), child: const Text('Connected'))),
                  const SizedBox(width: 10),
                  Expanded(child: ElevatedButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PrivateChatScreen(otherUserUid: uid))), style: _buttonStyle(), child: const Text('Message'))),
                ]),
                const SizedBox(height: 20),
                InkWell(
                  onTap: () => _showMembers(context),
                  borderRadius: BorderRadius.circular(18),
                  child: Container(width: double.infinity, padding: const EdgeInsets.all(18), decoration: BoxDecoration(color: const Color(0xFF18181F), borderRadius: BorderRadius.circular(18), border: Border.all(color: const Color(0xFFA78BFA).withValues(alpha: .35))), child: const Row(children: [Icon(Icons.people_alt_rounded, color: Color(0xFFA78BFA)), SizedBox(width: 12), Text('Members', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)), Spacer(), Icon(Icons.chevron_right_rounded, color: Colors.white54)])),
                ),
                const SizedBox(height: 28),
                const Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                  Icon(Icons.grid_view_rounded, color: Color(0xFFA78BFA)),
                  Icon(Icons.photo_library_rounded, color: Colors.white54),
                  Icon(Icons.link_rounded, color: Colors.white54),
                  Icon(Icons.bookmark_rounded, color: Colors.white54),
                ]),
              ]),
            ),
          ),
        );
      },
    );
  }

  ButtonStyle _buttonStyle() => ElevatedButton.styleFrom(backgroundColor: const Color(0xFF7C3AED), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)));

  // Tapping "Connected" no longer disconnects immediately -- it opens a
  // small centered dialog previewing the account's private profile
  // picture/name (the same values already resolved for this page from
  // privateName/privateImage) with Disconnect/Cancel. Only Disconnect
  // performs the actual disconnect/remove-connection action; Cancel just
  // closes the dialog and leaves the connection untouched.
  void _showDisconnectDialog(BuildContext pageContext, String name, String image) {
    showDialog(
      context: pageContext,
      barrierDismissible: true,
      builder: (dialogContext) {
        return Dialog(
          backgroundColor: const Color(0xFF18181F),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: const Color(0xFFA78BFA).withValues(alpha: 0.30)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 28,
                      backgroundColor: const Color(0xFF20202A),
                      backgroundImage: _profileImageProvider(image),
                      child: image.isEmpty
                          ? const Icon(Icons.person_rounded, color: Colors.white70, size: 28)
                          : null,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white70,
                          side: const BorderSide(color: Colors.white24),
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
                        ),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () async {
                          Navigator.pop(dialogContext);
                          await _disconnect(pageContext);
                        },
                        style: _buttonStyle(),
                        child: const Text('Disconnect'),
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

  Future<void> _disconnect(BuildContext context) async {
    final me = FirebaseAuth.instance.currentUser;
    if (me == null) return;
    final ids = [me.uid, uid]..sort();
    await FirebaseFirestore.instance.collection('connections').doc(ids.join('_')).delete();
    if (context.mounted) Navigator.pop(context);
  }

  Future<void> _showMembers(BuildContext context) async {
    final me = FirebaseAuth.instance.currentUser;
    if (me == null) return;
    final snap = await FirebaseFirestore.instance.collection('connections').where('users', arrayContains: uid).where('status', isEqualTo: 'connected').get();
    final members = <String>{};
    for (final doc in snap.docs) {
      for (final member in List<String>.from(doc.data()['users'] ?? const [])) {
        if (member != uid) members.add(member);
      }
    }
    if (!context.mounted) return;
    showModalBottomSheet(context: context, backgroundColor: const Color(0xFF18181F), isScrollControlled: true, builder: (sheet) => SafeArea(child: ListView(padding: const EdgeInsets.all(20), shrinkWrap: true, children: members.map((memberUid) => FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(future: FirebaseFirestore.instance.collection('users').doc(memberUid).get(), builder: (context, s) { final d=s.data?.data()??{}; final name=(d['privateName']??d['publicName']??'User').toString(); final image=(d['privateImage']??d['publicImage']??'').toString(); return ListTile(leading: CircleAvatar(backgroundImage:_profileImageProvider(image), child:image.isEmpty?const Icon(Icons.person):null), title:Text(name,style:const TextStyle(color:Colors.white)), onTap:() async {
  Navigator.pop(sheet);
  final me = FirebaseAuth.instance.currentUser;
  if (me == null) return;
  final ids = [me.uid, memberUid]..sort();
  final connection = await FirebaseFirestore.instance.collection('connections').doc(ids.join('_')).get();
  if (!context.mounted) return;
  if ((connection.data()?['status'] ?? '') == 'connected') {
    Navigator.push(context, MaterialPageRoute(builder: (_) => PrivateMemberProfilePage(uid: memberUid, initialData: d)));
  } else {
    Navigator.push(context, MaterialPageRoute(builder: (_) => PublicMemberProfilePage(uid: memberUid, initialData: d)));
  }
});})).toList())));
  }

  void _showMenu(BuildContext context) {
    showModalBottomSheet(context: context, backgroundColor: const Color(0xFF18181F), builder: (_) => SafeArea(child: ListTile(leading: const Icon(Icons.block_rounded, color: Colors.redAccent), title: const Text('Block Account', style: TextStyle(color: Colors.white)), onTap: () async { Navigator.pop(context); await ChatSettingsService.instance.setBlocked(uid, true); })));
  }
}