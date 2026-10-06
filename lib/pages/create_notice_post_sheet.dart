import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'app_theme.dart';
import 'community_members_directory_page.dart'
    show kCommunityYears, kDefaultDepartments;
import '../services/community_media_service.dart';
import '../services/notice_post_service.dart';
import '../widgets/community_widgets.dart';
import '../widgets/show_to_all_colleges_toggle.dart';
import '../widgets/top_alert.dart';

// ================================================================
// CREATE NOTICE POST SHEET
// ----------------------------------------------------------------
// Opened by the post icon on the Notice Board.
//   Step 1: choose the kind of post
//           (text / text + image / image / video / video + text)
//   Step 2: write it, set the END TIME and pick the AUDIENCE
//           (several audiences can be selected together).
// ================================================================
class CreateNoticePostSheet extends StatefulWidget {
  final String communityDocId;
  final Map<String, dynamic> community;

  /// Non-null = edit this existing notice post (author only).
  final Map<String, dynamic>? existing;

  const CreateNoticePostSheet({
    super.key,
    required this.communityDocId,
    required this.community,
    this.existing,
  });

  static Future<void> show(
    BuildContext context, {
    required String communityDocId,
    required Map<String, dynamic> community,
    Map<String, dynamic>? existing,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CreateNoticePostSheet(
        communityDocId: communityDocId,
        community: community,
        existing: existing,
      ),
    );
  }

  @override
  State<CreateNoticePostSheet> createState() => _CreateNoticePostSheetState();
}

class _CreateNoticePostSheetState extends State<CreateNoticePostSheet> {
  static const Color _tan = Color(0xFFD2B48C);

  final ImagePicker _picker = ImagePicker();
  final TextEditingController _title = TextEditingController();
  final TextEditingController _text = TextEditingController();

  String? _type; // null = still choosing the kind of post
  String? _imagePath;
  String? _videoPath;

  DateTime? _endAt;
  int? _presetHours = 24; // null = custom time

  final Set<String> _audiences = {NoticeAudience.community};
  final Set<String> _departments = {};
  final Set<String> _years = {};

  bool _posting = false;
  bool _showToAllColleges = false;
  String _status = '';

  /// Media already on the post being edited (kept unless replaced).
  String _existingMediaUrl = '';

  bool get _editing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    _endAt = DateTime.now().add(const Duration(hours: 24));

    final e = widget.existing;
    if (e == null) return;
    List<String> list(dynamic v) =>
        v is List ? v.map((x) => x.toString()).toList() : <String>[];

    _type = (e['type'] ?? '').toString();
    _title.text = (e['title'] ?? '').toString();
    _text.text = (e['text'] ?? '').toString();
    _existingMediaUrl = (e['mediaUrl'] ?? '').toString();
    final end = NoticePostService.endOf(e);
    if (end != null) _endAt = end;
    _presetHours = null;
    final kinds = list(e['audiences']);
    _audiences
      ..clear()
      ..addAll(kinds.isEmpty ? [NoticeAudience.community] : kinds);
    _departments.addAll(list(e['departments']));
    _years.addAll(list(e['years']));
    _showToAllColleges = e['showToAllColleges'] == true;
  }

  @override
  void dispose() {
    _title.dispose();
    _text.dispose();
    super.dispose();
  }

  List<String> get _departmentOptions {
    final raw = widget.community['departments'];
    if (raw is List && raw.isNotEmpty) {
      return raw.map((e) => e.toString()).where((e) => e.trim().isNotEmpty).toList();
    }
    return kDefaultDepartments;
  }

  // ----------------------------------------------------------
  // pickers
  // ----------------------------------------------------------
  Future<void> _pickImage() async {
    try {
      final x = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
        maxWidth: 1800,
      );
      if (x == null || !mounted) return;
      setState(() => _imagePath = x.path);
    } catch (_) {
      if (!mounted) return;
      showTopAlert(context, 'Couldn\'t open your gallery.', isError: true);
    }
  }

  Future<void> _pickVideo() async {
    try {
      final x = await _picker.pickVideo(
        source: ImageSource.gallery,
        maxDuration: const Duration(minutes: 5),
      );
      if (x == null || !mounted) return;
      setState(() => _videoPath = x.path);
    } catch (_) {
      if (!mounted) return;
      showTopAlert(context, 'Couldn\'t open your gallery.', isError: true);
    }
  }

  void _setPreset(int hours) {
    setState(() {
      _presetHours = hours;
      _endAt = DateTime.now().add(Duration(hours: hours));
    });
  }

  Future<void> _pickCustomEnd() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _endAt ?? now.add(const Duration(days: 1)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_endAt ?? now.add(const Duration(hours: 1))),
    );
    if (time == null || !mounted) return;
    final picked = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    if (!picked.isAfter(DateTime.now())) {
      showTopAlert(context, 'End time must be in the future', isError: true);
      return;
    }
    setState(() {
      _presetHours = null;
      _endAt = picked;
    });
  }

  void _toggleAudience(String kind) {
    setState(() {
      if (kind == NoticeAudience.community) {
        // "Entire Community" already covers everyone.
        _audiences
          ..clear()
          ..add(NoticeAudience.community);
        return;
      }
      _audiences.remove(NoticeAudience.community);
      if (!_audiences.add(kind)) _audiences.remove(kind);
      if (_audiences.isEmpty) _audiences.add(NoticeAudience.community);
    });
  }

  // ----------------------------------------------------------
  // post
  // ----------------------------------------------------------
  Future<void> _post() async {
    final user = FirebaseAuth.instance.currentUser;
    final type = _type;
    if (user == null || type == null) return;

    final title = _title.text.trim();
    final text = _text.text.trim();

    String? error;
    if (NoticePostType.hasText(type) && text.isEmpty) {
      error = 'Please write the text';
    } else if (NoticePostType.hasImage(type) &&
        _imagePath == null &&
        _existingMediaUrl.isEmpty) {
      error = 'Please add an image';
    } else if (NoticePostType.hasVideo(type) &&
        _videoPath == null &&
        _existingMediaUrl.isEmpty) {
      error = 'Please add a video';
    } else if (_endAt == null || !_endAt!.isAfter(DateTime.now())) {
      error = 'Please set an end time in the future';
    } else if (NoticeAudience.needsDepartments(_audiences) && _departments.isEmpty) {
      error = 'Select at least one department';
    } else if (NoticeAudience.needsYears(_audiences) && _years.isEmpty) {
      error = 'Select at least one year';
    }
    if (error != null) {
      showTopAlert(context, error, isError: true);
      return;
    }

    setState(() {
      _posting = true;
      _status = '';
    });
    try {
      var mediaUrl = '';
      if (NoticePostType.hasImage(type)) {
        if (_imagePath != null) {
          setState(() => _status = 'Uploading image…');
          final r = await CommunityMediaService.upload(
              path: _imagePath!, kind: CommunityMediaService.kindImage);
          mediaUrl = r.url;
        } else {
          mediaUrl = _existingMediaUrl;
        }
      } else if (NoticePostType.hasVideo(type)) {
        if (_videoPath != null) {
          setState(() => _status = 'Uploading video…');
          final r = await CommunityMediaService.upload(
              path: _videoPath!, kind: CommunityMediaService.kindVideo);
          mediaUrl = r.url;
        } else {
          mediaUrl = _existingMediaUrl;
        }
      }

      if (_editing) {
        setState(() => _status = 'Saving…');
        await NoticePostService.updatePost(
          id: (widget.existing!['id'] ?? '').toString(),
          requesterUid: user.uid,
          type: type,
          title: title,
          text: NoticePostType.hasText(type) ? text : '',
          mediaUrl: mediaUrl,
          audiences: _audiences.toList(),
          departments: _departments.toList(),
          years: _years.toList(),
          endAt: _endAt!,
          showToAllColleges: _showToAllColleges,
        );
        if (!mounted) return;
        Navigator.of(context).pop();
        showTopAlert(context, 'Notice updated');
        return;
      }

      setState(() => _status = 'Posting…');
      final userDoc =
          await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
      final u = userDoc.data() ?? {};

      await NoticePostService.createPost(
        communityDocId: widget.communityDocId,
        authorUid: user.uid,
        authorName: (u['publicName'] ?? '').toString(),
        authorAvatarUrl: (u['publicImage'] ?? '').toString(),
        type: type,
        title: title,
        text: NoticePostType.hasText(type) ? text : '',
        mediaUrl: mediaUrl,
        audiences: _audiences.toList(),
        departments: _departments.toList(),
        years: _years.toList(),
        endAt: _endAt!,
        showToAllColleges: _showToAllColleges,
      );

      if (!mounted) return;
      Navigator.of(context).pop();
      showTopAlert(context, 'Posted to the Notice Board');
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

  // ----------------------------------------------------------
  // build
  // ----------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * .92,
        ),
        decoration: const BoxDecoration(
          color: Color(0xFF1B120A),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          top: false,
          child: _type == null ? _buildTypePicker() : _buildForm(_type!),
        ),
      ),
    );
  }

  Widget _handle() => Center(
        child: Container(
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: Colors.white24,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
      );

  IconData _typeIcon(String t) {
    switch (t) {
      case NoticePostType.text:
        return Icons.notes_rounded;
      case NoticePostType.textImage:
        return Icons.photo_library_rounded;
      case NoticePostType.image:
        return Icons.image_rounded;
      case NoticePostType.video:
        return Icons.videocam_rounded;
      default:
        return Icons.video_collection_rounded;
    }
  }

  String _typeHint(String t) {
    switch (t) {
      case NoticePostType.text:
        return 'Write a text notice';
      case NoticePostType.textImage:
        return 'A text notice with a picture';
      case NoticePostType.image:
        return 'Just a picture';
      case NoticePostType.video:
        return 'Just a video';
      default:
        return 'A video with a text note';
    }
  }

  Widget _buildTypePicker() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _handle(),
          const SizedBox(height: 16),
          const Text(
            'Post to Notice Board',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          const Text(
            'What do you want to post?',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54, fontSize: 12.5),
          ),
          const SizedBox(height: 16),
          for (final t in NoticePostType.all)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Material(
                color: const Color(0xFF2A1B0E),
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => setState(() => _type = t),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: _tan.withValues(alpha: .35)),
                    ),
                    child: Row(
                      children: [
                        Icon(_typeIcon(t), color: _tan, size: 24),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                NoticePostType.label(t),
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 14.5,
                                    fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _typeHint(t),
                                style: const TextStyle(
                                    color: Colors.white54, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                        const Icon(Icons.chevron_right_rounded,
                            color: Colors.white38),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildForm(String type) {
    final showDepts = NoticeAudience.needsDepartments(_audiences);
    final showYears = NoticeAudience.needsYears(_audiences);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _handle(),
          const SizedBox(height: 10),
          Row(
            children: [
              IconButton(
                onPressed: _posting
                    ? null
                    : () {
                        if (_editing) {
                          Navigator.of(context).pop();
                        } else {
                          setState(() => _type = null);
                        }
                      },
                icon: const Icon(Icons.arrow_back_ios_new_rounded,
                    color: Colors.white, size: 18),
              ),
              Expanded(
                child: Text(
                  _editing ? 'Edit Notice' : NoticePostType.label(type),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 48),
            ],
          ),
          const SizedBox(height: 12),

          // Top option: also show this on other colleges' Notice Boards.
          ShowToAllCollegesToggle(
            communityDocId: widget.communityDocId,
            value: _showToAllColleges,
            onChanged: (v) => setState(() => _showToAllColleges = v),
          ),

          _label('Title (optional)'),
          const SizedBox(height: 6),
          _field(_title, 'Notice title'),

          if (NoticePostType.hasText(type)) ...[
            const SizedBox(height: 14),
            _label('Text'),
            const SizedBox(height: 6),
            _field(_text, 'Write your notice…', maxLines: 5),
          ],

          if (NoticePostType.hasImage(type)) ...[
            const SizedBox(height: 14),
            _label('Image'),
            const SizedBox(height: 8),
            _mediaBox(
              onTap: _posting ? null : _pickImage,
              child: _imagePath != null
                  ? Image.file(File(_imagePath!),
                      fit: BoxFit.cover, width: double.infinity)
                  : (_existingMediaUrl.startsWith('http')
                      ? Image.network(_existingMediaUrl,
                          fit: BoxFit.cover, width: double.infinity)
                      : const _MediaPlaceholder(
                          icon: Icons.add_photo_alternate_rounded,
                          text: 'Choose an image')),
            ),
          ],

          if (NoticePostType.hasVideo(type)) ...[
            const SizedBox(height: 14),
            _label('Video'),
            const SizedBox(height: 8),
            _mediaBox(
              onTap: _posting ? null : _pickVideo,
              child: _MediaPlaceholder(
                icon: (_videoPath == null && _existingMediaUrl.isEmpty)
                    ? Icons.video_library_rounded
                    : Icons.check_circle_rounded,
                text: _videoPath != null
                    ? CommunityMediaService.fileNameOf(_videoPath!)
                    : (_existingMediaUrl.isNotEmpty
                        ? 'Current video kept · tap to replace'
                        : 'Choose a video (max 100 MB)'),
              ),
              height: 100,
            ),
          ],

          // ---------------- end time ----------------
          const SizedBox(height: 18),
          _label('Post ends at'),
          const SizedBox(height: 4),
          const Text(
            'After this time the post is no longer shown.',
            style: TextStyle(color: Colors.white38, fontSize: 11.5),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _chip('6 hours', _presetHours == 6, () => _setPreset(6)),
              _chip('1 day', _presetHours == 24, () => _setPreset(24)),
              _chip('3 days', _presetHours == 72, () => _setPreset(72)),
              _chip('7 days', _presetHours == 168, () => _setPreset(168)),
              _chip('Custom…', _presetHours == null, _pickCustomEnd),
            ],
          ),
          if (_endAt != null) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(Icons.schedule_rounded, color: _tan, size: 16),
                const SizedBox(width: 6),
                Text(
                  'Ends ${communityFormatDateTime(_endAt!)}',
                  style: const TextStyle(color: Colors.white70, fontSize: 12.5),
                ),
              ],
            ),
          ],

          // ---------------- audience ----------------
          const SizedBox(height: 18),
          _label('Who is this post for?'),
          const SizedBox(height: 4),
          const Text(
            'You can select more than one.',
            style: TextStyle(color: Colors.white38, fontSize: 11.5),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final k in NoticeAudience.all)
                _chip(NoticeAudience.label(k), _audiences.contains(k),
                    () => _toggleAudience(k)),
            ],
          ),

          if (showDepts) ...[
            const SizedBox(height: 14),
            _label('Departments'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final d in _departmentOptions)
                  _chip(d, _departments.contains(d), () {
                    setState(() {
                      if (!_departments.add(d)) _departments.remove(d);
                    });
                  }),
              ],
            ),
          ],

          if (showYears) ...[
            const SizedBox(height: 14),
            _label('Years'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final y in kCommunityYears)
                  _chip(y, _years.contains(y), () {
                    setState(() {
                      if (!_years.add(y)) _years.remove(y);
                    });
                  }),
              ],
            ),
          ],

          const SizedBox(height: 20),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: AppColors.goldGradient,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: _posting ? null : _post,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Center(
                    child: _posting
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2.2,
                                    color: Color(0xFF1B120A)),
                              ),
                              if (_status.isNotEmpty) ...[
                                const SizedBox(width: 10),
                                Text(_status,
                                    style: const TextStyle(
                                        color: Color(0xFF1B120A),
                                        fontWeight: FontWeight.w600)),
                              ],
                            ],
                          )
                        : Text(_editing ? 'Save changes' : 'Post',
                            style: TextStyle(
                                color: Color(0xFF1B120A),
                                fontWeight: FontWeight.bold)),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ----------------------------------------------------------
  // small widgets
  // ----------------------------------------------------------
  Widget _label(String t) => Text(t,
      style: const TextStyle(
          color: Colors.white70, fontSize: 12.5, fontWeight: FontWeight.w600));

  Widget _field(TextEditingController c, String hint, {int maxLines = 1}) {
    return TextField(
      controller: c,
      maxLines: maxLines,
      enabled: !_posting,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white38),
        filled: true,
        fillColor: const Color(0xFF2A1B0E),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      ),
    );
  }

  Widget _mediaBox({
    required VoidCallback? onTap,
    required Widget child,
    double height = 150,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: height,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: const Color(0xFF2A1B0E),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _tan.withValues(alpha: .4)),
        ),
        child: child,
      ),
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: _posting ? null : onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          gradient: selected ? AppColors.goldGradient : null,
          color: selected ? null : const Color(0xFF2A1B0E),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _tan.withValues(alpha: selected ? 1 : .4)),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? const Color(0xFF1B120A) : Colors.white70,
            fontWeight: FontWeight.w600,
            fontSize: 12.5,
          ),
        ),
      ),
    );
  }
}

class _MediaPlaceholder extends StatelessWidget {
  final IconData icon;
  final String text;
  const _MediaPlaceholder({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: const Color(0xFFD2B48C), size: 30),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white54, fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }
}