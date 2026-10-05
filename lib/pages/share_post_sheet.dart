import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/community_feed_service.dart';
import '../services/community_share_service.dart';
import '../widgets/community_widgets.dart';
import '../widgets/top_alert.dart';

// ================================================================
// SHARE POST SHEET  -- "Share within Nexus"
// ----------------------------------------------------------------
// Multi-select list of the user's groups + connected users. Sending
// writes normal chat messages (see community_share_service.dart).
// ================================================================
class SharePostSheet extends StatefulWidget {
  final Map<String, dynamic> post;
  final String communityName;

  const SharePostSheet({
    super.key,
    required this.post,
    required this.communityName,
  });

  @override
  State<SharePostSheet> createState() => _SharePostSheetState();
}

class _SharePostSheetState extends State<SharePostSheet> {
  final TextEditingController _search = TextEditingController();
  final Set<String> _selected = {}; // "kind:id"
  late Future<List<CommunityShareTarget>> _future;
  bool _sending = false;

  String get _uid => FirebaseAuth.instance.currentUser?.uid ?? '';

  @override
  void initState() {
    super.initState();
    _future = CommunityShareService.loadTargets(_uid);
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String _key(CommunityShareTarget t) => '${t.kind}:${t.id}';

  Future<void> _send(List<CommunityShareTarget> all) async {
    if (_selected.isEmpty || _sending) return;
    setState(() => _sending = true);

    final text = CommunityShareService.buildShareText(
      communityName: widget.communityName,
      post: widget.post,
    );

    var sent = 0;
    var failed = 0;
    for (final t in all.where((t) => _selected.contains(_key(t)))) {
      try {
        if (t.kind == 'group') {
          await CommunityShareService.sendToGroup(
            groupDocId: t.id,
            senderUid: _uid,
            text: text,
            post: widget.post,
          );
        } else {
          await CommunityShareService.sendToUser(
            targetUid: t.id,
            senderUid: _uid,
            text: text,
            post: widget.post,
          );
        }
        sent++;
      } catch (_) {
        failed++;
      }
    }

    if (sent > 0) {
      try {
        await CommunityFeedService.incrementShareCount(
            (widget.post['id'] ?? '').toString());
      } catch (_) {
        // Share count is cosmetic; never fail the share because of it.
      }
    }

    if (!mounted) return;
    Navigator.of(context).pop();
    if (failed == 0) {
      showTopAlert(context, sent == 1 ? 'Post shared' : 'Post shared to $sent chats');
    } else if (sent > 0) {
      showTopAlert(context, 'Shared to $sent, failed for $failed', isError: true);
    } else {
      showTopAlert(context, 'Couldn\'t share the post. Please try again.',
          isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height * .75;

    return SizedBox(
      height: height,
      child: CommunitySheetShell(
        title: 'Share in Nexus',
        child: FutureBuilder<List<CommunityShareTarget>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const SizedBox(height: 220, child: CommunityLoading());
            }
            if (snap.hasError) {
              return SizedBox(
                height: 240,
                child: CommunityStateMessage(
                  icon: Icons.error_outline_rounded,
                  title: 'Unable to load chats',
                  subtitle: 'Check your connection and try again.',
                  actionLabel: 'Retry',
                  onAction: () => setState(() {
                    _future = CommunityShareService.loadTargets(_uid);
                  }),
                ),
              );
            }

            final all = snap.data ?? [];
            if (all.isEmpty) {
              return const SizedBox(
                height: 240,
                child: CommunityStateMessage(
                  icon: Icons.chat_bubble_outline_rounded,
                  title: 'Nobody to share with yet',
                  subtitle:
                      'Join a group or connect with someone to share posts in chat.',
                ),
              );
            }

            final q = _search.text.trim().toLowerCase();
            final visible = q.isEmpty
                ? all
                : all.where((t) => t.name.toLowerCase().contains(q)).toList();

            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: TextField(
                    controller: _search,
                    onChanged: (_) => setState(() {}),
                    style: const TextStyle(color: Colors.white),
                    decoration: communityInputDecoration('Search chats')
                        .copyWith(
                            prefixIcon: const Icon(Icons.search_rounded,
                                color: Colors.white38)),
                  ),
                ),
                Expanded(
                  child: visible.isEmpty
                      ? const Center(
                          child: Text('No matches',
                              style: TextStyle(color: Colors.white54)))
                      : ListView.builder(
                          itemCount: visible.length,
                          itemBuilder: (_, i) {
                            final t = visible[i];
                            final on = _selected.contains(_key(t));
                            return ListTile(
                              onTap: _sending
                                  ? null
                                  : () => setState(() {
                                        on
                                            ? _selected.remove(_key(t))
                                            : _selected.add(_key(t));
                                      }),
                              leading: CommunityAvatar(
                                  url: t.imageUrl, name: t.name, radius: 20),
                              title: Text(t.name,
                                  style: const TextStyle(color: Colors.white)),
                              subtitle: Text(
                                t.kind == 'group' ? 'Group' : 'Connection',
                                style: const TextStyle(
                                    color: Colors.white38, fontSize: 12),
                              ),
                              trailing: Icon(
                                on
                                    ? Icons.check_circle_rounded
                                    : Icons.radio_button_unchecked_rounded,
                                color:
                                    on ? CommunityColors.tan : Colors.white24,
                              ),
                            );
                          },
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                  child: SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      onPressed:
                          (_selected.isEmpty || _sending) ? null : () => _send(all),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: CommunityColors.tan,
                        foregroundColor: Colors.black,
                        disabledBackgroundColor: Colors.white12,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                      ),
                      child: _sending
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.black),
                            )
                          : Text(
                              _selected.isEmpty
                                  ? 'Select chats'
                                  : 'Send to ${_selected.length}',
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold),
                            ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
