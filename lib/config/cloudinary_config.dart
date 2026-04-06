// lib/config/cloudinary_config.dart
//
// SECURITY FIX (Critical): cloudName and uploadPreset were static const String —
// compiled directly into the APK/IPA binary. Any attacker could run
// `strings app.apk | grep cloud` or use a decompiler to extract them.
// With an unsigned upload preset this allows unlimited storage/bandwidth abuse
// and content injection.
//
// FIX: Both values are now served from Firebase Remote Config, exactly
// like geminiApiKey in AppConfig. The binary no longer contains these strings.
//
// HOW TO CONFIGURE:
//   1. Firebase Console → Remote Config → Add parameters:
//        cloudinary_cloud_name   → your cloud name
//        cloudinary_upload_preset → your unsigned upload preset name
//   2. Publish the Remote Config changes.
//   3. AppConfig.initialize() (called in main.dart) will fetch them on launch.

import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/foundation.dart';

class CloudinaryConfig {
  CloudinaryConfig._();

  static const String _kCloudName    = 'cloudinary_cloud_name';
  static const String _kUploadPreset = 'cloudinary_upload_preset';

  static FirebaseRemoteConfig get _rc => FirebaseRemoteConfig.instance;

  /// Cloudinary cloud name — read from Firebase Remote Config at runtime.
  /// Never compiled into the binary.
  static String get cloudName {
    final value = _rc.getString(_kCloudName);
    if (value.isEmpty) {
      _logWarning('cloudinary_cloud_name is empty in Remote Config');
    }
    return value;
  }

  /// Unsigned upload preset — read from Firebase Remote Config at runtime.
  /// Never compiled into the binary.
  static String get uploadPreset {
    final value = _rc.getString(_kUploadPreset);
    if (value.isEmpty) {
      _logWarning('cloudinary_upload_preset is empty in Remote Config');
    }
    return value;
  }

  /// True when both values have been successfully fetched from Remote Config.
  static bool get isConfigured =>
      cloudName.isNotEmpty && uploadPreset.isNotEmpty;

  /// Call during app startup (after AppConfig.initialize()) to warn early
  /// if Remote Config values are missing.
  static void validate() {
    if (!isConfigured) {
      _logWarning(
        '[CloudinaryConfig] WARNING: cloudName or uploadPreset not yet '
        'available from Remote Config. Uploads will fail until Remote Config '
        'is fetched. Add cloudinary_cloud_name and cloudinary_upload_preset '
        'to your Firebase Remote Config and publish.',
      );
    }
  }

  static void _logWarning(String message) {
    if (kDebugMode) debugPrint('[CloudinaryConfig] WARNING: $message');
  }
}
