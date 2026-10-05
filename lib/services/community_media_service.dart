import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

// ================================================================
// COMMUNITY MEDIA SERVICE
// ----------------------------------------------------------------
// One upload path for everything new in Community (feed images /
// videos, achievement certificates, resource documents).
//
// It reuses the SAME Cloudinary account + unsigned preset the chat
// screens already use for attachments (cloud 'hmae9acm', preset
// 'nexus_chat_media'), because that preset is already configured to
// accept image, video and raw files -- the profile-image preset is
// image-only and must not be used for videos or documents.
// No Firebase Storage dependency is introduced.
// ================================================================

class CommunityUploadResult {
  final String url;
  final String publicId;
  final String resourceType;
  final String fileName;
  final int sizeBytes;

  const CommunityUploadResult({
    required this.url,
    required this.publicId,
    required this.resourceType,
    required this.fileName,
    required this.sizeBytes,
  });
}

class CommunityMediaService {
  CommunityMediaService._();

  static const String _cloudName = 'hmae9acm';
  static const String _uploadPreset = 'nexus_chat_media';

  static const String kindImage = 'image';
  static const String kindVideo = 'video';
  static const String kindFile = 'file';

  static const int maxImageBytes = 15 * 1024 * 1024;
  static const int maxVideoBytes = 100 * 1024 * 1024;
  static const int maxFileBytes = 50 * 1024 * 1024;

  static String fileNameOf(String path) => path.split(RegExp(r'[\\/]')).last;

  static String extensionOf(String nameOrUrl) {
    final clean = nameOrUrl.split('?').first;
    final dot = clean.lastIndexOf('.');
    if (dot < 0 || dot == clean.length - 1) return '';
    return clean.substring(dot + 1).toLowerCase();
  }

  static String _resourceTypeFor(String kind) {
    switch (kind) {
      case kindImage:
        return 'image';
      case kindVideo:
        return 'video';
      default:
        return 'raw';
    }
  }

  static int _limitFor(String kind) {
    switch (kind) {
      case kindImage:
        return maxImageBytes;
      case kindVideo:
        return maxVideoBytes;
      default:
        return maxFileBytes;
    }
  }

  static String _mb(int bytes) => '${(bytes / (1024 * 1024)).round()} MB';

  /// Uploads [path] and returns its hosted URL. Throws an [Exception]
  /// with a user-presentable message on any failure (offline, too
  /// large, rejected, timeout) so callers can show it directly.
  static Future<CommunityUploadResult> upload({
    required String path,
    required String kind,
  }) async {
    final file = File(path);
    if (!await file.exists()) {
      throw Exception('The selected file could not be found.');
    }

    final size = await file.length();
    if (size <= 0) throw Exception('The selected file is empty.');

    final limit = _limitFor(kind);
    if (size > limit) {
      throw Exception('File is too large. Maximum size is ${_mb(limit)}.');
    }

    final resourceType = _resourceTypeFor(kind);
    final request = http.MultipartRequest(
      'POST',
      Uri.parse(
          'https://api.cloudinary.com/v1_1/$_cloudName/$resourceType/upload'),
    );
    request.fields['upload_preset'] = _uploadPreset;
    request.files.add(await http.MultipartFile.fromPath('file', path));

    try {
      final response = await request.send().timeout(const Duration(minutes: 6));
      final body = await response.stream.bytesToString();

      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint('Community media upload failed: $body');
        throw Exception('Upload failed. Please try again.');
      }

      final decoded = jsonDecode(body);
      if (decoded is! Map) throw Exception('Upload failed. Please try again.');

      final data = Map<String, dynamic>.from(decoded);
      final url = (data['secure_url'] ?? '').toString().trim();
      final publicId = (data['public_id'] ?? '').toString().trim();
      if (url.isEmpty) throw Exception('Upload failed. Please try again.');

      return CommunityUploadResult(
        url: url,
        publicId: publicId,
        resourceType: (data['resource_type'] ?? resourceType).toString(),
        fileName: fileNameOf(path),
        sizeBytes: size,
      );
    } on SocketException {
      throw Exception('No internet connection. Please try again.');
    } on TimeoutException {
      throw Exception('Upload timed out. Please try again.');
    } on http.ClientException {
      throw Exception('No internet connection. Please try again.');
    }
  }

  /// Poster frame for a Cloudinary-hosted video, so a video post can
  /// show a thumbnail without pulling in a video player package.
  static String videoThumbnailUrl(String videoUrl) {
    if (!videoUrl.contains('/video/upload/')) return '';
    final withFrame = videoUrl.replaceFirst('/video/upload/', '/video/upload/so_0/');
    final dot = withFrame.lastIndexOf('.');
    final slash = withFrame.lastIndexOf('/');
    if (dot > slash) return '${withFrame.substring(0, dot)}.jpg';
    return '$withFrame.jpg';
  }
}
