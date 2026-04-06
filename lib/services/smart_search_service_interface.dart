// lib/services/smart_search_service_interface.dart
//
// GeoSearchResult<T> is defined in lib/models/search_result_model.dart.
// This interface re-exports it so AiChatService only imports one file.

import '../models/search_result_model.dart';
import '../models/worker_model.dart';

export '../models/search_result_model.dart' show GeoSearchResult;

abstract class SmartSearchServiceInterface {
  Future<List<GeoSearchResult<WorkerModel>>> searchWorkers({
    required double userLat,
    required double userLng,
    required int userWilayaCode,
    required String serviceType,
    int maxResults,
    double maxRadius,
  });
}
