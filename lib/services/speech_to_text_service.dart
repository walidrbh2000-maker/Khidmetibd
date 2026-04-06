// lib/services/speech_to_text_service.dart

import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

typedef SttResultCallback = void Function(String text, bool isFinal);

class SpeechToTextService {
  final SpeechToText _stt = SpeechToText();
  bool _isInitialized = false;

  bool get isListening    => _stt.isListening;
  bool get isAvailable    => _stt.isAvailable;
  bool get isInitialized  => _isInitialized;

  // --------------------------------------------------------------------------
  // Init
  // --------------------------------------------------------------------------

  Future<bool> initialize() async {
    if (_isInitialized) return true;
    try {
      _isInitialized = await _stt.initialize(
        onError:  (e) => debugPrint('[STT] Error: ${e.errorMsg}'),
        onStatus: (s) => debugPrint('[STT] Status: $s'),
        debugLogging: kDebugMode,
      );
      return _isInitialized;
    } catch (e) {
      debugPrint('[STT] Initialize failed: $e');
      return false;
    }
  }

  // --------------------------------------------------------------------------
  // Listen / Stop
  // --------------------------------------------------------------------------

  Future<void> startListening({
    required SttResultCallback onResult,
    String localeId = 'fr_FR',
  }) async {
    if (!_isInitialized) {
      final ok = await initialize();
      if (!ok) return;
    }
    if (_stt.isListening) await stopListening();

    await _stt.listen(
      onResult: (SpeechRecognitionResult result) {
        // FIX: guard against premature final results — require at least
        // 2 words before treating a result as final.
        final words     = result.recognizedWords.trim().split(' ')
            .where((w) => w.isNotEmpty)
            .toList();
        final hasEnough = words.length >= 2;
        onResult(result.recognizedWords, result.finalResult && hasEnough);
      },
      localeId:       localeId,
      listenFor:      const Duration(seconds: 30),
      pauseFor:       const Duration(seconds: 5),
      partialResults: true,
      cancelOnError:  true,
    );
  }

  // FIX [3/3 — stopListening]: Added try/catch around _stt.stop().
  // The speech_to_text plugin can throw a PlatformException on some Android
  // devices when stop() is called in a state where the platform channel is
  // already torn down (e.g. app goes to background mid-utterance). Without
  // this guard the exception propagated unhandled through HomeSearchController
  // .stopListening(), bypassing the recording-failed error state and leaving
  // the controller frozen in HomeSearchStatus.listening with no recovery path.
  Future<void> stopListening() async {
    if (!_stt.isListening) return;
    try {
      await _stt.stop();
    } catch (e) {
      debugPrint('[STT] stopListening error: $e');
    }
  }

  // FIX [3/3 — cancelListening]: Added try/catch around _stt.cancel()
  // for the same reason as stopListening(). cancelListening() is called
  // from HomeSearchController.reset() and dispose(), both of which may fire
  // during widget disposal — a point where the platform channel can already
  // be in an unstable state on some devices.
  Future<void> cancelListening() async {
    if (!_stt.isListening) return;
    try {
      await _stt.cancel();
    } catch (e) {
      debugPrint('[STT] cancelListening error: $e');
    }
  }

  void dispose() {
    _stt.cancel();
  }
}
