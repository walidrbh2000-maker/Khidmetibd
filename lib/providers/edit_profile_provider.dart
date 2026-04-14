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
//   save() conserve le pattern existant (getWorker/getUser + copyWith merge)
//   qui est correct architecturalement — aucun changement nécessaire là.

import 'dart:io';

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/auth_providers.dart';
import '../../providers/core_providers.dart';
import '../../utils/constants.dart';
import '../../utils/logger.dart';
import '../../../utils/app_config.dart';
import '../../../utils/media_path_helper.dart';

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

  /// FIX (MIGRATION — collection unifiée) :
  ///
  /// AVANT — fragile, branché sur les prefs :
  ///   1. prefs.getString(PrefKeys.accountRole) == UserType.worker
  ///      → getWorker(uid)  (appel à l'ancienne collection via facade)
  ///   2. sinon → getUser(uid)
  ///   Problème : prefs absentes (réinstall, nouvel appareil) → branche client
  ///   → professionLabel jamais chargé pour un worker.
  ///
  /// APRÈS — source unique, identique à settings_provider.dart :
  ///   getUser(uid) → brancher sur userDoc.isWorker
  ///   Le champ `role` du document unifié est la seule source de vérité.
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

      // Une seule requête — le document unifié porte le rôle et tous les champs.
      final userDoc = await firestoreService.getUser(uid);

      if (!mounted) return;

      if (userDoc == null) {
        // Profil pas encore créé — fallback sur Firebase Auth.
        state = state.copyWith(
          status:          EditProfileStatus.idle,
          name:            authService.user?.displayName ?? '',
          email:           authService.user?.email       ?? '',
          isWorkerAccount: false,
          errorMessage:    null,
        );
        AppLogger.warning('EditProfileNotifier: userDoc null pour uid=$uid — fallback Firebase');
        return;
      }

      if (userDoc.isWorker) {
        state = state.copyWith(
          status:          EditProfileStatus.idle,
          name:            userDoc.name,
          email:           authService.user?.email ?? userDoc.email,
          phone:           userDoc.phoneNumber,
          professionLabel: userDoc.profession,       // String? — champ unifié
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

  /// Saves name + phone to Firestore and syncs Firebase Auth displayName.
  /// If [newImagePath] is provided, uploads the picked file via MediaService
  /// then stores the returned URL.
  ///
  /// Pattern:
  ///   1. Load current document → apply changes via copyWith → write back.
  ///      FirestoreService has no partial-update method — uses
  ///      createOrUpdateWorker / createOrUpdateUser which call set(merge:true).
  ///   2. MediaService.uploadImage(File) returns the MinIO URL.
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
      String? uploadedImageUrl = state.profileImageUrl;
      if (newImagePath != null) {
        uploadedImageUrl = (await _ref
            .read(mediaServiceProvider)
            .uploadImage(
              File(newImagePath),
              folder: 'profiles',
            )).storedPath;
      }

      if (state.isWorkerAccount) {
        // Load current worker, apply changes via copyWith, write back.
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
              name:            trimmedName,
              phoneNumber:     trimmedPhone,
              profileImageUrl: uploadedImageUrl,
            ),
          );
        }
      }

      // Sync Firebase Auth displayName so ProfileCard reflects the change.
      await authService.user?.updateDisplayName(trimmedName);

      // fire-and-forget — never block save on analytics
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
