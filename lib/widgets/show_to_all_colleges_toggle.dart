import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

// ================================================================
// SHOW TO ALL COLLEGE  (toggle at the top of the create sheets)
// ----------------------------------------------------------------
// Used by the Announcement, Event and Notice Board post forms.
// When it is ON the post also appears on the Notice Board of every
// OTHER college community, together with this college's name and
// location (see services/college_notice_service.dart).
//
// The toggle only appears for communities of type 'college'; for a
// normal community it renders nothing (and the value stays false).
// ================================================================
class ShowToAllCollegesToggle extends StatelessWidget {
  final String communityDocId;
  final bool value;
  final ValueChanged<bool> onChanged;

  const ShowToAllCollegesToggle({
    super.key,
    required this.communityDocId,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('communities')
          .doc(communityDocId)
          .snapshots(),
      builder: (context, snap) {
        final type = (snap.data?.data()?['type'] ?? '').toString();
        if (type != 'college') return const SizedBox.shrink();

        return Container(
          margin: const EdgeInsets.only(bottom: 14),
          padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
          decoration: BoxDecoration(
            color: const Color(0xFF20202A),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: const Color(0xFFA78BFA)
                  .withValues(alpha: value ? .8 : .3),
            ),
          ),
          child: Row(
            children: [
              const Icon(Icons.public_rounded,
                  color: Color(0xFFA78BFA), size: 22),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Show to all College',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Also shown on the Notice Board of other college communities',
                      style: TextStyle(color: Colors.white54, fontSize: 11.5),
                    ),
                  ],
                ),
              ),
              Switch(
                value: value,
                activeThumbColor: const Color(0xFFA78BFA),
                onChanged: onChanged,
              ),
            ],
          ),
        );
      },
    );
  }
}
