import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'app_theme.dart';
import '../services/event_service.dart';
import '../widgets/top_alert.dart';

// ================================================================
// EVENT DETAIL PAGE  (Community spec — Section 5)
// ----------------------------------------------------------------
// View event → RSVP (Going / Interested) → participants list →
// reminder toggle → organizer controls (cancel/reopen, check-in
// code) → check-in for participants who are "Going". Same
// loading/empty/error contract as the rest of the Community pages.
// ================================================================
class EventDetailPage extends StatelessWidget {
  final String eventDocId;

  const EventDetailPage({super.key, required this.eventDocId});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: EventService.watchEvent(eventDocId),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(
                  child: CircularProgressIndicator(color: Color(0xFFD2B48C)));
            }
            if (snapshot.hasError) {
              return _MessageState(
                icon: Icons.error_outline_rounded,
                title: 'Unable to load event',
                subtitle: 'Something went wrong. Please try again.',
              );
            }
            final data = snapshot.data?.data();
            if (data == null) {
              return _MessageState(
                icon: Icons.event_busy_rounded,
                title: 'Event not found',
                subtitle: 'This event may have been removed.',
              );
            }

            final event = {...data, 'id': eventDocId};
            return _EventBody(event: event, uid: uid);
          },
        ),
      ),
    );
  }
}

class _EventBody extends StatefulWidget {
  final Map<String, dynamic> event;
  final String uid;
  const _EventBody({required this.event, required this.uid});

  @override
  State<_EventBody> createState() => _EventBodyState();
}

class _EventBodyState extends State<_EventBody> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final event = widget.event;
    final title = (event['title'] ?? '').toString();
    final description = (event['description'] ?? '').toString();
    final coverUrl = (event['coverImageUrl'] ?? '').toString();
    final category = (event['category'] ?? '').toString();
    final isOnline = event['isOnline'] == true;
    final location = (event['location'] ?? '').toString();
    final onlineLink = (event['onlineLink'] ?? '').toString();
    final start = (event['startAt'] as Timestamp?)?.toDate();
    final end = (event['endAt'] as Timestamp?)?.toDate();
    final organizerName = (event['organizerName'] ?? 'Member').toString();
    final maxParticipants =
        (event['maxParticipants'] is int) ? event['maxParticipants'] as int : 0;
    final goingUids = _asStringList(event['goingUids']);
    final interestedUids = _asStringList(event['interestedUids']);
    final status = EventService.statusFor(event);
    final isOrganizer = (event['organizerUid'] ?? '').toString() == widget.uid;
    final isGoing = EventService.isGoing(event, widget.uid);
    final isInterested = EventService.isInterested(event, widget.uid);
    final isCheckedIn = EventService.isCheckedIn(event, widget.uid);
    final wantsReminder = EventService.wantsReminder(event, widget.uid);
    final full = maxParticipants > 0 && goingUids.length >= maxParticipants && !isGoing;

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
            child: Row(
              children: [
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.arrow_back_ios_new_rounded,
                      color: Colors.white, size: 18),
                ),
                const Expanded(
                  child: Text('Event',
                      style: TextStyle(
                          color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                ),
                _StatusPill(status: status),
              ],
            ),
          ),
        ),

        if (coverUrl.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image.network(coverUrl, height: 160, width: double.infinity, fit: BoxFit.cover),
              ),
            ),
          ),

        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title.isEmpty ? 'Untitled Event' : title,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                if (start != null)
                  _InfoRow(icon: Icons.calendar_month_rounded, text: _formatRange(start, end)),
                _InfoRow(
                  icon: isOnline ? Icons.videocam_rounded : Icons.location_on_rounded,
                  text: isOnline
                      ? (onlineLink.isEmpty ? 'Online event' : onlineLink)
                      : (location.isEmpty ? 'Location not set' : location),
                ),
                _InfoRow(icon: Icons.person_rounded, text: 'Organized by $organizerName'),
                if (category.isNotEmpty)
                  _InfoRow(icon: Icons.sell_rounded, text: category),
                _InfoRow(
                  icon: Icons.groups_rounded,
                  text: maxParticipants > 0
                      ? '${goingUids.length} / $maxParticipants going'
                      : '${goingUids.length} going · ${interestedUids.length} interested',
                ),
                if (description.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(description,
                      style: const TextStyle(color: Colors.white70, fontSize: 13.5, height: 1.4)),
                ],
              ],
            ),
          ),
        ),

        SliverToBoxAdapter(child: const SizedBox(height: 20)),

        // -------- RSVP actions --------
        if (status == 'upcoming' || status == 'live')
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Expanded(
                    child: _ActionButton(
                      label: isGoing ? 'Going ✓' : (full ? 'Full' : 'Going'),
                      filled: isGoing,
                      onTap: (_busy || (full && !isGoing)) ? null : () => _toggleGoing(isGoing),
                      busy: _busy,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _ActionButton(
                      label: isInterested ? 'Interested ✓' : 'Interested',
                      filled: false,
                      onTap: _busy ? null : () => _toggleInterested(isInterested),
                    ),
                  ),
                ],
              ),
            ),
          ),

        if (status == 'upcoming' || status == 'live')
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
              child: Row(
                children: [
                  Icon(wantsReminder ? Icons.notifications_active_rounded : Icons.notifications_none_rounded,
                      color: const Color(0xFFD2B48C), size: 18),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text('Remind me before this event',
                        style: TextStyle(color: Colors.white70, fontSize: 13)),
                  ),
                  Switch(
                    value: wantsReminder,
                    activeThumbColor: const Color(0xFFD2B48C),
                    onChanged: (v) => EventService.setReminder(
                      eventDocId: event['id'] as String,
                      uid: widget.uid,
                      remind: v,
                    ),
                  ),
                ],
              ),
            ),
          ),

        // -------- Check-in for attendees --------
        if (isGoing && status == 'live' && !isCheckedIn)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
              child: _CheckInCard(
                eventDocId: event['id'] as String,
                uid: widget.uid,
                event: event,
              ),
            ),
          ),
        if (isGoing && isCheckedIn)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(20, 14, 20, 0),
              child: _CheckedInBanner(),
            ),
          ),

        // -------- Organizer controls --------
        if (isOrganizer) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
              child: Text('Organizer controls',
                  style: const TextStyle(color: Colors.white38, fontSize: 11.5)),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: _OrganizerPanel(event: event, uid: widget.uid),
            ),
          ),
        ],

        // -------- Participants --------
        if (goingUids.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 22, 20, 8),
              child: Text('Going (${goingUids.length})',
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
            ),
          ),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => _ParticipantTile(uid: goingUids[index]),
              childCount: goingUids.length,
            ),
          ),
        ],

        SliverToBoxAdapter(child: const SizedBox(height: 40)),
      ],
    );
  }

  Future<void> _toggleGoing(bool currentlyGoing) async {
    setState(() => _busy = true);
    try {
      if (currentlyGoing) {
        await EventService.cancelRsvp(eventDocId: widget.event['id'] as String, uid: widget.uid);
      } else {
        await EventService.rsvpGoing(
          eventDocId: widget.event['id'] as String,
          uid: widget.uid,
          event: widget.event,
        );
      }
    } catch (e) {
      if (mounted) {
        showTopAlert(context, e.toString().replaceFirst('Exception: ', ''), isError: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleInterested(bool currentlyInterested) async {
    setState(() => _busy = true);
    try {
      await EventService.setInterested(
        eventDocId: widget.event['id'] as String,
        uid: widget.uid,
        interested: !currentlyInterested,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<String> _asStringList(dynamic v) => v is List ? List<String>.from(v) : <String>[];

  String _formatRange(DateTime start, DateTime? end) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    String time(DateTime d) {
      final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
      final m = d.minute.toString().padLeft(2, '0');
      return '$h:$m ${d.hour >= 12 ? 'PM' : 'AM'}';
    }

    final datePart = '${start.day} ${months[start.month - 1]} ${start.year}';
    if (end == null) return '$datePart · ${time(start)}';
    return '$datePart · ${time(start)} – ${time(end)}';
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String text;
  const _InfoRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: const Color(0xFFD2B48C)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: const TextStyle(color: Colors.white70, fontSize: 13)),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final bool filled;
  final VoidCallback? onTap;
  final bool busy;

  const _ActionButton({
    required this.label,
    required this.filled,
    required this.onTap,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    if (filled) {
      return DecoratedBox(
        decoration: BoxDecoration(
          gradient: AppColors.goldGradient,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 13),
              child: Center(
                child: busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1B120A)),
                      )
                    : Text(label,
                        style: const TextStyle(color: Color(0xFF1B120A), fontWeight: FontWeight.bold)),
              ),
            ),
          ),
        ),
      );
    }
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 13),
        side: const BorderSide(color: Color(0xFFD2B48C)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      child: Text(label, style: const TextStyle(color: Color(0xFFFFE9B0))),
    );
  }
}

class _CheckInCard extends StatefulWidget {
  final String eventDocId;
  final String uid;
  final Map<String, dynamic> event;
  const _CheckInCard({required this.eventDocId, required this.uid, required this.event});

  @override
  State<_CheckInCard> createState() => _CheckInCardState();
}

class _CheckInCardState extends State<_CheckInCard> {
  final TextEditingController _codeController = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    try {
      await EventService.checkIn(
        eventDocId: widget.eventDocId,
        uid: widget.uid,
        enteredCode: _codeController.text,
        event: widget.event,
      );
      if (mounted) showTopAlert(context, 'Checked in!');
    } catch (e) {
      if (mounted) {
        showTopAlert(context, e.toString().replaceFirst('Exception: ', ''), isError: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1B120A),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFD2B48C).withValues(alpha: .35)),
      ),
      child: Row(
        children: [
          const Icon(Icons.qr_code_scanner_rounded, color: Color(0xFFD2B48C), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _codeController,
              textCapitalization: TextCapitalization.characters,
              style: const TextStyle(color: Colors.white, letterSpacing: 2),
              decoration: const InputDecoration(
                hintText: 'Enter check-in code',
                hintStyle: TextStyle(color: Colors.white38),
                border: InputBorder.none,
              ),
            ),
          ),
          _busy
              ? const SizedBox(
                  width: 18, height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFD2B48C)))
              : TextButton(
                  onPressed: _submit,
                  child: const Text('Check In', style: TextStyle(color: Color(0xFFFFE9B0))),
                ),
        ],
      ),
    );
  }
}

class _CheckedInBanner extends StatelessWidget {
  const _CheckedInBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
      decoration: BoxDecoration(
        color: Colors.green.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.greenAccent.withValues(alpha: .5)),
      ),
      child: const Row(
        children: [
          Icon(Icons.check_circle_rounded, color: Colors.greenAccent, size: 18),
          SizedBox(width: 8),
          Text('Attendance checked in', style: TextStyle(color: Colors.greenAccent, fontSize: 13)),
        ],
      ),
    );
  }
}

class _OrganizerPanel extends StatefulWidget {
  final Map<String, dynamic> event;
  final String uid;
  const _OrganizerPanel({required this.event, required this.uid});

  @override
  State<_OrganizerPanel> createState() => _OrganizerPanelState();
}

class _OrganizerPanelState extends State<_OrganizerPanel> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) {
        showTopAlert(context, e.toString().replaceFirst('Exception: ', ''), isError: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final event = widget.event;
    final cancelled = event['cancelled'] == true;
    final code = (event['checkInCode'] ?? '').toString();

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1B120A),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFD2B48C).withValues(alpha: .3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.confirmation_number_rounded, color: Color(0xFFD2B48C), size: 18),
              const SizedBox(width: 8),
              const Text('Check-in code', style: TextStyle(color: Colors.white70, fontSize: 12.5)),
              const Spacer(),
              Text(code, style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 3, fontSize: 15)),
              IconButton(
                onPressed: _busy
                    ? null
                    : () => _run(() => EventService.regenerateCheckInCode(
                          eventDocId: event['id'] as String,
                          requesterUid: widget.uid,
                          event: event,
                        )),
                icon: const Icon(Icons.refresh_rounded, color: Color(0xFFD2B48C), size: 18),
              ),
            ],
          ),
          const Divider(color: Colors.white12, height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () => _run(() => cancelled
                          ? EventService.reopenEvent(
                              eventDocId: event['id'] as String,
                              requesterUid: widget.uid,
                              event: event,
                            )
                          : EventService.cancelEvent(
                              eventDocId: event['id'] as String,
                              requesterUid: widget.uid,
                              event: event,
                            )),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: cancelled ? Colors.greenAccent : Colors.redAccent),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text(
                    cancelled ? 'Reopen Event' : 'Cancel Event',
                    style: TextStyle(color: cancelled ? Colors.greenAccent : Colors.redAccent),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ParticipantTile extends StatelessWidget {
  final String uid;
  const _ParticipantTile({required this.uid});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      future: FirebaseFirestore.instance.collection('users').doc(uid).get(),
      builder: (context, snap) {
        final data = snap.data?.data() ?? {};
        final name = (data['publicName'] ?? 'Member').toString();
        final image = (data['publicImage'] ?? '').toString();
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
          child: Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: const Color(0xFF2A1B0E),
                backgroundImage: image.isEmpty ? null : NetworkImage(image),
                child: image.isEmpty
                    ? const Icon(Icons.person_rounded, color: Color(0xFFD2B48C), size: 16)
                    : null,
              ),
              const SizedBox(width: 12),
              Text(name, style: const TextStyle(color: Colors.white, fontSize: 13.5)),
            ],
          ),
        );
      },
    );
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
        color = const Color(0xFFD2B48C);
        label = 'Upcoming';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .16),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: .5)),
      ),
      child: Text(label, style: TextStyle(color: color, fontSize: 10.5, fontWeight: FontWeight.bold)),
    );
  }
}

class _MessageState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _MessageState({required this.icon, required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: const Color(0xFFD2B48C)),
            const SizedBox(height: 16),
            Text(title,
                style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54, fontSize: 12.5)),
          ],
        ),
      ),
    );
  }
}