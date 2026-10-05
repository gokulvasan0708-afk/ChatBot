import 'package:flutter/material.dart';

import '../club/pages/club_home_page.dart';

/// Backwards-compatible entry point.
///
/// Existing Community/Clubs navigation already opens `ClubDetailPage`.
/// Keeping this class means no other feature needs to change its route while
/// Phase 1 upgrades the actual Club screen to the new Club Home shell.
class ClubDetailPage extends StatelessWidget {
  final String clubDocId;

  const ClubDetailPage({
    super.key,
    required this.clubDocId,
  });

  @override
  Widget build(BuildContext context) {
    return ClubHomePage(clubDocId: clubDocId);
  }
}
