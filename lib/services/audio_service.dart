// lib/services/audio_service.dart
//
// CHANGES:
//   • _formatBytes() private method removed — replaced with FileSizeFormatter.format()
//     from lib/utils/file_size_formatter.dart
//   • _logInfo / _logWarning / _logError replaced with AppLogger calls

import 'dart:io';
import 'dart:async';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';

import '../utils/file_size_formatter.dart'; // NEW
import '../utils/logger.dart';               // NEW (replaces private _log* methods)

class AudioServiceException implements Exception {
  final String  message;
  final String? code;
  final dynamic originalError;

  AudioServiceException(this.message, {this.code, this.originalError});

  @override
  String toString() =>
      'AudioServiceException: $message${code != null ? ' (Code: $code)' : ''}';
}

class AudioService {
  static const int      maxRecordingDurationMinutes = 10;
  static const int      maxFileSizeMB               = 50;
  static const int      minFileSizeBytes             = 1000;
  static const Duration uploadTimeout               = Duration(minutes: 5);
  static const Duration _periodicDurationInterval   = Duration(seconds: 1);
  static const Duration _recorderTimeout            = Duration(seconds: 10);

  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer   _player   = AudioPlayer();

  bool   _isRecording = false;
  bool   _isPlaying   = false;
  String? _currentRecordingPath;

  StreamSubscription<Duration>?    _durationSubscription;
  StreamSubscription<PlayerState>? _playerStateSubscription;

  final _recordingStateController   = StreamController<bool>.broadcast();
  final _playingStateController     = StreamController<bool>.broadcast();
  final _recordingDurationController = StreamController<Duration>.broadcast();

  bool           get isRecording        => _isRecording;
  bool           get isPlaying          => _isPlaying;
  Stream<bool>   get recordingStateStream  => _recordingStateController.stream;
  Stream<bool>   get playingStateStream    => _playingStateController.stream;
  Stream<Duration> get recordingDurationStream => _recordingDurationController.stream;

  Future<bool> hasAudioPermission() async {
    try {
      return await _recorder.hasPermission();
    } catch (e) {
      AppLogger.error('AudioService.hasAudioPermission', e);
      return false;
    }
  }

  Future<bool> requestAudioPermission() async {
    try {
      final hasPermission = await _recorder.hasPermission();
      if (!hasPermission) {
        throw AudioServiceException(
          'Permission audio refusée. Veuillez activer les permissions dans les paramètres.',
          code: 'PERMISSION_DENIED',
        );
      }
      return true;
    } catch (e) {
      AppLogger.error('AudioService.requestAudioPermission', e);
      if (e is AudioServiceException) rethrow;
      return false;
    }
  }

  Future<void> startRecording() async {
    if (_isRecording) {
      throw AudioServiceException('Un enregistrement est déjà en cours',
          code: 'ALREADY_RECORDING');
    }

    try {
      final hasPermission = await hasAudioPermission();
      if (!hasPermission) {
        throw AudioServiceException(
          'Permission microphone requise. Veuillez activer dans les paramètres.',
          code: 'PERMISSION_DENIED',
        );
      }

      await _checkStorageSpace();

      final recordingPath = await _generateRecordingPath();
      _currentRecordingPath = recordingPath;

      await _recorder.start(
        const RecordConfig(
          encoder:     AudioEncoder.aacLc,
          bitRate:     128000,
          sampleRate:  44100,
          numChannels: 1,
        ),
        path: recordingPath,
      ).timeout(_recorderTimeout);

      _setRecordingState(true);
      _startRecordingDurationTimer();
      AppLogger.info('Enregistrement démarré: $recordingPath');
    } catch (e) {
      _setRecordingState(false);
      _currentRecordingPath = null;
      AppLogger.error('AudioService.startRecording', e);
      if (e is AudioServiceException) rethrow;
      if (e is TimeoutException) {
        throw AudioServiceException(
          "Démarrage de l'enregistrement trop long",
          code: 'START_RECORDING_TIMEOUT',
          originalError: e,
        );
      }
      throw AudioServiceException(
        "Erreur lors du démarrage de l'enregistrement",
        code: 'START_RECORDING_FAILED',
        originalError: e,
      );
    }
  }

  Future<String?> stopRecording() async {
    if (!_isRecording) {
      AppLogger.warning('stopRecording appelé mais aucun enregistrement en cours');
      return null;
    }

    try {
      final path = await _recorder.stop()
          .timeout(_recorderTimeout);
      _setRecordingState(false);
      _durationSubscription?.cancel();

      if (path != null) {
        await _validateRecordingFile(path);
        final size = await _getFileSize(path);
        AppLogger.info('Enregistrement arrêté: $path ($size)');
        return path;
      }

      return null;
    } catch (e) {
      _setRecordingState(false);
      _durationSubscription?.cancel();
      AppLogger.error('AudioService.stopRecording', e);
      if (e is AudioServiceException) rethrow;
      if (e is TimeoutException) {
        throw AudioServiceException(
          "Arrêt de l'enregistrement trop long",
          code: 'STOP_RECORDING_TIMEOUT',
          originalError: e,
        );
      }
      throw AudioServiceException(
        "Erreur lors de l'arrêt de l'enregistrement",
        code:          'STOP_RECORDING_FAILED',
        originalError: e,
      );
    } finally {
      _currentRecordingPath = null;
    }
  }

  Future<void> cancelRecording() async {
    try {
      if (_isRecording) {
        await _recorder.stop();
        _setRecordingState(false);
        _durationSubscription?.cancel();
      }

      if (_currentRecordingPath != null) {
        await _deleteRecordingFile(_currentRecordingPath!);
        _currentRecordingPath = null;
      }
    } catch (e) {
      AppLogger.error('AudioService.cancelRecording', e);
    }
  }

  Future<void> playAudio(String url, {void Function()? onComplete}) async {
    if (url.trim().isEmpty) {
      throw AudioServiceException('URL audio vide', code: 'INVALID_URL');
    }

    try {
      if (_isPlaying) await stopAudio();

      final source = await _createAudioSource(url);
      await _player.play(source);
      _setPlayingState(true);
      _setupPlayerStateListener(onComplete);

      AppLogger.info('Lecture audio démarrée: $url');
    } catch (e) {
      _setPlayingState(false);
      AppLogger.error('AudioService.playAudio', e);
      if (e is AudioServiceException) rethrow;
      throw AudioServiceException('Erreur lors de la lecture audio',
          code: 'PLAY_AUDIO_FAILED', originalError: e);
    }
  }

  Future<void> stopAudio() async {
    try {
      await _player.stop();
      _setPlayingState(false);
      AppLogger.info('Lecture audio arrêtée');
    } catch (e) {
      _setPlayingState(false);
      AppLogger.error('AudioService.stopAudio', e);
    }
  }

  Future<void> pauseAudio() async {
    if (!_isPlaying) return;
    try {
      await _player.pause();
      _setPlayingState(false);
    } catch (e) {
      AppLogger.error('AudioService.pauseAudio', e);
    }
  }

  Future<void> resumeAudio() async {
    if (_isPlaying) return;
    try {
      await _player.resume();
      _setPlayingState(true);
    } catch (e) {
      AppLogger.error('AudioService.resumeAudio', e);
    }
  }

  Future<Duration?> getCurrentPosition() async {
    try {
      return await _player.getCurrentPosition();
    } catch (e) {
      AppLogger.error('AudioService.getCurrentPosition', e);
      return null;
    }
  }

  Future<Duration?> getDuration() async {
    try {
      return await _player.getDuration();
    } catch (e) {
      AppLogger.error('AudioService.getDuration', e);
      return null;
    }
  }

  Future<void> seek(Duration position) async {
    try {
      await _player.seek(position);
    } catch (e) {
      AppLogger.error('AudioService.seek', e);
    }
  }

  void _setRecordingState(bool isRecording) {
    _isRecording = isRecording;
    _recordingStateController.add(isRecording);
  }

  void _setPlayingState(bool isPlaying) {
    _isPlaying = isPlaying;
    _playingStateController.add(isPlaying);
  }

  Future<String> _generateRecordingPath() async {
    final directory = await getApplicationDocumentsDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return '${directory.path}/audio_$timestamp.m4a';
  }

  Future<void> _validateRecordingFile(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw AudioServiceException("Fichier d'enregistrement introuvable",
          code: 'FILE_NOT_FOUND');
    }

    final fileSize = await file.length();
    if (fileSize < minFileSizeBytes) {
      await file.delete();
      throw AudioServiceException('Enregistrement trop court ou invalide',
          code: 'INVALID_RECORDING');
    }

    final maxFileSizeBytes = maxFileSizeMB * 1024 * 1024;
    if (fileSize > maxFileSizeBytes) {
      await file.delete();
      throw AudioServiceException(
        'Enregistrement trop volumineux (max: ${maxFileSizeMB}MB)',
        code: 'FILE_TOO_LARGE',
      );
    }
  }

  Future<void> _deleteRecordingFile(String path) async {
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
      AppLogger.info('Enregistrement annulé et fichier supprimé');
    }
  }

  Future<Source> _createAudioSource(String url) async {
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return UrlSource(url);
    }
    final file = File(url);
    if (await file.exists()) return DeviceFileSource(url);
    throw AudioServiceException('Fichier audio introuvable',
        code: 'FILE_NOT_FOUND');
  }

  void _setupPlayerStateListener(void Function()? onComplete) {
    _playerStateSubscription?.cancel();
    _playerStateSubscription = _player.onPlayerStateChanged.listen((state) {
      if (state == PlayerState.completed) {
        _setPlayingState(false);
        onComplete?.call();
      }
    });
  }

  void _startRecordingDurationTimer() {
    _durationSubscription?.cancel();

    _durationSubscription = Stream.periodic(
      _periodicDurationInterval,
      (tick) => Duration(seconds: tick + 1),
    ).listen((duration) {
      _recordingDurationController.add(duration);

      if (duration.inMinutes >= maxRecordingDurationMinutes) {
        AppLogger.warning('Durée maximale atteinte, arrêt automatique');
        stopRecording().catchError((Object e) {
          AppLogger.error('AudioService.auto-stop-timer', e);
        });
      }
    });
  }

  Future<void> _checkStorageSpace() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      if (!await directory.exists()) {
        throw AudioServiceException('Répertoire de stockage inaccessible',
            code: 'STORAGE_UNAVAILABLE');
      }
    } catch (e) {
      AppLogger.warning('Could not verify storage space: $e');
    }
  }

  Future<String> _getFileSize(String path) async {
    try {
      final file  = File(path);
      final bytes = await file.length();
      // REPLACED: _formatBytes(bytes) → FileSizeFormatter.format(bytes)
      return FileSizeFormatter.format(bytes);
    } catch (e) {
      return 'unknown';
    }
  }

  Future<void> dispose() async {
    await _durationSubscription?.cancel();
    await _playerStateSubscription?.cancel();
    await _player.dispose();
    await _recorder.dispose();
    await _recordingStateController.close();
    await _playingStateController.close();
    await _recordingDurationController.close();
  }
}
