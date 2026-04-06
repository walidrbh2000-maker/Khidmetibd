// lib/models/search_context.dart

import 'package:equatable/equatable.dart';

/// Contexte de recherche pour optimisation
class SearchContext extends Equatable {
  final double userLat;
  final double userLng;
  final int userWilayaCode;
  final String currentCellId;
  final double maxRadius;
  final int maxResults;
  final Set<String> searchedCellIds;
  final Set<int> searchedWilayaCodes;

  // FIX (A1): Removed `const {}` defaults — const Sets are immutable and throw
  // UnsupportedError on .add(). Replaced with nullable parameters that default
  // to a fresh mutable Set in the initializer list. Callers that previously
  // relied on the const default get an empty mutable Set transparently.
  SearchContext({
    required this.userLat,
    required this.userLng,
    required this.userWilayaCode,
    required this.currentCellId,
    this.maxRadius = 50.0,
    this.maxResults = 20,
    Set<String>? searchedCellIds,
    Set<int>? searchedWilayaCodes,
  })  : searchedCellIds = searchedCellIds ?? {},
        searchedWilayaCodes = searchedWilayaCodes ?? {};

  // FIX (A1 follow-up): copyWith now passes Set.from() defensive copies so
  // the new SearchContext owns its own mutable Set, preventing aliasing bugs
  // where two contexts share the same Set instance and writes bleed across.
  SearchContext copyWith({
    double? userLat,
    double? userLng,
    int? userWilayaCode,
    String? currentCellId,
    double? maxRadius,
    int? maxResults,
    Set<String>? searchedCellIds,
    Set<int>? searchedWilayaCodes,
  }) {
    return SearchContext(
      userLat: userLat ?? this.userLat,
      userLng: userLng ?? this.userLng,
      userWilayaCode: userWilayaCode ?? this.userWilayaCode,
      currentCellId: currentCellId ?? this.currentCellId,
      maxRadius: maxRadius ?? this.maxRadius,
      maxResults: maxResults ?? this.maxResults,
      // Defensive copies — caller gets a fresh mutable Set, never an alias.
      searchedCellIds:
          searchedCellIds != null ? Set.from(searchedCellIds) : Set.from(this.searchedCellIds),
      searchedWilayaCodes:
          searchedWilayaCodes != null ? Set.from(searchedWilayaCodes) : Set.from(this.searchedWilayaCodes),
    );
  }

  @override
  List<Object?> get props => [
        userLat,
        userLng,
        userWilayaCode,
        currentCellId,
        maxRadius,
        maxResults,
        searchedCellIds,
        searchedWilayaCodes,
      ];
}
