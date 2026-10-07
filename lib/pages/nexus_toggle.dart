import 'package:flutter/material.dart';

import 'app_theme.dart';

class NexusToggleButton extends StatelessWidget {
  final bool isPrivate;
  final VoidCallback onTap;

  const NexusToggleButton({
    super.key,
    required this.isPrivate,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
        decoration: BoxDecoration(
          color: isPrivate
              ? AppColors.primary.withValues(alpha: .22)
              : c.card,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: isPrivate
                ? AppColors.primary.withValues(alpha: .7)
                : c.cardBorder,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isPrivate ? Icons.lock_rounded : Icons.public_rounded,
              size: 16,
              color: isPrivate ? c.icon : AppColors.cyanAccent,
            ),
            const SizedBox(width: 8),
            Text(
              isPrivate ? 'Private' : 'Public',
              style: TextStyle(
                color: c.textPrimary,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
