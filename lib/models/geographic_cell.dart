// lib/models/geographic_cell.dart

import 'package:equatable/equatable.dart';

/// Représente une cellule géographique dans le système de grille
class GeographicCell extends Equatable {
  final String id; // Format: "wilaya_latitude_longitude"
  final int wilayaCode;
  final double centerLat;
  final double centerLng;
  final double radius; // en km
  final List<String> adjacentCellIds;

  const GeographicCell({
    required this.id,
    required this.wilayaCode,
    required this.centerLat,
    required this.centerLng,
    required this.radius,
    this.adjacentCellIds = const [],
  });

  factory GeographicCell.fromMap(Map<String, dynamic> map) {
    return GeographicCell(
      id: map['id'] as String? ?? '',
      wilayaCode: map['wilayaCode'] as int? ?? 0,
      centerLat: (map['centerLat'] as num?)?.toDouble() ?? 0.0,
      centerLng: (map['centerLng'] as num?)?.toDouble() ?? 0.0,
      radius: (map['radius'] as num?)?.toDouble() ?? 5.0,
      adjacentCellIds: List<String>.from(map['adjacentCellIds'] as List? ?? []),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'wilayaCode': wilayaCode,
      'centerLat': centerLat,
      'centerLng': centerLng,
      'radius': radius,
      'adjacentCellIds': adjacentCellIds,
    };
  }

  GeographicCell copyWith({
    String? id,
    int? wilayaCode,
    double? centerLat,
    double? centerLng,
    double? radius,
    List<String>? adjacentCellIds,
  }) {
    return GeographicCell(
      id: id ?? this.id,
      wilayaCode: wilayaCode ?? this.wilayaCode,
      centerLat: centerLat ?? this.centerLat,
      centerLng: centerLng ?? this.centerLng,
      radius: radius ?? this.radius,
      adjacentCellIds: adjacentCellIds ?? this.adjacentCellIds,
    );
  }

  @override
  List<Object?> get props => [
        id,
        wilayaCode,
        centerLat,
        centerLng,
        radius,
        adjacentCellIds,
      ];
}
