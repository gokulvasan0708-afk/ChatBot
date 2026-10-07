import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import 'app_theme.dart';
import '../club/club_icons.dart';
import '../services/club_service.dart';
import '../widgets/top_alert.dart';

// ================================================================
// CREATE CLUB DIALOG
// ----------------------------------------------------------------
// Creates a STANDALONE club (Hubs > Clubs) -- or, when
// [communityDocId] is given, a COMMUNITY club that belongs to that
// community only (separate collections, see club_paths.dart). The Club ID is generated live while typing, with the
// same rule the Group ID uses: "@<name>-<first 4 of Account ID>".
// The creator automatically becomes the Club's first Leader
// (ClubService.createClub).
// ================================================================
class CreateClubDialog extends StatefulWidget {
  /// Non-null = create a COMMUNITY club: it is stored separately from the
  /// Hubs clubs and is only shown inside that community.
  final String? communityDocId;

  const CreateClubDialog({super.key, this.communityDocId});

  @override
  State<CreateClubDialog> createState() => _CreateClubDialogState();
}

class _CreateClubDialogState extends State<CreateClubDialog> {
  static const String _cloudName = 'db4zevmud';
  static const String _uploadPreset = 'nexus_profile_images';

  final ImagePicker _imagePicker = ImagePicker();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _categoryController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();

  String? _logoUrl;
  bool _uploadingImage = false;
  bool _creating = false;
  String _joinMode = 'open'; // 'open' | 'approval'

  String? _creatorAccountId; // full Account ID (users/{uid}.userId)
  String _clubIdPreview = '';

  @override
  void initState() {
    super.initState();
    _loadCreatorAccountId();
    _nameController.addListener(_updateClubIdPreview);
  }

  // Needed for the Club ID suffix -- same source the Group dialog uses.
  Future<void> _loadCreatorAccountId() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final accountId = await ClubService.loadAccountId(user.uid);
      if (!mounted) return;
      setState(() {
        _creatorAccountId = accountId;
        _clubIdPreview =
            ClubService.buildClubId(_nameController.text, accountId);
      });
    } catch (_) {
      // Leave _creatorAccountId null; _create() tells the user to retry.
    }
  }

  void _updateClubIdPreview() {
    setState(() {
      _clubIdPreview = ClubService.buildClubId(
        _nameController.text,
        _creatorAccountId ?? '',
      );
    });
  }

  @override
  void dispose() {
    _nameController.removeListener(_updateClubIdPreview);
    _nameController.dispose();
    _categoryController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _pickLogo() async {
    try {
      final image = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 80,
        maxWidth: 800,
        maxHeight: 800,
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
        showTopAlert(context, 'Logo upload failed.', isError: true);
        return;
      }

      final data = jsonDecode(responseBody);
      final imageUrl = (data['secure_url'] ?? '').toString();
      setState(() {
        _logoUrl = imageUrl;
        _uploadingImage = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _uploadingImage = false);
      showTopAlert(context, 'Logo upload failed.', isError: true);
    }
  }

  Future<void> _create() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final name = _nameController.text.trim();
    if (name.isEmpty) {
      showTopAlert(context, 'Club name is required', isError: true);
      return;
    }

    final accountId = _creatorAccountId;
    if (accountId == null || accountId.isEmpty) {
      showTopAlert(context, 'Still loading your account, try again in a moment.');
      return;
    }

    setState(() => _creating = true);
    try {
      final communityDocId = widget.communityDocId;
      final clubDocId = (communityDocId != null && communityDocId.isNotEmpty)
          ? await ClubService.createCommunityClub(
              communityDocId: communityDocId,
              name: name,
              category: _categoryController.text,
              description: _descriptionController.text,
              logoUrl: _logoUrl ?? '',
              joinMode: _joinMode,
              creatorUid: user.uid,
              creatorAccountId: accountId,
            )
          : await ClubService.createClub(
              name: name,
              category: _categoryController.text,
              description: _descriptionController.text,
              logoUrl: _logoUrl ?? '',
              joinMode: _joinMode,
              creatorUid: user.uid,
              creatorAccountId: accountId,
            );

      if (!mounted) return;
      // Alert first: it lives in the root overlay, and `context` is no
      // longer usable once the dialog has been popped.
      showTopAlert(context, '"$name" created');
      Navigator.of(context).pop(clubDocId);
    } catch (e) {
      if (!mounted) return;
      setState(() => _creating = false);
      final reason = e.toString().replaceFirst('Exception: ', '');
      showTopAlert(
        context,
        reason.contains('already exists') ? reason : 'Failed to create club.',
        isError: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF18181F),
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
                'Create Club',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 18),

              Center(
                child: GestureDetector(
                  onTap: _uploadingImage ? null : _pickLogo,
                  child: Container(
                    width: 90,
                    height: 90,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFF20202A),
                      border: Border.all(color: const Color(0xFFA78BFA), width: 2),
                    ),
                    child: _uploadingImage
                        ? const Center(
                            child: SizedBox(
                              width: 26,
                              height: 26,
                              child: CircularProgressIndicator(
                                  color: Color(0xFFA78BFA), strokeWidth: 2.4),
                            ),
                          )
                        : (_logoUrl != null && _logoUrl!.isNotEmpty)
                            ? ClipOval(
                                child: Image.network(_logoUrl!,
                                    width: 90, height: 90, fit: BoxFit.cover),
                              )
                            : const Icon(ClubIcons.club,
                                color: Color(0xFFA78BFA), size: 34),
                  ),
                ),
              ),
              const SizedBox(height: 18),

              _Label('Club Name'),
              const SizedBox(height: 6),
              _Field(controller: _nameController, hint: 'e.g. Coding Club'),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    const Icon(Icons.tag_rounded,
                        size: 15, color: Color(0xFFA78BFA)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _clubIdPreview.isEmpty
                            ? 'Club ID will appear here'
                            : _clubIdPreview,
                        style: TextStyle(
                          color: _clubIdPreview.isEmpty
                              ? Colors.white38
                              : const Color(0xFFC4B5FD),
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),

              _Label('Category'),
              const SizedBox(height: 6),
              _Field(controller: _categoryController, hint: 'e.g. Technology, Sports, Arts'),
              const SizedBox(height: 14),

              _Label('Description'),
              const SizedBox(height: 6),
              _Field(
                controller: _descriptionController,
                hint: 'What does this club do?',
                maxLines: 3,
              ),
              const SizedBox(height: 16),

              _Label('Join Method'),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _TypeChip(
                      label: 'Open',
                      icon: Icons.lock_open_rounded,
                      selected: _joinMode == 'open',
                      onTap: () => setState(() => _joinMode = 'open'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _TypeChip(
                      label: 'Request to Join',
                      icon: Icons.fact_check_rounded,
                      selected: _joinMode == 'approval',
                      onTap: () => setState(() => _joinMode = 'approval'),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 22),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _creating ? null : () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        side: const BorderSide(color: Color(0xFFA78BFA)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      child: const Text('Cancel', style: TextStyle(color: Color(0xFFC4B5FD))),
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
                                          strokeWidth: 2.2, color: Color(0xFF18181F)),
                                    )
                                  : const Text('Create',
                                      style: TextStyle(
                                          color: Color(0xFF18181F), fontWeight: FontWeight.bold)),
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
        fillColor: const Color(0xFF20202A),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
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
          color: selected ? null : const Color(0xFF20202A),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFA78BFA).withValues(alpha: selected ? 1 : .4)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: selected ? const Color(0xFF18181F) : const Color(0xFFC4B5FD)),
            const SizedBox(height: 4),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: selected ? const Color(0xFF18181F) : Colors.white70,
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
