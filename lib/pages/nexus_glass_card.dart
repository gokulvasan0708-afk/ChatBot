import 'dart:ui';
import 'package:flutter/material.dart';

import 'app_theme.dart';

// ================================================================
// NEXUS GLASS CARD  (purple redesign)
// ----------------------------------------------------------------
// Shared card container. Dark mode  -> #18181F card, #292934 border.
// Light mode -> #FFFFFF card, #DDD7E8 border.
// Same constructor as before, so every existing usage keeps working.
//
//   NexusGlassCard(child: ...)
// ================================================================
class NexusGlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final double blur;
  final double borderOpacity;
  final double fillOpacity;
  final VoidCallback? onTap;

  const NexusGlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = 20,
    this.blur = 18,
    this.borderOpacity = 0.45,
    this.fillOpacity = 0.30,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Keep a little translucency (driven by fillOpacity) so the
    // cosmic background still glows through, but never let the card
    // get so transparent that text loses contrast.
    final fillAlpha = (0.55 + fillOpacity).clamp(0.6, 0.95).toDouble();

    final content = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: c.card.withValues(alpha: fillAlpha),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: c.cardBorder, width: 1),
            boxShadow: [
              BoxShadow(
                color: isDark
                    ? Colors.black.withValues(alpha: 0.30)
                    : AppColors.primary.withValues(alpha: 0.08),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );

    if (onTap == null) return content;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: content,
    );
  }
}

/// A single settings/list row: leading icon in a soft purple circle,
/// title + optional subtitle, trailing chevron.
class NexusGlassRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color? iconColor;

  const NexusGlassRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: NexusGlassCard(
        radius: 16,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        onTap: onTap,
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.primary.withValues(alpha: 0.16),
                border: Border.all(
                  color: AppColors.primary.withValues(alpha: 0.35),
                ),
              ),
              child: Icon(icon, size: 19, color: iconColor ?? c.icon),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: TextStyle(
                        color: c.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            trailing ??
                Icon(
                  Icons.chevron_right_rounded,
                  color: c.textMuted,
                ),
          ],
        ),
      ),
    );
  }
}
