// lib/models/map_bounds.dart

import 'package:equatable/equatable.dart';
import 'package:latlong2/latlong.dart';

class MapBounds extends Equatable {
  final LatLng center;
  final double zoom;

  const MapBounds({
    required this.center,
    required this.zoom,
  });

  MapBounds copyWith({
    LatLng? center,
    double? zoom,
  }) {
    return MapBounds(
      center: center ?? this.center,
      zoom: zoom ?? this.zoom,
    );
  }

  @override
  List<Object?> get props => [center, zoom];
}
