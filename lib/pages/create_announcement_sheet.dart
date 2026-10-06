import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import 'app_theme.dart';
import '../services/announcement_service.dart';
import '../widgets/show_to_all_colleges_toggle.dart';
import '../widgets/top_alert.dart';

// ================================================================
// CREATE ANNOUNCEMENT SHEET
// ----------------------------------------------------------------
// Only reachable by Community admins/moderators (CommunityAnnounce-
// mentsPage only shows the "+" when AnnouncementService.canCreate()
// is true), so no permission gate is re-checked visually here — but
// the write itself is still validated against CommunityService.
// isPrivileged() server-side-equivalent logic if this is ever called
// from anywhere else, since createAnnouncement() has no such guard
// on its own (mirrors how CommunityService.createCommunity() also
// trusts its caller — the *screens* are the gate today, exactly like
// the rest of this app's Firestore-direct-write architecture).
//
// Same Cloudinary upload flow as CreateCommunityDialog for the image
// type; text/link/document/video/poll/event share one flexible form
// so this stays ONE sheet instead of seven near-duplicate ones.
// ================================================================
class CreateAnnouncementSheet extends StatefulWidget {
  final String communityDocId;

  const CreateAnnouncementSheet({super.key, required this.communityDocId});

  @override
  State<CreateAnnouncementSheet> createState() => _CreateAnnouncementSheetState();
}

class _CreateAnnouncementSheetState extends State<CreateAnnouncementSheet> {
  static const String _cloudName = 'db4zevmud';
  static const String _uploadPreset = 'nexus_profile_images';

  final ImagePicker _imagePicker = ImagePicker();
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _bodyController = TextEditingController();
  final TextEditingController _linkController = TextEditingController();
  final TextEditingController _audienceValueController = TextEditingController();

  String _type = 'text';
  String _audienceKind = 'community';
  bool _isUrgent = false;
  bool _showToAllColleges = false;
  bool _posting = false;
  bool _uploadingImage = false;
  String? _imageUrl;

  @override
  void dispose() {
    _titleController.dispose();
    _bodyController.dispose();
    _linkController.dispose();
    _audienceValueController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    try {
      final image = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 82,
        maxWidth: 1600,
      );
      if (image == null) return;
      setState(() => _uploadingImage = true);

      final request = http.MultipartRequest(
        'POST',
        Uri.parse('https://api.cloudinary.com/v1_1/$_cloudName/image/upload'),
      );
      request.fields['upload_preset'] = _uploadPreset;
      request.files.add(await http.MultipartFile.fromPath('file', image.path));

      final response = await request.send();
      final responseBody = await response.stream.bytesToString();
      if (!mounted) return;

      if (response.statusCode != 200) {
        setState(() => _uploadingImage = false);
        showTopAlert(context, 'Image upload failed.', isError: true);
        return;
      }

      final data = jsonDecode(responseBody);
      final url = (data['secure_url'] ?? '').toString();
      setState(() {
        _imageUrl = url;
        _uploadingImage = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _uploadingImage = false);
      showTopAlert(context, 'Image upload failed.', isError: true);
    }
  }

  Future<void> _post() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final title = _titleController.text.trim();
    if (title.isEmpty) {
      showTopAlert(context, 'Title is required', isError: true);
      return;
    }
    if (_type == 'image' && (_imageUrl == null || _imageUrl!.isEmpty)) {
      showTopAlert(context, 'Please attach an image', isError: true);
      return;
    }
    if (_type == 'link' && _linkController.text.trim().isEmpty) {
      showTopAlert(context, 'Please add a link', isError: true);
      return;
    }
    if (_audienceKind != 'community' && _audienceValueController.text.trim().isEmpty) {
      showTopAlert(context, 'Please specify the target $_audienceKind', isError: true);
      return;
    }

    setState(() => _posting = true);
    try {
      final userDoc =
          await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
      final userData = userDoc.data() ?? {};
      final authorName = (userData['publicName'] ?? 'Admin').toString();
      final authorAvatarUrl = (userData['publicImage'] ?? '').toString();

      await AnnouncementService.createAnnouncement(
        communityDocId: widget.communityDocId,
        authorUid: user.uid,
        authorName: authorName,
        authorAvatarUrl: authorAvatarUrl,
        type: _type,
        title: title,
        body: _bodyController.text,
        mediaUrl: _type == 'image' ? (_imageUrl ?? '') : '',
        linkUrl: _type == 'link' ? _linkController.text.trim() : '',
        audienceKind: _audienceKind,
        audienceValue: _audienceKind == 'community' ? '' : _audienceValueController.text,
        isUrgent: _isUrgent,
        showToAllColleges: _showToAllColleges,
      );

      if (!mounted) return;
      Navigator.of(context).pop();
      showTopAlert(context, 'Announcement posted');
    } catch (e) {
      if (!mounted) return;
      setState(() => _posting = false);
      showTopAlert(context, e.toString().replaceFirst('Exception: ', ''), isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1B120A),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Text('New Announcement',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
                const SizedBox(height: 18),

                // Top option: also show this on other colleges' Notice Boards.
                ShowToAllCollegesToggle(
                  communityDocId: widget.communityDocId,
                  value: _showToAllColleges,
                  onChanged: (v) => setState(() => _showToAllColleges = v),
                ),

                _Label('Type'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: AnnouncementService.types.map((t) {
                    return _Chip(
                      label: _typeLabel(t),
                      selected: _type == t,
                      onTap: () => setState(() => _type = t),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),

                _Label('Title'),
                const SizedBox(height: 6),
                _Field(controller: _titleController, hint: 'Announcement title'),
                const SizedBox(height: 14),

                _Label('Details'),
                const SizedBox(height: 6),
                _Field(controller: _bodyController, hint: 'Write the details…', maxLines: 4),

                if (_type == 'image') ...[
                  const SizedBox(height: 14),
                  _Label('Image'),
                  const SizedBox(height: 8),
                  GestureDetector(
                    onTap: _uploadingImage ? null : _pickImage,
                    child: Container(
                      height: 140,
                      decoration: BoxDecoration(
                        color: const Color(0xFF2A1B0E),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFFD2B48C).withValues(alpha: .4)),
                      ),
                      child: _uploadingImage
                          ? const Center(
                              child: CircularProgressIndicator(color: Color(0xFFD2B48C)))
                          : (_imageUrl != null
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(14),
                                  child: Image.network(_imageUrl!, fit: BoxFit.cover),
                                )
                              : const Center(
                                  child: Icon(Icons.add_photo_alternate_rounded,
                                      color: Color(0xFFD2B48C), size: 32),
                                )),
                    ),
                  ),
                ],

                if (_type == 'link') ...[
                  const SizedBox(height: 14),
                  _Label('Link URL'),
                  const SizedBox(height: 6),
                  _Field(controller: _linkController, hint: 'https://…'),
                ],

                if (_type == 'video' || _type == 'document') ...[
                  const SizedBox(height: 14),
                  _Label(_type == 'video' ? 'Video link' : 'Document link'),
                  const SizedBox(height: 6),
                  _Field(
                    controller: _linkController,
                    hint: _type == 'video'
                        ? 'Paste a video link (YouTube, Drive, etc.)'
                        : 'Paste a document link (Drive, PDF, etc.)',
                  ),
                ],

                if (_type == 'poll' || _type == 'event') ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2A1B0E),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.info_outline_rounded, color: Colors.white38, size: 16),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _type == 'poll'
                                ? 'This posts as a poll announcement linking to the Polls section once it\'s created there.'
                                : 'This posts as an event announcement linking to the Events section once it\'s created there.',
                            style: const TextStyle(color: Colors.white38, fontSize: 11.5),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 16),
                _Label('Audience'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _Chip(
                      label: 'Entire Community',
                      selected: _audienceKind == 'community',
                      onTap: () => setState(() => _audienceKind = 'community'),
                    ),
                    _Chip(
                      label: 'Specific Year',
                      selected: _audienceKind == 'year',
                      onTap: () => setState(() => _audienceKind = 'year'),
                    ),
                    _Chip(
                      label: 'Specific Department',
                      selected: _audienceKind == 'department',
                      onTap: () => setState(() => _audienceKind = 'department'),
                    ),
                  ],
                ),
                if (_audienceKind != 'community') ...[
                  const SizedBox(height: 10),
                  _Field(
                    controller: _audienceValueController,
                    hint: _audienceKind == 'year' ? 'e.g. 2nd Year' : 'e.g. IT Department',
                  ),
                ],

                const SizedBox(height: 14),
                Row(
                  children: [
                    Switch(
                      value: _isUrgent,
                      activeThumbColor: const Color(0xFFD2B48C),
                      onChanged: (v) => setState(() => _isUrgent = v),
                    ),
                    const Text('Mark as urgent / important',
                        style: TextStyle(color: Colors.white70, fontSize: 13)),
                  ],
                ),

                const SizedBox(height: 18),
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
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2.2, color: Color(0xFF1B120A)),
                                )
                              : const Text('Post Announcement',
                                  style: TextStyle(
                                      color: Color(0xFF1B120A), fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _typeLabel(String t) {
    switch (t) {
      case 'text':
        return 'Text';
      case 'image':
        return 'Image';
      case 'video':
        return 'Video';
      case 'document':
        return 'Document';
      case 'link':
        return 'Link';
      case 'poll':
        return 'Poll';
      case 'event':
        return 'Event';
      default:
        return t;
    }
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);
  @override
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(color: Colors.white70, fontSize: 12.5, fontWeight: FontWeight.w600));
}

class _Field extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final int maxLines;
  const _Field({required this.controller, required this.hint, this.maxLines = 1});

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white38),
        filled: true,
        fillColor: const Color(0xFF2A1B0E),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _Chip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          gradient: selected ? AppColors.goldGradient : null,
          color: selected ? null : const Color(0xFF2A1B0E),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFFD2B48C).withValues(alpha: selected ? 1 : .4)),
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