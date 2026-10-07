import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../../pages/app_theme.dart';
import '../../widgets/top_alert.dart';
import '../services/club_watchlist_service.dart';

class ClubWatchlistPage extends StatefulWidget {
  final String clubDocId;
  const ClubWatchlistPage({super.key, required this.clubDocId});
  @override State<ClubWatchlistPage> createState() => _ClubWatchlistPageState();
}

class _ClubWatchlistPageState extends State<ClubWatchlistPage> {
  String query = '';
  String get uid => FirebaseAuth.instance.currentUser?.uid ?? '';

  Future<void> _add() async {
    if (uid.isEmpty) return;
    final title = TextEditingController();
    final thumb = TextEditingController();
    final progress = TextEditingController();
    final id = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      backgroundColor: const Color(0xFF18181F),
      title: const Text('Add to Watchlist', style: TextStyle(color: Colors.white)),
      content: SingleChildScrollView(child: Column(children: [
        _field(id, 'Content ID'), _field(title, 'Title'), _field(thumb, 'Thumbnail URL'), _field(progress, 'Progress (optional)'),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')), ElevatedButton(onPressed: () => Navigator.pop(c, true), child: const Text('Save'))],
    ));
    if (ok != true || title.text.trim().isEmpty) { for (final x in [title, thumb, progress, id]) {
      x.dispose();
    } return; }
    try {
      final contentId = id.text.trim().isEmpty ? title.text.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-') : id.text.trim();
      await ClubWatchlistService.save(clubId: widget.clubDocId, uid: uid, contentId: contentId, title: title.text.trim(), thumbnailUrl: thumb.text.trim(), progress: progress.text.trim());
      if (mounted) showTopAlert(context, 'Added to watchlist.');
    } catch (e) { if (mounted) showTopAlert(context, 'Unable to save item.', isError: true); }
    for (final x in [title, thumb, progress, id]) {
      x.dispose();
    }
  }

  @override Widget build(BuildContext context) {
    if (uid.isEmpty) return const Center(child: Text('Sign in to use Watchlist', style: TextStyle(color: Colors.white54)));
    return Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 10), child: Row(children: [
        Expanded(child: TextField(onChanged: (v) => setState(() => query = v.toLowerCase()), style: const TextStyle(color: Colors.white), decoration: _decoration('Search watchlist', Icons.search))),
        const SizedBox(width: 8), IconButton(onPressed: _add, icon: const Icon(Icons.add_circle_rounded, color: AppColors.tan, size: 30)),
      ])),
      Expanded(child: StreamBuilder<QuerySnapshot<Map<String,dynamic>>>(stream: ClubWatchlistService.watch(widget.clubDocId, uid), builder: (context, snap) {
        if (snap.hasError) return const Center(child: Text('Unable to load watchlist', style: TextStyle(color: Colors.white54)));
        if (!snap.hasData) return const Center(child: CircularProgressIndicator(color: AppColors.tan));
        final docs = snap.data!.docs.where((d) => (d.data()['title'] ?? '').toString().toLowerCase().contains(query)).toList();
        if (docs.isEmpty) return const Center(child: Text('No saved content', style: TextStyle(color: Colors.white54)));
        return ListView.builder(padding: const EdgeInsets.fromLTRB(16, 0, 16, 20), itemCount: docs.length, itemBuilder: (_, i) {
          final d = docs[i]; final x = d.data();
          return Container(margin: const EdgeInsets.only(bottom: 10), decoration: BoxDecoration(color: const Color(0xFF18181F), borderRadius: BorderRadius.circular(16)), child: ListTile(
            leading: ClipRRect(borderRadius: BorderRadius.circular(9), child: SizedBox(width: 72, height: 54, child: _thumb(x['thumbnailUrl']?.toString() ?? ''))),
            title: Text(x['title']?.toString() ?? 'Untitled', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            subtitle: Text('${x['progress']?.toString().isNotEmpty == true ? x['progress'] : 'No progress'} • ${x['status'] ?? 'Saved'}', style: const TextStyle(color: Colors.white54)),
            trailing: PopupMenuButton<String>(color: const Color(0xFF18181F), onSelected: (v) async { if (v == 'remove') await ClubWatchlistService.remove(clubId: widget.clubDocId, uid: uid, itemId: d.id); if (v == 'done') await ClubWatchlistService.update(clubId: widget.clubDocId, uid: uid, itemId: d.id, status: 'Completed'); }, itemBuilder: (_) => const [PopupMenuItem(value:'done', child: Text('Mark completed', style: TextStyle(color: Colors.white))), PopupMenuItem(value:'remove', child: Text('Remove', style: TextStyle(color: Colors.redAccent)))]),
          ));
        });
      }))
    ]);
  }
  InputDecoration _decoration(String hint, IconData icon) => InputDecoration(hintText: hint, hintStyle: const TextStyle(color: Colors.white38), prefixIcon: Icon(icon, color: AppColors.tan), filled: true, fillColor: const Color(0xFF18181F), border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none));
  Widget _field(TextEditingController c, String label) => Padding(padding: const EdgeInsets.only(bottom: 10), child: TextField(controller:c, style:const TextStyle(color:Colors.white), decoration: InputDecoration(labelText:label,labelStyle:const TextStyle(color:Colors.white54), filled:true, fillColor:const Color(0xFF20202A), border:OutlineInputBorder(borderRadius:BorderRadius.all(Radius.circular(12))))));
  Widget _thumb(String url) => url.isEmpty ? const ColoredBox(color: Color(0xFF20202A), child: Icon(Icons.movie_rounded, color: Colors.white38)) : Image.network(url, fit: BoxFit.cover, errorBuilder: (_, _, _) => const ColoredBox(color: Color(0xFF20202A), child: Icon(Icons.broken_image_rounded, color: Colors.white38)));
}
