import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'create_community_group_dialog.dart';
import 'groupchat.dart';
import '../services/community_group_service.dart';
import '../widgets/top_alert.dart';

// ================================================================
// COMMUNITY GROUPS  (spec — Section 3)
// ----------------------------------------------------------------
// Lists every focused-discussion group that belongs to ONE community
// (communityDocId) -- Public/Private/Approval/Temporary, each with
// its own join rule. Same loading/empty/error contract as
// CommunityEventsPage. Tapping a group you're
// already in opens the real GroupChatScreen; tapping one you're not
// in shows Join/Request instead.
// ================================================================
class CommunityGroupsPage extends StatelessWidget {
  final String communityDocId;

  const CommunityGroupsPage({super.key, required this.communityDocId});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 16, 4),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.arrow_back_ios_new_rounded,
                        color: Colors.white, size: 18),
                  ),
                  const Expanded(
                    child: Text('Groups',
                        style: TextStyle(
                            color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                  ),
                  IconButton(
                    onPressed: () => showDialog(
                      context: context,
                      builder: (_) => CreateCommunityGroupDialog(communityDocId: communityDocId),
                    ),
                    icon: const Icon(Icons.add_circle_rounded,
                        color: Color(0xFFD2B48C), size: 26),
                  ),
                ],
              ),
            ),
            Expanded(
              child: StreamBuilder<List<Map<String, dynamic>>>(
                stream: CommunityGroupService.watchGroups(communityDocId),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(
                        child: CircularProgressIndicator(color: Color(0xFFD2B48C)));
                  }
                  if (snapshot.hasError) {
                    return const _StateMessage(
                      icon: Icons.error_outline_rounded,
                      title: 'Unable to load groups',
                      subtitle: 'Something went wrong. Please try again.',
                    );
                  }
                  final groups = snapshot.data ?? [];
                  if (groups.isEmpty) {
                    return _StateMessage(
                      icon: Icons.groups_rounded,
                      title: 'No groups yet',
                      subtitle: 'Start the first focused-discussion group.',
                      actionLabel: 'Create Group',
                      onAction: () => showDialog(
                        context: context,
                        builder: (_) => CreateCommunityGroupDialog(communityDocId: communityDocId),
                      ),
                    );
                  }

                  final active = groups.where((g) => !CommunityGroupService.isExpired(g)).toList();
                  final archived = groups.where(CommunityGroupService.isExpired).toList();

                  return ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    children: [
                      ...active.map((g) => _GroupCard(group: g, uid: uid)),
                      if (archived.isNotEmpty) ...[
                        const Padding(
                          padding: EdgeInsets.fromLTRB(4, 18, 4, 8),
                          child: Text('Archived',
                              style: TextStyle(
                                  color: Colors.white38,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600)),
                        ),
                        ...archived.map((g) => _GroupCard(group: g, uid: uid)),
                      ],
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GroupCard extends StatefulWidget {
  final Map<String, dynamic> group;
  final String uid;
  const _GroupCard({required this.group, required this.uid});

  @override
  State<_GroupCard> createState() => _GroupCardState();
}

class _GroupCardState extends State<_GroupCard> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final group = widget.group;
    final id = group['id'] as String;
    final name = (group['groupName'] ?? '').toString();
    final imageUrl = (group['groupProfileImage'] ?? '').toString();
    final type = (group['groupType'] ?? 'public').toString();
    final membersCount = (group['membersCount'] is int) ? group['membersCount'] as int : 0;
    final isMember = CommunityGroupService.isMember(group, widget.uid);
    final isAdmin = CommunityGroupService.isAdmin(group, widget.uid);
    final requested = CommunityGroupService.hasPendingRequest(group, widget.uid);
    final expired = CommunityGroupService.isExpired(group);
    final pendingCount = (group['pendingMembers'] is List)
        ? (group['pendingMembers'] as List).length
        : 0;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Opacity(
        opacity: expired ? .55 : 1,
        child: Material(
          color: const Color(0xFF1B120A),
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: expired
                ? null
                : (isMember
                    ? () => Navigator.of(context)
                        .push(MaterialPageRoute(builder: (_) => GroupChatScreen(groupDocId: id)))
                    : null),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFD2B48C).withValues(alpha: .3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFF2A1B0E),
                          border: Border.all(color: const Color(0xFFD2B48C).withValues(alpha: .6)),
                        ),
                        child: imageUrl.isEmpty
                            ? const Icon(Icons.groups_rounded, color: Color(0xFFD2B48C), size: 20)
                            : ClipOval(child: Image.network(imageUrl, fit: BoxFit.cover)),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(name.isEmpty ? 'Unnamed Group' : name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 14.5)),
                                ),
                                _TypePill(type: expired ? 'archived' : type),
                              ],
                            ),
                            const SizedBox(height: 3),
                            Text('$membersCount member${membersCount == 1 ? '' : 's'}',
                                style: const TextStyle(color: Colors.white54, fontSize: 12)),
                          ],
                        ),
                      ),
                      const SizedBox(width: 6),
                      if (isAdmin && !expired)
                        IconButton(
                          onPressed: () => _openManageSheet(context),
                          icon: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              const Icon(Icons.settings_rounded, color: Color(0xFFD2B48C), size: 20),
                              if (pendingCount > 0)
                                Positioned(
                                  right: -2,
                                  top: -2,
                                  child: Container(
                                    padding: const EdgeInsets.all(3),
                                    decoration: const BoxDecoration(
                                        color: Colors.redAccent, shape: BoxShape.circle),
                                    child: Text('$pendingCount',
                                        style: const TextStyle(color: Colors.white, fontSize: 8)),
                                  ),
                                ),
                            ],
                          ),
                        )
                      else if (!isMember && !expired)
                        _joinButton(type, requested)
                      else if (isMember && !isAdmin)
                        IconButton(
                          onPressed: () => _showMemberActions(context),
                          icon: const Icon(Icons.more_vert_rounded, color: Colors.white38, size: 20),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _joinButton(String type, bool requested) {
    if (requested) {
      return OutlinedButton(
        onPressed: _busy ? null : _cancelRequest,
        style: OutlinedButton.styleFrom(
          side: const BorderSide(color: Colors.white38),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        child: const Text('Requested', style: TextStyle(color: Colors.white54, fontSize: 12)),
      );
    }
    if (type == 'private') {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 4),
        child: Icon(Icons.lock_rounded, color: Colors.white38, size: 18),
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(gradient: AppColors.goldGradient, borderRadius: BorderRadius.circular(10)),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: _busy ? null : _join,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: _busy
                ? const SizedBox(
                    width: 14, height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1B120A)))
                : Text(
                    type == 'approval' ? 'Request' : 'Join',
                    style: const TextStyle(
                        color: Color(0xFF1B120A), fontWeight: FontWeight.bold, fontSize: 12.5),
                  ),
          ),
        ),
      ),
    );
  }

  Future<void> _join() async {
    setState(() => _busy = true);
    try {
      final result = await CommunityGroupService.joinOrRequest(
        groupDocId: widget.group['id'] as String,
        uid: widget.uid,
        group: widget.group,
      );
      if (mounted) {
        showTopAlert(context, result == 'requested' ? 'Request sent' : 'Joined the group');
      }
    } catch (e) {
      if (mounted) {
        showTopAlert(context, e.toString().replaceFirst('Exception: ', ''), isError: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancelRequest() async {
    setState(() => _busy = true);
    try {
      await CommunityGroupService.cancelRequest(
          groupDocId: widget.group['id'] as String, uid: widget.uid);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showMemberActions(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1B120A),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.flag_rounded, color: Colors.orangeAccent),
              title: const Text('Report Group', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(sheetContext);
                _openReportSheet(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.logout_rounded, color: Colors.redAccent),
              title: const Text('Leave Group', style: TextStyle(color: Colors.redAccent)),
              onTap: () async {
                Navigator.pop(sheetContext);
                try {
                  await CommunityGroupService.leaveGroup(
                    groupDocId: widget.group['id'] as String,
                    uid: widget.uid,
                    group: widget.group,
                  );
                } catch (e) {
                  if (context.mounted) {
                    showTopAlert(context, e.toString().replaceFirst('Exception: ', ''), isError: true);
                  }
                }
              },
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  void _openReportSheet(BuildContext context) {
    final reasons = ['Spam', 'Harassment', 'Inappropriate content', 'Fake information', 'Other'];
    String selected = reasons.first;
    final detailsController = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1B120A),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => Padding(
          padding: EdgeInsets.only(
            left: 20, right: 20, top: 18,
            bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 18,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Report Group',
                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8, runSpacing: 8,
                children: reasons.map((r) {
                  final sel = r == selected;
                  return ChoiceChip(
                    label: Text(r, style: TextStyle(color: sel ? const Color(0xFF1B120A) : Colors.white70)),
                    selected: sel,
                    selectedColor: const Color(0xFFD2B48C),
                    backgroundColor: const Color(0xFF2A1B0E),
                    onSelected: (_) => setSheetState(() => selected = r),
                  );
                }).toList(),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: detailsController,
                maxLines: 3,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Additional details (optional)',
                  hintStyle: const TextStyle(color: Colors.white38),
                  filled: true,
                  fillColor: const Color(0xFF2A1B0E),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFD2B48C),
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: () async {
                  final communityDocId = (widget.group['communityDocId'] ?? '').toString();
                  try {
                    await CommunityGroupService.reportGroup(
                      groupDocId: widget.group['id'] as String,
                      communityDocId: communityDocId,
                      reporterUid: widget.uid,
                      category: selected,
                      details: detailsController.text,
                    );
                    if (sheetContext.mounted) {
                      Navigator.pop(sheetContext);
                      showTopAlert(context, 'Report submitted');
                    }
                  } catch (e) {
                    if (sheetContext.mounted) {
                      showTopAlert(sheetContext, 'Failed to submit report', isError: true);
                    }
                  }
                },
                child: const Text('Submit Report',
                    style: TextStyle(color: Color(0xFF1B120A), fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openManageSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1B120A),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (sheetContext) => _ManageGroupSheet(group: widget.group, uid: widget.uid),
    );
  }
}

class _ManageGroupSheet extends StatelessWidget {
  final Map<String, dynamic> group;
  final String uid;
  const _ManageGroupSheet({required this.group, required this.uid});

  @override
  Widget build(BuildContext context) {
    final pending = (group['pendingMembers'] is List)
        ? List<String>.from(group['pendingMembers'])
        : <String>[];
    final groupDocId = group['id'] as String;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Manage Group',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 14),
            if (pending.isEmpty)
              const Text('No pending join requests', style: TextStyle(color: Colors.white54, fontSize: 12.5))
            else
              Column(
                children: pending
                    .map((requesterUid) => _PendingRequestTile(
                          requesterUid: requesterUid,
                          onApprove: () => CommunityGroupService.respondToRequest(
                            groupDocId: groupDocId,
                            requesterUid: requesterUid,
                            reviewerUid: uid,
                            group: group,
                            approve: true,
                          ),
                          onReject: () => CommunityGroupService.respondToRequest(
                            groupDocId: groupDocId,
                            requesterUid: requesterUid,
                            reviewerUid: uid,
                            group: group,
                            approve: false,
                          ),
                        ))
                    .toList(),
              ),
            const Divider(color: Colors.white12, height: 28),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.archive_rounded, color: Color(0xFFD2B48C)),
              title: const Text('Archive Now', style: TextStyle(color: Colors.white)),
              onTap: () async {
                try {
                  await CommunityGroupService.archiveNow(
                      groupDocId: groupDocId, requesterUid: uid, group: group);
                  if (context.mounted) Navigator.pop(context);
                } catch (e) {
                  if (context.mounted) {
                    showTopAlert(context, e.toString().replaceFirst('Exception: ', ''), isError: true);
                  }
                }
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.delete_forever_rounded, color: Colors.redAccent),
              title: const Text('Delete Group', style: TextStyle(color: Colors.redAccent)),
              onTap: () async {
                try {
                  await CommunityGroupService.deleteGroup(
                      groupDocId: groupDocId, requesterUid: uid, group: group);
                  if (context.mounted) Navigator.pop(context);
                } catch (e) {
                  if (context.mounted) {
                    showTopAlert(context, e.toString().replaceFirst('Exception: ', ''), isError: true);
                  }
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _PendingRequestTile extends StatelessWidget {
  final String requesterUid;
  final Future<void> Function() onApprove;
  final Future<void> Function() onReject;

  const _PendingRequestTile({
    required this.requesterUid,
    required this.onApprove,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      future: FirebaseFirestore.instance.collection('users').doc(requesterUid).get(),
      builder: (context, snap) {
        final data = snap.data?.data() ?? {};
        final name = (data['publicName'] ?? 'Member').toString();
        final image = (data['publicImage'] ?? '').toString();
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: const Color(0xFF2A1B0E),
                backgroundImage: image.isEmpty ? null : NetworkImage(image),
                child: image.isEmpty
                    ? const Icon(Icons.person_rounded, color: Color(0xFFD2B48C), size: 14)
                    : null,
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(name, style: const TextStyle(color: Colors.white, fontSize: 13))),
              IconButton(
                onPressed: onApprove,
                icon: const Icon(Icons.check_circle_rounded, color: Colors.greenAccent, size: 22),
              ),
              IconButton(
                onPressed: onReject,
                icon: const Icon(Icons.cancel_rounded, color: Colors.redAccent, size: 22),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _TypePill extends StatelessWidget {
  final String type;
  const _TypePill({required this.type});

  @override
  Widget build(BuildContext context) {
    Color color;
    String label;
    IconData icon;
    switch (type) {
      case 'private':
        color = Colors.white54;
        label = 'Private';
        icon = Icons.lock_rounded;
        break;
      case 'approval':
        color = const Color(0xFFD2B48C);
        label = 'Approval';
        icon = Icons.how_to_reg_rounded;
        break;
      case 'temporary':
        color = Colors.orangeAccent;
        label = 'Temporary';
        icon = Icons.hourglass_bottom_rounded;
        break;
      case 'archived':
        color = Colors.white38;
        label = 'Archived';
        icon = Icons.archive_rounded;
        break;
      default:
        color = Colors.lightBlueAccent;
        label = 'Public';
        icon = Icons.public_rounded;
    }
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .16),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: .5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: color),
          const SizedBox(width: 3),
          Text(label, style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}

class _StateMessage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _StateMessage({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: const Color(0xFFD2B48C)),
            const SizedBox(height: 14),
            Text(title,
                style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54, fontSize: 12.5)),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 18),
              OutlinedButton(
                onPressed: onAction,
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFFD2B48C)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                ),
                child: Text(actionLabel!, style: const TextStyle(color: Color(0xFFFFE9B0))),
              ),
            ],
          ],
        ),
      ),
    );
  }
}