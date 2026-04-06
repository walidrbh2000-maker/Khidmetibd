// lib/services/cloudinary_service.dart
//
// SECURITY FIX (Warning): _isImageExtension() only checked file extension.
// An attacker could rename malware.php to image.jpg and bypass this check.
//
// Fix: _isValidImageMagicBytes() reads the first 8 bytes of every file to
// verify it is actually a JPEG or PNG before uploading. Extension check is
// kept as a fast first-pass; magic bytes are the authoritative check.
//
// Supported signatures:
//   JPEG  FF D8 FF
//   PNG   89 50 4E 47 0D 0A 1A 0A
//   GIF   47 49 46 38
//   WebP  52 49 46 46 (RIFF header; additional 'WEBP' check at offset 8)
//   BMP   42 4D

import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:cloudinary/cloudinary.dart';
import 'package:path/path.dart' as path;

class CloudinaryServiceException implements Exception {
  final String message;
  final String? code;
  final dynamic originalError;

  CloudinaryServiceException(
    this.message, {
    this.code,
    this.originalError,
  });

  @override
  String toString() =>
      'CloudinaryServiceException: $message${code != null ? ' (Code: $code)' : ''}';
}

class CloudinaryService {
  static const int maxImageSizeMB = 10;
  static const int maxVideoSizeMB = 100;
  static const int maxAudioSizeMB = 50;
  static const Duration uploadTimeout = Duration(minutes: 5);
  static const int defaultImageQuality = 80;
  static const int defaultImageMaxWidth = 1920;
  static const int defaultImageMaxHeight = 1080;

  final String cloudName;
  final String uploadPreset;

  late final Cloudinary _cloudinary;

  CloudinaryService({
    required this.cloudName,
    required this.uploadPreset,
  }) {
    _validateCredentials();
    _initializeCloudinary();
  }

  void _validateCredentials() {
    if (cloudName.trim().isEmpty) {
      throw CloudinaryServiceException(
        'Cloud name cannot be empty',
        code: 'INVALID_CREDENTIALS',
      );
    }
    if (uploadPreset.trim().isEmpty) {
      throw CloudinaryServiceException(
        'Upload preset cannot be empty',
        code: 'INVALID_CREDENTIALS',
      );
    }
  }

  void _initializeCloudinary() {
    _cloudinary = Cloudinary.unsignedConfig(cloudName: cloudName);
    _logInfo('Cloudinary initialized (unsigned) for cloud: $cloudName');
  }

  Future<String> uploadFile(
    File file, {
    CloudinaryResourceType resourceType = CloudinaryResourceType.auto,
    String? folder,
    Map<String, dynamic>? transformations,
  }) async {
    try {
      await _validateFile(file, resourceType);

      final fileName = _generateFileName(file);
      final uploadFolder = folder ?? _getDefaultFolder(resourceType);

      _logInfo('Uploading file: $fileName to folder: $uploadFolder');

      final response = await _cloudinary
          .upload(
            file: file.path,
            resourceType: resourceType,
            folder: uploadFolder,
            fileName: fileName,
            optParams: {
              'upload_preset': uploadPreset,
              if (transformations != null) ...transformations,
            },
          )
          .timeout(
            uploadTimeout,
            onTimeout: () => throw CloudinaryServiceException(
              'Upload timeout after ${uploadTimeout.inMinutes} minutes',
              code: 'UPLOAD_TIMEOUT',
            ),
          );

      if (response.isSuccessful && response.secureUrl != null) {
        _logInfo('Upload successful: ${response.secureUrl}');
        return response.secureUrl!;
      }

      throw CloudinaryServiceException(
        'Upload failed: ${response.error ?? "Unknown error"}',
        code: 'UPLOAD_FAILED',
        originalError: response.error,
      );
    } catch (e) {
      _logError('uploadFile', e);
      if (e is CloudinaryServiceException) rethrow;
      throw CloudinaryServiceException(
        'Error uploading file to Cloudinary',
        code: 'UPLOAD_ERROR',
        originalError: e,
      );
    }
  }

  Future<String> uploadImage(
    File file, {
    String? folder,
    int? maxWidth,
    int? maxHeight,
    int? quality,
  }) async {
    final transformations = <String, dynamic>{
      'quality': quality ?? defaultImageQuality,
      'fetch_format': 'auto',
    };

    if (maxWidth != null || maxHeight != null) {
      transformations['transformation'] = [
        {
          'width': maxWidth ?? defaultImageMaxWidth,
          'height': maxHeight ?? defaultImageMaxHeight,
          'crop': 'limit',
        }
      ];
    }

    return uploadFile(
      file,
      resourceType: CloudinaryResourceType.image,
      folder: folder ?? 'images',
      transformations: transformations,
    );
  }

  Future<String> uploadVideo(
    File file, {
    String? folder,
    int? maxDurationSeconds,
  }) async {
    final transformations = <String, dynamic>{
      'resource_type': 'video',
      'format': 'mp4',
    };

    if (maxDurationSeconds != null) {
      transformations['duration'] = maxDurationSeconds;
    }

    return uploadFile(
      file,
      resourceType: CloudinaryResourceType.video,
      folder: folder ?? 'videos',
      transformations: transformations,
    );
  }

  Future<String> uploadAudio(File file, {String? folder}) async {
    return uploadFile(
      file,
      resourceType: CloudinaryResourceType.auto,
      folder: folder ?? 'audios',
    );
  }

  /// File deletion requires signed authentication and must be performed
  /// server-side. Call your backend endpoint or Cloud Function.
  Future<bool> deleteFile(String publicId) async {
    if (publicId.trim().isEmpty) {
      throw CloudinaryServiceException(
        'Public ID cannot be empty',
        code: 'INVALID_PUBLIC_ID',
      );
    }

    _logWarning(
      'deleteFile: server-side only — call your Cloud Function or backend '
      'endpoint to delete "$publicId".',
    );
    return false;
  }

  String getOptimizedImageUrl(
    String publicId, {
    int? width,
    int? height,
    String crop = 'fill',
    int quality = 80,
    String format = 'auto',
  }) {
    if (publicId.trim().isEmpty) {
      throw CloudinaryServiceException(
        'Public ID cannot be empty',
        code: 'INVALID_PUBLIC_ID',
      );
    }

    final transformations = <String>[];

    if (width != null || height != null) {
      final w = width != null ? 'w_$width' : '';
      final h = height != null ? 'h_$height' : '';
      final c = 'c_$crop';
      transformations.add([w, h, c].where((s) => s.isNotEmpty).join(','));
    }

    transformations.add('q_$quality');
    transformations.add('f_$format');

    final transformationString = transformations.join('/');
    return 'https://res.cloudinary.com/$cloudName/image/upload/$transformationString/$publicId';
  }

  String getVideoUrl(
    String publicId, {
    int? width,
    int? height,
    String format = 'mp4',
  }) {
    if (publicId.trim().isEmpty) {
      throw CloudinaryServiceException(
        'Public ID cannot be empty',
        code: 'INVALID_PUBLIC_ID',
      );
    }

    final transformations = <String>[];

    if (width != null || height != null) {
      final w = width != null ? 'w_$width' : '';
      final h = height != null ? 'h_$height' : '';
      const c = 'c_fit';
      transformations.add([w, h, c].where((s) => s.isNotEmpty).join(','));
    }

    final transformationString =
        transformations.isEmpty ? '' : '${transformations.join('/')}/';

    return 'https://res.cloudinary.com/$cloudName/video/upload/$transformationString$publicId.$format';
  }

  // =========================================================================
  // VALIDATION (with magic bytes check)
  // =========================================================================

  Future<void> _validateFile(
    File file,
    CloudinaryResourceType resourceType,
  ) async {
    if (!await file.exists()) {
      throw CloudinaryServiceException(
        'File does not exist: ${file.path}',
        code: 'FILE_NOT_FOUND',
      );
    }

    final fileSize = await file.length();
    final fileSizeMB = fileSize / (1024 * 1024);

    int maxSizeMB;
    String fileType;
    bool isImageType = false;

    switch (resourceType) {
      case CloudinaryResourceType.image:
        maxSizeMB = maxImageSizeMB;
        fileType = 'Image';
        isImageType = true;
        break;
      case CloudinaryResourceType.video:
        maxSizeMB = maxVideoSizeMB;
        fileType = 'Video';
        break;
      case CloudinaryResourceType.auto:
        final extension = path.extension(file.path).toLowerCase();
        if (_isImageExtension(extension)) {
          maxSizeMB = maxImageSizeMB;
          fileType = 'Image';
          isImageType = true;
        } else if (_isVideoExtension(extension)) {
          maxSizeMB = maxVideoSizeMB;
          fileType = 'Video';
        } else if (_isAudioExtension(extension)) {
          maxSizeMB = maxAudioSizeMB;
          fileType = 'Audio';
        } else {
          maxSizeMB = maxImageSizeMB;
          fileType = 'File';
        }
        break;
      default:
        maxSizeMB = maxImageSizeMB;
        fileType = 'File';
    }

    if (fileSizeMB > maxSizeMB) {
      throw CloudinaryServiceException(
        '$fileType file too large: ${fileSizeMB.toStringAsFixed(2)}MB (max: ${maxSizeMB}MB)',
        code: 'FILE_TOO_LARGE',
      );
    }

    if (fileSize == 0) {
      throw CloudinaryServiceException('File is empty', code: 'EMPTY_FILE');
    }

    // SECURITY FIX: magic bytes validation for image uploads.
    // Extension-only checks can be bypassed by renaming malware.php → image.jpg.
    // Reading the actual file header (magic bytes) is the authoritative check.
    if (isImageType) {
      final valid = await _isValidImageMagicBytes(file);
      if (!valid) {
        throw CloudinaryServiceException(
          'File content does not match an allowed image format. '
          'Only JPEG, PNG, GIF, WebP, and BMP are permitted.',
          code: 'INVALID_IMAGE_CONTENT',
        );
      }
    }
  }

  /// SECURITY FIX: validates image files by reading their magic bytes (file
  /// header) rather than trusting the file extension alone.
  ///
  /// Supported formats and their signatures:
  ///   JPEG   FF D8 FF
  ///   PNG    89 50 4E 47 0D 0A 1A 0A
  ///   GIF    47 49 46 38  (GIF8)
  ///   WebP   52 49 46 46 ?? ?? ?? ?? 57 45 42 50  (RIFF....WEBP)
  ///   BMP    42 4D
  Future<bool> _isValidImageMagicBytes(File file) async {
    try {
      // Read enough bytes for the longest signature (WebP needs 12 bytes).
      const int headerLength = 12;
      final List<int> bytes = await file
          .openRead(0, headerLength)
          .expand((chunk) => chunk)
          .take(headerLength)
          .toList();

      if (bytes.length < 3) return false;

      // JPEG: FF D8 FF
      if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
        return true;
      }

      // PNG: 89 50 4E 47 0D 0A 1A 0A
      if (bytes.length >= 8 &&
          bytes[0] == 0x89 && bytes[1] == 0x50 &&
          bytes[2] == 0x4E && bytes[3] == 0x47 &&
          bytes[4] == 0x0D && bytes[5] == 0x0A &&
          bytes[6] == 0x1A && bytes[7] == 0x0A) {
        return true;
      }

      // GIF: 47 49 46 38 (GIF8)
      if (bytes.length >= 4 &&
          bytes[0] == 0x47 && bytes[1] == 0x49 &&
          bytes[2] == 0x46 && bytes[3] == 0x38) {
        return true;
      }

      // WebP: RIFF (52 49 46 46) at offset 0, WEBP (57 45 42 50) at offset 8
      if (bytes.length >= 12 &&
          bytes[0] == 0x52 && bytes[1] == 0x49 &&
          bytes[2] == 0x46 && bytes[3] == 0x46 &&
          bytes[8] == 0x57 && bytes[9] == 0x45 &&
          bytes[10] == 0x42 && bytes[11] == 0x50) {
        return true;
      }

      // BMP: 42 4D
      if (bytes.length >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4D) {
        return true;
      }

      _logWarning(
        '_isValidImageMagicBytes: unrecognized file header in ${file.path}. '
        'First bytes: ${bytes.take(4).map((b) => b.toRadixString(16).padLeft(2, "0")).join(" ")}',
      );
      return false;
    } catch (e) {
      _logError('_isValidImageMagicBytes', e);
      // Fail closed: if we cannot read the file, treat it as invalid.
      return false;
    }
  }

  String _generateFileName(File file) {
    final originalName = path.basenameWithoutExtension(file.path);
    final extension = path.extension(file.path);
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return '${originalName}_$timestamp$extension';
  }

  String _getDefaultFolder(CloudinaryResourceType resourceType) {
    switch (resourceType) {
      case CloudinaryResourceType.image:
        return 'images';
      case CloudinaryResourceType.video:
        return 'videos';
      case CloudinaryResourceType.auto:
        return 'uploads';
      default:
        return 'uploads';
    }
  }

  bool _isImageExtension(String extension) {
    const imageExtensions = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp'];
    return imageExtensions.contains(extension);
  }

  bool _isVideoExtension(String extension) {
    const videoExtensions = ['.mp4', '.mov', '.avi', '.mkv', '.webm'];
    return videoExtensions.contains(extension);
  }

  bool _isAudioExtension(String extension) {
    const audioExtensions = ['.mp3', '.m4a', '.wav', '.aac', '.ogg'];
    return audioExtensions.contains(extension);
  }

  void _logInfo(String message) {
    if (kDebugMode) debugPrint('[CloudinaryService] INFO: $message');
  }

  void _logWarning(String message) {
    if (kDebugMode) debugPrint('[CloudinaryService] WARNING: $message');
  }

  void _logError(String method, dynamic error) {
    if (kDebugMode) debugPrint('[CloudinaryService] ERROR in $method: $error');
  }
}
