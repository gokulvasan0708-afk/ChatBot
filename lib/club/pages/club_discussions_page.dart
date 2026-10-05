import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../pages/app_theme.dart';
import '../../widgets/top_alert.dart';
import '../services/club_discussion_service.dart';

class ClubDiscussionsPage extends StatefulWidget {
  final String clubDocId;
  final bool canModerate;
  const ClubDiscussionsPage({super.key, required this.clubDocId, this.canModerate = false});
  @override State<ClubDiscussionsPage> createState() => _ClubDiscussionsPageState();
}

class _ClubDiscussionsPageState extends State<ClubDiscussionsPage> {
  String get _uid => FirebaseAuth.instance.currentUser?.uid ?? '';

  Future<void> _compose() async {
    final text = TextEditingController();
    bool spoiler = false;
    final created = await showModalBottomSheet<bool>(
      context: context, isScrollControlled: true, backgroundColor: AppColors.darkSheet,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: SafeArea(child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Start a discussion', style: TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w800)),
              const SizedBox(height: 14),
              TextField(controller: text, minLines: 4, maxLines: 8, maxLength: 3000,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(hintText: 'Share something with the club…', hintStyle: const TextStyle(color: Colors.white38), filled: true, fillColor: AppColors.darkCard, border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none))),
              SwitchListTile(contentPadding: EdgeInsets.zero, value: spoiler, onChanged: (v) => setSheet(() => spoiler = v), activeThumbColor: AppColors.tan,
                title: const Text('Mark as spoiler', style: TextStyle(color: Colors.white)), subtitle: const Text('Members can reveal and hide it again.', style: TextStyle(color: Colors.white54))),
              const SizedBox(height: 6),
              SizedBox(width: double.infinity, child: ElevatedButton(onPressed: () async {
                if (_uid.isEmpty) { showTopAlert(ctx, 'Please sign in first.', isError: true); return; }
                try {
                  final me = await FirebaseFirestore.instance.collection('users').doc(_uid).get();
                  final d = me.data() ?? {};
                  await ClubDiscussionService.createPost(clubId: widget.clubDocId, uid: _uid,
                    authorName: (d['publicName'] ?? 'Member').toString(), authorAvatar: (d['publicImage'] ?? '').toString(), text: text.text, spoiler: spoiler);
                  if (ctx.mounted) Navigator.pop(ctx, true);
                } catch (e) { if (ctx.mounted) showTopAlert(ctx, e.toString().replaceFirst('Exception: ', ''), isError: true); }
              }, child: const Text('Post'))),
            ]),
          )),
        );
      }),
    );
    text.dispose();
    if (created == true && mounted) showTopAlert(context, 'Discussion posted.');
  }

  @override Widget build(BuildContext context) {
    return Scaffold(backgroundColor: Colors.black, body: StreamBuilder<List<Map<String, dynamic>>>(
      stream: ClubDiscussionService.watchPosts(widget.clubDocId),
      builder: (context, snap) {
        if (snap.hasError) return _Message(icon: Icons.error_outline, title: 'Unable to load discussions', subtitle: snap.error.toString());
        if (snap.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator(color: AppColors.tan));
        final posts = [...(snap.data ?? const [])];
        posts.sort((a,b) => ((b['isPinned'] == true ? 1 : 0)).compareTo(a['isPinned'] == true ? 1 : 0));
        return Stack(children: [
          if (posts.isEmpty) const _Message(icon: Icons.forum_outlined, title: 'No discussions yet', subtitle: 'Start the first conversation in this club.')
          else ListView.builder(padding: const EdgeInsets.fromLTRB(14, 12, 14, 90), itemCount: posts.length, itemBuilder: (_, i) => _PostCard(
            clubId: widget.clubDocId, post: posts[i], uid: _uid, canModerate: widget.canModerate,
          )),
          Positioned(right: 18, bottom: 18, child: FloatingActionButton(onPressed: _compose, backgroundColor: AppColors.tan, foregroundColor: Colors.black, child: const Icon(Icons.edit_rounded))),
        ]);
      },
    ));
  }
}

class _PostCard extends StatefulWidget {
  final String clubId; final Map<String,dynamic> post; final String uid; final bool canModerate;
  const _PostCard({required this.clubId, required this.post, required this.uid, required this.canModerate});
  @override State<_PostCard> createState() => _PostCardState();
}
class _PostCardState extends State<_PostCard> {
  bool _revealed = false;
  bool _busy = false;
  bool get _liked => ((widget.post['likes'] as List?) ?? const []).contains(widget.uid);
  bool get _owner => widget.post['authorUid'] == widget.uid;
  String _time(dynamic value) { if (value is Timestamp) { final d = value.toDate(); final diff = DateTime.now().difference(d); if (diff.inMinutes < 1) return 'now'; if (diff.inHours < 1) return '${diff.inMinutes}m'; if (diff.inDays < 1) return '${diff.inHours}h'; return '${diff.inDays}d'; } return 'now'; }

  Future<void> _like() async { if (widget.uid.isEmpty || _busy) return; setState(() => _busy = true); try { await ClubDiscussionService.toggleLike(clubId: widget.clubId, postId: widget.post['id'], uid: widget.uid, liked: _liked); } finally { if (mounted) setState(() => _busy = false); } }
  Future<void> _comments() async { await showModalBottomSheet(context: context, isScrollControlled: true, backgroundColor: Colors.transparent, builder: (_) => _CommentsSheet(clubId: widget.clubId, postId: widget.post['id'],)); }
  Future<void> _share() async { await Clipboard.setData(ClipboardData(text: 'Discussion: ${(widget.post['text'] ?? '').toString()}\nPost ID: ${widget.post['id']}')); if (mounted) showTopAlert(context, 'Discussion copied.'); }
  Future<void> _report() async { final reasons = ['Spam','Harassment','Off-topic','Copyright','Other']; final reason = await showModalBottomSheet<String>(context: context, backgroundColor: AppColors.darkSheet, builder: (_) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [const Padding(padding: EdgeInsets.all(16), child: Text('Report discussion', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold))), ...reasons.map((r) => ListTile(title: Text(r, style: const TextStyle(color: Colors.white)), onTap: () => Navigator.pop(context, r)))]))); if (reason == null || widget.uid.isEmpty) return; await ClubDiscussionService.reportPost(clubId: widget.clubId, postId: widget.post['id'], reporterUid: widget.uid, targetUid: (widget.post['authorUid'] ?? '').toString(), reason: reason); if (mounted) showTopAlert(context, 'Report submitted.'); }
  Future<void> _delete() async { await ClubDiscussionService.deletePost(clubId: widget.clubId, postId: widget.post['id']); if (mounted) showTopAlert(context, 'Discussion deleted.'); }

  @override Widget build(BuildContext context) {
    final spoiler = widget.post['isSpoiler'] == true;
    final hidden = spoiler && !_revealed;
    final likes = ((widget.post['likes'] as List?) ?? const []).length;
    final comments = (widget.post['commentCount'] ?? 0) as num;
    return Container(margin: const EdgeInsets.only(bottom: 12), padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: AppColors.darkCard, borderRadius: BorderRadius.circular(18), border: Border.all(color: AppColors.darkCardBorder)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [CircleAvatar(radius: 19, backgroundColor: AppColors.darkAvatarBg, backgroundImage: (widget.post['authorAvatar'] ?? '').toString().isNotEmpty ? NetworkImage(widget.post['authorAvatar']) : null, child: (widget.post['authorAvatar'] ?? '').toString().isEmpty ? const Icon(Icons.person, color: AppColors.tan) : null), const SizedBox(width: 10), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text((widget.post['authorName'] ?? 'Member').toString(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)), Row(children: [if (widget.post['isPinned'] == true) const Icon(Icons.push_pin, size: 13, color: AppColors.tan), if (widget.post['isPinned'] == true) const SizedBox(width: 3), Text(_time(widget.post['createdAt']), style: const TextStyle(color: Colors.white38, fontSize: 12))])])), PopupMenuButton<String>(iconColor: Colors.white54, onSelected: (v) async { if (v == 'report') await _report(); if (v == 'delete') await _delete(); if (v == 'pin') await ClubDiscussionService.togglePin(clubId: widget.clubId, postId: widget.post['id'], pinned: widget.post['isPinned'] == true); }, itemBuilder: (_) => [if (widget.canModerate) PopupMenuItem(value: 'pin', child: Text(widget.post['isPinned'] == true ? 'Unpin' : 'Pin')), if (_owner || widget.canModerate) const PopupMenuItem(value: 'delete', child: Text('Delete')), if (!_owner) const PopupMenuItem(value: 'report', child: Text('Report'))])]),
      const SizedBox(height: 10),
      if (spoiler && hidden) GestureDetector(onTap: () => setState(() => _revealed = true), child: Container(width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16), decoration: BoxDecoration(color: Colors.black.withValues(alpha: .35), borderRadius: BorderRadius.circular(14)), child: const Column(children: [Icon(Icons.visibility_off_rounded, color: AppColors.tan, size: 28), SizedBox(height: 7), Text('Spoiler hidden — tap to reveal', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w700))]))) else Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text((widget.post['text'] ?? '').toString(), style: const TextStyle(color: Colors.white, height: 1.45, fontSize: 14)), if (spoiler) Align(alignment: Alignment.centerRight, child: TextButton(onPressed: () => setState(() => _revealed = false), child: const Text('Hide spoiler again')))]),
      const SizedBox(height: 8), const Divider(color: Colors.white10, height: 1),
      Row(children: [TextButton.icon(onPressed: _like, icon: Icon(_liked ? Icons.favorite_rounded : Icons.favorite_border_rounded, size: 18, color: _liked ? Colors.redAccent : Colors.white54), label: Text('$likes', style: const TextStyle(color: Colors.white60))), TextButton.icon(onPressed: _comments, icon: const Icon(Icons.chat_bubble_outline_rounded, size: 18, color: Colors.white54), label: Text('$comments', style: const TextStyle(color: Colors.white60))), TextButton.icon(onPressed: _share, icon: const Icon(Icons.share_outlined, size: 18, color: Colors.white54), label: const Text('Share', style: TextStyle(color: Colors.white60)))])
    ]));
  }
}

class _CommentsSheet extends StatefulWidget { final String clubId, postId; const _CommentsSheet({required this.clubId, required this.postId}); @override State<_CommentsSheet> createState() => _CommentsSheetState(); }
class _CommentsSheetState extends State<_CommentsSheet> {
  final _input = TextEditingController(); String? _replyId; String? _replyName; bool _sending = false; String get _uid => FirebaseAuth.instance.currentUser?.uid ?? '';
  @override void dispose(){_input.dispose();super.dispose();}
  Future<void> _send() async { final text=_input.text.trim(); if(text.isEmpty||_uid.isEmpty||_sending)return; setState(()=>_sending=true); try { final me=await FirebaseFirestore.instance.collection('users').doc(_uid).get(); final d=me.data()??{}; await ClubDiscussionService.addComment(clubId:widget.clubId,postId:widget.postId,uid:_uid,authorName:(d['publicName']??'Member').toString(),authorAvatar:(d['publicImage']??'').toString(),text:text,parentId:_replyId??''); _input.clear(); setState(()=>_replyId=null); }catch(e){if(mounted)showTopAlert(context,e.toString().replaceFirst('Exception: ',''),isError:true);}finally{if(mounted)setState(()=>_sending=false);}}
  @override Widget build(BuildContext context){ final inset=MediaQuery.of(context).viewInsets.bottom; return Padding(padding:EdgeInsets.only(bottom:inset),child:Container(height:MediaQuery.of(context).size.height*.82,decoration:const BoxDecoration(color:AppColors.darkSheet,borderRadius:BorderRadius.vertical(top:Radius.circular(24))),child:Column(children:[const Padding(padding:EdgeInsets.all(16),child:Text('Comments',style:TextStyle(color:Colors.white,fontSize:18,fontWeight:FontWeight.bold))),Expanded(child:StreamBuilder<List<Map<String,dynamic>>>(stream:ClubDiscussionService.watchComments(widget.clubId,widget.postId),builder:(c,s){if(s.connectionState==ConnectionState.waiting)return const Center(child:CircularProgressIndicator(color:AppColors.tan));final all=s.data??[];final top=all.where((x)=>(x['parentId']??'').toString().isEmpty).toList();if(top.isEmpty)return const Center(child:Text('No comments yet',style:TextStyle(color:Colors.white54)));return ListView(padding:const EdgeInsets.symmetric(horizontal:14),children:[for(final item in top)_Comment(comment:item,onReply:()=>setState(() { _replyId=item['id'].toString(); _replyName=(item['authorName']??'Member').toString(); })),for(final reply in all.where((x)=>(x['parentId']??'').toString().isNotEmpty))Padding(padding:const EdgeInsets.only(left:34),child:_Comment(comment:reply,onReply:()=>setState(() { _replyId=reply['id'].toString(); _replyName=(reply['authorName']??'Member').toString(); })))]);})),if(_replyName!=null)Padding(padding:const EdgeInsets.symmetric(horizontal:16,vertical:5),child:Row(children:[Expanded(child:Text('Replying to $_replyName',style:const TextStyle(color:AppColors.tan))),IconButton(onPressed:()=>setState(()=>_replyName=null),icon:const Icon(Icons.close,color:Colors.white54))])),Padding(padding:const EdgeInsets.fromLTRB(14,6,10,14),child:Row(children:[Expanded(child:TextField(controller:_input,maxLines:4,style:const TextStyle(color:Colors.white),decoration:InputDecoration(hintText:'Write a comment…',hintStyle:const TextStyle(color:Colors.white38),filled:true,fillColor:AppColors.darkCard,border:OutlineInputBorder(borderRadius:BorderRadius.all(Radius.circular(18)),borderSide:BorderSide.none)))),IconButton(onPressed:_sending?null:_send,icon:const Icon(Icons.send_rounded,color:AppColors.tan))]))]))); }
}
class _Comment extends StatelessWidget { final Map<String,dynamic> comment; final VoidCallback onReply; const _Comment({required this.comment,required this.onReply}); @override Widget build(BuildContext context)=>Padding(padding:const EdgeInsets.symmetric(vertical:7),child:Row(crossAxisAlignment:CrossAxisAlignment.start,children:[CircleAvatar(radius:15,backgroundColor:AppColors.darkAvatarBg,backgroundImage:(comment['authorAvatar']??'').toString().isNotEmpty?NetworkImage(comment['authorAvatar']):null,child:(comment['authorAvatar']??'').toString().isEmpty?const Icon(Icons.person,size:16,color:AppColors.tan):null),const SizedBox(width:9),Expanded(child:Container(padding:const EdgeInsets.all(11),decoration:BoxDecoration(color:AppColors.darkCard,borderRadius:BorderRadius.circular(14)),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text((comment['authorName']??'Member').toString(),style:const TextStyle(color:Colors.white,fontWeight:FontWeight.w700,fontSize:13)),const SizedBox(height:3),Text((comment['text']??'').toString(),style:const TextStyle(color:Colors.white70,height:1.35)),TextButton(onPressed:onReply,style:TextButton.styleFrom(padding:EdgeInsets.zero),child:const Text('Reply',style:TextStyle(color:AppColors.tan,fontSize:12)))])))]));
}
class _Message extends StatelessWidget { final IconData icon; final String title,subtitle; const _Message({required this.icon,required this.title,required this.subtitle}); @override Widget build(BuildContext context)=>Center(child:Padding(padding:const EdgeInsets.all(30),child:Column(mainAxisSize:MainAxisSize.min,children:[Icon(icon,size:42,color:AppColors.tan),const SizedBox(height:12),Text(title,style:const TextStyle(color:Colors.white,fontSize:18,fontWeight:FontWeight.bold)),const SizedBox(height:6),Text(subtitle,textAlign:TextAlign.center,style:const TextStyle(color:Colors.white54))])));}