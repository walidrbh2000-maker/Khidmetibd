// lib/providers/edit_profile_provider.dart
//
// FIX (MIGRATION — collection unifiée) :
//   _load() ne branch plus sur prefs.getString(PrefKeys.accountRole) avant
//   l'appel API. Ce pattern était fragile : sur un appareil neuf ou après
//   réinstallation, les prefs sont vides → la branche worker ne s'exécutait
//   jamais → professionLabel vide dans l'écran d'édition pour les travailleurs.
//
//   AVANT : lire prefs → si worker → getWorker(uid) / sinon → getUser(uid)
//   APRÈS : getUser(uid) → brancher sur userDoc.isWorker
//           (même pattern que settings_provider.dart et splash_controller.dart)
//
//   FIX (import paths) :
//   Imports corrigés — le fichier est en lib/providers/, pas dans un sous-dossier.
//   Suppression des imports inutilisés (app_config, media_path_helper).

import 'dart:io';

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../utils/constants.dart';
import '../utils/logger.dart';
import 'auth_providers.dart';
import 'core_providers.dart';

// ============================================================================
// EDIT PROFILE STATE
// ============================================================================

enum EditProfileStatus { loading, idle, saving, success, error }

// Sentinel: lets copyWith distinguish "clear errorMessage" from "keep current".
const _kKeepError = Object();

class EditProfileState {
  final EditProfileStatus status;
  final String  name;
  final String  email;           // read-only — sourced from Firebase Auth
  final String  phone;
  final String? professionLabel; // workers only — read-only display
  final String? profileImageUrl;
  final bool    isWorkerAccount;
  final String? errorMessage;    // localization key

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

  bool get isLoading => status == EditProfileStatus.loading ||
                        status == EditProfileStatus.saving;
  bool get hasError  => status == EditProfileStatus.error;
  bool get isSuccess => status == EditProfileStatus.success;

  EditProfileState copyWith({
    EditProfileStatus? status,
    String?  name,
    String?  email,
    String?  phone,
    String?  professionLabel,
    String?  profileImageUrl,
    bool?    isWorkerAccount,
    // Omit (sentinel)  → keep current value.
    // Pass null         → clear the error.
    // Pass a String     → set the new error key.
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

  // ── Load ───────────────────────────────────────────────────────────────────

  /// Loads the authenticated user's profile using the unified /users/:uid endpoint.
  ///
  /// DESIGN: single GET /users/:uid → branch on userDoc.isWorker.
  /// No need to check SharedPrefs for role — the document IS the source of truth.
  Future<void> _load() async {
    try {
      final authService = _ref.read(authServiceProvider);
      final apiService  = _ref.read(firestoreServiceProvider);
      final uid         = authService.user?.uid;

      if (uid == null) {
        state = state.copyWith(
          status:       EditProfileStatus.error,
          errorMessage: 'errors.no_user',
        );
        return;
      }

      // Single request — unified collection, `role` field discriminates.
      final userDoc = await apiService.getUser(uid);

      if (!mounted) return;

      if (userDoc == null) {
        // Profile not yet created — fallback to Firebase Auth claims.
        state = state.copyWith(
          status:          EditProfileStatus.idle,
          name:            authService.user?.displayName ?? '',
          email:           authService.user?.email       ?? '',
          isWorkerAccount: false,
          errorMessage:    null,
        );
        AppLogger.warning(
          'EditProfileNotifier: userDoc null for uid=$uid — fallback to Firebase',
        );
        return;
      }

      if (userDoc.isWorker) {
        state = state.copyWith(
          status:          EditProfileStatus.idle,
          name:            userDoc.name,
          email:           authService.user?.email ?? userDoc.email,
          phone:           userDoc.phoneNumber,
          professionLabel: userDoc.profession,
          profileImageUrl: userDoc.profileImageUrl,
          isWorkerAccount: true,
          errorMessage:    null,
        );
      } else {
        state = state.copyWith(
          status:          EditProfileStatus.idle,
          name:            userDoc.name,
          email:           authService.user?.email ?? userDoc.email,
          phone:           userDoc.phoneNumber,
          profileImageUrl: userDoc.profileImageUrl,
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

  // ── Save ───────────────────────────────────────────────────────────────────

  /// Persists name + phone changes and optionally a new profile image.
  ///
  /// Steps:
  ///   1. Upload image via MediaService (if provided) → get storedPath.
  ///   2. Load current document → apply changes via copyWith → write back.
  ///   3. Sync Firebase Auth displayName.
  ///   4. Log analytics event (fire-and-forget).
  ///
  /// Returns true on success, false if an error occurred (state.errorMessage set).
  Future<bool> save({
    required String name,
    required String phone,
    String?         newImagePath,
  }) async {
    if (!mounted) return false;
    state = state.copyWith(status: EditProfileStatus.saving);

    try {
      final authService = _ref.read(authServiceProvider);
      final apiService  = _ref.read(firestoreServiceProvider);
      final uid         = authService.user?.uid;

      if (uid == null) {
        state = state.copyWith(
          status:       EditProfileStatus.error,
          errorMessage: 'errors.no_user',
        );
        return false;
      }

      final trimmedName  = name.trim();
      final trimmedPhone = phone.trim();

      // Step 1 — upload image if the user picked a new one.
      String? uploadedImageUrl = state.profileImageUrl;
      if (newImagePath != null) {
        uploadedImageUrl = (await _ref
                .read(mediaServiceProvider)
                .uploadImage(File(newImagePath)))
            .storedPath;
      }

      // Step 2 — load current document, apply delta, write back.
      if (state.isWorkerAccount) {
        final current = await apiService.getWorker(uid);
        if (current != null) {
          await apiService.createOrUpdateWorker(
            current.copyWith(
              name:            trimmedName,
              phoneNumber:     trimmedPhone,
              profileImageUrl: uploadedImageUrl,
            ),
          );
        }
      } else {
        final current = await apiService.getUser(uid);
        if (current != null) {
          await apiService.createOrUpdateUser(
            current.copyWith(
              name:            trimmedName,
              phoneNumber:     trimmedPhone,
              profileImageUrl: uploadedImageUrl,
            ),
          );
        }
      }

      // Step 3 — keep Firebase Auth displayName in sync.
      await authService.user?.updateDisplayName(trimmedName);

      // Step 4 — analytics (fire-and-forget — never block save).
      FirebaseAnalytics.instance.logEvent(
        name: 'profile_updated',
        parameters: {
          'account_type':  state.isWorkerAccount ? 'worker' : 'client',
          'image_changed': (newImagePath != null).toString(),
        },
      ).ignore();

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

  // ── Retry ──────────────────────────────────────────────────────────────────

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
  (ref) => EditProfileNotifier(ref),
);
