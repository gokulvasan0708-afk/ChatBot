import 'package:flutter/material.dart';

import '../../pages/app_theme.dart';

enum ClubSection {
  home,
  discussions,
  members,
  polls,
  activities,
  watchlist,
  notifications,
  rules,
}

extension ClubSectionLabel on ClubSection {
  String get label {
    switch (this) {
      case ClubSection.home:
        return 'Home';
      case ClubSection.discussions:
        return 'Discussions';
      case ClubSection.members:
        return 'Members';
      case ClubSection.polls:
        return 'Polls';
      case ClubSection.activities:
        return 'Activities';
      case ClubSection.watchlist:
        return 'Watchlist';
      case ClubSection.notifications:
        return 'Notifications';
      case ClubSection.rules:
        return 'Rules';
    }
  }

  IconData get icon {
    switch (this) {
      case ClubSection.home:
        return Icons.home_rounded;
      case ClubSection.discussions:
        return Icons.forum_rounded;
      case ClubSection.members:
        return Icons.people_alt_rounded;
      case ClubSection.polls:
        return Icons.poll_rounded;
      case ClubSection.activities:
        return Icons.event_rounded;
      case ClubSection.watchlist:
        return Icons.bookmark_rounded;
      case ClubSection.notifications:
        return Icons.notifications_rounded;
      case ClubSection.rules:
        return Icons.rule_rounded;
    }
  }
}

class ClubSectionNav extends StatelessWidget {
  final ClubSection selected;
  final ValueChanged<ClubSection> onChanged;

  const ClubSectionNav({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        scrollDirection: Axis.horizontal,
        itemCount: ClubSection.values.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final section = ClubSection.values[index];
          final active = section == selected;
          return GestureDetector(
            onTap: () => onChanged(section),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              padding: const EdgeInsets.symmetric(horizontal: 13),
              decoration: BoxDecoration(
                gradient: active ? AppColors.goldGradient : null,
                color: active ? null : const Color(0xFF18181F),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: const Color(0xFFA78BFA).withValues(alpha: active ? .95 : .30),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    section.icon,
                    size: 16,
                    color: active ? const Color(0xFF18181F) : const Color(0xFFC4B5FD),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    section.label,
                    style: TextStyle(
                      color: active ? const Color(0xFF18181F) : Colors.white70,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class ClubSectionPlaceholder extends StatelessWidget {
  final ClubSection section;

  const ClubSectionPlaceholder({super.key, required this.section});

  String get phase {
    switch (section) {
      case ClubSection.discussions:
        return 'Phase 2';
      case ClubSection.members:
        return 'Phase 3';
      case ClubSection.polls:
        return 'Phase 4';
      case ClubSection.activities:
        return 'Phase 4';
      case ClubSection.watchlist:
        return 'Phase 5';
      case ClubSection.notifications:
        return 'Phase 5';
      case ClubSection.rules:
        return 'Phase 5';
      case ClubSection.home:
        return 'Phase 1';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: const Color(0xFF18181F),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: const Color(0xFFA78BFA).withValues(alpha: .30),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(section.icon, size: 42, color: const Color(0xFFA78BFA)),
              const SizedBox(height: 12),
              Text(
                section.label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 7),
              Text(
                '$phase — this Club section is connected and ready for its feature implementation.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54, fontSize: 13, height: 1.4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
