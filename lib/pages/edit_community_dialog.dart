import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import 'app_theme.dart';
import '../services/community_service.dart';
import '../widgets/community_about_section.dart';
import '../widgets/top_alert.dart';

// ================================================================
// EDIT COMMUNITY DIALOG
// ----------------------------------------------------------------
// Same fields as Create Community -- logo, name, type (Normal /
// College), college name, vision, mission and location -- pre-filled with the
// community's current values. The Community ID is shown but can't be
// changed. Opened from "Edit Community" in the community details sheet
// (Controller / Principal only). Pops with `true` once saved.
// ================================================================
class EditCommunityDialog extends StatefulWidget {
  final String communityDocId;
  final String communityId;
  final String name;
  final String type;
  final String collegeName;
  final String vision;
  final String mission;
  final String location;
  final String locationLink;
  final String logoUrl;
  final String coverUrl;

  const EditCommunityDialog({
    super.key,
    required this.communityDocId,
    required this.communityId,
    required this.name,
    required this.type,
    required this.collegeName,
    this.vision = '',
    this.mission = '',
    this.location = '',
    this.locationLink = '',
    required this.logoUrl,
    this.coverUrl = '',
  });

  @override
  State<EditCommunityDialog> createState() => _EditCommunityDialogState();
}

class _EditCommunityDialogState extends State<EditCommunityDialog> {
  static const String _cloudName = 'db4zevmud';
  static const String _uploadPreset = 'nexus_profile_images';

  final ImagePicker _imagePicker = ImagePicker();
  late final TextEditingController _nameController =
      TextEditingController(text: widget.name);
  late final TextEditingController _collegeController =
      TextEditingController(text: widget.collegeName);
  late final TextEditingController _visionController =
      TextEditingController(text: widget.vision);
  late final TextEditingController _missionController =
      TextEditingController(text: widget.mission);
  late final TextEditingController _locationController =
      TextEditingController(text: widget.location);
  late final TextEditingController _locationLinkController =
      TextEditingController(text: widget.locationLink);

  late String _logoUrl = widget.logoUrl;
  late String _coverUrl = widget.coverUrl;
  bool _uploadingCover = false;
  late String _type = widget.type == 'college' ? 'college' : 'normal';
  bool _uploadingImage = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    // The location link field only appears once a location is typed.
    _locationController.addListener(() => setState(() {}));
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

  Future<void> _save() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final name = _nameController.text.trim();
    if (name.isEmpty) {
      showTopAlert(context, 'Community name is required', isError: true);
      return;
    }
    if (_type == 'college' && _collegeController.text.trim().isEmpty) {
      showTopAlert(context, 'College / institution name is required',
          isError: true);
      return;
    }

    if (_locationController.text.trim().isNotEmpty &&
        !isValidCommunityLink(_locationLinkController.text)) {
      showTopAlert(context, 'Enter a valid location link', isError: true);
      return;
    }

    setState(() => _saving = true);
    try {
      await CommunityService.updateCommunity(
        communityDocId: widget.communityDocId,
        requesterUid: user.uid,
        name: name,
        type: _type,
        collegeName: _collegeController.text,
        vision: _visionController.text,
        mission: _missionController.text,
        location: _locationController.text,
        locationLink: normalizeCommunityLink(_locationLinkController.text),
        logoUrl: _logoUrl,
        coverUrl: _type == 'college' ? _coverUrl : '',
      );
      if (!mounted) return;
      final root = Navigator.of(context, rootNavigator: true).context;
      Navigator.of(context).pop(true);
      showTopAlert(root, 'Community updated');
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showTopAlert(context, e.toString().replaceFirst('Exception: ', ''),
          isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = _saving || _uploadingImage || _uploadingCover;
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
                'Edit Community',
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
                  onTap: busy ? null : _pickLogo,
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
                            : _logoUrl.isNotEmpty
                                ? ClipOval(
                                    child: Image.network(
                                      _logoUrl,
                                      width: 90,
                                      height: 90,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, _, _) => const Icon(
                                        Icons.public_rounded,
                                        color: Color(0xFFD2B48C),
                                        size: 34,
                                      ),
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
              if (_logoUrl.isNotEmpty)
                Center(
                  child: TextButton(
                    onPressed:
                        busy ? null : () => setState(() => _logoUrl = ''),
                    child: const Text('Remove logo',
                        style:
                            TextStyle(color: Colors.white54, fontSize: 12)),
                  ),
                ),

              const SizedBox(height: 12),

              // -------- Name --------
              const _EditLabel('Community Name'),
              const SizedBox(height: 6),
              _EditField(
                controller: _nameController,
                hint: 'e.g. Coding Club Community',
              ),
              if (widget.communityId.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  '${widget.communityId}  (ID can\'t be changed)',
                  style: const TextStyle(
                    color: Color(0xFFFFE9B0),
                    fontWeight: FontWeight.w600,
                    fontSize: 12.5,
                  ),
                ),
              ],

              const SizedBox(height: 16),

              // -------- Type: Normal / College --------
              const _EditLabel('Community Type'),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _EditTypeChip(
                      label: 'Normal',
                      icon: Icons.groups_rounded,
                      selected: _type == 'normal',
                      onTap: () => setState(() => _type = 'normal'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _EditTypeChip(
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
                const _EditLabel('College / Institution Name'),
                const SizedBox(height: 6),
                _EditField(
                  controller: _collegeController,
                  hint: 'e.g. Anna University',
                ),
                const SizedBox(height: 16),
                const _EditLabel('College Cover Image (optional)'),
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

              const _EditLabel('Vision (optional)'),
              const SizedBox(height: 6),
              _EditField(
                controller: _visionController,
                hint: 'Where do you want this community to go?',
                maxLines: 3,
              ),

              const SizedBox(height: 16),

              const _EditLabel('Mission (optional)'),
              const SizedBox(height: 6),
              _EditField(
                controller: _missionController,
                hint: 'What will this community do to get there?',
                maxLines: 3,
              ),

              const SizedBox(height: 16),

              const _EditLabel('Location (optional)'),
              const SizedBox(height: 6),
              _EditField(
                controller: _locationController,
                hint: 'e.g. Coimbatore, Tamil Nadu',
                maxLines: 2,
              ),

              if (_locationController.text.trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                const _EditLabel('Location Link (optional)'),
                const SizedBox(height: 6),
                _EditField(
                  controller: _locationLinkController,
                  hint: 'Paste a Google Maps link',
                ),
              ],

              const SizedBox(height: 22),

              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed:
                          _saving ? null : () => Navigator.of(context).pop(),
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
                          onTap: busy ? null : _save,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            child: Center(
                              child: _saving
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.2,
                                        color: Color(0xFF1B120A),
                                      ),
                                    )
                                  : const Text(
                                      'Save',
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

class _EditLabel extends StatelessWidget {
  final String text;
  const _EditLabel(this.text);

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

class _EditField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final int maxLines;

  const _EditField({
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

class _EditTypeChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _EditTypeChip({
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
