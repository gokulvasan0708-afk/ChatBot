import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'create_poll_sheet.dart';
import '../services/community_feed_service.dart';
import '../services/community_media_service.dart';
import '../widgets/community_widgets.dart';
import '../widgets/top_alert.dart';

// ================================================================
// CREATE POST SHEET  (Community Feed -- Section 6)
// ----------------------------------------------------------------
// One composer for every post type. Fields shown depend on the
// selected type; media is uploaded through CommunityMediaService
// right before the post is written, with a visible progress label
// and a clear error if anything fails (post is NOT created then).
// ================================================================
class CreatePostSheet extends StatefulWidget {
  final String communityDocId;
  final String initialType;

  const CreatePostSheet({
    super.key,
    required this.communityDocId,
    this.initialType = 'text',
  });

  @override
  State<CreatePostSheet> createState() => _CreatePostSheetState();
}

class _CreatePostSheetState extends State<CreatePostSheet> {
  final ImagePicker _picker = ImagePicker();

  final TextEditingController _text = TextEditingController();
  final TextEditingController _title = TextEditingController();
  final TextEditingController _location = TextEditingController();
  final TextEditingController _item = TextEditingController();

  late String _type;

  final List<String> _imagePaths = [];
  String? _videoPath;
  String? _certificatePath;

  DateTime? _eventAt;
  DateTime _achievementDate = DateTime.now();
  String _achievementKind = 'certification';
  String _lostKind = 'lost';

  bool _posting = false;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _type = widget.initialType;
  }

  @override
  void dispose() {
    _text.dispose();
    _title.dispose();
    _location.dispose();
    _item.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------
  // Pickers
  // ------------------------------------------------------------

  Future<void> _pickImages() async {
    try {
      final remaining = CommunityFeedService.maxImages - _imagePaths.length;
      if (remaining <= 0) {
        showTopAlert(context,
            'You can add up to ${CommunityFeedService.maxImages} images.',
            isError: true);
        return;
      }
      final picked = await _picker.pickMultiImage(
        imageQuality: 80,
        maxWidth: 1600,
        maxHeight: 1600,
      );
      if (picked.isEmpty || !mounted) return;
      setState(() => _imagePaths.addAll(picked.take(remaining).map((x) => x.path)));
    } catch (_) {
      if (!mounted) return;
      showTopAlert(context, 'Couldn\'t open your gallery.', isError: true);
    }
  }

  Future<void> _pickVideo() async {
    try {
      final picked = await _picker.pickVideo(
        source: ImageSource.gallery,
        maxDuration: const Duration(minutes: 5),
      );
      if (picked == null || !mounted) return;
      setState(() => _videoPath = picked.path);
    } catch (_) {
      if (!mounted) return;
      showTopAlert(context, 'Couldn\'t open your gallery.', isError: true);
    }
  }

  Future<void> _pickCertificate() async {
    try {
      final picked = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
        maxWidth: 1800,
      );
      if (picked == null || !mounted) return;
      setState(() => _certificatePath = picked.path);
    } catch (_) {
      if (!mounted) return;
      showTopAlert(context, 'Couldn\'t open your gallery.', isError: true);
    }
  }

  Future<void> _pickEventDateTime() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _eventAt ?? now.add(const Duration(days: 1)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 730)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_eventAt ?? now.add(const Duration(hours: 2))),
    );
    if (time == null || !mounted) return;
    setState(() => _eventAt =
        DateTime(date.year, date.month, date.day, time.hour, time.minute));
  }

  Future<void> _pickAchievementDate() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _achievementDate,
      firstDate: DateTime(now.year - 10),
      lastDate: now,
    );
    if (date == null || !mounted) return;
    setState(() => _achievementDate = date);
  }

  void _insertHashtag(String tag) {
    final current = _text.text.trimRight();
    final next = current.isEmpty ? '#$tag ' : '$current #$tag ';
    _text.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
  }

  Future<void> _openPollSheet() async {
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CreatePollSheet(communityDocId: widget.communityDocId),
    );
    if (created == true && mounted) Navigator.of(context).pop(true);
  }

  // ------------------------------------------------------------
  // Submit
  // ------------------------------------------------------------

  Future<void> _submit() async {
    if (_posting) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    setState(() {
      _posting = true;
      _status = 'Preparing…';
    });

    try {
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();
      final userData = userDoc.data() ?? {};

      List<String> mediaUrls = [];
      String mediaType = '';
      Map<String, dynamic>? event;
      Map<String, dynamic>? achievement;
      Map<String, dynamic>? lostFound;

      if (_type == 'image') {
        if (_imagePaths.isEmpty) throw Exception('Please add at least one image.');
        for (var i = 0; i < _imagePaths.length; i++) {
          if (mounted) setState(() => _status = 'Uploading image ${i + 1}/${_imagePaths.length}…');
          final r = await CommunityMediaService.upload(
              path: _imagePaths[i], kind: CommunityMediaService.kindImage);
          mediaUrls.add(r.url);
        }
        mediaType = 'image';
      } else if (_type == 'video') {
        if (_videoPath == null) throw Exception('Please add a video.');
        if (mounted) setState(() => _status = 'Uploading video…');
        final r = await CommunityMediaService.upload(
            path: _videoPath!, kind: CommunityMediaService.kindVideo);
        mediaUrls = [r.url];
        mediaType = 'video';
      } else if (_type == 'event') {
        if (_eventAt == null) throw Exception('Please choose the event date and time.');
        event = {
          'dateTime': Timestamp.fromDate(_eventAt!),
          'location': _location.text.trim(),
        };
      } else if (_type == 'achievement') {
        String certUrl = '';
        if (_certificatePath != null) {
          if (mounted) setState(() => _status = 'Uploading certificate…');
          final r = await CommunityMediaService.upload(
              path: _certificatePath!, kind: CommunityMediaService.kindImage);
          certUrl = r.url;
        }
        achievement = {
          'kind': _achievementKind,
          'date': Timestamp.fromDate(_achievementDate),
          'certificateUrl': certUrl,
        };
      } else if (_type == 'lostfound') {
        if (_imagePaths.isNotEmpty) {
          if (mounted) setState(() => _status = 'Uploading photo…');
          final r = await CommunityMediaService.upload(
              path: _imagePaths.first, kind: CommunityMediaService.kindImage);
          mediaUrls = [r.url];
          mediaType = 'image';
        }
        lostFound = {
          'status': _lostKind,
          'item': _item.text.trim(),
          'location': _location.text.trim(),
        };
      }

      if (mounted) setState(() => _status = 'Posting…');

      await CommunityFeedService.createPost(
        communityDocId: widget.communityDocId,
        authorUid: user.uid,
        authorName: (userData['publicName'] ?? 'Member').toString(),
        authorAvatarUrl: (userData['publicImage'] ?? '').toString(),
        type: _type,
        title: _title.text,
        text: _text.text,
        mediaUrls: mediaUrls,
        mediaType: mediaType,
        event: event,
        achievement: achievement,
        lostFound: lostFound,
      );

      if (!mounted) return;
      Navigator.of(context).pop(true);
      showTopAlert(context, 'Posted');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _posting = false;
        _status = '';
      });
      showTopAlert(context, e.toString().replaceFirst('Exception: ', ''),
          isError: true);
    }
  }

  // ------------------------------------------------------------
  // UI
  // ------------------------------------------------------------

  static const Map<String, IconData> _typeIcons = {
    'text': Icons.notes_rounded,
    'image': Icons.image_rounded,
    'video': Icons.videocam_rounded,
    'poll': Icons.poll_rounded,
    'question': Icons.help_outline_rounded,
    'event': Icons.event_rounded,
    'achievement': Icons.emoji_events_rounded,
    'help': Icons.volunteer_activism_rounded,
    'lostfound': Icons.search_rounded,
  };

  String get _textHint {
    switch (_type) {
      case 'question':
        return 'Ask your question…';
      case 'help':
        return 'What help do you need?';
      case 'event':
        return 'Describe the event…';
      case 'achievement':
        return 'Tell everyone about it…';
      case 'lostfound':
        return 'Add details (colour, where to collect, contact)…';
      case 'image':
      case 'video':
        return 'Add a caption… (optional)';
      default:
        return 'What\'s on your mind?';
    }
  }

  bool get _showTitle =>
      _type == 'event' || _type == 'achievement' || _type == 'help';

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: inset),
      child: CommunitySheetShell(
        title: 'Create post',
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final t in CommunityFeedService.types)
                    ChoiceChip(
                      avatar: Icon(_typeIcons[t],
                          size: 16,
                          color: _type == t ? Colors.black : CommunityColors.tan),
                      label: Text(CommunityFeedService.typeLabels[t] ?? t),
                      selected: _type == t,
                      onSelected: _posting
                          ? null
                          : (_) {
                              if (t == 'poll') {
                                _openPollSheet();
                              } else {
                                setState(() => _type = t);
                              }
                            },
                      selectedColor: CommunityColors.tan,
                      backgroundColor: const Color(0xFF18181F),
                      labelStyle: TextStyle(
                        color: _type == t ? Colors.black : Colors.white70,
                        fontSize: 12.5,
                      ),
                      side: BorderSide(
                          color: CommunityColors.tan.withValues(alpha: .3)),
                    ),
                ],
              ),
              const SizedBox(height: 16),

              if (_showTitle) ...[
                TextField(
                  controller: _title,
                  maxLength: 100,
                  style: const TextStyle(color: Colors.white),
                  decoration: communityInputDecoration(
                    _type == 'event'
                        ? 'Event title'
                        : _type == 'achievement'
                            ? 'Achievement title'
                            : 'Short title (optional)',
                    label: 'Title',
                  ),
                ),
                const SizedBox(height: 4),
              ],

              if (_type == 'lostfound') ...[
                Row(
                  children: [
                    for (final k in const ['lost', 'found'])
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(k == 'lost' ? 'I lost something' : 'I found something'),
                          selected: _lostKind == k,
                          onSelected: (_) => setState(() => _lostKind = k),
                          selectedColor: CommunityColors.tan,
                          backgroundColor: const Color(0xFF18181F),
                          labelStyle: TextStyle(
                              color: _lostKind == k ? Colors.black : Colors.white70),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _item,
                  maxLength: 80,
                  style: const TextStyle(color: Colors.white),
                  decoration: communityInputDecoration('e.g. Blue water bottle',
                      label: 'Item'),
                ),
                const SizedBox(height: 4),
                TextField(
                  controller: _location,
                  maxLength: 100,
                  style: const TextStyle(color: Colors.white),
                  decoration: communityInputDecoration(
                      _lostKind == 'lost' ? 'Last seen at…' : 'Found at…',
                      label: 'Location'),
                ),
                const SizedBox(height: 4),
              ],

              if (_type == 'event') ...[
                OutlinedButton.icon(
                  onPressed: _pickEventDateTime,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: BorderSide(color: CommunityColors.tan.withValues(alpha: .4)),
                    minimumSize: const Size.fromHeight(46),
                    alignment: Alignment.centerLeft,
                  ),
                  icon: const Icon(Icons.schedule_rounded,
                      color: CommunityColors.tan, size: 18),
                  label: Text(_eventAt == null
                      ? 'Choose date & time'
                      : communityFormatDateTime(_eventAt!)),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _location,
                  maxLength: 100,
                  style: const TextStyle(color: Colors.white),
                  decoration:
                      communityInputDecoration('Venue or online link', label: 'Location'),
                ),
                const SizedBox(height: 4),
              ],

              if (_type == 'achievement') ...[
                DropdownButtonFormField<String>(
                  initialValue: _achievementKind,
                  dropdownColor: CommunityColors.card,
                  style: const TextStyle(color: Colors.white),
                  decoration: communityInputDecoration('Category'),
                  items: CommunityFeedService.achievementKinds
                      .map((k) => DropdownMenuItem(
                          value: k,
                          child: Text(
                              CommunityFeedService.achievementKindLabels[k] ?? k)))
                      .toList(),
                  onChanged: (v) =>
                      setState(() => _achievementKind = v ?? _achievementKind),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _pickAchievementDate,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: BorderSide(color: CommunityColors.tan.withValues(alpha: .4)),
                    minimumSize: const Size.fromHeight(46),
                    alignment: Alignment.centerLeft,
                  ),
                  icon: const Icon(Icons.calendar_today_rounded,
                      color: CommunityColors.tan, size: 18),
                  label: Text('Date: ${communityFormatDate(_achievementDate)}'),
                ),
                const SizedBox(height: 12),
                _MediaPickRow(
                  label: 'Certificate / photo (optional)',
                  paths: _certificatePath == null ? const [] : [_certificatePath!],
                  onAdd: _pickCertificate,
                  onRemove: (_) => setState(() => _certificatePath = null),
                  addEnabled: _certificatePath == null && !_posting,
                ),
                const SizedBox(height: 12),
              ],

              TextField(
                controller: _text,
                minLines: _type == 'text' || _type == 'question' ? 4 : 2,
                maxLines: 8,
                maxLength: CommunityFeedService.maxTextLength,
                style: const TextStyle(color: Colors.white),
                decoration: communityInputDecoration(_textHint),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 34,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final tag in CommunityFeedService.suggestedHashtags)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ActionChip(
                          label: Text('#$tag'),
                          onPressed: () => _insertHashtag(tag),
                          backgroundColor: const Color(0xFF18181F),
                          labelStyle: const TextStyle(
                              color: CommunityColors.glow, fontSize: 12),
                          side: BorderSide(
                              color: CommunityColors.tan.withValues(alpha: .3)),
                        ),
                      ),
                  ],
                ),
              ),

              if (_type == 'image' || _type == 'lostfound') ...[
                const SizedBox(height: 14),
                _MediaPickRow(
                  label: _type == 'image'
                      ? 'Images (up to ${CommunityFeedService.maxImages})'
                      : 'Photo (optional)',
                  paths: _imagePaths,
                  onAdd: _pickImages,
                  onRemove: (i) => setState(() => _imagePaths.removeAt(i)),
                  addEnabled: !_posting &&
                      (_type == 'image'
                          ? _imagePaths.length < CommunityFeedService.maxImages
                          : _imagePaths.isEmpty),
                ),
              ],

              if (_type == 'video') ...[
                const SizedBox(height: 14),
                OutlinedButton.icon(
                  onPressed: _posting ? null : _pickVideo,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: BorderSide(color: CommunityColors.tan.withValues(alpha: .4)),
                    minimumSize: const Size.fromHeight(46),
                    alignment: Alignment.centerLeft,
                  ),
                  icon: const Icon(Icons.video_library_rounded,
                      color: CommunityColors.tan, size: 18),
                  label: Text(
                    _videoPath == null
                        ? 'Choose a video (max 100 MB)'
                        : CommunityMediaService.fileNameOf(_videoPath!),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],

              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: _posting ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: CommunityColors.tan,
                    foregroundColor: Colors.black,
                    disabledBackgroundColor: Colors.white12,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                  child: _posting
                      ? Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.black),
                            ),
                            const SizedBox(width: 10),
                            Flexible(
                              child: Text(_status,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      color: Colors.black,
                                      fontWeight: FontWeight.w600)),
                            ),
                          ],
                        )
                      : const Text('Post',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MediaPickRow extends StatelessWidget {
  final String label;
  final List<String> paths;
  final VoidCallback onAdd;
  final void Function(int index) onRemove;
  final bool addEnabled;

  const _MediaPickRow({
    required this.label,
    required this.paths,
    required this.onAdd,
    required this.onRemove,
    required this.addEnabled,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                color: CommunityColors.tan,
                fontWeight: FontWeight.w600,
                fontSize: 13)),
        const SizedBox(height: 8),
        SizedBox(
          height: 78,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (var i = 0; i < paths.length; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Stack(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.file(File(paths[i]),
                            width: 78, height: 78, fit: BoxFit.cover),
                      ),
                      Positioned(
                        top: 2,
                        right: 2,
                        child: GestureDetector(
                          onTap: () => onRemove(i),
                          child: Container(
                            decoration: const BoxDecoration(
                                color: Colors.black87, shape: BoxShape.circle),
                            padding: const EdgeInsets.all(3),
                            child: const Icon(Icons.close_rounded,
                                color: Colors.white, size: 14),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (addEnabled)
                GestureDetector(
                  onTap: onAdd,
                  child: Container(
                    width: 78,
                    height: 78,
                    decoration: BoxDecoration(
                      color: const Color(0xFF18181F),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: CommunityColors.tan.withValues(alpha: .4)),
                    ),
                    child: const Icon(Icons.add_photo_alternate_rounded,
                        color: CommunityColors.tan),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
