// lib/services/geographic_grid_service_interface.dart
//
// Thin interface extracted from GeographicGridService so that
// AiChatService can call it without a circular import.

import '../models/geographic_cell.dart';

abstract class GeographicGridServiceInterface {
  int? getWilayaCodeFromCoordinates(double lat, double lng);
  Future<GeographicCell?> getCellForLocation(double lat, double lng, int wilayaCode);
}
