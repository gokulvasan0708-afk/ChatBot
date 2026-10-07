import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'community_poll_card.dart';
import 'post_comments_sheet.dart';
import 'share_post_sheet.dart';
import '../services/community_activity_service.dart';
import '../services/community_feed_service.dart';
import '../services/community_media_service.dart';
import '../services/community_service.dart';
import '../widgets/community_widgets.dart';
import '../widgets/top_alert.dart';

// ================================================================
// COMMUNITY POST CARD  (Feed -- Section 6)
// ----------------------------------------------------------------
// Renders any post type and exposes every action from the spec:
// like/reaction, comment, reply (inside the comments sheet), share
// within Nexus, save, report, edit own, delete own (or moderate),
// pin (authorized users), mark resolved (author).
// ================================================================
class CommunityPostCard extends StatelessWidget {
  final Map<String, dynamic> post;
  final Map<String, dynamic> community;
  final String communityName;
  final ValueChanged<String>? onHashtagTap;

  /// Hides the author-header actions in compact contexts.
  final bool showMenu;

  /// Shows "Highlight" for an achievement. Only Community owners/admins/
  /// moderators get it (see HighlightScope). The write is re-checked in
  /// CommunityActivityService.setHighlighted.
  final bool highlightAllowed;

  const CommunityPostCard({
    super.key,
    required this.post,
    required this.community,
    required this.communityName,
    this.onHashtagTap,
    this.showMenu = true,
    this.highlightAllowed = false,
  });

  String get _uid => FirebaseAuth.instance.currentUser?.uid ?? '';
  String get _postId => (post['id'] ?? '').toString();
  String get _type => (post['type'] ?? 'text').toString();

  String _clean(Object e) => e.toString().replaceFirst('Exception: ', '');

  // ------------------------------------------------------------
  // Actions
  // ------------------------------------------------------------

  Future<void> _react(BuildContext context, String emoji) async {
    final reactions = post['reactions'] is Map ? post['reactions'] as Map : {};
    final current = (reactions[_uid] ?? '').toString();
    try {
      await CommunityFeedService.toggleReaction(
        postId: _postId,
        uid: _uid,
        emoji: emoji,
        currentEmoji: current,
      );
    } catch (e) {
      if (context.mounted) showTopAlert(context, _clean(e), isError: true);
    }
  }

  void _showReactionPicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: CommunityColors.card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (final e in CommunityFeedService.reactionEmojis)
                GestureDetector(
                  onTap: () {
                    Navigator.pop(ctx);
                    _react(context, e);
                  },
                  child: Text(e, style: const TextStyle(fontSize: 32)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _toggleSave(BuildContext context, bool currentlySaved) async {
    try {
      await CommunityFeedService.setSaved(
          postId: _postId, uid: _uid, saved: !currentlySaved);
      if (context.mounted) {
        showTopAlert(context, currentlySaved ? 'Removed from saved' : 'Post saved',
            icon: Icons.bookmark_rounded);
      }
    } catch (e) {
      if (context.mounted) showTopAlert(context, _clean(e), isError: true);
    }
  }

  void _openComments(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => PostCommentsSheet(postId: _postId, community: community),
    );
  }

  void _openShare(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SharePostSheet(post: post, communityName: communityName),
    );
  }

  Future<void> _edit(BuildContext context) async {
    final hasTitle = _type == 'event' || _type == 'achievement' || _type == 'help';
    final titleCtrl = TextEditingController(text: (post['title'] ?? '').toString());
    final textCtrl = TextEditingController(text: (post['text'] ?? '').toString());

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: CommunityColors.card,
        title: const Text('Edit post', style: TextStyle(color: Colors.white)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hasTitle) ...[
                TextField(
                  controller: titleCtrl,
                  maxLength: 100,
                  style: const TextStyle(color: Colors.white),
                  decoration: communityInputDecoration('Title', label: 'Title'),
                ),
                const SizedBox(height: 8),
              ],
              TextField(
                controller: textCtrl,
                minLines: 3,
                maxLines: 8,
                maxLength: CommunityFeedService.maxTextLength,
                style: const TextStyle(color: Colors.white),
                decoration: communityInputDecoration('Text'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save',
                  style: TextStyle(color: CommunityColors.tan))),
        ],
      ),
    );

    final newTitle = titleCtrl.text;
    final newText = textCtrl.text;
    titleCtrl.dispose();
    textCtrl.dispose();
    if (ok != true) return;

    try {
      await CommunityFeedService.editPost(
        postId: _postId,
        requesterUid: _uid,
        title: hasTitle ? newTitle : null,
        text: newText,
      );
      if (context.mounted) showTopAlert(context, 'Post updated');
    } catch (e) {
      if (context.mounted) showTopAlert(context, _clean(e), isError: true);
    }
  }

  Future<void> _delete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: CommunityColors.card,
        title: const Text('Delete post?', style: TextStyle(color: Colors.white)),
        content: const Text(
            'This post and its comments will be permanently removed.',
            style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete',
                  style: TextStyle(color: CommunityColors.danger))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await CommunityFeedService.deletePost(
          postId: _postId, requesterUid: _uid, community: community);
      if (context.mounted) showTopAlert(context, 'Post deleted');
    } catch (e) {
      if (context.mounted) showTopAlert(context, _clean(e), isError: true);
    }
  }

  Future<void> _togglePin(BuildContext context) async {
    final pinned = post['isPinned'] == true;
    try {
      await CommunityFeedService.setPinned(
        postId: _postId,
        requesterUid: _uid,
        community: community,
        pinned: !pinned,
      );
      if (context.mounted) {
        showTopAlert(context, pinned ? 'Post unpinned' : 'Post pinned');
      }
    } catch (e) {
      if (context.mounted) showTopAlert(context, _clean(e), isError: true);
    }
  }

  Future<void> _toggleHighlight(BuildContext context) async {
    final highlighted = post['isHighlighted'] == true;
    try {
      await CommunityActivityService.setHighlighted(
        postId: _postId,
        requesterUid: _uid,
        community: community,
        highlighted: !highlighted,
      );
      if (context.mounted) {
        showTopAlert(
            context, highlighted ? 'Highlight removed' : 'Achievement highlighted',
            icon: Icons.star_rounded);
      }
    } catch (e) {
      if (context.mounted) showTopAlert(context, _clean(e), isError: true);
    }
  }

  Future<void> _toggleResolved(BuildContext context) async {
    final resolved = post['isResolved'] == true;
    try {
      await CommunityFeedService.setResolved(
          postId: _postId, requesterUid: _uid, resolved: !resolved);
    } catch (e) {
      if (context.mounted) showTopAlert(context, _clean(e), isError: true);
    }
  }

  Future<void> _report(BuildContext context) async {
    final reason = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: CommunityColors.card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Why are you reporting this post?',
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 15)),
              ),
            ),
            for (final r in CommunityFeedService.reportReasons)
              ListTile(
                title: Text(r, style: const TextStyle(color: Colors.white70)),
                onTap: () => Navigator.pop(ctx, r),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (reason == null) return;
    try {
      await CommunityFeedService.reportPost(
          postId: _postId, uid: _uid, reason: reason);
      if (context.mounted) {
        showTopAlert(context, 'Thanks — the post was reported and hidden for you.');
      }
    } catch (e) {
      if (context.mounted) showTopAlert(context, _clean(e), isError: true);
    }
  }

  Future<void> _openUrl(BuildContext context, String url) async {
    try {
      final ok = await launchUrl(Uri.parse(url),
          mode: LaunchMode.externalApplication);
      if (!ok && context.mounted) {
        showTopAlert(context, 'Couldn\'t open this link.', isError: true);
      }
    } catch (_) {
      if (context.mounted) {
        showTopAlert(context, 'Couldn\'t open this link.', isError: true);
      }
    }
  }

  // ------------------------------------------------------------
  // Build
  // ------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final isPinned = post['isPinned'] == true;
    final isAuthor = CommunityFeedService.isAuthor(post, _uid);
    final privileged = CommunityService.isPrivileged(community, _uid);
    final saved = CommunityFeedService.isSaved(post, _uid);
    final reactions = post['reactions'] is Map ? post['reactions'] as Map : {};
    final myReaction = (reactions[_uid] ?? '').toString();
    final reactionCount = CommunityFeedService.reactionCount(post);
    final commentCount = CommunityFeedService.commentCount(post);
    final created = communityToDate(post['createdAt']);
    final edited = post['editedAt'] != null;
    final name = (post['authorName'] ?? 'Member').toString();
    final title = (post['title'] ?? '').toString();
    final text = (post['text'] ?? '').toString();
    final hashtags = post['hashtags'] is List
        ? (post['hashtags'] as List).map((e) => e.toString()).toList()
        : <String>[];
    final resolved = post['isResolved'] == true;

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: CommunityColors.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isPinned
              ? CommunityColors.glow.withValues(alpha: .5)
              : CommunityColors.tan.withValues(alpha: .2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isPinned)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
              child: Row(
                children: const [
                  Icon(Icons.push_pin_rounded,
                      color: CommunityColors.glow, size: 14),
                  SizedBox(width: 6),
                  Text('Pinned',
                      style: TextStyle(
                          color: CommunityColors.glow,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600)),
                ],
              ),
            ),

          // ---- Header ----
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 4, 0),
            child: Row(
              children: [
                CommunityAvatar(
                    url: (post['authorAvatarUrl'] ?? '').toString(),
                    name: name,
                    radius: 19),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 14)),
                      Text(
                        '${communityTimeAgo(created)}${edited ? ' · edited' : ''}',
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 11.5),
                      ),
                    ],
                  ),
                ),
                _TypeBadge(type: _type),
                if (showMenu)
                  PopupMenuButton<String>(
                    color: CommunityColors.card,
                    icon: const Icon(Icons.more_vert_rounded,
                        color: Colors.white54, size: 20),
                    onSelected: (v) {
                      switch (v) {
                        case 'edit':
                          _edit(context);
                          break;
                        case 'delete':
                          _delete(context);
                          break;
                        case 'pin':
                          _togglePin(context);
                          break;
                        case 'highlight':
                          _toggleHighlight(context);
                          break;
                        case 'resolve':
                          _toggleResolved(context);
                          break;
                        case 'report':
                          _report(context);
                          break;
                      }
                    },
                    itemBuilder: (_) => [
                      if (isAuthor && _type != 'poll')
                        const PopupMenuItem(
                            value: 'edit',
                            child: Text('Edit',
                                style: TextStyle(color: Colors.white))),
                      if (isAuthor && CommunityFeedService.supportsResolved(post))
                        PopupMenuItem(
                            value: 'resolve',
                            child: Text(
                                resolved ? 'Mark as open' : 'Mark as resolved',
                                style: const TextStyle(color: Colors.white))),
                      if (_type == 'achievement' &&
                          (privileged || highlightAllowed) &&
                          !isAuthor)
                        PopupMenuItem(
                            value: 'highlight',
                            child: Text(
                                post['isHighlighted'] == true
                                    ? 'Remove highlight'
                                    : 'Highlight achievement',
                                style: const TextStyle(color: Colors.white))),
                      if (privileged)
                        PopupMenuItem(
                            value: 'pin',
                            child: Text(isPinned ? 'Unpin' : 'Pin to top',
                                style: const TextStyle(color: Colors.white))),
                      if (!isAuthor)
                        const PopupMenuItem(
                            value: 'report',
                            child: Text('Report',
                                style: TextStyle(color: Colors.white))),
                      if (CommunityFeedService.canDelete(post, community, _uid))
                        const PopupMenuItem(
                            value: 'delete',
                            child: Text('Delete',
                                style: TextStyle(color: CommunityColors.danger))),
                    ],
                  ),
              ],
            ),
          ),

          // ---- Body ----
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title.isNotEmpty && _type != 'event' && _type != 'achievement')
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(title,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15.5,
                            fontWeight: FontWeight.w700)),
                  ),
                if (_type == 'event') _EventBlock(post: post),
                if (_type == 'achievement')
                  _AchievementBlock(post: post, onOpenUrl: (u) => _openUrl(context, u)),
                if (_type == 'lostfound') _LostFoundBlock(post: post),
                if ((_type == 'question' || _type == 'help') && resolved)
                  const _ResolvedBadge(),
                if (text.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: _HashtagText(text: text),
                  ),
              ],
            ),
          ),

          if (_type == 'poll' && (post['pollId'] ?? '').toString().isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
              child: CommunityPollLoader(
                pollId: (post['pollId'] ?? '').toString(),
                community: community,
              ),
            ),

          if (_type == 'image' || (_type == 'lostfound' && _hasMedia))
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: _ImageGallery(urls: _mediaUrls),
            ),

          if (_type == 'video' && _hasMedia)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
              child: _VideoTile(
                url: _mediaUrls.first,
                onPlay: () => _openUrl(context, _mediaUrls.first),
              ),
            ),

          if (hashtags.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final tag in hashtags)
                    GestureDetector(
                      onTap: onHashtagTap == null ? null : () => onHashtagTap!(tag),
                      child: Container(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: CommunityColors.tan.withValues(alpha: .1),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text('#$tag',
                            style: const TextStyle(
                                color: CommunityColors.glow, fontSize: 11.5)),
                      ),
                    ),
                ],
              ),
            ),

          // ---- Actions ----
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 8, 6, 6),
            child: Row(
              children: [
                _ActionButton(
                  onTap: () => _react(context, '❤️'),
                  onLongPress: () => _showReactionPicker(context),
                  active: myReaction.isNotEmpty,
                  label: reactionCount == 0 ? 'React' : '$reactionCount',
                  leading: myReaction.isEmpty
                      ? const Icon(Icons.favorite_border_rounded,
                          color: Colors.white54, size: 20)
                      : Text(myReaction, style: const TextStyle(fontSize: 18)),
                ),
                _ActionButton(
                  onTap: () => _openComments(context),
                  label: commentCount == 0 ? 'Comment' : '$commentCount',
                  leading: const Icon(Icons.chat_bubble_outline_rounded,
                      color: Colors.white54, size: 20),
                ),
                _ActionButton(
                  onTap: () => _openShare(context),
                  label: 'Share',
                  leading: const Icon(Icons.send_rounded,
                      color: Colors.white54, size: 19),
                ),
                const Spacer(),
                IconButton(
                  onPressed: () => _toggleSave(context, saved),
                  tooltip: saved ? 'Unsave' : 'Save',
                  icon: Icon(
                    saved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
                    color: saved ? CommunityColors.tan : Colors.white54,
                    size: 22,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<String> get _mediaUrls => post['mediaUrls'] is List
      ? (post['mediaUrls'] as List).map((e) => e.toString()).toList()
      : <String>[];

  bool get _hasMedia => _mediaUrls.isNotEmpty;
}

// ================================================================
// Sub-widgets
// ================================================================

class _ActionButton extends StatelessWidget {
  final Widget leading;
  final String label;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool active;

  const _ActionButton({
    required this.leading,
    required this.label,
    required this.onTap,
    this.onLongPress,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                    color: active ? CommunityColors.glow : Colors.white54,
                    fontSize: 12.5)),
          ],
        ),
      ),
    );
  }
}

class _TypeBadge extends StatelessWidget {
  final String type;
  const _TypeBadge({required this.type});

  @override
  Widget build(BuildContext context) {
    if (type == 'text') return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(right: 2),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: CommunityColors.tan.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: CommunityColors.tan.withValues(alpha: .3)),
      ),
      child: Text(
        CommunityFeedService.typeLabels[type] ?? type,
        style: const TextStyle(color: CommunityColors.tan, fontSize: 10.5),
      ),
    );
  }
}

class _ResolvedBadge extends StatelessWidget {
  const _ResolvedBadge();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Icon(Icons.check_circle_rounded, color: CommunityColors.success, size: 15),
          SizedBox(width: 6),
          Text('Resolved',
              style: TextStyle(
                  color: CommunityColors.success,
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// Body text with #hashtags highlighted.
class _HashtagText extends StatelessWidget {
  final String text;
  const _HashtagText({required this.text});

  @override
  Widget build(BuildContext context) {
    final spans = <TextSpan>[];
    var cursor = 0;
    for (final m in CommunityFeedService.hashtagPattern.allMatches(text)) {
      if (m.start > cursor) spans.add(TextSpan(text: text.substring(cursor, m.start)));
      spans.add(TextSpan(
        text: m.group(0),
        style: const TextStyle(
            color: CommunityColors.glow, fontWeight: FontWeight.w600),
      ));
      cursor = m.end;
    }
    if (cursor < text.length) spans.add(TextSpan(text: text.substring(cursor)));

    return Text.rich(
      TextSpan(children: spans),
      style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.4),
    );
  }
}

class _EventBlock extends StatelessWidget {
  final Map<String, dynamic> post;
  const _EventBlock({required this.post});

  @override
  Widget build(BuildContext context) {
    final event = post['event'] is Map ? post['event'] as Map : {};
    final at = communityToDate(event['dateTime']);
    final location = (event['location'] ?? '').toString();
    final past = at != null && at.isBefore(DateTime.now());

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF18181F),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: CommunityColors.tan.withValues(alpha: .25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.event_rounded, color: CommunityColors.glow, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text((post['title'] ?? '').toString(),
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 15)),
              ),
              if (past)
                const Text('Past',
                    style: TextStyle(color: Colors.white38, fontSize: 11)),
            ],
          ),
          if (at != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.schedule_rounded, color: Colors.white38, size: 14),
                const SizedBox(width: 6),
                Text(communityFormatDateTime(at),
                    style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
              ],
            ),
          ],
          if (location.isNotEmpty) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                const Icon(Icons.place_rounded, color: Colors.white38, size: 14),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(location,
                      style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _AchievementBlock extends StatelessWidget {
  final Map<String, dynamic> post;
  final ValueChanged<String> onOpenUrl;
  const _AchievementBlock({required this.post, required this.onOpenUrl});

  @override
  Widget build(BuildContext context) {
    final a = post['achievement'] is Map ? post['achievement'] as Map : {};
    final kind = (a['kind'] ?? 'other').toString();
    final date = communityToDate(a['date']);
    final cert = (a['certificateUrl'] ?? '').toString();
    final highlighted = post['isHighlighted'] == true;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF18181F),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: highlighted
              ? CommunityColors.glow.withValues(alpha: .6)
              : CommunityColors.tan.withValues(alpha: .25),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.emoji_events_rounded,
                  color: CommunityColors.glow, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text((post['title'] ?? '').toString(),
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 15)),
              ),
              if (highlighted)
                const Icon(Icons.star_rounded, color: CommunityColors.glow, size: 18),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${CommunityFeedService.achievementKindLabels[kind] ?? 'Achievement'}'
            '${date == null ? '' : ' · ${communityFormatDate(date)}'}',
            style: const TextStyle(color: CommunityColors.tan, fontSize: 12),
          ),
          if (cert.isNotEmpty) ...[
            const SizedBox(height: 10),
            GestureDetector(
              onTap: () => onOpenUrl(cert),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.network(
                  cert,
                  height: 170,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Container(
                    height: 60,
                    color: Colors.white10,
                    alignment: Alignment.center,
                    child: const Text('Certificate',
                        style: TextStyle(color: Colors.white54)),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _LostFoundBlock extends StatelessWidget {
  final Map<String, dynamic> post;
  const _LostFoundBlock({required this.post});

  @override
  Widget build(BuildContext context) {
    final lf = post['lostFound'] is Map ? post['lostFound'] as Map : {};
    final isLost = (lf['status'] ?? 'lost') == 'lost';
    final color = isLost ? CommunityColors.danger : CommunityColors.success;
    final location = (lf['location'] ?? '').toString();
    final resolved = post['isResolved'] == true;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF18181F),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: .4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: .15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(isLost ? 'LOST' : 'FOUND',
                    style: TextStyle(
                        color: color, fontWeight: FontWeight.bold, fontSize: 11)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text((lf['item'] ?? '').toString(),
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 15)),
              ),
              if (resolved)
                const Icon(Icons.check_circle_rounded,
                    color: CommunityColors.success, size: 18),
            ],
          ),
          if (location.isNotEmpty) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(Icons.place_rounded, color: Colors.white38, size: 14),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(location,
                      style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
                ),
              ],
            ),
          ],
          if (resolved)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('Resolved',
                  style: TextStyle(
                      color: CommunityColors.success,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
            ),
        ],
      ),
    );
  }
}

class _ImageGallery extends StatefulWidget {
  final List<String> urls;
  const _ImageGallery({required this.urls});

  @override
  State<_ImageGallery> createState() => _ImageGalleryState();
}

class _ImageGalleryState extends State<_ImageGallery> {
  int _index = 0;

  void _openFull(String url) {
    showDialog(
      context: context,
      builder: (_) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            Center(
              child: InteractiveViewer(
                child: Image.network(url, fit: BoxFit.contain),
              ),
            ),
            Positioned(
              top: 12,
              right: 12,
              child: SafeArea(
                child: IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded, color: Colors.white),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.urls.isEmpty) return const SizedBox.shrink();

    return Column(
      children: [
        SizedBox(
          height: 280,
          child: PageView.builder(
            itemCount: widget.urls.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (_, i) => GestureDetector(
              onTap: () => _openFull(widget.urls[i]),
              child: Image.network(
                widget.urls[i],
                fit: BoxFit.cover,
                width: double.infinity,
                loadingBuilder: (context, child, progress) => progress == null
                    ? child
                    : const Center(
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: CommunityColors.tan)),
                errorBuilder: (_, _, _) => Container(
                  color: Colors.white10,
                  alignment: Alignment.center,
                  child: const Icon(Icons.broken_image_rounded,
                      color: Colors.white38, size: 36),
                ),
              ),
            ),
          ),
        ),
        if (widget.urls.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < widget.urls.length; i++)
                  Container(
                    width: 6,
                    height: 6,
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i == _index ? CommunityColors.tan : Colors.white24,
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _VideoTile extends StatelessWidget {
  final String url;
  final VoidCallback onPlay;
  const _VideoTile({required this.url, required this.onPlay});

  @override
  Widget build(BuildContext context) {
    final thumb = CommunityMediaService.videoThumbnailUrl(url);

    return GestureDetector(
      onTap: onPlay,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Container(
          height: 200,
          width: double.infinity,
          color: const Color(0xFF18181F),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (thumb.isNotEmpty)
                Image.network(thumb,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox.shrink()),
              Container(color: Colors.black26),
              Center(
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: const BoxDecoration(
                      color: Colors.black54, shape: BoxShape.circle),
                  child: const Icon(Icons.play_arrow_rounded,
                      color: Colors.white, size: 38),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
