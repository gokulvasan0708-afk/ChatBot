import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../pages/app_theme.dart';
import '../models/club_model.dart';

class ClubMembersPage extends StatefulWidget {
  final ClubModel club;
  const ClubMembersPage({super.key, required this.club});

  @override
  State<ClubMembersPage> createState() => _ClubMembersPageState();
}

class _ClubMembersPageState extends State<ClubMembersPage> {
  final _search = TextEditingController();

  Stream<QuerySnapshot<Map<String, dynamic>>> get _users =>
      FirebaseFirestore.instance.collection('users').where('uid', whereIn: widget.club.memberUids.take(10).toList()).snapshots();

  void _showProfile(BuildContext context, Map<String, dynamic> data, String uid) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF18181F),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          CircleAvatar(radius: 38, backgroundImage: (data['publicImage'] ?? '').toString().isNotEmpty ? NetworkImage(data['publicImage']) : null, child: (data['publicImage'] ?? '').toString().isEmpty ? const Icon(Icons.person, size: 34) : null),
          const SizedBox(height: 12),
          Text((data['publicName'] ?? data['userId'] ?? 'Member').toString(), style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text('@${data['userId'] ?? uid}', style: const TextStyle(color: Colors.white54)),
          const SizedBox(height: 12),
          Text((data['bio'] ?? '').toString().isEmpty ? 'No bio added.' : data['bio'].toString(), textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, height: 1.4)),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ids = widget.club.memberUids;
    if (ids.isEmpty) return const Center(child: Text('No members yet.', style: TextStyle(color: Colors.white54)));
    return Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 10), child: TextField(
        controller: _search, onChanged: (_) => setState(() {}), style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(hintText: 'Search members', hintStyle: const TextStyle(color: Colors.white38), prefixIcon: const Icon(Icons.search, color: Colors.white54), filled: true, fillColor: const Color(0xFF18181F), border: OutlineInputBorder(borderRadius: BorderRadius.circular(15), borderSide: BorderSide.none)),
      )),
      Expanded(child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: ids.length <= 10 ? _users : FirebaseFirestore.instance.collection('users').snapshots(),
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator(color: AppColors.tan));
          final docs = snap.data!.docs.where((d) => ids.contains(d.id) || ids.contains(d.data()['uid']?.toString())).toList();
          final q = _search.text.trim().toLowerCase();
          final filtered = docs.where((d) {
            final x = d.data();
            final name = (x['publicName'] ?? x['userId'] ?? '').toString().toLowerCase();
            return q.isEmpty || name.contains(q);
          }).toList();
          return ListView.builder(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), itemCount: filtered.length, itemBuilder: (context, i) {
            final data = filtered[i].data();
            final uid = (data['uid'] ?? filtered[i].id).toString();
            final role = uid == widget.club.ownerUid ? 'Owner' : widget.club.moderatorUids.contains(uid) ? 'Moderator' : 'Member';
            final online = data['online'] == true;
            return Card(color: const Color(0xFF18181F), margin: const EdgeInsets.only(bottom: 8), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)), child: ListTile(
              onTap: () => _showProfile(context, data, uid),
              leading: Stack(children: [CircleAvatar(radius: 23, backgroundImage: (data['publicImage'] ?? '').toString().isNotEmpty ? NetworkImage(data['publicImage']) : null, child: (data['publicImage'] ?? '').toString().isEmpty ? const Icon(Icons.person) : null), if (online) Positioned(right: 0, bottom: 1, child: Container(width: 11, height: 11, decoration: BoxDecoration(color: Color(0xFF10B981), shape: BoxShape.circle, border: Border.all(color: const Color(0xFF18181F), width: 2))))]),
              title: Text((data['publicName'] ?? data['userId'] ?? 'Member').toString(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
              subtitle: Text('@${data['userId'] ?? uid} • $role', style: TextStyle(color: role == 'Member' ? Colors.white54 : AppColors.tan, fontSize: 12)),
              trailing: const Icon(Icons.chevron_right_rounded, color: Colors.white38),
            ));
          });
        },
      )),
    ]);
  }
}
