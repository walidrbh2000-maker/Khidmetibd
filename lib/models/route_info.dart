// lib/models/route_info.dart

import 'package:equatable/equatable.dart';

class RouteInfo extends Equatable {
  final double distance; // en mètres
  final double duration; // en secondes

  const RouteInfo({
    required this.distance,
    required this.duration,
  });

  RouteInfo copyWith({
    double? distance,
    double? duration,
  }) {
    return RouteInfo(
      distance: distance ?? this.distance,
      duration: duration ?? this.duration,
    );
  }

  @override
  List<Object?> get props => [distance, duration];
}
