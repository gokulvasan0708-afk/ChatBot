import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import 'app_theme.dart';
import '../services/community_service.dart';
import '../widgets/community_about_section.dart';
import '../widgets/top_alert.dart';

// ================================================================
// CREATE COMMUNITY DIALOG
// ----------------------------------------------------------------
// Same dialog shell, same Cloudinary upload flow (identical cloud
// name + preset already used for group images in groupstab.dart /
// profile images in me_page.dart) and the same "live ID preview as
// you type the name" pattern as _CreateGroupDialog -- just for a
// Community instead of a Group, with the one thing a Group doesn't
// have: a Normal / College type switch.
// ================================================================
class CreateCommunityDialog extends StatefulWidget {
  const CreateCommunityDialog({super.key});

  @override
  State<CreateCommunityDialog> createState() => _CreateCommunityDialogState();
}

class _CreateCommunityDialogState extends State<CreateCommunityDialog> {
  static const String _cloudName = 'db4zevmud';
  static const String _uploadPreset = 'nexus_profile_images';

  final ImagePicker _imagePicker = ImagePicker();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _collegeController = TextEditingController();
  final TextEditingController _visionController = TextEditingController();
  final TextEditingController _missionController = TextEditingController();
  final TextEditingController _locationController = TextEditingController();
  final TextEditingController _locationLinkController = TextEditingController();

  String? _logoUrl;
  String _coverUrl = '';
  bool _uploadingCover = false;
  bool _uploadingImage = false;
  bool _creating = false;

  String _type = 'normal'; // 'normal' | 'college'

  // Purely visual preview -- a random 4-digit suffix generated once
  // when the dialog opens, so the user sees roughly what shape their
  // Community ID will take. The REAL id (uniqueness-checked against
  // Firestore) is generated once, at create time, by CommunityService.
  String _previewSuffix = '';

  @override
  void initState() {
    super.initState();
    _previewSuffix = _newSuffix();
    _nameController.addListener(() => setState(() {}));
    // The location link field only appears once a location is typed.
    _locationController.addListener(() => setState(() {}));
  }

  String _newSuffix() {
    return (1000 +
            (DateTime.now().millisecondsSinceEpoch % 9000))
        .toString();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _collegeController.dispose();
    _visionController.dispose();
    _missionController.dispose();
    _locationController.dispose();
    _locationLinkController.dispose();
    super.dispose();
  }

  String get _idPreview =>
      CommunityService.previewCommunityId(_nameController.text, _previewSuffix);

  // ==========================================================
  // LOGO UPLOAD -- identical Cloudinary flow to the group/profile
  // image pickers elsewhere in the app.
  // ==========================================================

  Future<void> _pickLogo() async {
    try {
      final XFile? image = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 80,
        maxWidth: 800,
        maxHeight: 800,
      );
      if (image == null) return;
      if (!mounted) return;

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
        debugPrint('Cloudinary community logo upload failed: $responseBody');
        setState(() => _uploadingImage = false);
        showTopAlert(context, 'Logo upload failed.', isError: true);
        return;
      }

      final Map<String, dynamic> data = jsonDecode(responseBody);
      final String imageUrl = (data['secure_url'] ?? '').toString();
      if (imageUrl.isEmpty) throw Exception('Cloudinary URL not received.');

      setState(() {
        _logoUrl = imageUrl;
        _uploadingImage = false;
      });
    } catch (e) {
      debugPrint('Community logo pick/upload error: $e');
      if (!mounted) return;
      setState(() => _uploadingImage = false);
      showTopAlert(context, 'Logo upload failed.', isError: true);
    }
  }


  // ==========================================================
  // COLLEGE COVER IMAGE (wide) -- same Cloudinary flow as the logo.
  // ==========================================================
  Future<void> _pickCover() async {
    try {
      final XFile? image = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 80,
        maxWidth: 1600,
        maxHeight: 1600,
      );
      if (image == null) return;
      if (!mounted) return;

      setState(() => _uploadingCover = true);

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
        setState(() => _uploadingCover = false);
        showTopAlert(context, 'Cover image upload failed.', isError: true);
        return;
      }

      final Map<String, dynamic> data = jsonDecode(responseBody);
      final String imageUrl = (data['secure_url'] ?? '').toString();
      if (imageUrl.isEmpty) throw Exception('Cloudinary URL not received.');

      setState(() {
        _coverUrl = imageUrl;
        _uploadingCover = false;
      });
    } catch (e) {
      debugPrint('Community cover pick/upload error: $e');
      if (!mounted) return;
      setState(() => _uploadingCover = false);
      showTopAlert(context, 'Cover image upload failed.', isError: true);
    }
  }

  // ==========================================================
  // CREATE
  // ==========================================================

  Future<void> _create() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final name = _nameController.text.trim();
    if (name.isEmpty) {
      showTopAlert(context, 'Community name is required', isError: true);
      return;
    }
    if (_type == 'college' && _collegeController.text.trim().isEmpty) {
      showTopAlert(context, 'College / institution name is required', isError: true);
      return;
    }

    if (_locationController.text.trim().isNotEmpty &&
        !isValidCommunityLink(_locationLinkController.text)) {
      showTopAlert(context, 'Enter a valid location link', isError: true);
      return;
    }

    setState(() => _creating = true);

    try {
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();
      final accountId = (userDoc.data()?['userId'] ?? '').toString();

      final result = await CommunityService.createCommunity(
        name: name,
        type: _type,
        collegeName: _collegeController.text,
        vision: _visionController.text,
        mission: _missionController.text,
        location: _locationController.text,
        locationLink: normalizeCommunityLink(_locationLinkController.text),
        logoUrl: _logoUrl ?? '',
        coverUrl: _type == 'college' ? _coverUrl : '',
        ownerUid: user.uid,
        ownerAccountId: accountId,
      );

      if (!mounted) return;
      Navigator.of(context).pop(result);
      showTopAlert(context, '"$name" created');
    } catch (e) {
      debugPrint('Create community error: $e');
      if (!mounted) return;
      setState(() => _creating = false);
      showTopAlert(context, 'Failed to create community.', isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1B120A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 680),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Create Community',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 18),

              // -------- Logo --------
              Center(
                child: GestureDetector(
                  onTap: _uploadingImage ? null : _pickLogo,
                  child: Stack(
                    children: [
                      Container(
                        width: 90,
                        height: 90,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFF2A1B0E),
                          border: Border.all(
                            color: const Color(0xFFD2B48C),
                            width: 2,
                          ),
                        ),
                        child: _uploadingImage
                            ? const Center(
                                child: SizedBox(
                                  width: 26,
                                  height: 26,
                                  child: CircularProgressIndicator(
                                    color: Color(0xFFD2B48C),
                                    strokeWidth: 2.4,
                                  ),
                                ),
                              )
                            : (_logoUrl != null && _logoUrl!.isNotEmpty)
                                ? ClipOval(
                                    child: Image.network(
                                      _logoUrl!,
                                      width: 90,
                                      height: 90,
                                      fit: BoxFit.cover,
                                    ),
                                  )
                                : const Icon(
                                    Icons.public_rounded,
                                    color: Color(0xFFD2B48C),
                                    size: 34,
                                  ),
                      ),
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: Container(
                          width: 26,
                          height: 26,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: AppColors.goldGradient,
                          ),
                          child: const Icon(
                            Icons.camera_alt_rounded,
                            size: 14,
                            color: Color(0xFF1B120A),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 18),

              // -------- Name --------
              _Label('Community Name'),
              const SizedBox(height: 6),
              _TextField(
                controller: _nameController,
                hint: 'e.g. Coding Club Community',
              ),

              if (_idPreview.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  _idPreview,
                  style: const TextStyle(
                    color: Color(0xFFFFE9B0),
                    fontWeight: FontWeight.w600,
                    fontSize: 12.5,
                  ),
                ),
              ],

              const SizedBox(height: 16),

              // -------- Type: Normal / College --------
              _Label('Community Type'),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _TypeChip(
                      label: 'Normal',
                      icon: Icons.groups_rounded,
                      selected: _type == 'normal',
                      onTap: () => setState(() => _type = 'normal'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _TypeChip(
                      label: 'College',
                      icon: Icons.school_rounded,
                      selected: _type == 'college',
                      onTap: () => setState(() => _type = 'college'),
                    ),
                  ),
                ],
              ),

              if (_type == 'college') ...[
                const SizedBox(height: 16),
                _Label('College / Institution Name'),
                const SizedBox(height: 6),
                _TextField(
                  controller: _collegeController,
                  hint: 'e.g. Anna University',
                ),
                const SizedBox(height: 16),
                _Label('College Cover Image (optional)'),
                const SizedBox(height: 6),
                GestureDetector(
                  onTap: _uploadingCover ? null : _pickCover,
                  child: Container(
                    height: 130,
                    decoration: BoxDecoration(
                      color: const Color(0xFF2A1B0E),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: const Color(0xFFD2B48C).withValues(alpha: .6),
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: _uploadingCover
                        ? const Center(
                            child: SizedBox(
                              width: 26,
                              height: 26,
                              child: CircularProgressIndicator(
                                color: Color(0xFFD2B48C),
                                strokeWidth: 2.4,
                              ),
                            ),
                          )
                        : _coverUrl.isNotEmpty
                            ? Image.network(
                                _coverUrl,
                                width: double.infinity,
                                height: 130,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => const SizedBox(),
                              )
                            : const Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.add_photo_alternate_outlined,
                                      color: Color(0xFFD2B48C), size: 30),
                                  SizedBox(height: 6),
                                  Text(
                                    'Tap to add a cover image',
                                    style: TextStyle(
                                        color: Colors.white54, fontSize: 12),
                                  ),
                                ],
                              ),
                  ),
                ),
                if (_coverUrl.isNotEmpty)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: _uploadingCover
                          ? null
                          : () => setState(() => _coverUrl = ''),
                      child: const Text('Remove cover image',
                          style:
                              TextStyle(color: Colors.white54, fontSize: 12)),
                    ),
                  ),
              ],

              const SizedBox(height: 16),

              _Label('Vision (optional)'),
              const SizedBox(height: 6),
              _TextField(
                controller: _visionController,
                hint: 'Where do you want this community to go?',
                maxLines: 3,
              ),

              const SizedBox(height: 16),

              _Label('Mission (optional)'),
              const SizedBox(height: 6),
              _TextField(
                controller: _missionController,
                hint: 'What will this community do to get there?',
                maxLines: 3,
              ),

              const SizedBox(height: 16),

              _Label('Location (optional)'),
              const SizedBox(height: 6),
              _TextField(
                controller: _locationController,
                hint: 'e.g. Coimbatore, Tamil Nadu',
                maxLines: 2,
              ),

              if (_locationController.text.trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                _Label('Location Link (optional)'),
                const SizedBox(height: 6),
                _TextField(
                  controller: _locationLinkController,
                  hint: 'Paste a Google Maps link',
                ),
              ],

              const SizedBox(height: 22),

              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _creating
                          ? null
                          : () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        side: const BorderSide(color: Color(0xFFD2B48C)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: const Text(
                        'Cancel',
                        style: TextStyle(color: Color(0xFFFFE9B0)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: AppColors.goldGradient,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: _creating ? null : _create,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            child: Center(
                              child: _creating
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.2,
                                        color: Color(0xFF1B120A),
                                      ),
                                    )
                                  : const Text(
                                      'Create',
                                      style: TextStyle(
                                        color: Color(0xFF1B120A),
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: Colors.white70,
        fontSize: 12.5,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

class _TextField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final int maxLines;

  const _TextField({
    required this.controller,
    required this.hint,
    this.maxLines = 1,
  });

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
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

class _TypeChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _TypeChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          gradient: selected ? AppColors.goldGradient : null,
          color: selected ? null : const Color(0xFF2A1B0E),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: const Color(0xFFD2B48C).withValues(alpha: selected ? 1 : .4),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 20,
              color: selected ? const Color(0xFF1B120A) : const Color(0xFFFFE9B0),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: selected ? const Color(0xFF1B120A) : Colors.white70,
                fontWeight: FontWeight.w700,
                fontSize: 12.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}