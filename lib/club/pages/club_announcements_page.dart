import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../pages/app_theme.dart';
import '../../services/user_profile_service.dart';
import '../../widgets/top_alert.dart';
import '../services/club_announcement_service.dart';

class ClubAnnouncementsPage extends StatelessWidget {
  final String clubDocId;
  final bool canModerate;

  const ClubAnnouncementsPage({super.key, required this.clubDocId, required this.canModerate});

  Future<void> _create(BuildContext context) async {
    final title = TextEditingController();
    final description = TextEditingController();
    final profile = await UserProfileService.getCurrentUserProfile();
    final user = FirebaseAuth.instance.currentUser;
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF18181F),
      builder: (sheet) => Padding(
        padding: EdgeInsets.fromLTRB(18, 18, 18, MediaQuery.of(sheet).viewInsets.bottom + 18),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('New Announcement', style: TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.bold)),
          const SizedBox(height: 14),
          TextField(controller: title, style: const TextStyle(color: Colors.white), decoration: _decoration('Title')),
          const SizedBox(height: 10),
          TextField(controller: description, minLines: 3, maxLines: 6, style: const TextStyle(color: Colors.white), decoration: _decoration('Description')),
          const SizedBox(height: 14),
          SizedBox(width: double.infinity, child: FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.tan, foregroundColor: Colors.black),
            onPressed: () async {
              try {
                await ClubAnnouncementService.create(
                  clubId: clubDocId,
                  authorUid: user?.uid ?? '',
                  authorName: (profile?['publicName'] ?? user?.displayName ?? 'Member').toString(),
                  authorAvatar: (profile?['publicImage'] ?? user?.photoURL ?? '').toString(),
                  title: title.text,
                  description: description.text,
                );
                if (sheet.mounted) Navigator.pop(sheet);
                if (context.mounted) showTopAlert(context, 'Announcement published.');
              } catch (e) {
                if (context.mounted) showTopAlert(context, e.toString().replaceFirst('Exception: ', ''), isError: true);
              }
            }, child: const Text('Publish'),
          )),
        ]),
      ),
    );
  }

  static InputDecoration _decoration(String hint) => InputDecoration(
    hintText: hint, hintStyle: const TextStyle(color: Colors.white38),
    filled: true, fillColor: const Color(0xFF20202A),
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
  );

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: ClubAnnouncementService.watch(clubDocId),
      builder: (context, snapshot) {
        if (snapshot.hasError) return const Center(child: Text('Unable to load announcements', style: TextStyle(color: Colors.white70)));
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator(color: AppColors.tan));
        final docs = [...snapshot.data!.docs];
        docs.sort((a, b) {
          final pa = a.data()['isPinned'] == true;
          final pb = b.data()['isPinned'] == true;
          if (pa != pb) return pa ? -1 : 1;
          return 0;
        });
        return Column(children: [
          Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 8), child: Row(children: [
            const Expanded(child: Text('Announcements', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold))),
            if (canModerate) IconButton(onPressed: () => _create(context), icon: const Icon(Icons.add_rounded, color: AppColors.tan)),
          ])),
          Expanded(child: docs.isEmpty
            ? const Center(child: Text('No announcements yet.', style: TextStyle(color: Colors.white54)))
            : ListView.builder(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), itemCount: docs.length, itemBuilder: (context, i) {
                final doc = docs[i];
                final data = doc.data();
                final readBy = List<String>.from(data['readBy'] ?? const []);
                final unread = !readBy.contains(uid);
                final ts = data['createdAt'] as Timestamp?;
                return Card(
                  color: const Color(0xFF18181F), margin: const EdgeInsets.only(bottom: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: unread ? AppColors.tan.withValues(alpha: .5) : Colors.white10)),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(18),
                    onTap: () => ClubAnnouncementService.markRead(clubId: clubDocId, announcementId: doc.id, uid: uid),
                    child: Padding(padding: const EdgeInsets.all(15), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        if (data['isPinned'] == true) const Icon(Icons.push_pin_rounded, size: 17, color: AppColors.tan),
                        if (data['isPinned'] == true) const SizedBox(width: 6),
                        Expanded(child: Text(data['title']?.toString() ?? '', style: TextStyle(color: Colors.white, fontWeight: unread ? FontWeight.w800 : FontWeight.w600, fontSize: 16))),
                        if (unread) Container(width: 8, height: 8, decoration: const BoxDecoration(color: AppColors.tan, shape: BoxShape.circle)),
                        if (canModerate) PopupMenuButton<String>(color: const Color(0xFF20202A), onSelected: (v) async {
                          if (v == 'pin') await ClubAnnouncementService.setPinned(clubId: clubDocId, announcementId: doc.id, pinned: data['isPinned'] != true);
                          if (v == 'delete') await ClubAnnouncementService.delete(clubId: clubDocId, announcementId: doc.id);
                        }, itemBuilder: (_) => [
                          PopupMenuItem(value: 'pin', child: Text(data['isPinned'] == true ? 'Unpin' : 'Pin', style: const TextStyle(color: Colors.white))),
                          const PopupMenuItem(value: 'delete', child: Text('Delete', style: TextStyle(color: Colors.redAccent))),
                        ]),
                      ]),
                      const SizedBox(height: 8),
                      Text(data['description']?.toString() ?? '', style: const TextStyle(color: Colors.white70, height: 1.45)),
                      const SizedBox(height: 10),
                      Text('${data['authorName'] ?? 'Moderator'} • ${ts == null ? 'Just now' : _time(ts.toDate())}', style: const TextStyle(color: Colors.white38, fontSize: 11)),
                    ])),
                  ),
                );
              })),
        ]);
      },
    );
  }

  static String _time(DateTime value) {
    final d = DateTime.now().difference(value);
    if (d.inMinutes < 1) return 'Just now';
    if (d.inHours < 1) return '${d.inMinutes}m ago';
    if (d.inDays < 1) return '${d.inHours}h ago';
    if (d.inDays < 7) return '${d.inDays}d ago';
    return '${value.day}/${value.month}/${value.year}';
  }
}
