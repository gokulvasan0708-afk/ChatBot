import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class VoiceUploadResult {
  final String secureUrl;
  final String publicId;

  const VoiceUploadResult({
    required this.secureUrl,
    required this.publicId,
  });
}

class VoiceMessageService {
  VoiceMessageService._();

  static final VoiceMessageService instance = VoiceMessageService._();

  static const String cloudinaryCloudName =
      String.fromEnvironment('CLOUDINARY_CLOUD_NAME');
  static const String cloudinaryUploadPreset =
      String.fromEnvironment('CLOUDINARY_UPLOAD_PRESET');
  static const String backendBaseUrl =
      String.fromEnvironment('VOICE_BACKEND_URL');

  Future<Directory> _voiceDirectory() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/voice_messages');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<String> localPathFor(String messageId) async {
    final dir = await _voiceDirectory();
    return '${dir.path}/$messageId.m4a';
  }

  Future<bool> localFileExists(String messageId) async {
    try {
      final file = File(await localPathFor(messageId));
      return await file.exists() && await file.length() > 0;
    } catch (_) {
      return false;
    }
  }

  Future<void> deleteLocal(String messageId) async {
    try {
      final file = File(await localPathFor(messageId));
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  Future<void> copyRecordingToPermanent({
    required String recordingPath,
    required String messageId,
  }) async {
    final source = File(recordingPath);
    if (!await source.exists()) {
      throw StateError('Recording file does not exist.');
    }

    final destination = File(await localPathFor(messageId));
    await source.copy(destination.path);
  }

  Future<VoiceUploadResult> uploadToCloudinary(String recordingPath) async {
    if (cloudinaryCloudName.isEmpty || cloudinaryUploadPreset.isEmpty) {
      throw StateError(
        'Cloudinary is not configured. Add CLOUDINARY_CLOUD_NAME and CLOUDINARY_UPLOAD_PRESET.',
      );
    }

    final request = http.MultipartRequest(
      'POST',
      Uri.parse(
        'https://api.cloudinary.com/v1_1/$cloudinaryCloudName/video/upload',
      ),
    );

    request.fields['upload_preset'] = cloudinaryUploadPreset;
    request.files.add(
      await http.MultipartFile.fromPath(
        'file',
        recordingPath,
        filename: 'voice_${DateTime.now().millisecondsSinceEpoch}.m4a',
      ),
    );

    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        'Cloudinary upload failed (${response.statusCode}): ${response.body}',
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw StateError('Invalid Cloudinary response.');
    }

    final secureUrl = (decoded['secure_url'] ?? '').toString().trim();
    final publicId = (decoded['public_id'] ?? '').toString().trim();

    if (secureUrl.isEmpty || publicId.isEmpty) {
      throw StateError('Cloudinary did not return secure_url/public_id.');
    }

    return VoiceUploadResult(
      secureUrl: secureUrl,
      publicId: publicId,
    );
  }

  Future<bool> downloadToLocal({
    required String messageId,
    required String audioUrl,
  }) async {
    final url = audioUrl.trim();
    if (url.isEmpty) return false;

    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return false;
      }

      final file = File(await localPathFor(messageId));
      await file.writeAsBytes(response.bodyBytes, flush: true);
      return await file.exists() && await file.length() > 0;
    } catch (_) {
      return false;
    }
  }

  Future<bool> deleteCloudinaryAsset({
    required String chatId,
    required String messageId,
    required String publicId,
  }) async {
    final base = backendBaseUrl.trim().replaceFirst(RegExp(r'/$'), '');
    if (base.isEmpty || publicId.trim().isEmpty) return false;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;

    try {
      final token = await user.getIdToken();
      final response = await http.post(
        Uri.parse('$base/api/cloudinary/delete-audio'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${token ?? ''}',
        },
        body: jsonEncode({
          'chatId': chatId,
          'messageId': messageId,
          'publicId': publicId,
        }),
      );

      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (_) {
      return false;
    }
  }
}
