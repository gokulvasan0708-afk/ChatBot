import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import 'app_theme.dart';
import '../services/community_group_service.dart';
import '../widgets/top_alert.dart';

// ================================================================
// CREATE COMMUNITY GROUP DIALOG  (spec — Section 3)
// ----------------------------------------------------------------
// Same dialog shell + Cloudinary upload flow as CreateClubDialog,
// plus the one thing a Club doesn't need: 4 group types instead of
// 2 join modes, with a date+time picker that only appears for
// "Temporary" groups (their auto-archive expiry).
// ================================================================
class CreateCommunityGroupDialog extends StatefulWidget {
  final String communityDocId;

  const CreateCommunityGroupDialog({super.key, required this.communityDocId});

  @override
  State<CreateCommunityGroupDialog> createState() => _CreateCommunityGroupDialogState();
}

class _CreateCommunityGroupDialogState extends State<CreateCommunityGroupDialog> {
  static const String _cloudName = 'db4zevmud';
  static const String _uploadPreset = 'nexus_profile_images';

  final ImagePicker _imagePicker = ImagePicker();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();

  String? _imageUrl;
  bool _uploadingImage = false;
  bool _creating = false;
  String _type = 'public'; // 'public' | 'private' | 'approval' | 'temporary'

  DateTime? _expiryDate;
  TimeOfDay? _expiryTime;

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
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
        showTopAlert(context, 'Image upload failed.', isError: true);
        return;
      }

      final data = jsonDecode(responseBody);
      final imageUrl = (data['secure_url'] ?? '').toString();
      setState(() {
        _imageUrl = imageUrl;
        _uploadingImage = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _uploadingImage = false);
      showTopAlert(context, 'Image upload failed.', isError: true);
    }
  }

  Future<void> _pickExpiry() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _expiryDate ?? now.add(const Duration(days: 1)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 3650)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: _expiryTime ?? const TimeOfDay(hour: 23, minute: 59),
    );
    setState(() {
      _expiryDate = date;
      _expiryTime = time ?? _expiryTime ?? const TimeOfDay(hour: 23, minute: 59);
    });
  }

  DateTime? get _expiresAt {
    if (_expiryDate == null) return null;
    final t = _expiryTime ?? const TimeOfDay(hour: 23, minute: 59);
    return DateTime(_expiryDate!.year, _expiryDate!.month, _expiryDate!.day, t.hour, t.minute);
  }

  Future<void> _create() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final name = _nameController.text.trim();
    if (name.isEmpty) {
      showTopAlert(context, 'Group name is required', isError: true);
      return;
    }
    if (_type == 'temporary' && _expiresAt == null) {
      showTopAlert(context, 'Pick an expiry date for this temporary group', isError: true);
      return;
    }

    setState(() => _creating = true);
    try {
      await CommunityGroupService.createGroup(
        communityDocId: widget.communityDocId,
        name: name,
        description: _descriptionController.text,
        imageUrl: _imageUrl ?? '',
        groupType: _type,
        expiresAt: _type == 'temporary' ? _expiresAt : null,
        creatorUid: user.uid,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
      showTopAlert(context, '"$name" created');
    } catch (e) {
      debugPrint('Create community group error: $e');
      if (!mounted) return;
      setState(() => _creating = false);
      showTopAlert(context, e.toString().replaceFirst('Exception: ', ''), isError: true);
    }
  }

  String _formatExpiry() {
    if (_expiryDate == null) return 'Pick expiry date & time';
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final t = _expiryTime ?? const TimeOfDay(hour: 23, minute: 59);
    final h = t.hourOfPeriod == 0 ? 12 : t.hourOfPeriod;
    final m = t.minute.toString().padLeft(2, '0');
    final period = t.period == DayPeriod.am ? 'AM' : 'PM';
    return '${_expiryDate!.day} ${months[_expiryDate!.month - 1]} ${_expiryDate!.year}, $h:$m $period';
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF18181F),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 700),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Create Group',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 18),

              Center(
                child: GestureDetector(
                  onTap: _uploadingImage ? null : _pickImage,
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
                              width: 26, height: 26,
                              child: CircularProgressIndicator(
                                  color: Color(0xFFA78BFA), strokeWidth: 2.4),
                            ),
                          )
                        : (_imageUrl != null && _imageUrl!.isNotEmpty)
                            ? ClipOval(child: Image.network(_imageUrl!, fit: BoxFit.cover))
                            : const Icon(Icons.groups_rounded, color: Color(0xFFA78BFA), size: 34),
                  ),
                ),
              ),

              const SizedBox(height: 18),
              _Label('Group Name'),
              const SizedBox(height: 6),
              _TextField(controller: _nameController, hint: 'e.g. Placement Discussion'),

              const SizedBox(height: 14),
              _Label('Description'),
              const SizedBox(height: 6),
              _TextField(
                controller: _descriptionController,
                hint: 'What is this group for?',
                maxLines: 3,
              ),

              const SizedBox(height: 16),
              _Label('Group Type'),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _TypeChip(
                      label: 'Public',
                      icon: Icons.public_rounded,
                      selected: _type == 'public',
                      onTap: () => setState(() => _type = 'public'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _TypeChip(
                      label: 'Private',
                      icon: Icons.lock_rounded,
                      selected: _type == 'private',
                      onTap: () => setState(() => _type = 'private'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _TypeChip(
                      label: 'Approval',
                      icon: Icons.how_to_reg_rounded,
                      selected: _type == 'approval',
                      onTap: () => setState(() => _type = 'approval'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _TypeChip(
                      label: 'Temporary',
                      icon: Icons.hourglass_bottom_rounded,
                      selected: _type == 'temporary',
                      onTap: () => setState(() => _type = 'temporary'),
                    ),
                  ),
                ],
              ),

              if (_type == 'temporary') ...[
                const SizedBox(height: 14),
                _Label('Expires On'),
                const SizedBox(height: 6),
                GestureDetector(
                  onTap: _pickExpiry,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF20202A),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFA78BFA).withValues(alpha: .4)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.event_busy_rounded, size: 16, color: Color(0xFFA78BFA)),
                        const SizedBox(width: 8),
                        Text(_formatExpiry(),
                            style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
                      ],
                    ),
                  ),
                ),
              ],

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
                                      width: 18, height: 18,
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
  Widget build(BuildContext context) {
    return Text(text,
        style: const TextStyle(color: Colors.white70, fontSize: 12.5, fontWeight: FontWeight.w600));
  }
}

class _TextField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final int maxLines;

  const _TextField({required this.controller, required this.hint, this.maxLines = 1});

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
          border: Border.all(
            color: const Color(0xFFA78BFA).withValues(alpha: selected ? 1 : .4),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: selected ? const Color(0xFF18181F) : const Color(0xFFC4B5FD)),
            const SizedBox(height: 4),
            Text(
              label,
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