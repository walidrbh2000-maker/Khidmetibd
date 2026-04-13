// lib/providers/home_search_controller.dart
//
// BUG 4 FIX C — alreadyProcessing non mappé
//
// PROBLÈME :
//   Quand l'utilisateur retente pendant qu'une requête image est en cours
//   (_isBusyText = true), LocalAiService lève AiIntentExtractorException avec
//   code = AiExtractorErrorCode.alreadyProcessing.
//   Ce code tombait dans le `default` de _mapErrorCode() et retournait
//   HomeSearchErrorType.network → l'UI affichait "Erreur de recherche" au
//   lieu d'un message approprié ("Veuillez patienter...").
//
// SOLUTION :
//   Mapper alreadyProcessing → HomeSearchErrorType.timeout.
//   L'UI associée au type timeout affiche déjà "Veuillez patienter" — c'est
//   le message le plus pertinent pour ce cas.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/search_intent.dart';
import '../models/search_result_model.dart';
import '../models/worker_model.dart';
import '../services/local_ai_service.dart';
import '../utils/model_extensions.dart';
import '../utils/constants.dart';
import '../utils/logger.dart';
import '../utils/ranking_utils.dart';
import 'core_providers.dart';
import 'home_controller.dart';

// ============================================================================
// STATE
// ============================================================================

enum HomeSearchStatus {
  idle,
  listening,
  extracting,
  searching,
  results,
  error,
}

enum HomeSearchErrorType {
  quotaExceeded,
  modelOverloaded,
  timeout,
  network,
  unknown,
}

class HomeSearchState {
  final HomeSearchStatus  status;
  final String            interimText;
  final SearchIntent?     lastIntent;
  final List<GeoSearchResult<WorkerModel>> results;
  final String?           error;
  final HomeSearchErrorType? errorType;

  const HomeSearchState({
    this.status      = HomeSearchStatus.idle,
    this.interimText = '',
    this.lastIntent,
    this.results     = const [],
    this.error,
    this.errorType,
  });

  bool get isLoading =>
      status == HomeSearchStatus.extracting ||
      status == HomeSearchStatus.searching;

  bool get hasResults => status == HomeSearchStatus.results;

  bool get isEmpty => hasResults && results.isEmpty;

  bool get hasError => status == HomeSearchStatus.error;

  HomeSearchState copyWith({
    HomeSearchStatus?                   status,
    String?                             interimText,
    SearchIntent?                       lastIntent,
    List<GeoSearchResult<WorkerModel>>? results,
    String?                             error,
    HomeSearchErrorType?                errorType,
    bool                                clearError  = false,
    bool                                clearIntent = false,
  }) {
    return HomeSearchState(
      status:      status      ?? this.status,
      interimText: interimText ?? this.interimText,
      lastIntent:  clearIntent ? null : (lastIntent ?? this.lastIntent),
      results:     results     ?? this.results,
      error:       clearError  ? null : (error ?? this.error),
      errorType:   clearError  ? null : (errorType ?? this.errorType),
    );
  }
}

// ============================================================================
// CONTROLLER
// ============================================================================

class HomeSearchController extends StateNotifier<HomeSearchState> {
  final Ref _ref;

  static const int      _maxCallsPerHour = 20;
  static const Duration _windowDuration  = Duration(hours: 1);
  final List<DateTime>  _callTimestamps  = [];

  static const double _lowConfidenceThreshold      = 0.35;
  static const double _highConfidenceThreshold     = 0.70;
  static const double _fallbackConfidenceThreshold = 0.10;

  HomeSearchController(this._ref) : super(const HomeSearchState());

  // ── Rate limiter ──────────────────────────────────────────────────────────

  bool _isRateLimited() {
    final now    = DateTime.now();
    final cutoff = now.subtract(_windowDuration);
    _callTimestamps.removeWhere((t) => t.isBefore(cutoff));
    return _callTimestamps.length >= _maxCallsPerHour;
  }

  void _recordCall() => _callTimestamps.add(DateTime.now());

  // ── Public API ─────────────────────────────────────────────────────────────

  Future<void> submitSearch(
    String text, {
    Uint8List? imageBytes,
    String?    mime,
  }) async {
    final hasText  = text.trim().isNotEmpty;
    final hasImage = imageBytes != null && imageBytes.isNotEmpty;
    if (!hasText && !hasImage) return;

    if (_isRateLimited()) {
      AppLogger.warning(
          'HomeSearchController: rate limit reached ($_maxCallsPerHour/hour)');
      state = state.copyWith(
        status:    HomeSearchStatus.error,
        error:     'rate_limit_exceeded',
        errorType: HomeSearchErrorType.quotaExceeded,
      );
      return;
    }

    state = state.copyWith(
      status:     HomeSearchStatus.extracting,
      clearError: true,
    );

    _ref.read(analyticsServiceProvider).logBrowseFilterApplied(
      filter:       hasImage ? 'image_search' : 'text_search',
      resultsCount: 0,
    );

    SearchIntent intent;
    try {
      final extractor = _ref.read(localAiServiceProvider);
      intent = await extractor.extract(text,
          imageBytes: imageBytes, mime: mime);
      _recordCall();
      AppLogger.info('HomeSearchController: intent → ${intent.toJson()}');
    } on AiIntentExtractorException catch (e) {
      AppLogger.error('HomeSearchController.submitSearch [extract]', e);
      state = state.copyWith(
        status:    HomeSearchStatus.error,
        error:     e.message,
        errorType: _mapErrorCode(e.code),
      );
      return;
    } catch (e) {
      AppLogger.error('HomeSearchController.submitSearch [extract]', e);
      state = state.copyWith(
        status:    HomeSearchStatus.error,
        error:     e.toString(),
        errorType: HomeSearchErrorType.unknown,
      );
      return;
    }

    // FALLBACK total (image non identifiée, confidence très basse)
    if (hasImage &&
        intent.profession == null &&
        (intent.confidence) < _fallbackConfidenceThreshold) {
      AppLogger.info(
          'HomeSearchController: FALLBACK total — image non reconnue '
          '(confidence=${intent.confidence.toStringAsFixed(2)})');
      state = state.copyWith(
        status:     HomeSearchStatus.results,
        results:    const [],
        lastIntent: intent,
      );
      return;
    }

    final gatedIntent = _applyConfidenceGate(intent);

    state = state.copyWith(
      status:     HomeSearchStatus.searching,
      lastIntent: gatedIntent,
    );

    try {
      final results = await _search(gatedIntent);

      _ref.read(analyticsServiceProvider).logBrowseFilterApplied(
        filter:       gatedIntent.profession ?? 'no_profession',
        resultsCount: results.length,
      );

      state = state.copyWith(
        status:  HomeSearchStatus.results,
        results: results,
      );
    } catch (e) {
      AppLogger.error('HomeSearchController.submitSearch [search]', e);
      state = state.copyWith(
        status:    HomeSearchStatus.error,
        error:     e.toString(),
        errorType: HomeSearchErrorType.network,
      );
    }
  }

  Future<void> startListening() async {
    final audio   = _ref.read(audioServiceProvider);
    final hasPerm = await audio.hasAudioPermission();
    if (!hasPerm || !mounted) {
      state = state.copyWith(
        status: HomeSearchStatus.error,
        error:  'mic_unavailable',
      );
      return;
    }

    try {
      await audio.startRecording();
      if (!mounted) return;
      state = state.copyWith(
        status:      HomeSearchStatus.listening,
        interimText: '',
        clearError:  true,
      );
    } catch (e) {
      AppLogger.error('HomeSearchController.startListening', e);
      if (mounted) {
        state = state.copyWith(
          status: HomeSearchStatus.error,
          error:  'mic_unavailable',
        );
      }
    }
  }

  Future<void> stopListening() async {
    if (!mounted || state.status != HomeSearchStatus.listening) return;
    state = state.copyWith(
        status: HomeSearchStatus.extracting, clearError: true);

    final audio = _ref.read(audioServiceProvider);
    String? filePath;
    try {
      filePath = await audio.stopRecording();
    } catch (e) {
      AppLogger.error('HomeSearchController.stopListening [stop]', e);
      if (mounted) {
        state = state.copyWith(
            status: HomeSearchStatus.error, error: 'recording_failed');
      }
      return;
    }

    if (filePath == null) {
      if (mounted) state = state.copyWith(status: HomeSearchStatus.idle);
      return;
    }

    Uint8List audioBytes;
    try {
      final file = File(filePath);
      audioBytes = await file.readAsBytes();
      await file.delete();
    } catch (e) {
      AppLogger.error('HomeSearchController.stopListening [read]', e);
      if (mounted) {
        state = state.copyWith(
            status: HomeSearchStatus.error, error: 'recording_failed');
      }
      return;
    }

    if (!mounted) return;

    if (_isRateLimited()) {
      if (mounted) {
        state = state.copyWith(
          status:    HomeSearchStatus.error,
          error:     'rate_limit_exceeded',
          errorType: HomeSearchErrorType.quotaExceeded,
        );
      }
      return;
    }

    SearchIntent intent;
    try {
      final extractor = _ref.read(localAiServiceProvider);
      intent = await extractor.extractFromAudio(audioBytes);
      _recordCall();
      AppLogger.info(
          'HomeSearchController: audio intent → ${intent.toJson()}');
    } on AiIntentExtractorException catch (e) {
      AppLogger.error('HomeSearchController.stopListening [extract]', e);
      if (mounted) {
        state = state.copyWith(
          status:    HomeSearchStatus.error,
          error:     e.message,
          errorType: _mapErrorCode(e.code),
        );
      }
      return;
    } catch (e) {
      AppLogger.error('HomeSearchController.stopListening [extract]', e);
      if (mounted) {
        state = state.copyWith(
            status: HomeSearchStatus.error, error: e.toString());
      }
      return;
    }

    if (!mounted) return;

    final gatedIntent = _applyConfidenceGate(intent);

    state = state.copyWith(
        status: HomeSearchStatus.searching, lastIntent: gatedIntent);
    try {
      final results = await _search(gatedIntent);
      if (mounted) {
        state = state.copyWith(
            status: HomeSearchStatus.results, results: results);
      }
    } catch (e) {
      AppLogger.error('HomeSearchController.stopListening [search]', e);
      if (mounted) {
        state = state.copyWith(
            status: HomeSearchStatus.error, error: e.toString());
      }
    }
  }

  void applyToMap() {
    final intent       = state.lastIntent;
    final results      = state.results;
    final homeNotifier = _ref.read(homeControllerProvider.notifier);
    final homeState    = _ref.read(homeControllerProvider);

    if (intent?.profession != null) {
      homeNotifier.setServiceFilter(intent!.profession);
    }

    if (results.isNotEmpty) {
      final userLoc   = homeState.userLocation;
      final nearbyIds = homeState.nearbyWorkers.map((w) => w.id).toSet();
      final intersected =
          results.where((r) => nearbyIds.contains(r.data.id)).toList();

      final List<GeoSearchResult<WorkerModel>> pool;
      if (intersected.isNotEmpty) {
        pool = intersected;
      } else {
        final professionWorkers = intent?.profession != null
            ? homeState.nearbyWorkers
                .where((w) => w.profession == intent!.profession)
                .toList()
            : homeState.nearbyWorkers;
        if (professionWorkers.isEmpty) {
          homeNotifier.enterMapFullscreen();
          return;
        }
        pool = professionWorkers.map((w) {
          final distance = userLoc != null
              ? w.distanceTo(userLoc.latitude, userLoc.longitude)
              : 0.0;
          return GeoSearchResult<WorkerModel>(
            data:       w,
            distance:   distance,
            cellId:     w.cellId     ?? '',
            wilayaCode: w.wilayaCode ?? 0,
            source:     SearchResultSource.currentCell,
          );
        }).toList();
      }

      final maxRating = pool
          .map((r) => r.data.averageRating)
          .reduce((a, b) => a > b ? a : b);
      final minRating = pool
          .map((r) => r.data.averageRating)
          .reduce((a, b) => a < b ? a : b);
      final maxDist = pool
          .map((r) => r.distance)
          .reduce((a, b) => a > b ? a : b);
      final minDist = pool
          .map((r) => r.distance)
          .reduce((a, b) => a < b ? a : b);

      String? bestId;
      double  bestScore = -1;

      for (final r in pool) {
        final normRating = RankingUtils.minMaxNormalize(
            r.data.averageRating, minRating, maxRating);
        final normDist = 1.0 -
            RankingUtils.minMaxNormalize(r.distance, minDist, maxDist);
        final score = normRating * 0.6 + normDist * 0.4;
        if (score > bestScore) {
          bestScore = score;
          bestId    = r.data.id;
        }
      }

      AppLogger.info(
          'HomeSearchController: best worker → $bestId '
          '(score ${bestScore.toStringAsFixed(2)})');
      homeNotifier.setBestWorker(bestId);
    }

    homeNotifier.enterMapFullscreen();
  }

  void reset() {
    _ref.read(audioServiceProvider).cancelRecording();
    state = const HomeSearchState();
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  SearchIntent _applyConfidenceGate(SearchIntent intent) {
    final confidence = intent.confidence ?? 1.0;

    if (confidence < _lowConfidenceThreshold) {
      AppLogger.warning(
          'HomeSearchController: low confidence '
          '(${confidence.toStringAsFixed(2)} < $_lowConfidenceThreshold) — '
          'clearing profession, falling back to all nearby workers');
      return intent.copyWith(profession: null);
    }

    if (confidence < _highConfidenceThreshold) {
      AppLogger.info(
          'HomeSearchController: mid confidence '
          '(${confidence.toStringAsFixed(2)}) — '
          'using intent but monitoring recommended');
    }

    return intent;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BUG 4 FIX C — _mapErrorCode()
  //
  // AVANT :
  //   alreadyProcessing tombait dans `default` → HomeSearchErrorType.network
  //   → UI affichait "Erreur de recherche" quand une requête était déjà en cours.
  //
  // APRÈS :
  //   alreadyProcessing → HomeSearchErrorType.timeout
  //   → UI affiche "Veuillez patienter…" (message timeout), ce qui est
  //   sémantiquement correct : l'utilisateur doit attendre la fin de la
  //   requête en cours avant d'en lancer une nouvelle.
  // ─────────────────────────────────────────────────────────────────────────
  HomeSearchErrorType _mapErrorCode(AiExtractorErrorCode code) {
    switch (code) {
      case AiExtractorErrorCode.quotaExceeded:
        return HomeSearchErrorType.quotaExceeded;
      case AiExtractorErrorCode.modelOverloaded:
        return HomeSearchErrorType.modelOverloaded;
      case AiExtractorErrorCode.timeout:
        return HomeSearchErrorType.timeout;
      case AiExtractorErrorCode.alreadyProcessing:
        // BUG 4 FIX C : traiter comme timeout — l'UI affiche "Veuillez patienter"
        // plutôt que "Erreur de recherche" qui est trompeur pour l'utilisateur.
        return HomeSearchErrorType.timeout;
      default:
        return HomeSearchErrorType.network;
    }
  }

  Future<List<GeoSearchResult<WorkerModel>>> _search(
      SearchIntent intent) async {
    final homeState = _ref.read(homeControllerProvider);
    final userLoc   = homeState.userLocation;
    final maxRadius =
        intent.maxRadiusKm ?? AppConstants.defaultSearchRadiusKm;

    if (userLoc == null) {
      return _buildFallbackResults(intent, homeState);
    }

    final gridService = _ref.read(geographicGridServiceProvider);
    final wilayaCode  = gridService.getWilayaCodeFromCoordinates(
      userLoc.latitude,
      userLoc.longitude,
    );

    if (intent.profession == null) {
      return _buildFallbackResults(intent, homeState);
    }

    if (wilayaCode != null) {
      try {
        final searchService = _ref.read(smartSearchServiceProvider);
        return await searchService.searchWorkers(
          userLat:        userLoc.latitude,
          userLng:        userLoc.longitude,
          userWilayaCode: wilayaCode,
          serviceType:    intent.profession!,
          maxResults:     20,
          maxRadius:      maxRadius,
        );
      } catch (e) {
        AppLogger.warning(
            'HomeSearchController: SmartSearch failed, falling back. $e');
      }
    }

    return _buildFallbackResults(intent, homeState);
  }

  List<GeoSearchResult<WorkerModel>> _buildFallbackResults(
    SearchIntent intent,
    HomeState    homeState,
  ) {
    final userLoc = homeState.userLocation;
    final workers = intent.profession == null
        ? homeState.nearbyWorkers
        : homeState.nearbyWorkers
            .where((w) => w.profession == intent.profession)
            .toList();

    return workers.map((w) {
      final distance = userLoc != null
          ? w.distanceTo(userLoc.latitude, userLoc.longitude)
          : 0.0;
      return GeoSearchResult<WorkerModel>(
        data:       w,
        distance:   distance,
        cellId:     w.cellId     ?? '',
        wilayaCode: w.wilayaCode ?? 0,
        source:     SearchResultSource.currentCell,
      );
    }).toList()
      ..sort((a, b) => a.distance.compareTo(b.distance));
  }

  @override
  void dispose() {
    _ref.read(audioServiceProvider).cancelRecording();
    super.dispose();
  }
}

// ============================================================================
// PROVIDER
// ============================================================================

final homeSearchControllerProvider =
    StateNotifierProvider.autoDispose<HomeSearchController, HomeSearchState>(
        (ref) => HomeSearchController(ref));
