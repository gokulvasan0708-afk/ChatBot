import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'community_search_sheets.dart';
import '../services/community_feed_service.dart';
import '../services/community_search_service.dart';
import '../widgets/community_widgets.dart';

// ================================================================
// COMMUNITY SEARCH  (spec -- Section 11)
// ----------------------------------------------------------------
// One search box for the whole Community: Members, Groups,
// Posts, Events, Resources, Announcements and Polls. Searching
// "Flutter" returns the Flutter group, resources, events,
// posts and members who list Flutter as a public skill.
//
// The data is read once when the page opens (privacy filtering is
// done in CommunitySearchService.loadCorpus) and ranked locally as
// the user types. Only what the signed-in member is allowed to see
// is ever searched -- see the service header for the exact rules.
// ================================================================
class CommunitySearchPage extends StatefulWidget {
  final String communityDocId;
  final String initialQuery;

  const CommunitySearchPage({
    super.key,
    required this.communityDocId,
    this.initialQuery = '',
  });

  @override
  State<CommunitySearchPage> createState() => _CommunitySearchPageState();
}

class _CommunitySearchPageState extends State<CommunitySearchPage> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();
  Timer? _debounce;

  CommunityCorpus? _corpus;
  Object? _error;
  bool _loading = true;

  String _query = '';
  String _kind = ''; // '' = all sections

  String get _uid => FirebaseAuth.instance.currentUser?.uid ?? '';

  @override
  void initState() {
    super.initState();
    _controller.text = widget.initialQuery;
    _query = widget.initialQuery.trim();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final corpus = await CommunitySearchService.loadCorpus(
        communityDocId: widget.communityDocId,
        uid: _uid,
      );
      if (!mounted) return;
      setState(() {
        _corpus = corpus;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 220), () {
      if (!mounted) return;
      setState(() {
        _query = value.trim();
        _kind = '';
      });
    });
    // Keep the clear button in sync immediately.
    setState(() {});
  }

  void _setQuery(String value) {
    _debounce?.cancel();
    _controller.text = value;
    _controller.selection = TextSelection.collapsed(offset: value.length);
    setState(() {
      _query = value.trim();
      _kind = '';
    });
  }

  Future<void> _editSkills() async {
    final saved = await CommunitySearchOpener.editMySkills(
      context,
      communityDocId: widget.communityDocId,
    );
    if (saved && mounted) _load(); // refresh so the new skills are searchable
  }

  String _errorText(Object e) {
    final text = e.toString().replaceFirst('Exception: ', '');
    // Firebase errors look like "[cloud_firestore/unavailable] ..." -
    // not something to show a student.
    return (e is Exception && !text.startsWith('['))
        ? text
        : 'Check your connection and try again.';
  }

  // ------------------------------------------------------------
  // Build
  // ------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            _buildSearchBar(),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 16, 6),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.arrow_back_ios_new_rounded,
                color: Colors.white, size: 18),
          ),
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _focus,
              autofocus: widget.initialQuery.isEmpty,
              textInputAction: TextInputAction.search,
              onChanged: _onChanged,
              onSubmitted: (v) => _setQuery(v),
              style: const TextStyle(color: Colors.white),
              cursorColor: CommunityColors.tan,
              decoration: communityInputDecoration(
                'Search this Community',
              ).copyWith(
                prefixIcon: const Icon(Icons.search_rounded,
                    color: CommunityColors.tan, size: 22),
                suffixIcon: _controller.text.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          _setQuery('');
                          _focus.requestFocus();
                        },
                        icon: const Icon(Icons.close_rounded,
                            color: Colors.white54, size: 20),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const CommunityLoading();

    if (_error != null || _corpus == null) {
      return CommunityStateMessage(
        icon: Icons.error_outline_rounded,
        title: 'Search unavailable',
        subtitle: _errorText(_error ?? 'error'),
        actionLabel: 'Retry',
        onAction: _load,
      );
    }

    final corpus = _corpus!;
    final banners = <Widget>[
      if (corpus.fromCache) const CommunityOfflineBanner(),
      if (corpus.failedSections.isNotEmpty) _buildFailedNotice(corpus),
    ];

    if (_query.length < CommunitySearchService.minQueryLength) {
      return Column(
        children: [
          ...banners,
          Expanded(child: _buildIdle(corpus)),
        ],
      );
    }

    final allHits = CommunitySearchService.search(corpus, _query);
    final counts = CommunitySearchService.countByKind(allHits);
    final shown = _kind.isEmpty
        ? allHits
        : allHits.where((h) => h.kind == _kind).toList();

    return Column(
      children: [
        ...banners,
        if (allHits.isNotEmpty) _buildKindRow(counts, allHits.length),
        Expanded(
          child: shown.isEmpty
              ? CommunityStateMessage(
                  icon: Icons.search_off_rounded,
                  title: 'No results for "$_query"',
                  subtitle:
                      'Try a different word, a shorter search, or a #hashtag.',
                )
              : _buildResults(shown, corpus),
        ),
      ],
    );
  }

  Widget _buildFailedNotice(CommunityCorpus corpus) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      color: const Color(0xFF20202A),
      child: Row(
        children: [
          const Icon(Icons.info_outline_rounded,
              color: CommunityColors.glow, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Couldn\'t search ${corpus.failedSections.join(', ')} right now.',
              style: const TextStyle(color: CommunityColors.glow, fontSize: 12),
            ),
          ),
          TextButton(
            onPressed: _load,
            style: TextButton.styleFrom(
                foregroundColor: CommunityColors.tan,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 30)),
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  // ---- idle (no query yet) ----

  Widget _buildIdle(CommunityCorpus corpus) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      children: [
        const Text(
          'Search members, groups, posts, events, resources, announcements and polls.',
          style: TextStyle(color: Colors.white54, fontSize: 13, height: 1.4),
        ),
        const SizedBox(height: 18),
        const Text('Try a topic',
            style: TextStyle(
                color: Colors.white,
                fontSize: 13.5,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final tag in CommunityFeedService.suggestedHashtags)
              ActionChip(
                label: Text('#$tag'),
                onPressed: () => _setQuery(tag),
                backgroundColor: const Color(0xFF18181F),
                labelStyle: const TextStyle(
                    color: CommunityColors.glow, fontSize: 12.5),
                side: BorderSide(
                    color: CommunityColors.tan.withValues(alpha: .3)),
              ),
          ],
        ),
        const SizedBox(height: 26),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: CommunityColors.card,
            borderRadius: BorderRadius.circular(16),
            border:
                Border.all(color: CommunityColors.tan.withValues(alpha: .25)),
          ),
          child: Row(
            children: [
              const Icon(Icons.psychology_alt_rounded,
                  color: CommunityColors.glow, size: 24),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Let people find you by your skills. Add the skills you want to be public.',
                  style: TextStyle(
                      color: Colors.white70, fontSize: 12.5, height: 1.35),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: _editSkills,
                style: TextButton.styleFrom(
                    foregroundColor: CommunityColors.tan),
                child: const Text('My skills'),
              ),
            ],
          ),
        ),
        if (corpus.membersTruncated) ...[
          const SizedBox(height: 14),
          Text(
            'Large Community: member search covers the first '
            '${CommunitySearchService.maxMembers} members.',
            style: const TextStyle(color: Colors.white30, fontSize: 11.5),
          ),
        ],
      ],
    );
  }

  // ---- results ----

  Widget _buildKindRow(Map<String, int> counts, int total) {
    final entries = <MapEntry<String, String>>[
      MapEntry('', 'All ($total)'),
      for (final k in CommunitySearchKind.all)
        if ((counts[k] ?? 0) > 0)
          MapEntry(k, '${CommunitySearchKind.labels[k]} (${counts[k]})'),
    ];
    return SizedBox(
      height: 46,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        itemCount: entries.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final e = entries[i];
          final selected = _kind == e.key;
          return ChoiceChip(
            label: Text(e.value),
            selected: selected,
            onSelected: (_) => setState(() => _kind = e.key),
            selectedColor: CommunityColors.tan,
            backgroundColor: const Color(0xFF18181F),
            labelStyle: TextStyle(
              color: selected ? Colors.black : Colors.white70,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
            side: BorderSide(color: CommunityColors.tan.withValues(alpha: .3)),
          );
        },
      ),
    );
  }

  Widget _buildResults(List<CommunitySearchHit> hits, CommunityCorpus corpus) {
    // Sections ordered by their best hit, so the most relevant kind
    // is first; inside a section hits stay ranked.
    final byKind = <String, List<CommunitySearchHit>>{};
    for (final h in hits) {
      byKind.putIfAbsent(h.kind, () => []).add(h);
    }
    final kinds = byKind.keys.toList()
      ..sort((a, b) => byKind[b]!.first.score.compareTo(byKind[a]!.first.score));

    final rows = <Widget>[];
    for (final k in kinds) {
      if (_kind.isEmpty) {
        rows.add(Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
          child: Text(
            CommunitySearchKind.labels[k] ?? k,
            style: TextStyle(
                color: CommunityColors.tan.withValues(alpha: .9),
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                letterSpacing: .3),
          ),
        ));
      }
      for (final h in byKind[k]!) {
        rows.add(_ResultTile(
          hit: h,
          onTap: () => CommunitySearchOpener.open(context,
              hit: h, corpus: corpus),
        ));
      }
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: rows,
    );
  }
}

class _ResultTile extends StatelessWidget {
  final CommunitySearchHit hit;
  final VoidCallback onTap;

  const _ResultTile({required this.hit, required this.onTap});

  static const Map<String, IconData> _icons = {
    CommunitySearchKind.member: Icons.person_rounded,
    CommunitySearchKind.group: Icons.groups_rounded,
    CommunitySearchKind.post: Icons.dynamic_feed_rounded,
    CommunitySearchKind.event: Icons.event_rounded,
    CommunitySearchKind.resource: Icons.folder_copy_rounded,
    CommunitySearchKind.announcement: Icons.campaign_rounded,
    CommunitySearchKind.poll: Icons.poll_rounded,
  };

  Widget _leading() {
    final isPerson = hit.kind == CommunitySearchKind.member;
    if (isPerson || hit.imageUrl.isNotEmpty) {
      return CommunityAvatar(url: hit.imageUrl, name: hit.title, radius: 22);
    }
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: CommunityColors.avatarBg,
        shape: BoxShape.circle,
        border: Border.all(color: CommunityColors.tan.withValues(alpha: .35)),
      ),
      child: Icon(_icons[hit.kind] ?? Icons.search_rounded,
          color: CommunityColors.glow, size: 21),
    );
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
        child: Row(
          children: [
            _leading(),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    hit.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600),
                  ),
                  if (hit.subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      hit.subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 12, height: 1.3),
                    ),
                  ],
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: Colors.white24),
          ],
        ),
      ),
    );
  }
}
