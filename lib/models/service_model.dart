// lib/models/service_model.dart

import 'package:equatable/equatable.dart';
import 'package:flutter/material.dart';

class ServiceModel extends Equatable {
  final String name;
  final IconData icon;
  final Color color;

  const ServiceModel(
    this.name,
    this.icon,
    this.color,
  );

  ServiceModel copyWith({
    String? name,
    IconData? icon,
    Color? color,
  }) {
    return ServiceModel(
      name ?? this.name,
      icon ?? this.icon,
      color ?? this.color,
    );
  }

  @override
  List<Object?> get props => [name, icon, color];
}
