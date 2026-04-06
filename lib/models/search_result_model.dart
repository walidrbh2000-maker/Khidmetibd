// lib/models/search_result_model.dart

import 'package:equatable/equatable.dart';

/// Résultat enrichi de recherche géographique
class GeoSearchResult<T> extends Equatable {
  final T data;
  final double distance; // Distance en km
  final String cellId;
  final int wilayaCode;
  final SearchResultSource source;

  const GeoSearchResult({
    required this.data,
    required this.distance,
    required this.cellId,
    required this.wilayaCode,
    required this.source,
  });

  GeoSearchResult<T> copyWith({
    T? data,
    double? distance,
    String? cellId,
    int? wilayaCode,
    SearchResultSource? source,
  }) {
    return GeoSearchResult<T>(
      data: data ?? this.data,
      distance: distance ?? this.distance,
      cellId: cellId ?? this.cellId,
      wilayaCode: wilayaCode ?? this.wilayaCode,
      source: source ?? this.source,
    );
  }

  @override
  List<Object?> get props => [
        data,
        distance,
        cellId,
        wilayaCode,
        source,
      ];
}

enum SearchResultSource {
  currentCell,      // Cellule actuelle
  adjacentCell,     // Cellule adjacente
  sameWilaya,       // Même wilaya
  neighboringWilaya // Wilaya voisine
}
