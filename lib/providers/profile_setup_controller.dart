// lib/providers/profile_setup_controller.dart
//
// Controls the profile setup flow for both client and worker accounts.
//
// Flow:
//   1. User/worker sets name, avatar, and (worker only) profession.
//   2. submit() uploads the image (if any), then POSTs to /users or /workers.
//   3. On success → router.go(AppRoutes.home)
//
// Voice profession:
//   setProfessionByVoice() records audio → POST /ai/extract-intent/audio →
//   reads SearchIntent.profession → updates profession in state.
//   The UI shows the detected profession highlighted in the grid.

import 'dart:async';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/profile_setup_state.dart';
import '../models/user_model.dart';
import '../models/profession_model.dart';
import '../services/api_service.dart';
import '../services/local_ai_service.dart';
import '../services/media_service.dart';
import '../utils/form_validators.dart';
import 'core_providers.dart';

// ─────────────────────────────────────────────────────────────────────────────

class ProfileSetupController extends StateNotifier<ProfileSetupState> {
  final ApiService     _api;
  final MediaService   _media;
  final LocalAiService _ai;

  static const int _uploadRetries = 3;

  ProfileSetupController({
    required ApiService     api,
    required MediaService   media,
    required LocalAiService ai,
  })  : _api   = api,
        _media = media,
        _ai    = ai,
        super(const ProfileSetupState());

  // ══════════════════════════════════════════════════════════════════════════
  // Field setters
  // ══════════════════════════════════════════════════════════════════════════

  void setName(String name) {
    state = state.copyWith(name: name, clearError: true);
  }

  void setAvatarPath(String? localPath) {
    state = state.copyWith(
      avatarLocalPath: localPath,
      avatarEmoji:     null, // picked photo overrides emoji
      clearAvatar:     localPath == null,
    );
  }

  void setAvatarEmoji(String emoji) {
    state = state.copyWith(
      avatarEmoji:     emoji,
      avatarLocalPath: null, // emoji overrides local photo
    );
  }

  void setProfession(String key) {
    if (!kValidProfessionKeys.contains(key)) return;
    state = state.copyWith(profession: key, clearError: true);
  }

  void clearProfession() {
    state = state.copyWith(clearProfession: true);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Voice profession detection
  // ══════════════════════════════════════════════════════════════════════════

  /// Sends [audioBytes] to the AI backend and auto-selects the detected profession.
  ///
  /// Returns the detected profession key, or null if none detected.
  /// The UI should show a success/error feedback based on the return value.
  Future<String?> setProfessionByVoice(
    Uint8List audioBytes, {
    String mime = 'audio/m4a',
  }) async {
    if (audioBytes.isEmpty) return null;
    if (state.isVoiceProcessing)  return null;

    state = state.copyWith(isVoiceProcessing: true);

    try {
      final intent = await _ai.extractFromAudio(audioBytes, mime: mime);
      final key    = intent.profession;

      if (!mounted) return null;

      if (key != null && kValidProfessionKeys.contains(key)) {
        state = state.copyWith(
          profession:        key,
          isVoiceProcessing: false,
          clearError:        true,
        );
        _log('Voice detected profession: $key');
        return key;
      }

      state = state.copyWith(
        isVoiceProcessing: false,
        errorKey:          'errors.voice_profession_not_found',
      );
      return null;
    } catch (e) {
      if (!mounted) return null;
      _logError('setProfessionByVoice', e);
      state = state.copyWith(
        isVoiceProcessing: false,
        errorKey:          'errors.voice_generic',
      );
      return null;
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Submit
  // ══════════════════════════════════════════════════════════════════════════

  /// Submits the profile for a client account.
  ///
  /// Returns true on success. Navigation is handled by the router watching
  /// [firebaseAuthStreamProvider] — no explicit navigation here.
  Future<bool> submitClientProfile() async {
    if (!state.canSubmitClient) return false;
    return _submit(isWorker: false);
  }

  /// Submits the profile for a worker account.
  Future<bool> submitWorkerProfile() async {
    if (!state.canSubmitWorker) return false;
    return _submit(isWorker: true);
  }

  Future<bool> _submit({required bool isWorker}) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      state = state.copyWith(
        status:   ProfileSetupStatus.error,
        errorKey: 'errors.no_user',
      );
      return false;
    }

    state = state.copyWith(status: ProfileSetupStatus.idle);

    // ── Step 1: upload image if picked ──────────────────────────────────────
    String? storedPath;
    if (state.avatarLocalPath != null) {
      state = state.copyWith(status: ProfileSetupStatus.uploadingImage);
      storedPath = await _uploadImageWithRetry(state.avatarLocalPath!);
      if (storedPath == null) return false; // error state already set
    }

    // ── Step 2: POST to backend ──────────────────────────────────────────────
    state = state.copyWith(status: ProfileSetupStatus.submitting);
    try {
      if (isWorker) {
        final worker = UserModel(
          id:              uid,
          name:            state.name.trim(),
          email:           '',
          phoneNumber:     FirebaseAuth.instance.currentUser?.phoneNumber ?? '',
          role:            'worker',
          profession:      state.profession,
          profileImageUrl: storedPath,
          lastUpdated:     DateTime.now(),
        );
        await _api.createOrUpdateWorker(worker);
      } else {
        final user = UserModel(
          id:              uid,
          name:            state.name.trim(),
          email:           '',
          phoneNumber:     FirebaseAuth.instance.currentUser?.phoneNumber ?? '',
          role:            'client',
          profileImageUrl: storedPath,
          lastUpdated:     DateTime.now(),
        );
        await _api.createOrUpdateUser(user);
      }

      if (!mounted) return false;
      state = state.copyWith(status: ProfileSetupStatus.success, clearError: true);
      _log('Profile created: uid=$uid isWorker=$isWorker');
      return true;
    } catch (e) {
      if (!mounted) return false;
      _logError('_submit', e);
      state = state.copyWith(
        status:   ProfileSetupStatus.error,
        errorKey: 'errors.submit_failed',
      );
      return false;
    }
  }

  Future<String?> _uploadImageWithRetry(String localPath) async {
    for (int attempt = 1; attempt <= _uploadRetries; attempt++) {
      try {
        final result = await _media.uploadImage(File(localPath));
        state = state.copyWith(uploadProgress: 1.0);
        return result.storedPath;
      } catch (e) {
        _logError('uploadImage attempt $attempt', e);
        if (attempt == _uploadRetries) {
          if (mounted) {
            state = state.copyWith(
              status:         ProfileSetupStatus.error,
              uploadProgress: 0.0,
              errorKey:       'errors.image_upload_failed',
            );
          }
          return null;
        }
        await Future.delayed(Duration(seconds: attempt * 2));
      }
    }
    return null;
  }

  void _log(String msg)               { if (kDebugMode) debugPrint('[ProfileSetupController] $msg'); }
  void _logError(String m, Object e)  { if (kDebugMode) debugPrint('[ProfileSetupController] ✗ $m: $e'); }
}

// ─────────────────────────────────────────────────────────────────────────────
// Provider — autoDispose: released after setup screens are popped.
// ─────────────────────────────────────────────────────────────────────────────

final profileSetupControllerProvider =
    StateNotifierProvider.autoDispose<ProfileSetupController, ProfileSetupState>((ref) {
  return ProfileSetupController(
    api:   ref.read(apiServiceProvider),
    media: ref.read(mediaServiceProvider),
    ai:    ref.read(localAiServiceProvider),
  );
});
