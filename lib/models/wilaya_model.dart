// lib/models/wilaya_model.dart

import 'package:equatable/equatable.dart';

/// Modèle représentant une wilaya algérienne
class WilayaModel extends Equatable {
  final int code;
  final String name;
  final String arabicName;
  final double centerLat;
  final double centerLng;
  final List<int> neighboringWilayas;

  const WilayaModel({
    required this.code,
    required this.name,
    required this.arabicName,
    required this.centerLat,
    required this.centerLng,
    required this.neighboringWilayas,
  });

  factory WilayaModel.fromMap(Map<String, dynamic> map) {
    return WilayaModel(
      code: map['code'] as int? ?? 0,
      name: map['name'] as String? ?? '',
      arabicName: map['arabicName'] as String? ?? '',
      centerLat: (map['centerLat'] as num?)?.toDouble() ?? 0.0,
      centerLng: (map['centerLng'] as num?)?.toDouble() ?? 0.0,
      neighboringWilayas:
          List<int>.from(map['neighboringWilayas'] as List? ?? []),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'code': code,
      'name': name,
      'arabicName': arabicName,
      'centerLat': centerLat,
      'centerLng': centerLng,
      'neighboringWilayas': neighboringWilayas,
    };
  }

  WilayaModel copyWith({
    int? code,
    String? name,
    String? arabicName,
    double? centerLat,
    double? centerLng,
    List<int>? neighboringWilayas,
  }) {
    return WilayaModel(
      code: code ?? this.code,
      name: name ?? this.name,
      arabicName: arabicName ?? this.arabicName,
      centerLat: centerLat ?? this.centerLat,
      centerLng: centerLng ?? this.centerLng,
      neighboringWilayas: neighboringWilayas ?? this.neighboringWilayas,
    );
  }

  @override
  List<Object?> get props => [
        code,
        name,
        arabicName,
        centerLat,
        centerLng,
        neighboringWilayas,
      ];
}
