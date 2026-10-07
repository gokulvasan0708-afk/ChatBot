import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'community_resource_card.dart';
import '../services/community_media_service.dart';
import '../services/community_resource_service.dart';
import '../widgets/community_widgets.dart';
import '../widgets/top_alert.dart';

// ================================================================
// UPLOAD RESOURCE SHEET  (Community Resources -- Section 8)
// ----------------------------------------------------------------
// Title, description, category, tags and one file. Everything that
// can be validated is checked BEFORE the upload starts; if the
// upload or save fails nothing is written and the sheet stays open
// with the entered data so the user can retry.
// ================================================================
class UploadResourceSheet extends StatefulWidget {
  final String communityDocId;
  final String initialCategory;

  const UploadResourceSheet({
    super.key,
    required this.communityDocId,
    this.initialCategory = '',
  });

  @override
  State<UploadResourceSheet> createState() => _UploadResourceSheetState();
}

class _UploadResourceSheetState extends State<UploadResourceSheet> {
  final TextEditingController _title = TextEditingController();
  final TextEditingController _description = TextEditingController();
  final TextEditingController _tags = TextEditingController();

  String _category = '';
  String? _filePath;
  String _fileName = '';
  int _fileSize = 0;

  bool _uploading = false;
  String _status = '';

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
    _title.dispose();
    _description.dispose();
    _tags.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.any,
        allowMultiple: false,
        withData: false,
      );
      if (files.isEmpty || !mounted) return;

      final path = files.first.path;
      if (path == null || path.isEmpty) {
        showTopAlert(context, 'Unable to access the selected file.',
            isError: true);
        return;
      }

      final ext = CommunityMediaService.extensionOf(path);
      if (CommunityResourceService.blockedExtensions.contains(ext)) {
        showTopAlert(context, '.$ext files can\'t be uploaded to the library.',
            isError: true);
        return;
      }

      final name = CommunityMediaService.fileNameOf(path);

      // Read the size from the file itself: PlatformFile's size getter
      // differs between file_picker versions.
      var size = 0;
      try {
        size = await File(path).length();
      } catch (_) {
        size = 0;
      }
      if (!mounted) return;

      setState(() {
        _filePath = path;
        _fileName = name;
        _fileSize = size;
        if (_title.text.trim().isEmpty) {
          // Friendly default title: file name without its extension.
          final dot = name.lastIndexOf('.');
          _title.text = dot > 0 ? name.substring(0, dot) : name;
        }
      });
    } catch (_) {
      if (!mounted) return;
      showTopAlert(context, 'Couldn\'t open your files.', isError: true);
    }
  }

  Future<void> _submit() async {
    if (_uploading) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    setState(() {
      _uploading = true;
      _status = 'Preparing…';
    });

    try {
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();
      final userData = userDoc.data() ?? {};

      await CommunityResourceService.uploadResource(
        communityDocId: widget.communityDocId,
        uploaderUid: user.uid,
        uploaderName: (userData['publicName'] ?? 'Member').toString(),
        uploaderAvatarUrl: (userData['publicImage'] ?? '').toString(),
        title: _title.text,
        description: _description.text,
        category: _category,
        tags: CommunityResourceService.parseTags(_tags.text),
        filePath: _filePath ?? '',
        onStatus: (s) {
          if (mounted) setState(() => _status = s);
        },
      );

      if (!mounted) return;
      Navigator.of(context).pop(true);
      showTopAlert(context, 'Resource uploaded');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _status = '';
      });
      showTopAlert(context, e.toString().replaceFirst('Exception: ', ''),
          isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.of(context).viewInsets.bottom;
    final sizeLabel = CommunityResourceService.formatBytes(_fileSize);

    return Padding(
      padding: EdgeInsets.only(bottom: inset),
      child: CommunitySheetShell(
        title: 'Upload resource',
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ---- File ----
              OutlinedButton.icon(
                onPressed: _uploading ? null : _pickFile,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: BorderSide(
                      color: CommunityColors.tan.withValues(alpha: .4)),
                  minimumSize: const Size.fromHeight(54),
                  alignment: Alignment.centerLeft,
                ),
                icon: Icon(
                  _filePath == null
                      ? Icons.upload_file_rounded
                      : CommunityResourceCard.iconForExt(
                          CommunityMediaService.extensionOf(_fileName)),
                  color: CommunityColors.tan,
                ),
                label: Text(
                  _filePath == null
                      ? 'Choose a file (PDF, DOC, PPT, ZIP, images…)'
                      : (sizeLabel.isEmpty
                          ? _fileName
                          : '$_fileName · $sizeLabel'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(height: 14),

              // ---- Title ----
              TextField(
                controller: _title,
                enabled: !_uploading,
                maxLength: CommunityResourceService.maxTitleLength,
                style: const TextStyle(color: Colors.white),
                decoration: communityInputDecoration(
                    'e.g. Data Structures – Unit 2 Notes',
                    label: 'Title'),
              ),
              const SizedBox(height: 4),

              // ---- Category ----
              const Text('Category',
                  style: TextStyle(
                      color: CommunityColors.tan,
                      fontWeight: FontWeight.w600,
                      fontSize: 13)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final c in CommunityResourceService.categories)
                    ChoiceChip(
                      avatar: Icon(CommunityResourceCard.iconForCategory(c),
                          size: 16,
                          color: _category == c
                              ? Colors.black
                              : CommunityColors.tan),
                      label: Text(
                          CommunityResourceService.categoryShortLabels[c] ??
                              c),
                      selected: _category == c,
                      onSelected:
                          _uploading ? null : (_) => setState(() => _category = c),
                      selectedColor: CommunityColors.tan,
                      backgroundColor: const Color(0xFF18181F),
                      labelStyle: TextStyle(
                        color: _category == c ? Colors.black : Colors.white70,
                        fontSize: 12.5,
                      ),
                      side: BorderSide(
                          color: CommunityColors.tan.withValues(alpha: .3)),
                    ),
                ],
              ),
              const SizedBox(height: 16),

              // ---- Description ----
              TextField(
                controller: _description,
                enabled: !_uploading,
                maxLines: 4,
                minLines: 2,
                maxLength: CommunityResourceService.maxDescriptionLength,
                style: const TextStyle(color: Colors.white),
                decoration: communityInputDecoration(
                    'What is this and who is it useful for? (optional)',
                    label: 'Description'),
              ),
              const SizedBox(height: 4),

              // ---- Tags ----
              TextField(
                controller: _tags,
                enabled: !_uploading,
                style: const TextStyle(color: Colors.white),
                decoration: communityInputDecoration(
                    'dsa, 2nd year, semester 3 (comma separated)',
                    label: 'Tags (optional)'),
              ),
              const SizedBox(height: 18),

              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: _uploading ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: CommunityColors.tan,
                    foregroundColor: Colors.black,
                    disabledBackgroundColor: Colors.white12,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                  child: _uploading
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
                      : const Text('Upload',
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