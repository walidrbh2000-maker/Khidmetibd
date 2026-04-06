// lib/providers/edit_profile_provider.dart

import 'dart:io';

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../providers/auth_providers.dart';
import '../../providers/core_providers.dart';
import '../../utils/constants.dart';
import '../../utils/logger.dart';

// ============================================================================
// EDIT PROFILE STATE
// ============================================================================

enum EditProfileStatus { loading, idle, saving, success, error }

// Sentinel used so copyWith can distinguish "clear errorMessage" from
// "leave errorMessage unchanged". Without this, every copyWith call that
// omits the parameter silently resets a live error to null.
const _kKeepError = Object();

class EditProfileState {
  final EditProfileStatus status;
  final String  name;
  final String  email;           // read-only — sourced from Firebase Auth
  final String  phone;
  final String? professionLabel; // workers only — read-only (business-critical)
  final String? profileImageUrl;
  final bool    isWorkerAccount;
  final String? errorMessage;

  const EditProfileState({
    this.status           = EditProfileStatus.loading,
    this.name             = '',
    this.email            = '',
    this.phone            = '',
    this.professionLabel,
    this.profileImageUrl,
    this.isWorkerAccount  = false,
    this.errorMessage,
  });

  EditProfileState copyWith({
    EditProfileStatus? status,
    String?  name,
    String?  email,
    String?  phone,
    String?  professionLabel,
    String?  profileImageUrl,
    bool?    isWorkerAccount,
    // Pass a String to set, pass null to CLEAR, omit (default sentinel) to KEEP.
    Object?  errorMessage = _kKeepError,
  }) {
    return EditProfileState(
      status:          status          ?? this.status,
      name:            name            ?? this.name,
      email:           email           ?? this.email,
      phone:           phone           ?? this.phone,
      professionLabel: professionLabel ?? this.professionLabel,
      profileImageUrl: profileImageUrl ?? this.profileImageUrl,
      isWorkerAccount: isWorkerAccount ?? this.isWorkerAccount,
      errorMessage: identical(errorMessage, _kKeepError)
          ? this.errorMessage
          : errorMessage as String?,
    );
  }
}

// ============================================================================
// EDIT PROFILE NOTIFIER
// ============================================================================

class EditProfileNotifier extends StateNotifier<EditProfileState> {
  final Ref _ref;

  EditProfileNotifier(this._ref) : super(const EditProfileState()) {
    _load();
  }

  Future<void> _load() async {
    try {
      final authService      = _ref.read(authServiceProvider);
      final firestoreService = _ref.read(firestoreServiceProvider);
      final uid              = authService.user?.uid;

      if (uid == null) {
        state = state.copyWith(
          status:       EditProfileStatus.error,
          errorMessage: 'errors.no_user',
        );
        return;
      }

      final prefs            = await SharedPreferences.getInstance();
      final savedAccountRole = prefs.getString(PrefKeys.accountRole);

      // Worker path.
      if (savedAccountRole == UserType.worker) {
        final worker = await firestoreService.getWorker(uid);
        if (worker != null && mounted) {
          state = state.copyWith(
            status:          EditProfileStatus.idle,
            name:            worker.name,
            email:           authService.user?.email ?? worker.email,
            phone:           worker.phoneNumber,
            professionLabel: worker.profession,
            profileImageUrl: worker.profileImageUrl,
            isWorkerAccount: true,
            errorMessage:    null,
          );
        }
        return;
      }

      // Client path.
      final user = await firestoreService.getUser(uid);
      if (user != null && mounted) {
        state = state.copyWith(
          status:          EditProfileStatus.idle,
          name:            user.name,
          email:           authService.user?.email ?? user.email,
          phone:           user.phoneNumber ?? '',
          isWorkerAccount: false,
          errorMessage:    null,
        );
      }
    } catch (e, st) {
      AppLogger.error('EditProfileNotifier._load', e, st);
      if (mounted) {
        state = state.copyWith(
          status:       EditProfileStatus.error,
          errorMessage: 'errors.load_failed',
        );
      }
    }
  }

  /// Saves name + phone to Firestore and syncs Firebase Auth displayName.
  /// If [newImagePath] is provided, uploads the picked file via MediaService
  /// then stores the returned URL.
  ///
  /// Pattern:
  ///   1. Load current document → apply changes via copyWith → write back.
  ///      FirestoreService has no partial-update method — uses
  ///      createOrUpdateWorker / createOrUpdateUser which call set(merge:true).
  ///   2. MediaService.uploadImage(File) returns the Cloudinary URL.
  ///   3. FirebaseAnalytics.instance.logEvent for profile_updated.
  Future<bool> save({
    required String name,
    required String phone,
    String?         newImagePath,
  }) async {
    if (!mounted) return false;
    state = state.copyWith(status: EditProfileStatus.saving);

    try {
      final authService      = _ref.read(authServiceProvider);
      final firestoreService = _ref.read(firestoreServiceProvider);
      final uid              = authService.user?.uid;

      if (uid == null) {
        state = state.copyWith(
          status:       EditProfileStatus.error,
          errorMessage: 'errors.no_user',
        );
        return false;
      }

      final trimmedName  = name.trim();
      final trimmedPhone = phone.trim();

      // Upload image if user picked one.
      // MediaService.uploadImage(File, {folder?}) → Future<String> (URL).
      String? uploadedImageUrl = state.profileImageUrl;
      if (newImagePath != null) {
        uploadedImageUrl = await _ref
            .read(mediaServiceProvider)
            .uploadImage(
              File(newImagePath),
              folder: 'profiles',
            );
      }

      if (state.isWorkerAccount) {
        // Load current worker, apply changes via copyWith, write back.
        // createOrUpdateWorker calls set(merge:true) — safe for partial update.
        final current = await firestoreService.getWorker(uid);
        if (current != null) {
          await firestoreService.createOrUpdateWorker(
            current.copyWith(
              name:            trimmedName,
              phoneNumber:     trimmedPhone,
              profileImageUrl: uploadedImageUrl,
            ),
          );
        }
      } else {
        // Load current user, apply changes via copyWith, write back.
        final current = await firestoreService.getUser(uid);
        if (current != null) {
          await firestoreService.createOrUpdateUser(
            current.copyWith(
              name:        trimmedName,
              phoneNumber: trimmedPhone,
              // UserModel.profileImageUrl — add to UserModel if missing.
            ),
          );
        }
      }

      // Sync Firebase Auth displayName so ProfileCard reflects the change.
      await authService.user?.updateDisplayName(trimmedName);

      // FirebaseAnalytics.instance is available directly — AnalyticsService
      // does not expose a generic logEvent (only domain-specific methods).
      FirebaseAnalytics.instance.logEvent(
        name: 'profile_updated',
        parameters: {
          'account_type':  state.isWorkerAccount ? 'worker' : 'client',
          'image_changed': (newImagePath != null).toString(),
        },
      ).ignore(); // fire-and-forget — never block save on analytics

      if (mounted) {
        state = state.copyWith(
          status:          EditProfileStatus.success,
          name:            trimmedName,
          phone:           trimmedPhone,
          profileImageUrl: uploadedImageUrl,
          errorMessage:    null,
        );
      }
      return true;

    } catch (e, st) {
      AppLogger.error('EditProfileNotifier.save', e, st);
      if (mounted) {
        state = state.copyWith(
          status:       EditProfileStatus.error,
          errorMessage: 'errors.save_failed',
        );
      }
      return false;
    }
  }

  Future<void> retry() async {
    if (mounted) state = const EditProfileState();
    await _load();
  }
}

// ============================================================================
// PROVIDER
// ============================================================================

final editProfileProvider =
    StateNotifierProvider.autoDispose<EditProfileNotifier, EditProfileState>(
        (ref) => EditProfileNotifier(ref));
