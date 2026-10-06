import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'top_alert.dart';

// ================================================================
// COMMUNITY ABOUT SECTION
// ----------------------------------------------------------------
// Shows the optional Vision / Mission / Location details of a
// community. Anything left empty is simply not shown. When a
// location link was given it appears under the location as a
// tappable "Open location link" row.
// ================================================================

/// Adds https:// when the user typed a link without a scheme.
String normalizeCommunityLink(String raw) {
  final v = raw.trim();
  if (v.isEmpty) return '';
  if (v.startsWith('http://') || v.startsWith('https://')) return v;
  return 'https://$v';
}

/// True for an empty link (it's optional) or a link with a real host.
bool isValidCommunityLink(String raw) {
  final v = normalizeCommunityLink(raw);
  if (v.isEmpty) return true;
  final uri = Uri.tryParse(v);
  return uri != null && uri.host.contains('.');
}

class CommunityAboutSection extends StatelessWidget {
  final String vision;
  final String mission;
  final String location;
  final String locationLink;

  const CommunityAboutSection({
    super.key,
    this.vision = '',
    this.mission = '',
    this.location = '',
    this.locationLink = '',
  });

  bool get isEmpty =>
      vision.trim().isEmpty &&
      mission.trim().isEmpty &&
      location.trim().isEmpty &&
      locationLink.trim().isEmpty;

  Future<void> _openLink(BuildContext context) async {
    final url = normalizeCommunityLink(locationLink);
    final uri = Uri.tryParse(url);
    var opened = false;
    if (uri != null) {
      try {
        opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {
        opened = false;
      }
    }
    if (!opened && context.mounted) {
      showTopAlert(context, 'Unable to open the location link.', isError: true);
    }
  }

  Widget _block(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: const Color(0xFFD2B48C), size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(
                        color: Colors.white38, fontSize: 11.5)),
                const SizedBox(height: 2),
                Text(value,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 14.5, height: 1.35)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasLink = locationLink.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (vision.trim().isNotEmpty)
          _block(Icons.visibility_rounded, 'Vision', vision.trim()),
        if (mission.trim().isNotEmpty)
          _block(Icons.flag_rounded, 'Mission', mission.trim()),
        if (location.trim().isNotEmpty)
          _block(Icons.location_on_rounded, 'Location', location.trim()),
        if (hasLink)
          Padding(
            padding: const EdgeInsets.only(top: 8, left: 32),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => _openLink(context),
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.open_in_new_rounded,
                        color: Color(0xFFFFE9B0), size: 16),
                    SizedBox(width: 6),
                    Text(
                      'Open location link',
                      style: TextStyle(
                        color: Color(0xFFFFE9B0),
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        decoration: TextDecoration.underline,
                        decorationColor: Color(0xFFFFE9B0),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}