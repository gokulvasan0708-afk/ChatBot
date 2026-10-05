import 'package:flutter/material.dart';

import '../../pages/app_theme.dart';
import '../../widgets/top_alert.dart';
import '../services/club_discussion_service.dart';
import '../services/club_moderation_service.dart';

class ClubModerationPage extends StatelessWidget {
  final String clubDocId;
  final String moderatorUid;

  const ClubModerationPage({
    super.key,
    required this.clubDocId,
    required this.moderatorUid,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Moderation'),
      ),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: ClubModerationService.watchReports(clubDocId),
        builder: (context, snap) {
          if (snap.hasError) {
            return const Center(child: Text('Unable to load reports.', style: TextStyle(color: Colors.white54)));
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator(color: AppColors.tan));
          }
          final reports = snap.data!;
          if (reports.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(28),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.verified_user_outlined, color: AppColors.tan, size: 48),
                  SizedBox(height: 12),
                  Text('No reports', style: TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.bold)),
                  SizedBox(height: 6),
                  Text('Your club has no moderation reports right now.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white54)),
                ]),
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
            itemCount: reports.length,
            itemBuilder: (context, index) => _ReportCard(
              report: reports[index],
              clubId: clubDocId,
              moderatorUid: moderatorUid,
            ),
          );
        },
      ),
    );
  }
}

class _ReportCard extends StatelessWidget {
  final Map<String, dynamic> report;
  final String clubId;
  final String moderatorUid;

  const _ReportCard({required this.report, required this.clubId, required this.moderatorUid});

  String _status() => (report['status'] ?? 'pending').toString();
  String _reason() => (report['reason'] ?? 'Other').toString();
  String _targetUid() => (report['targetUid'] ?? '').toString();
  String _postId() => (report['postId'] ?? '').toString();

  Future<void> _statusUpdate(BuildContext context, String status) async {
    try {
      await ClubModerationService.setReportStatus(
        reportId: report['id'].toString(),
        status: status,
        moderatorUid: moderatorUid,
        clubId: (report['clubId'] ?? '').toString(),
      );
      if (context.mounted) showTopAlert(context, 'Report marked $status.');
    } catch (e) {
      if (context.mounted) showTopAlert(context, e.toString().replaceFirst('Exception: ', ''), isError: true);
    }
  }

  Future<void> _removePost(BuildContext context) async {
    final postId = _postId();
    if (postId.isEmpty) return;
    try {
      await ClubDiscussionService.deletePost(clubId: clubId, postId: postId);
      await _statusUpdate(context, 'reviewed');
    } catch (e) {
      if (context.mounted) showTopAlert(context, e.toString().replaceFirst('Exception: ', ''), isError: true);
    }
  }

  Future<void> _warn(BuildContext context) async {
    final target = _targetUid();
    if (target.isEmpty) return;
    final reason = await _reasonDialog(context, 'Warn member', 'Warning reason');
    if (reason == null) return;
    try {
      await ClubModerationService.warnUser(clubId: clubId, targetUid: target, moderatorUid: moderatorUid, reason: reason);
      await _statusUpdate(context, 'reviewed');
    } catch (e) {
      if (context.mounted) showTopAlert(context, e.toString().replaceFirst('Exception: ', ''), isError: true);
    }
  }

  Future<void> _mute(BuildContext context) async {
    final target = _targetUid();
    if (target.isEmpty) return;
    final choice = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: const Color(0xFF1B120A),
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Padding(padding: EdgeInsets.all(18), child: Text('Mute member', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold))),
          for (final item in const <Map<String, dynamic>>[
            {'minutes': 60, 'label': '1 hour'},
            {'minutes': 1440, 'label': '24 hours'},
            {'minutes': 10080, 'label': '7 days'},
          ])
            ListTile(title: Text(item['label'] as String, style: const TextStyle(color: Colors.white)), onTap: () => Navigator.pop(context, item['minutes'] as int)),
        ]),
      ),
    );
    if (choice == null) return;
    try {
      await ClubModerationService.muteUser(clubId: clubId, targetUid: target, moderatorUid: moderatorUid, duration: Duration(minutes: choice), reason: _reason());
      await _statusUpdate(context, 'reviewed');
    } catch (e) {
      if (context.mounted) showTopAlert(context, e.toString().replaceFirst('Exception: ', ''), isError: true);
    }
  }

  Future<String?> _reasonDialog(BuildContext context, String title, String hint) async {
    final controller = TextEditingController(text: _reason());
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF1B120A),
        title: Text(title, style: const TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          maxLines: 3,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(hintText: hint, hintStyle: const TextStyle(color: Colors.white38)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, controller.text.trim()), child: const Text('Save')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final status = _status();
    return Card(
      color: const Color(0xFF1B120A),
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.flag_outlined, color: AppColors.tan),
            const SizedBox(width: 8),
            Expanded(child: Text(_reason(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700))),
            _StatusChip(status: status),
          ]),
          const SizedBox(height: 8),
          Text('Reporter: ${(report['reporterUid'] ?? 'Unknown').toString()}', style: const TextStyle(color: Colors.white54, fontSize: 12)),
          if (_targetUid().isNotEmpty) Text('Target: ${_targetUid()}', style: const TextStyle(color: Colors.white54, fontSize: 12)),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (status == 'pending') OutlinedButton(onPressed: () => _statusUpdate(context, 'dismissed'), child: const Text('Dismiss')),
            if (status == 'pending' && _postId().isNotEmpty) FilledButton(onPressed: () => _removePost(context), child: const Text('Remove post')),
            if (status == 'pending' && _targetUid().isNotEmpty) OutlinedButton(onPressed: () => _warn(context), child: const Text('Warn')),
            if (status == 'pending' && _targetUid().isNotEmpty) OutlinedButton(onPressed: () => _mute(context), child: const Text('Mute')),
          ]),
        ]),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String status;
  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(color: Colors.white.withValues(alpha: .08), borderRadius: BorderRadius.circular(20)),
        child: Text(status, style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w700)),
      );
}
