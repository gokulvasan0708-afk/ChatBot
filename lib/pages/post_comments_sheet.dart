import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/community_feed_service.dart';
import '../services/community_service.dart';
import '../widgets/community_widgets.dart';
import '../widgets/top_alert.dart';

// ================================================================
// POST COMMENTS SHEET  (Feed -- Comment + Reply)
// ----------------------------------------------------------------
// Top-level comments with one level of replies (parentId). Authors,
// the post author and Community admins/moderators can delete.
// ================================================================
class PostCommentsSheet extends StatefulWidget {
  final String postId;
  final Map<String, dynamic> community;

  const PostCommentsSheet({
    super.key,
    required this.postId,
    required this.community,
  });

  @override
  State<PostCommentsSheet> createState() => _PostCommentsSheetState();
}

class _PostCommentsSheetState extends State<PostCommentsSheet> {
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();

  Map<String, dynamic>? _replyTo; // top-level comment being replied to
  bool _sending = false;
  Map<String, String>? _me; // name / avatar cache

  String get _uid => FirebaseAuth.instance.currentUser?.uid ?? '';

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<Map<String, String>> _loadMe() async {
    if (_me != null) return _me!;
    final doc =
        await FirebaseFirestore.instance.collection('users').doc(_uid).get();
    final d = doc.data() ?? {};
    _me = {
      'name': (d['publicName'] ?? 'Member').toString(),
      'avatar': (d['publicImage'] ?? '').toString(),
    };
    return _me!;
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;

    setState(() => _sending = true);
    try {
      final me = await _loadMe();
      await CommunityFeedService.addComment(
        postId: widget.postId,
        uid: _uid,
        authorName: me['name']!,
        authorAvatarUrl: me['avatar']!,
        text: text,
        parentId: (_replyTo?['id'] ?? '').toString(),
      );
      if (!mounted) return;
      _input.clear();
      setState(() {
        _replyTo = null;
        _sending = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      showTopAlert(context, e.toString().replaceFirst('Exception: ', ''),
          isError: true);
    }
  }

  Future<void> _delete(Map<String, dynamic> comment) async {
    try {
      await CommunityFeedService.deleteComment(
        postId: widget.postId,
        commentId: (comment['id'] ?? '').toString(),
        requesterUid: _uid,
        community: widget.community,
      );
    } catch (e) {
      if (!mounted) return;
      showTopAlert(context, e.toString().replaceFirst('Exception: ', ''),
          isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.of(context).viewInsets.bottom;
    final height = MediaQuery.of(context).size.height * .8;

    return Padding(
      padding: EdgeInsets.only(bottom: inset),
      child: SizedBox(
        height: height,
        child: CommunitySheetShell(
          title: 'Comments',
          child: Column(
            children: [
              Expanded(
                child: StreamBuilder<List<Map<String, dynamic>>>(
                  stream: CommunityFeedService.watchComments(widget.postId),
                  builder: (context, snap) {
                    if (snap.hasError) {
                      return const CommunityStateMessage(
                        icon: Icons.error_outline_rounded,
                        title: 'Unable to load comments',
                        subtitle: 'Please try again in a moment.',
                      );
                    }
                    if (snap.connectionState == ConnectionState.waiting) {
                      return const CommunityLoading();
                    }

                    final all = snap.data ?? [];
                    final top = all
                        .where((c) => (c['parentId'] ?? '').toString().isEmpty)
                        .toList();
                    final repliesByParent = <String, List<Map<String, dynamic>>>{};
                    for (final c in all) {
                      final p = (c['parentId'] ?? '').toString();
                      if (p.isEmpty) continue;
                      repliesByParent.putIfAbsent(p, () => []).add(c);
                    }

                    if (top.isEmpty) {
                      return const CommunityStateMessage(
                        icon: Icons.chat_bubble_outline_rounded,
                        title: 'No comments yet',
                        subtitle: 'Start the conversation.',
                      );
                    }

                    return ListView(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                      children: [
                        for (final c in top) ...[
                          _CommentTile(
                            comment: c,
                            canDelete: _canDelete(c),
                            onReply: () => setState(() {
                              _replyTo = c;
                              _focus.requestFocus();
                            }),
                            onDelete: () => _delete(c),
                          ),
                          for (final r in repliesByParent[c['id']] ?? const [])
                            Padding(
                              padding: const EdgeInsets.only(left: 38),
                              child: _CommentTile(
                                comment: r,
                                canDelete: _canDelete(r),
                                isReply: true,
                                onReply: () => setState(() {
                                  _replyTo = c; // replies stay one level deep
                                  _focus.requestFocus();
                                }),
                                onDelete: () => _delete(r),
                              ),
                            ),
                        ],
                      ],
                    );
                  },
                ),
              ),
              if (_replyTo != null)
                Container(
                  color: const Color(0xFF18181F),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Replying to ${(_replyTo!['authorName'] ?? 'Member')}',
                          style: const TextStyle(
                              color: CommunityColors.tan, fontSize: 12.5),
                        ),
                      ),
                      GestureDetector(
                        onTap: () => setState(() => _replyTo = null),
                        child: const Icon(Icons.close_rounded,
                            color: Colors.white54, size: 18),
                      ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 12, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _input,
                        focusNode: _focus,
                        minLines: 1,
                        maxLines: 4,
                        maxLength: 1000,
                        style: const TextStyle(color: Colors.white),
                        decoration: communityInputDecoration(
                                _replyTo == null
                                    ? 'Add a comment…'
                                    : 'Write a reply…')
                            .copyWith(counterText: ''),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _sending
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: CommunityColors.tan),
                            ),
                          )
                        : IconButton(
                            onPressed: _send,
                            icon: const Icon(Icons.send_rounded,
                                color: CommunityColors.tan),
                          ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool _canDelete(Map<String, dynamic> c) =>
      (c['authorUid'] ?? '').toString() == _uid ||
      CommunityService.isPrivileged(widget.community, _uid);
}

class _CommentTile extends StatelessWidget {
  final Map<String, dynamic> comment;
  final bool canDelete;
  final bool isReply;
  final VoidCallback onReply;
  final VoidCallback onDelete;

  const _CommentTile({
    required this.comment,
    required this.canDelete,
    required this.onReply,
    required this.onDelete,
    this.isReply = false,
  });

  @override
  Widget build(BuildContext context) {
    final name = (comment['authorName'] ?? 'Member').toString();
    final created = communityToDate(comment['createdAt']);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CommunityAvatar(
            url: (comment['authorAvatarUrl'] ?? '').toString(),
            name: name,
            radius: isReply ? 12 : 15,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 13)),
                    ),
                    const SizedBox(width: 8),
                    Text(communityTimeAgo(created),
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 11)),
                  ],
                ),
                const SizedBox(height: 3),
                Text((comment['text'] ?? '').toString(),
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 13.5, height: 1.35)),
                const SizedBox(height: 4),
                Row(
                  children: [
                    GestureDetector(
                      onTap: onReply,
                      child: const Text('Reply',
                          style: TextStyle(
                              color: CommunityColors.tan,
                              fontSize: 12,
                              fontWeight: FontWeight.w600)),
                    ),
                    if (canDelete) ...[
                      const SizedBox(width: 16),
                      GestureDetector(
                        onTap: onDelete,
                        child: const Text('Delete',
                            style: TextStyle(
                                color: CommunityColors.danger, fontSize: 12)),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
