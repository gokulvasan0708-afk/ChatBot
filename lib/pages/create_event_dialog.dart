import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import 'app_theme.dart';
import '../services/event_service.dart';
import '../widgets/community_about_section.dart';
import '../widgets/show_to_all_colleges_toggle.dart';
import '../widgets/top_alert.dart';

// ================================================================
// CREATE EVENT DIALOG  (Community spec — Section 5)
// ----------------------------------------------------------------
// Same dialog shell + Cloudinary upload flow as CreateClubDialog /
// CreateCommunityDialog, extended with the fields an Event needs
// that a Club/Community don't: date + start/end time, an
// Online/Offline switch (location vs. an external link), and an
// optional participant cap.
// ================================================================
class CreateEventDialog extends StatefulWidget {
  final String communityDocId;

  const CreateEventDialog({super.key, required this.communityDocId});

  @override
  State<CreateEventDialog> createState() => _CreateEventDialogState();
}

class _CreateEventDialogState extends State<CreateEventDialog> {
  static const String _cloudName = 'db4zevmud';
  static const String _uploadPreset = 'nexus_profile_images';

  final ImagePicker _imagePicker = ImagePicker();
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();
  final TextEditingController _categoryController = TextEditingController();
  final TextEditingController _locationController = TextEditingController();
  final TextEditingController _linkController = TextEditingController();
  final TextEditingController _locationLinkController = TextEditingController();
  final TextEditingController _maxController = TextEditingController();

  String? _coverUrl;
  bool _uploadingImage = false;
  bool _creating = false;
  bool _isOnline = false;
  bool _showToAllColleges = false;

  DateTime? _date;
  TimeOfDay? _startTime;
  TimeOfDay? _endTime;

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _categoryController.dispose();
    _locationController.dispose();
    _linkController.dispose();
    _locationLinkController.dispose();
    _maxController.dispose();
    super.dispose();
  }

  // ==========================================================
  // COVER IMAGE UPLOAD -- identical Cloudinary flow used elsewhere.
  // ==========================================================

  Future<void> _pickCover() async {
    try {
      final image = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 80,
        maxWidth: 1200,
        maxHeight: 1200,
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
        showTopAlert(context, 'Cover image upload failed.', isError: true);
        return;
      }

      final data = jsonDecode(responseBody);
      final imageUrl = (data['secure_url'] ?? '').toString();
      setState(() {
        _coverUrl = imageUrl;
        _uploadingImage = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _uploadingImage = false);
      showTopAlert(context, 'Cover image upload failed.', isError: true);
    }
  }

  // ==========================================================
  // DATE / TIME PICKERS
  // ==========================================================

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date ?? now,
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: now.add(const Duration(days: 3650)),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _pickStartTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _startTime ?? TimeOfDay.now(),
    );
    if (picked != null) setState(() => _startTime = picked);
  }

  Future<void> _pickEndTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _endTime ?? (_startTime ?? TimeOfDay.now()),
    );
    if (picked != null) setState(() => _endTime = picked);
  }

  DateTime? _combine(DateTime? date, TimeOfDay? time) {
    if (date == null || time == null) return null;
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  // ==========================================================
  // CREATE
  // ==========================================================

  Future<void> _create() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final title = _titleController.text.trim();
    if (title.isEmpty) {
      showTopAlert(context, 'Event title is required', isError: true);
      return;
    }
    if (_date == null || _startTime == null || _endTime == null) {
      showTopAlert(context, 'Pick a date, start time and end time', isError: true);
      return;
    }
    if (_isOnline && _linkController.text.trim().isEmpty) {
      showTopAlert(context, 'Add an online link for this event', isError: true);
      return;
    }
    if (!_isOnline && _locationController.text.trim().isEmpty) {
      showTopAlert(context, 'Add a location for this event', isError: true);
      return;
    }

    if (!_isOnline && !isValidCommunityLink(_locationLinkController.text)) {
      showTopAlert(context, 'Enter a valid location link', isError: true);
      return;
    }

    final startAt = _combine(_date, _startTime)!;
    final endAt = _combine(_date, _endTime)!;
    if (!endAt.isAfter(startAt)) {
      showTopAlert(context, 'End time must be after start time', isError: true);
      return;
    }

    setState(() => _creating = true);

    try {
      final userDoc =
          await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
      final userData = userDoc.data() ?? {};

      await EventService.createEvent(
        communityDocId: widget.communityDocId,
        title: title,
        description: _descriptionController.text,
        coverImageUrl: _coverUrl ?? '',
        category: _categoryController.text,
        isOnline: _isOnline,
        location: _locationController.text,
        onlineLink: _linkController.text,
        startAt: startAt,
        endAt: endAt,
        maxParticipants: int.tryParse(_maxController.text.trim()) ?? 0,
        organizerUid: user.uid,
        organizerName: (userData['publicName'] ?? 'Member').toString(),
        organizerAvatarUrl: (userData['publicImage'] ?? '').toString(),
        showToAllColleges: _showToAllColleges,
        locationLink: normalizeCommunityLink(_locationLinkController.text),
      );

      if (!mounted) return;
      Navigator.of(context).pop(true);
      showTopAlert(context, '"$title" created');
    } catch (e) {
      debugPrint('Create event error: $e');
      if (!mounted) return;
      setState(() => _creating = false);
      showTopAlert(context, e.toString().replaceFirst('Exception: ', ''), isError: true);
    }
  }

  String _formatDate(DateTime? d) {
    if (d == null) return 'Pick date';
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }

  String _formatTime(TimeOfDay? t) {
    if (t == null) return '--:--';
    final h = t.hourOfPeriod == 0 ? 12 : t.hourOfPeriod;
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m ${t.period == DayPeriod.am ? 'AM' : 'PM'}';
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1B120A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 720),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Create Event',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 18),

              // Top option: also show this on other colleges' Notice Boards.
              ShowToAllCollegesToggle(
                communityDocId: widget.communityDocId,
                value: _showToAllColleges,
                onChanged: (v) => setState(() => _showToAllColleges = v),
              ),

              // -------- Cover image --------
              GestureDetector(
                onTap: _uploadingImage ? null : _pickCover,
                child: Container(
                  height: 110,
                  decoration: BoxDecoration(
                    color: const Color(0xFF2A1B0E),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: const Color(0xFFD2B48C).withValues(alpha: .4),
                    ),
                  ),
                  child: _uploadingImage
                      ? const Center(
                          child: SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              color: Color(0xFFD2B48C),
                              strokeWidth: 2.2,
                            ),
                          ),
                        )
                      : (_coverUrl != null && _coverUrl!.isNotEmpty)
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(14),
                              child: Image.network(
                                _coverUrl!,
                                fit: BoxFit.cover,
                                width: double.infinity,
                              ),
                            )
                          : const Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.image_rounded,
                                      color: Color(0xFFD2B48C), size: 26),
                                  SizedBox(height: 6),
                                  Text(
                                    'Add cover image (optional)',
                                    style: TextStyle(
                                        color: Colors.white54, fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                ),
              ),

              const SizedBox(height: 16),
              _Label('Event Title'),
              const SizedBox(height: 6),
              _TextField(controller: _titleController, hint: 'e.g. Hackathon 2026'),

              const SizedBox(height: 14),
              _Label('Description'),
              const SizedBox(height: 6),
              _TextField(
                controller: _descriptionController,
                hint: 'What is this event about?',
                maxLines: 3,
              ),

              const SizedBox(height: 14),
              _Label('Category'),
              const SizedBox(height: 6),
              _TextField(controller: _categoryController, hint: 'e.g. Workshop, Sports'),

              const SizedBox(height: 16),
              _Label('Date & Time'),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _PickerChip(
                      icon: Icons.calendar_month_rounded,
                      label: _formatDate(_date),
                      onTap: _pickDate,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _PickerChip(
                      icon: Icons.schedule_rounded,
                      label: 'Start ${_formatTime(_startTime)}',
                      onTap: _pickStartTime,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _PickerChip(
                      icon: Icons.schedule_rounded,
                      label: 'End ${_formatTime(_endTime)}',
                      onTap: _pickEndTime,
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 16),
              _Label('Mode'),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _TypeChip(
                      label: 'Offline',
                      icon: Icons.location_on_rounded,
                      selected: !_isOnline,
                      onTap: () => setState(() => _isOnline = false),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _TypeChip(
                      label: 'Online',
                      icon: Icons.videocam_rounded,
                      selected: _isOnline,
                      onTap: () => setState(() => _isOnline = true),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 14),
              if (_isOnline) ...[
                _Label('Online Link'),
                const SizedBox(height: 6),
                _TextField(controller: _linkController, hint: 'https://meet.example.com/...'),
              ] else ...[
                _Label('Location'),
                const SizedBox(height: 6),
                _TextField(controller: _locationController, hint: 'e.g. Main Auditorium'),
                const SizedBox(height: 12),
                _Label('Location Link (optional)'),
                const SizedBox(height: 6),
                _TextField(
                  controller: _locationLinkController,
                  hint: 'Paste a Google Maps link',
                ),
              ],

              const SizedBox(height: 14),
              _Label('Max Participants (optional)'),
              const SizedBox(height: 6),
              _TextField(
                controller: _maxController,
                hint: 'Leave blank for unlimited',
                keyboardType: TextInputType.number,
              ),

              const SizedBox(height: 22),

              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _creating ? null : () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        side: const BorderSide(color: Color(0xFFD2B48C)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: const Text('Cancel',
                          style: TextStyle(color: Color(0xFFFFE9B0))),
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
  final TextInputType? keyboardType;

  const _TextField({
    required this.controller,
    required this.hint,
    this.maxLines = 1,
    this.keyboardType,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      keyboardType: keyboardType,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white38),
        filled: true,
        fillColor: const Color(0xFF2A1B0E),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

class _PickerChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _PickerChip({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF2A1B0E),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFD2B48C).withValues(alpha: .4)),
        ),
        child: Row(
          children: [
            Icon(icon, size: 16, color: const Color(0xFFD2B48C)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(color: Colors.white70, fontSize: 12.5),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
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
            Icon(icon, size: 20, color: selected ? const Color(0xFF1B120A) : const Color(0xFFFFE9B0)),
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