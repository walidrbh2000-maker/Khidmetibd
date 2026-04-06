// lib/services/media_service.dart
//
// CHANGES:
//   • _formatBytes() private method removed — replaced with FileSizeFormatter.format()
//     from lib/utils/file_size_formatter.dart
//   • _logInfo / _logWarning / _logError replaced with AppLogger calls

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:video_compress/video_compress.dart';
import 'cloudinary_service.dart';
import '../utils/constants.dart';
import '../utils/file_size_formatter.dart'; // NEW
import '../utils/logger.dart';               // NEW (replaces private _log* methods)

class MediaServiceException implements Exception {
  final String  message;
  final String? code;
  final dynamic originalError;

  MediaServiceException(this.message, {this.code, this.originalError});

  @override
  String toString() =>
      'MediaServiceException: $message${code != null ? ' (Code: $code)' : ''}';
}

// ============================================================================
// ISOLATE HELPERS
// ============================================================================

class _CompressImageParams {
  final String inputPath;
  final String outputPath;
  final int    quality;
  final int    maxDimension;

  const _CompressImageParams({
    required this.inputPath,
    required this.outputPath,
    required this.quality,
    required this.maxDimension,
  });
}

Future<String> _compressImageIsolate(_CompressImageParams params) async {
  final bytes = await File(params.inputPath).readAsBytes();
  final image = img.decodeImage(bytes);
  if (image == null) {
    throw Exception('Could not decode image: ${params.inputPath}');
  }

  img.Image processed = image;
  if (image.width > params.maxDimension || image.height > params.maxDimension) {
    processed = img.copyResize(
      image,
      width:  image.width > image.height ? params.maxDimension : null,
      height: image.height >= image.width ? params.maxDimension : null,
    );
  }

  final compressed = img.encodeJpg(processed, quality: params.quality);
  await File(params.outputPath).writeAsBytes(compressed);
  return params.outputPath;
}

class MediaService {
  static const int      maxImageSizeMB       = AppConstants.maxImageSizeMB;
  static const int      maxVideoSizeMB       = AppConstants.maxVideoSizeMB;
  static const int      maxImageSizeBytes    = maxImageSizeMB * 1024 * 1024;
  static const int      maxVideoSizeBytes    = maxVideoSizeMB * 1024 * 1024;
  static const int      defaultImageQuality  = 85;
  static const int      defaultImageDimension = 1920;
  static const int      thumbnailQuality     = 50;
  static const int      minImageQuality      = 1;
  static const int      maxImageQuality      = 100;
  static const int      maxMultipleImages    = 10;
  static const Duration maxVideoDuration     = Duration(minutes: 5);
  static const Duration compressionTimeout   = Duration(minutes: 3);

  static const List<String> supportedImageExtensions = [
    '.jpg', '.jpeg', '.png', '.gif', '.webp',
  ];
  static const List<String> supportedVideoExtensions = [
    '.mp4', '.mov', '.avi', '.mkv',
  ];

  final CloudinaryService cloudinaryService;
  final ImagePicker       _picker = ImagePicker();

  bool _isDisposed = false;

  MediaService(this.cloudinaryService);

  Future<File?> pickImage({required bool fromCamera}) async {
    _ensureNotDisposed();

    try {
      AppLogger.info('Picking image from ${fromCamera ? 'camera' : 'gallery'}');

      final XFile? pickedFile = await _picker.pickImage(
        source:       fromCamera ? ImageSource.camera : ImageSource.gallery,
        maxWidth:     defaultImageDimension.toDouble(),
        maxHeight:    defaultImageDimension.toDouble(),
        imageQuality: defaultImageQuality,
      );

      if (pickedFile == null) return null;

      final file = File(pickedFile.path);
      await _validateImageFile(file);

      AppLogger.info('Image picked: ${pickedFile.path}');
      return file;
    } catch (e) {
      AppLogger.error('MediaService.pickImage', e);
      if (e is MediaServiceException) rethrow;
      throw MediaServiceException('Failed to pick image',
          code: 'PICK_IMAGE_ERROR', originalError: e);
    }
  }

  Future<List<File>> pickMultipleImages({int maxImages = 5}) async {
    _ensureNotDisposed();
    _validateMaxImages(maxImages);

    try {
      AppLogger.info('Picking multiple images (max: $maxImages)');

      final List<XFile> pickedFiles = await _picker.pickMultiImage(
        maxWidth:     defaultImageDimension.toDouble(),
        maxHeight:    defaultImageDimension.toDouble(),
        imageQuality: defaultImageQuality,
      );

      if (pickedFiles.isEmpty) return [];

      final limitedFiles = pickedFiles.take(maxImages).toList();
      final files        = <File>[];

      for (final xFile in limitedFiles) {
        try {
          final file = File(xFile.path);
          await _validateImageFile(file);
          files.add(file);
        } catch (e) {
          AppLogger.warning('Skipping invalid image: ${xFile.path} - $e');
        }
      }

      AppLogger.info('Picked ${files.length} valid images');
      return files;
    } catch (e) {
      AppLogger.error('MediaService.pickMultipleImages', e);
      if (e is MediaServiceException) rethrow;
      throw MediaServiceException('Failed to pick multiple images',
          code: 'PICK_MULTIPLE_ERROR', originalError: e);
    }
  }

  Future<File?> pickVideo({required bool fromCamera}) async {
    _ensureNotDisposed();

    try {
      AppLogger.info('Picking video from ${fromCamera ? 'camera' : 'gallery'}');

      final XFile? pickedFile = await _picker.pickVideo(
        source:      fromCamera ? ImageSource.camera : ImageSource.gallery,
        maxDuration: maxVideoDuration,
      );

      if (pickedFile == null) return null;

      final file = File(pickedFile.path);
      await _validateVideoFile(file);

      AppLogger.info('Video picked: ${pickedFile.path}');
      return file;
    } catch (e) {
      AppLogger.error('MediaService.pickVideo', e);
      if (e is MediaServiceException) rethrow;
      throw MediaServiceException('Failed to pick video',
          code: 'PICK_VIDEO_ERROR', originalError: e);
    }
  }

  Future<File> compressImage(File file, {int quality = defaultImageQuality}) async {
    _ensureNotDisposed();
    await _validateImageFile(file);
    _validateImageQuality(quality);

    try {
      AppLogger.info('Compressing image: ${file.path}');

      final originalSize = await file.length();
      final tempDir      = await getTemporaryDirectory();
      final outputPath   =
          '${tempDir.path}/compressed_${DateTime.now().millisecondsSinceEpoch}.jpg';

      final resultPath = await compute(
        _compressImageIsolate,
        _CompressImageParams(
          inputPath:    file.path,
          outputPath:   outputPath,
          quality:      quality,
          maxDimension: defaultImageDimension,
        ),
      );

      final compressedFile  = File(resultPath);
      final compressedSize  = await compressedFile.length();
      final compressionRatio =
          ((1 - compressedSize / originalSize) * 100).toStringAsFixed(1);

      // REPLACED: _formatBytes → FileSizeFormatter.format
      AppLogger.info(
        'Image compressed: ${FileSizeFormatter.format(originalSize)} → '
        '${FileSizeFormatter.format(compressedSize)} ($compressionRatio% reduction)',
      );

      return compressedFile;
    } catch (e) {
      AppLogger.error('MediaService.compressImage', e);
      if (e is MediaServiceException) rethrow;
      throw MediaServiceException('Failed to compress image',
          code: 'COMPRESS_ERROR', originalError: e);
    }
  }

  Future<File?> compressVideo(File file) async {
    _ensureNotDisposed();
    await _validateVideoFile(file);

    try {
      AppLogger.info('Compressing video: ${file.path}');

      final originalSize = await file.length();

      final info = await VideoCompress.compressVideo(
        file.path,
        quality:       VideoQuality.MediumQuality,
        deleteOrigin:  false,
        includeAudio:  true,
      ).timeout(
        compressionTimeout,
        onTimeout: () => throw MediaServiceException(
          'Video compression timed out',
          code: 'COMPRESSION_TIMEOUT',
        ),
      );

      if (info == null) {
        AppLogger.warning('Video compression returned null');
        return null;
      }
      if (info.file == null) {
        throw MediaServiceException('Video compression failed',
            code: 'COMPRESS_FAILED');
      }

      final compressedSize   = info.filesize ?? 0;
      final compressionRatio = compressedSize > 0
          ? ((1 - compressedSize / originalSize) * 100).toStringAsFixed(1)
          : '0.0';

      // REPLACED: _formatBytes → FileSizeFormatter.format
      AppLogger.info(
        'Video compressed: ${FileSizeFormatter.format(originalSize)} → '
        '${FileSizeFormatter.format(compressedSize)} ($compressionRatio% reduction)',
      );

      return info.file;
    } catch (e) {
      AppLogger.error('MediaService.compressVideo', e);
      if (e is MediaServiceException) rethrow;
      throw MediaServiceException('Failed to compress video',
          code: 'COMPRESS_VIDEO_ERROR', originalError: e);
    }
  }

  Future<String> uploadImage(File file, {String? folder}) async {
    _ensureNotDisposed();
    await _validateImageFile(file);

    File? compressedFile;

    try {
      AppLogger.info('Uploading image: ${file.path}');
      compressedFile = await compressImage(file);

      final url = await cloudinaryService.uploadImage(compressedFile,
          folder: folder);

      AppLogger.info('Image uploaded successfully: $url');
      return url;
    } catch (e) {
      AppLogger.error('MediaService.uploadImage', e);
      if (e is MediaServiceException) rethrow;
      throw MediaServiceException('Failed to upload image',
          code: 'UPLOAD_IMAGE_ERROR', originalError: e);
    } finally {
      await _cleanupTempFile(compressedFile, file);
    }
  }

  Future<String> uploadVideo(File file, {String? folder}) async {
    _ensureNotDisposed();
    await _validateVideoFile(file);

    File? compressedFile;

    try {
      AppLogger.info('Uploading video: ${file.path}');
      compressedFile = await compressVideo(file);
      final fileToUpload = compressedFile ?? file;

      final url = await cloudinaryService.uploadVideo(fileToUpload,
          folder: folder);

      AppLogger.info('Video uploaded successfully: $url');
      return url;
    } catch (e) {
      AppLogger.error('MediaService.uploadVideo', e);
      if (e is MediaServiceException) rethrow;
      throw MediaServiceException('Failed to upload video',
          code: 'UPLOAD_VIDEO_ERROR', originalError: e);
    } finally {
      await _cleanupTempFile(compressedFile, file);
    }
  }

  Future<List<String>> uploadMultipleImages(List<File> files,
      {String? folder}) async {
    _ensureNotDisposed();

    if (files.isEmpty) {
      AppLogger.warning('uploadMultipleImages called with empty list');
      return [];
    }

    if (files.length > maxMultipleImages) {
      throw MediaServiceException(
          'Too many images: ${files.length} (max: $maxMultipleImages)',
          code: 'TOO_MANY_IMAGES');
    }

    AppLogger.info('Uploading ${files.length} images');

    final List<String> urls   = [];
    final List<String> errors = [];

    for (int i = 0; i < files.length; i++) {
      try {
        final url = await uploadImage(files[i], folder: folder);
        urls.add(url);
        AppLogger.info('Uploaded image ${i + 1}/${files.length}');
      } catch (e) {
        AppLogger.warning('Failed to upload image ${i + 1}/${files.length}: $e');
        errors.add('Image ${i + 1}: $e');
      }
    }

    if (urls.isEmpty && errors.isNotEmpty) {
      throw MediaServiceException(
          'All image uploads failed: ${errors.join(', ')}',
          code: 'ALL_UPLOADS_FAILED');
    }

    AppLogger.info('Successfully uploaded ${urls.length}/${files.length} images');
    return urls;
  }

  Future<File?> getVideoThumbnail(String videoPath) async {
    _ensureNotDisposed();

    if (videoPath.trim().isEmpty) {
      throw MediaServiceException('Video path cannot be empty',
          code: 'INVALID_VIDEO_PATH');
    }

    final videoFile = File(videoPath);
    if (!await videoFile.exists()) {
      throw MediaServiceException(
          'Video file does not exist: $videoPath', code: 'FILE_NOT_FOUND');
    }

    try {
      AppLogger.info('Generating thumbnail for: $videoPath');
      final thumbnail = await VideoCompress.getFileThumbnail(videoPath,
          quality: thumbnailQuality);
      return thumbnail;
    } catch (e) {
      AppLogger.error('MediaService.getVideoThumbnail', e);
      return null;
    }
  }

  void cancelVideoCompression() {
    _ensureNotDisposed();
    try {
      VideoCompress.cancelCompression();
    } catch (e) {
      AppLogger.error('MediaService.cancelVideoCompression', e);
    }
  }

  Future<void> _validateImageFile(File file) async {
    if (!await file.exists()) {
      throw MediaServiceException('Image file does not exist: ${file.path}',
          code: 'FILE_NOT_FOUND');
    }
    final fileSize = await file.length();
    if (fileSize == 0) {
      throw MediaServiceException('Image file is empty', code: 'EMPTY_FILE');
    }
    if (fileSize > maxImageSizeBytes) {
      throw MediaServiceException(
          // REPLACED: _formatBytes → FileSizeFormatter.format
          'Image size exceeds ${maxImageSizeMB}MB: ${FileSizeFormatter.format(fileSize)}',
          code: 'FILE_TOO_LARGE');
    }
    final extension = _getFileExtension(file.path);
    if (!supportedImageExtensions.contains(extension)) {
      throw MediaServiceException('Unsupported image format: $extension',
          code: 'UNSUPPORTED_FORMAT');
    }
  }

  Future<void> _validateVideoFile(File file) async {
    if (!await file.exists()) {
      throw MediaServiceException('Video file does not exist: ${file.path}',
          code: 'FILE_NOT_FOUND');
    }
    final fileSize = await file.length();
    if (fileSize == 0) {
      throw MediaServiceException('Video file is empty', code: 'EMPTY_FILE');
    }
    if (fileSize > maxVideoSizeBytes) {
      throw MediaServiceException(
          // REPLACED: _formatBytes → FileSizeFormatter.format
          'Video size exceeds ${maxVideoSizeMB}MB: ${FileSizeFormatter.format(fileSize)}',
          code: 'FILE_TOO_LARGE');
    }
    final extension = _getFileExtension(file.path);
    if (!supportedVideoExtensions.contains(extension)) {
      throw MediaServiceException('Unsupported video format: $extension',
          code: 'UNSUPPORTED_FORMAT');
    }
  }

  void _validateImageQuality(int quality) {
    if (quality < minImageQuality || quality > maxImageQuality) {
      throw MediaServiceException(
          'Invalid image quality: $quality '
          '(must be between $minImageQuality and $maxImageQuality)',
          code: 'INVALID_QUALITY');
    }
  }

  void _validateMaxImages(int maxImages) {
    if (maxImages < 1 || maxImages > maxMultipleImages) {
      throw MediaServiceException(
          'Invalid maxImages: $maxImages '
          '(must be between 1 and $maxMultipleImages)',
          code: 'INVALID_MAX_IMAGES');
    }
  }

  String _getFileExtension(String path) {
    final lastDot = path.lastIndexOf('.');
    if (lastDot == -1) return '';
    return path.substring(lastDot).toLowerCase();
  }

  Future<void> _cleanupTempFile(File? tempFile, File originalFile) async {
    if (tempFile != null && tempFile.path != originalFile.path) {
      try {
        if (await tempFile.exists()) {
          await tempFile.delete();
          AppLogger.info('Cleaned up temp file: ${tempFile.path}');
        }
      } catch (e) {
        AppLogger.warning('Failed to cleanup temp file: $e');
      }
    }
  }

  void _ensureNotDisposed() {
    if (_isDisposed) {
      throw MediaServiceException('MediaService has been disposed',
          code: 'SERVICE_DISPOSED');
    }
  }

  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    try {
      await VideoCompress.deleteAllCache();
    } catch (e) {
      AppLogger.error('MediaService.dispose', e);
    }
  }
}
