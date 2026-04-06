// lib/services/wilaya_manager_interface.dart

import '../models/wilaya_model.dart';

abstract class WilayaManagerInterface {
  WilayaModel? findWilayaByName(String name);
  List<WilayaModel> getWilayasByRegion(String region);
  List<WilayaModel> getNeighboringWilayas(int code);
  List<WilayaModel> getAllWilayas();
}
