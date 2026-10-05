import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../../pages/app_theme.dart';
import '../services/club_notification_service.dart';

class ClubNotificationsPage extends StatelessWidget {
  const ClubNotificationsPage({super.key});
  @override Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty) return const Center(child: Text('Sign in to view notifications', style: TextStyle(color: Colors.white54)));
    return Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(16, 2, 16, 8), child: Row(children: [const Expanded(child: Text('Notifications', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800))), TextButton(onPressed: () => ClubNotificationService.markAllRead(uid), child: const Text('Mark all read'))])),
      Expanded(child: StreamBuilder(stream: ClubNotificationService.watch(uid), builder: (context, snap) {
        if (!snap.hasData) return const Center(child: CircularProgressIndicator(color: AppColors.tan));
        final docs = snap.data!.docs;
        if (docs.isEmpty) return const Center(child: Text('No club notifications', style: TextStyle(color: Colors.white54)));
        return ListView.builder(padding: const EdgeInsets.symmetric(horizontal: 16), itemCount: docs.length, itemBuilder: (_, i) {
          final d = docs[i]; final x = d.data(); final read = x['isRead'] == true;
          return Dismissible(key: ValueKey(d.id), direction: DismissDirection.endToStart, onDismissed: (_) => ClubNotificationService.delete(uid, d.id), background: Container(margin: const EdgeInsets.only(bottom:8), alignment:Alignment.centerRight, padding:const EdgeInsets.only(right:20), decoration:BoxDecoration(color:Colors.redAccent, borderRadius:BorderRadius.circular(15)), child:const Icon(Icons.delete,color:Colors.white)), child: Card(color: read ? const Color(0xFF1B120A) : const Color(0xFF2A1D12), child: ListTile(onTap: () => ClubNotificationService.markRead(uid, d.id), leading: Icon(read ? Icons.notifications_none_rounded : Icons.notifications_active_rounded, color: AppColors.tan), title: Text(x['title']?.toString() ?? 'Club notification', style: const TextStyle(color:Colors.white,fontWeight:FontWeight.w700)), subtitle: Text(x['body']?.toString() ?? '', style:const TextStyle(color:Colors.white60)), trailing: read ? null : const CircleAvatar(radius:4, backgroundColor:AppColors.tan))));
        });
      }))
    ]);
  }
}