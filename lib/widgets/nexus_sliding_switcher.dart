import 'package:flutter/material.dart';

import '../pages/app_theme.dart';

// ================================================================
// NEXUS SLIDING SWITCHER
// ----------------------------------------------------------------
// The same segmented control the Hubs page uses for
// Community | Clubs | Groups: a gold pill that SLIDES from one
// segment to the next (springy overshoot) while the labels animate.
// Used by the Chats page for Public | Private.
//
// [badges] (optional, one bool per segment) draws a small dot in the
// top-right corner of a segment -- used for "unseen messages".
// ================================================================
class NexusSlidingSwitcher extends StatelessWidget {
  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onChanged;

  /// One entry per label; true -> unseen dot on that segment.
  final List<bool>? badges;

  const NexusSlidingSwitcher({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onChanged,
    this.badges,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0xFF1B120A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(0xFFD2B48C).withValues(alpha: .35),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final segmentCount = labels.length;
          final totalWidth = constraints.maxWidth;
          final segmentWidth = totalWidth / segmentCount;

          return SizedBox(
            width: totalWidth,
            height: 34,
            child: Stack(
              children: [
                // -------- Sliding indicator --------
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 380),
                  curve: Curves.easeOutBack,
                  left: selectedIndex * segmentWidth,
                  top: 0,
                  bottom: 0,
                  width: segmentWidth,
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: AppColors.goldGradient,
                      borderRadius: BorderRadius.circular(13),
                    ),
                  ),
                ),

                // -------- Tap targets + labels (+ unseen dots) --------
                Row(
                  children: [
                    for (var i = 0; i < segmentCount; i++)
                      SizedBox(
                        width: segmentWidth,
                        height: 34,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => onChanged(i),
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Center(
                                child: AnimatedDefaultTextStyle(
                                  duration: const Duration(milliseconds: 380),
                                  curve: Curves.easeOutBack,
                                  style: TextStyle(
                                    color: i == selectedIndex
                                        ? const Color(0xFF1B120A)
                                        : Colors.white70,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 12.5,
                                  ),
                                  child: Text(
                                    labels[i],
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                              if (badges != null &&
                                  i < badges!.length &&
                                  badges![i])
                                Positioned(
                                  top: 5,
                                  right: 12,
                                  child: Container(
                                    width: 9,
                                    height: 9,
                                    decoration: BoxDecoration(
                                      // cream on the dark segment, brown on
                                      // the gold (selected) one so it never
                                      // disappears into the pill.
                                      color: i == selectedIndex
                                          ? const Color(0xFF8B4513)
                                          : const Color(0xFFFFE9B0),
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: const Color(0xFF1B120A),
                                        width: 1.2,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
