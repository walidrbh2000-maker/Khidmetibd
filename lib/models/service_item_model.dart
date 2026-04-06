// lib/models/service_item_model.dart
//
// EXTRACTED FROM: service_selection_row.dart and service_selection_sheet.dart
// REASON: _ServiceItem was defined identically as a private class in both files.
//         Canonical public model eliminates duplication and makes the type
//         importable by any future screen that needs to work with service items.

import 'package:flutter/material.dart';

/// Data model representing a single selectable home-service type.
///
/// Used by [ServiceSelectionRow] (horizontal chip row) and
/// [ServiceSelectionSheet] (full-screen search + grid).
class ServiceItem {
  final String   type;
  final String   label;
  final IconData icon;

  const ServiceItem(this.type, this.label, this.icon);
}
