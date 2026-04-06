// lib/models/search_intent.dart

import 'package:equatable/equatable.dart';

/// Structured search parameters extracted from user input by the AI
/// Intent Extractor. This is the single data contract between the AI
/// layer and the geographic search layer.
class SearchIntent extends Equatable {
  /// Canonical profession key matching AppTheme.getProfessionIcon / Firebase.
  /// One of: plumber, electrician, cleaner, painter, carpenter, gardener,
  /// ac_repair, appliance_repair, mason, mechanic, mover.
  /// Null when no specific profession could be determined.
  final String? profession;

  /// True when the problem sounds like an emergency (flooding, power outage,
  /// gas leak, broken lock, etc.).
  final bool isUrgent;

  /// Concise English description of the extracted problem (max ~120 chars).
  final String? problemDescription;

  /// Optional search radius override from the user's explicit request.
  /// Null means use AppConstants.defaultSearchRadiusKm.
  final double? maxRadiusKm;

  /// AI confidence in the profession match (0.0 – 1.0).
  final double confidence;

  const SearchIntent({
    this.profession,
    this.isUrgent           = false,
    this.problemDescription,
    this.maxRadiusKm,
    this.confidence         = 0.0,
  });

  // ── Valid profession whitelist ─────────────────────────────────────────────

  static const Set<String> validProfessions = {
    'plumber', 'electrician', 'cleaner', 'painter', 'carpenter',
    'gardener', 'ac_repair', 'appliance_repair', 'mason', 'mechanic', 'mover',
  };

  // ── Deserialization ────────────────────────────────────────────────────────

  factory SearchIntent.fromJson(Map<String, dynamic> json) {
    final raw = json['profession'] as String?;
    return SearchIntent(
      profession:          (raw != null && validProfessions.contains(raw)) ? raw : null,
      isUrgent:            (json['is_urgent']            as bool?)   ?? false,
      problemDescription:  json['problem_description']  as String?,
      maxRadiusKm:         (json['max_radius_km']        as num?)?.toDouble(),
      confidence:          (json['confidence']           as num?)?.toDouble() ?? 0.0,
    );
  }

  Map<String, dynamic> toJson() => {
    'profession':          profession,
    'is_urgent':           isUrgent,
    'problem_description': problemDescription,
    'max_radius_km':       maxRadiusKm,
    'confidence':          confidence,
  };

  // ── copyWith ───────────────────────────────────────────────────────────────

  SearchIntent copyWith({
    String? profession,
    bool?   isUrgent,
    String? problemDescription,
    double? maxRadiusKm,
    double? confidence,
    bool    clearProfession = false,
  }) {
    return SearchIntent(
      profession:          clearProfession ? null : (profession ?? this.profession),
      isUrgent:            isUrgent            ?? this.isUrgent,
      problemDescription:  problemDescription  ?? this.problemDescription,
      maxRadiusKm:         maxRadiusKm         ?? this.maxRadiusKm,
      confidence:          confidence           ?? this.confidence,
    );
  }

  @override
  List<Object?> get props =>
      [profession, isUrgent, problemDescription, maxRadiusKm, confidence];
}