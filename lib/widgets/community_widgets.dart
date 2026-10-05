import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

// ================================================================
// COMMUNITY SHARED UI HELPERS
// ----------------------------------------------------------------
// Small, dependency-free building blocks reused by every new
// Community screen (Feed, Polls, Resources, Activities, Search,
// Contributions). Uses exactly the same palette the existing
// Community pages already hard-code (tan / glow / dark-brown cards)
// so the new screens look native next to Announcements, Clubs,
// Events and Groups.
// ================================================================

class CommunityColors {
  CommunityColors._();

  static const Color tan = Color(0xFFD2B48C);
  static const Color glow = Color(0xFFFFE9B0);
  static const Color card = Color(0xFF1B120A);
  static const Color avatarBg = Color(0xFF2A1B0E);
  static const Color danger = Colors.redAccent;
  static const Color success = Color(0xFF7BC67B);
}

// ----------------------------------------------------------------
// Date helpers
// ----------------------------------------------------------------

DateTime? communityToDate(dynamic value) {
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  return null;
}

const List<String> _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String communityFormatDate(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')} ${_months[d.month - 1]} ${d.year}';

String communityFormatTime(DateTime d) {
  final hour12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final minute = d.minute.toString().padLeft(2, '0');
  final suffix = d.hour >= 12 ? 'PM' : 'AM';
  return '$hour12:$minute $suffix';
}

String communityFormatDateTime(DateTime d) =>
    '${communityFormatDate(d)}, ${communityFormatTime(d)}';

/// "just now", "5m", "3h", "2d", or a short date for older items.
String communityTimeAgo(DateTime? time) {
  if (time == null) return 'just now';
  final diff = DateTime.now().difference(time);
  if (diff.isNegative || diff.inSeconds < 45) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m';
  if (diff.inHours < 24) return '${diff.inHours}h';
  if (diff.inDays < 7) return '${diff.inDays}d';
  return communityFormatDate(time);
}

/// Human friendly remaining time for poll / event deadlines.
String communityTimeLeft(DateTime deadline) {
  final diff = deadline.difference(DateTime.now());
  if (diff.isNegative) return 'Ended';
  if (diff.inMinutes < 1) return 'Ends in under a minute';
  if (diff.inMinutes < 60) return 'Ends in ${diff.inMinutes}m';
  if (diff.inHours < 24) return 'Ends in ${diff.inHours}h';
  return 'Ends in ${diff.inDays}d';
}

// ----------------------------------------------------------------
// Avatar
// ----------------------------------------------------------------

class CommunityAvatar extends StatelessWidget {
  final String url;
  final String name;
  final double radius;

  const CommunityAvatar({
    super.key,
    required this.url,
    this.name = '',
    this.radius = 18,
  });

  @override
  Widget build(BuildContext context) {
    final size = radius * 2;
    final initial = name.trim().isEmpty ? '' : name.trim()[0].toUpperCase();

    Widget fallback() => Center(
          child: initial.isEmpty
              ? Icon(Icons.person_rounded,
                  color: CommunityColors.tan, size: radius * 1.1)
              : Text(
                  initial,
                  style: TextStyle(
                    color: CommunityColors.glow,
                    fontWeight: FontWeight.bold,
                    fontSize: radius * 0.9,
                  ),
                ),
        );

    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: CommunityColors.avatarBg,
      ),
      child: url.isEmpty
          ? fallback()
          : ClipOval(
              child: Image.network(
                url,
                width: size,
                height: size,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => fallback(),
              ),
            ),
    );
  }
}

// ----------------------------------------------------------------
// Empty / error state (same look as the existing per-page ones)
// ----------------------------------------------------------------

class CommunityStateMessage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  const CommunityStateMessage({
    super.key,
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
            Icon(icon, color: CommunityColors.tan, size: 44),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 13),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: onAction,
                style: OutlinedButton.styleFrom(
                  foregroundColor: CommunityColors.tan,
                  side: const BorderSide(color: CommunityColors.tan),
                ),
                child: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class CommunityLoading extends StatelessWidget {
  const CommunityLoading({super.key});

  @override
  Widget build(BuildContext context) => const Center(
        child: CircularProgressIndicator(color: CommunityColors.tan),
      );
}

class CommunityOfflineBanner extends StatelessWidget {
  const CommunityOfflineBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
      color: const Color(0xFF3A2A12),
      child: const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.cloud_off_rounded, color: CommunityColors.glow, size: 14),
          SizedBox(width: 8),
          Text(
            'Offline — showing saved content',
            style: TextStyle(color: CommunityColors.glow, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// Reusable dark bottom-sheet container (drag handle + rounded top),
/// matching the existing create-announcement / join sheets.
class CommunitySheetShell extends StatelessWidget {
  final String title;
  final Widget child;
  final List<Widget>? actions;

  const CommunitySheetShell({
    super.key,
    required this.title,
    required this.child,
    this.actions,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: CommunityColors.card,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 42,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 12, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  ...?actions,
                  IconButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.close_rounded, color: Colors.white54),
                  ),
                ],
              ),
            ),
            Flexible(child: child),
          ],
        ),
      ),
    );
  }
}

/// Common dark text-field decoration used by all the new sheets.
InputDecoration communityInputDecoration(String hint, {String? label}) {
  return InputDecoration(
    hintText: hint,
    labelText: label,
    hintStyle: const TextStyle(color: Colors.white38, fontSize: 14),
    labelStyle: const TextStyle(color: CommunityColors.tan),
    filled: true,
    fillColor: const Color(0xFF120C07),
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: CommunityColors.tan.withValues(alpha: .25)),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: CommunityColors.tan),
    ),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: CommunityColors.tan.withValues(alpha: .25)),
    ),
  );
}
