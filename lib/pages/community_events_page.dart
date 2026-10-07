import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'create_event_dialog.dart';
import 'event_detail_page.dart';
import '../services/event_service.dart';

// ================================================================
// COMMUNITY EVENTS  (spec — Section 5)
// ----------------------------------------------------------------
// Lists every event that belongs to ONE community (communityDocId),
// split into "Upcoming & Live" and "Past" (completed/cancelled) --
// same loading/empty/error contract as
// CommunityAnnouncementsPage. Any community member can organize an
// event here.
// ================================================================
class CommunityEventsPage extends StatelessWidget {
  final String communityDocId;

  const CommunityEventsPage({super.key, required this.communityDocId});

  @override
  Widget build(BuildContext context) {
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
                    child: Text('Events',
                        style: TextStyle(
                            color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                  ),
                  IconButton(
                    onPressed: () => showDialog(
                      context: context,
                      builder: (_) => CreateEventDialog(communityDocId: communityDocId),
                    ),
                    icon: const Icon(Icons.add_circle_rounded,
                        color: Color(0xFFA78BFA), size: 26),
                  ),
                ],
              ),
            ),
            Expanded(
              child: StreamBuilder<List<Map<String, dynamic>>>(
                stream: EventService.watchEvents(communityDocId),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(
                        child: CircularProgressIndicator(color: Color(0xFFA78BFA)));
                  }
                  if (snapshot.hasError) {
                    return const _StateMessage(
                      icon: Icons.error_outline_rounded,
                      title: 'Unable to load events',
                      subtitle: 'Something went wrong. Please try again.',
                    );
                  }
                  final events = snapshot.data ?? [];
                  if (events.isEmpty) {
                    return _StateMessage(
                      icon: Icons.event_rounded,
                      title: 'No upcoming events',
                      subtitle: 'Create the first event for this community.',
                      actionLabel: 'Create Event',
                      onAction: () => showDialog(
                        context: context,
                        builder: (_) => CreateEventDialog(communityDocId: communityDocId),
                      ),
                    );
                  }

                  final upcoming =
                      events.where((e) => !EventService.isPast(e)).toList();
                  final past = events.where(EventService.isPast).toList()
                    ..sort((a, b) {
                      final at = (a['startAt'] as Timestamp?)?.toDate() ?? DateTime(0);
                      final bt = (b['startAt'] as Timestamp?)?.toDate() ?? DateTime(0);
                      return bt.compareTo(at);
                    });

                  return ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    children: [
                      if (upcoming.isEmpty && past.isNotEmpty)
                        const _StateMessage(
                          icon: Icons.event_busy_rounded,
                          title: 'No upcoming events',
                          subtitle: 'Check Past events below, or create a new one.',
                        ),
                      ...upcoming.map((e) => _EventCard(event: e)),
                      if (past.isNotEmpty) ...[
                        const Padding(
                          padding: EdgeInsets.fromLTRB(4, 18, 4, 8),
                          child: Text('Past',
                              style: TextStyle(
                                  color: Colors.white38,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600)),
                        ),
                        ...past.map((e) => _EventCard(event: e)),
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

class _EventCard extends StatelessWidget {
  final Map<String, dynamic> event;
  const _EventCard({required this.event});

  @override
  Widget build(BuildContext context) {
    final id = event['id'] as String;
    final title = (event['title'] ?? '').toString();
    final coverUrl = (event['coverImageUrl'] ?? '').toString();
    final category = (event['category'] ?? '').toString();
    final isOnline = event['isOnline'] == true;
    final location = isOnline ? 'Online' : (event['location'] ?? '').toString();
    final start = (event['startAt'] as Timestamp?)?.toDate();
    final end = (event['endAt'] as Timestamp?)?.toDate();
    final going = (event['goingUids'] is List) ? (event['goingUids'] as List).length : 0;
    final status = EventService.statusFor(event);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: const Color(0xFF18181F),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => EventDetailPage(eventDocId: id)),
          ),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFA78BFA).withValues(alpha: .3)),
            ),
            child: Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: const Color(0xFF20202A),
                    border: Border.all(color: const Color(0xFFA78BFA).withValues(alpha: .6)),
                  ),
                  child: coverUrl.isEmpty
                      ? const Icon(Icons.event_rounded, color: Color(0xFFA78BFA), size: 22)
                      : ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.network(coverUrl, fit: BoxFit.cover),
                        ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(title.isEmpty ? 'Untitled Event' : title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
                          ),
                          _StatusPill(status: status),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        [
                          if (start != null) _formatSpan(start, end),
                          if (category.isNotEmpty) category,
                          if (location.isNotEmpty) location,
                          '$going going',
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.chevron_right_rounded, color: Colors.white38),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// "7 Oct, 9:00 AM" for a one-day event,
  /// "7 Oct, 9:00 AM – 9 Oct, 5:00 PM" when it runs over several days.
  String _formatSpan(DateTime start, DateTime? end) {
    if (end == null) return _formatDateTime(start);
    final sameDay = start.year == end.year &&
        start.month == end.month &&
        start.day == end.day;
    if (sameDay) return _formatDateTime(start);
    return '${_formatDateTime(start)} – ${_formatDateTime(end)}';
  }

  String _formatDateTime(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final m = d.minute.toString().padLeft(2, '0');
    final period = d.hour >= 12 ? 'PM' : 'AM';
    return '${d.day} ${months[d.month - 1]}, $h:$m $period';
  }
}

class _StatusPill extends StatelessWidget {
  final String status;
  const _StatusPill({required this.status});

  @override
  Widget build(BuildContext context) {
    Color color;
    String label;
    switch (status) {
      case 'live':
        color = Colors.redAccent;
        label = 'LIVE';
        break;
      case 'completed':
        color = Colors.white38;
        label = 'Completed';
        break;
      case 'cancelled':
        color = Colors.white38;
        label = 'Cancelled';
        break;
      default:
        color = const Color(0xFF10B981);
        label = 'Upcoming';
    }
    return Container(
      margin: const EdgeInsets.only(left: 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .16),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: .5)),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontSize: 9.5, fontWeight: FontWeight.bold),
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
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: const Color(0xFFA78BFA)),
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
                  side: const BorderSide(color: Color(0xFFA78BFA)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                ),
                child: Text(actionLabel!, style: const TextStyle(color: Color(0xFFC4B5FD))),
              ),
            ],
          ],
        ),
      ),
    );
  }
}