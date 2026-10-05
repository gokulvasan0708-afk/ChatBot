import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'community_resource_card.dart';
import 'upload_resource_sheet.dart';
import '../services/community_resource_service.dart';
import '../services/community_service.dart';
import '../widgets/community_widgets.dart';

// ================================================================
// COMMUNITY RESOURCES  (spec -- Section 8)
// ----------------------------------------------------------------
// The Community Resources library: upload, view / download, search,
// category + tag filters, description, uploaded-by, date, report and
// delete (uploader or Community admin/moderator).
//
// [CommunityResourcesBody] holds all of the behaviour so the same
// library is shown both here and inside the Feed's "Resources" tab.
// Loading / empty / error / offline / permission states included.
// ================================================================
class CommunityResourcesPage extends StatefulWidget {
  final String communityDocId;
  final String initialCategory;

  const CommunityResourcesPage({
    super.key,
    required this.communityDocId,
    this.initialCategory = '',
  });

  @override
  State<CommunityResourcesPage> createState() => _CommunityResourcesPageState();
}

class _CommunityResourcesPageState extends State<CommunityResourcesPage> {
  int _retryKey = 0;

  String get _uid => FirebaseAuth.instance.currentUser?.uid ?? '';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          key: ValueKey(_retryKey),
          stream: CommunityService.watchCommunity(widget.communityDocId),
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const CommunityLoading();
            }
            if (snap.hasError) {
              return CommunityStateMessage(
                icon: Icons.error_outline_rounded,
                title: 'Unable to load Community',
                subtitle: 'Something went wrong. Please try again.',
                actionLabel: 'Retry',
                onAction: () => setState(() => _retryKey++),
              );
            }
            final community = snap.data?.data();
            if (community == null) {
              return const CommunityStateMessage(
                icon: Icons.public_off_rounded,
                title: 'Community not found',
                subtitle: 'This community may have been deleted.',
              );
            }

            final isMember = community['members'] is List &&
                (community['members'] as List).contains(_uid);

            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 12, 12, 0),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.arrow_back_ios_new_rounded,
                            color: Colors.white, size: 18),
                      ),
                      const Expanded(
                        child: Text('Resources',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: CommunityResourcesBody(
                    communityDocId: widget.communityDocId,
                    community: community,
                    isMember: isMember,
                    initialCategory: widget.initialCategory,
                    showUploadButton: true,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Search + category + tag filters + resource list.
///
/// Call [CommunityResourcesBody.openUploadSheet] to open the upload
/// sheet from outside (the Feed header does this on its Resources tab).
class CommunityResourcesBody extends StatefulWidget {
  final String communityDocId;
  final Map<String, dynamic> community;
  final bool isMember;
  final String initialCategory;
  final bool showUploadButton;

  const CommunityResourcesBody({
    super.key,
    required this.communityDocId,
    required this.community,
    required this.isMember,
    this.initialCategory = '',
    this.showUploadButton = true,
  });

  /// Opens the upload sheet for [communityDocId].
  static Future<void> openUploadSheet(
    BuildContext context, {
    required String communityDocId,
    String category = '',
  }) async {
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => UploadResourceSheet(
        communityDocId: communityDocId,
        initialCategory: category,
      ),
    );
  }

  @override
  State<CommunityResourcesBody> createState() => _CommunityResourcesBodyState();
}

class _CommunityResourcesBodyState extends State<CommunityResourcesBody> {
  final TextEditingController _search = TextEditingController();

  late String _category;
  String _tag = '';
  String _query = '';
  String _sort = 'newest';
  int _retryKey = 0;

  String get _uid => FirebaseAuth.instance.currentUser?.uid ?? '';

  @override
  void initState() {
    super.initState();
    _category =
        CommunityResourceService.categories.contains(widget.initialCategory)
            ? widget.initialCategory
            : '';
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _upload() => CommunityResourcesBody.openUploadSheet(
        context,
        communityDocId: widget.communityDocId,
        category: _category,
      );

  bool get _hasActiveFilter =>
      _category.isNotEmpty || _tag.isNotEmpty || _query.trim().isNotEmpty;

  void _clearFilters() {
    _search.clear();
    setState(() {
      _category = '';
      _tag = '';
      _query = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<CommunityResourceSnapshot>(
      key: ValueKey(_retryKey),
      stream: CommunityResourceService.watchResources(widget.communityDocId),
      builder: (context, snap) {
        if (snap.hasError) {
          return CommunityStateMessage(
            icon: Icons.error_outline_rounded,
            title: 'Unable to load resources',
            subtitle: 'Check your connection and try again.',
            actionLabel: 'Retry',
            onAction: () => setState(() => _retryKey++),
          );
        }
        if (snap.connectionState == ConnectionState.waiting) {
          return const CommunityLoading();
        }

        final data = snap.data ??
            const CommunityResourceSnapshot(resources: [], fromCache: false);
        final all = data.resources;
        final counts = CommunityResourceService.categoryCounts(all, _uid);
        final visibleTotal = counts.values.fold<int>(0, (a, b) => a + b);
        final tags = CommunityResourceService.topTags(all, _uid);

        final visible = CommunityResourceService.applyFilter(
          all,
          uid: _uid,
          category: _category,
          tag: _tag,
          query: _query,
          sort: _sort,
        );

        return Column(
          children: [
            if (data.fromCache && all.isNotEmpty) const CommunityOfflineBanner(),
            _buildSearchRow(),
            _buildCategoryRow(counts, visibleTotal),
            if (_tag.isNotEmpty || tags.isNotEmpty) _buildTagRow(tags),
            Expanded(
              child: visible.isEmpty
                  ? _buildEmpty(allIsEmpty: visibleTotal == 0)
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                      itemCount: visible.length,
                      itemBuilder: (_, i) => CommunityResourceCard(
                        key: ValueKey(visible[i]['id']),
                        resource: visible[i],
                        community: widget.community,
                        onTagTap: (t) => setState(() => _tag = t),
                        onCategoryTap: (c) => setState(() => _category = c),
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSearchRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _search,
              style: const TextStyle(color: Colors.white),
              textInputAction: TextInputAction.search,
              onChanged: (v) => setState(() => _query = v),
              decoration: communityInputDecoration(
                'Search title, tag, subject or uploader',
              ).copyWith(
                prefixIcon: const Icon(Icons.search_rounded,
                    color: CommunityColors.tan, size: 20),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          _search.clear();
                          setState(() => _query = '');
                        },
                        icon: const Icon(Icons.close_rounded,
                            color: Colors.white54, size: 18),
                      ),
              ),
            ),
          ),
          PopupMenuButton<String>(
            color: CommunityColors.card,
            tooltip: 'Sort',
            icon: const Icon(Icons.sort_rounded,
                color: CommunityColors.tan, size: 24),
            onSelected: (v) => setState(() => _sort = v),
            itemBuilder: (_) => [
              for (final s in CommunityResourceService.sorts)
                PopupMenuItem(
                  value: s,
                  child: Row(
                    children: [
                      Icon(
                        Icons.check_rounded,
                        size: 16,
                        color: _sort == s
                            ? CommunityColors.glow
                            : Colors.transparent,
                      ),
                      const SizedBox(width: 8),
                      Text(CommunityResourceService.sortLabels[s] ?? s,
                          style: const TextStyle(color: Colors.white)),
                    ],
                  ),
                ),
            ],
          ),
          if (widget.showUploadButton && widget.isMember)
            IconButton(
              onPressed: _upload,
              tooltip: 'Upload resource',
              icon: const Icon(Icons.upload_file_rounded,
                  color: CommunityColors.tan, size: 26),
            ),
        ],
      ),
    );
  }

  Widget _buildCategoryRow(Map<String, int> counts, int total) {
    Widget chip(String key, String label, int count) {
      final selected = _category == key;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          label: Text('$label ($count)'),
          selected: selected,
          onSelected: (_) => setState(() => _category = key),
          selectedColor: CommunityColors.tan,
          backgroundColor: CommunityColors.card,
          labelStyle: TextStyle(
            color: selected ? Colors.black : Colors.white70,
            fontWeight: FontWeight.w600,
            fontSize: 12.5,
          ),
          side: BorderSide(color: CommunityColors.tan.withValues(alpha: .3)),
        ),
      );
    }

    return SizedBox(
      height: 46,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        children: [
          chip('', 'All', total),
          for (final c in CommunityResourceService.categories)
            chip(c, CommunityResourceService.categoryShortLabels[c] ?? c,
                counts[c] ?? 0),
        ],
      ),
    );
  }

  Widget _buildTagRow(List<String> tags) {
    return SizedBox(
      height: 38,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
        children: [
          if (_tag.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: InputChip(
                label: Text('#$_tag'),
                onDeleted: () => setState(() => _tag = ''),
                backgroundColor: CommunityColors.tan.withValues(alpha: .25),
                labelStyle:
                    const TextStyle(color: CommunityColors.glow, fontSize: 12),
                deleteIconColor: CommunityColors.glow,
              ),
            ),
          for (final t in tags.where((t) => t != _tag))
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ActionChip(
                label: Text('#$t'),
                onPressed: () => setState(() => _tag = t),
                backgroundColor: CommunityColors.card,
                labelStyle:
                    const TextStyle(color: CommunityColors.tan, fontSize: 12),
                side: BorderSide(
                    color: CommunityColors.tan.withValues(alpha: .25)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEmpty({required bool allIsEmpty}) {
    if (allIsEmpty) {
      return CommunityStateMessage(
        icon: Icons.folder_open_rounded,
        title: 'No resources yet',
        subtitle: widget.isMember
            ? 'Share notes, question papers or project material with the community.'
            : 'Join this community to upload and access resources.',
        actionLabel: widget.isMember ? 'Upload resource' : null,
        onAction: widget.isMember ? _upload : null,
      );
    }

    if (_query.trim().isNotEmpty) {
      return CommunityStateMessage(
        icon: Icons.search_off_rounded,
        title: 'No matching resources',
        subtitle: 'Nothing matches "${_query.trim()}". Try a different word.',
        actionLabel: _hasActiveFilter ? 'Clear filters' : null,
        onAction: _hasActiveFilter ? _clearFilters : null,
      );
    }

    if (_category.isNotEmpty) {
      return CommunityStateMessage(
        icon: CommunityResourceCard.iconForCategory(_category),
        title:
            'No ${CommunityResourceService.categoryLabel(_category)} yet',
        subtitle: widget.isMember
            ? 'Be the first to add one to this category.'
            : 'Nothing has been added to this category.',
        actionLabel: widget.isMember ? 'Upload resource' : 'Show all',
        onAction: widget.isMember ? _upload : _clearFilters,
      );
    }

    return CommunityStateMessage(
      icon: Icons.tag_rounded,
      title: 'Nothing tagged #$_tag',
      subtitle: 'Try another tag or clear the filter.',
      actionLabel: 'Clear filters',
      onAction: _clearFilters,
    );
  }
}
