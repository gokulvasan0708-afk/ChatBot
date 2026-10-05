import 'package:flutter/material.dart';

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
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
        decoration: BoxDecoration(
          color: isPrivate
              ? const Color(0xFF8B4513).withValues(alpha: .35)
              : const Color(0xFF1B120A),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: const Color(0xFFD2B48C).withValues(alpha: .55),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isPrivate ? Icons.lock_rounded : Icons.public_rounded,
              size: 16,
              color: const Color(0xFFFFE9B0),
            ),
            const SizedBox(width: 8),
            Text(
              isPrivate ? 'Private' : 'Public',
              style: const TextStyle(
                color: Colors.white,
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
