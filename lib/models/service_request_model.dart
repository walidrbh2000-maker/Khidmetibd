// lib/models/service_request_model.dart
//
// @Deprecated — use ServiceRequestEnhancedModel for all new code.
//
// This is the original push-model request with a plain String status field.
// It predates the Hybrid Bid Model migration and is kept only to avoid
// breaking any code that still imports it. New screens, controllers, and
// services MUST use ServiceRequestEnhancedModel.
//
// Planned removal: after all consumers have been migrated and verified in
// production, this file will be deleted.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:equatable/equatable.dart';

@Deprecated(
  'Use ServiceRequestEnhancedModel. '
  'ServiceRequestModel predates the Hybrid Bid Model and will be deleted '
  'after full consumer migration.',
)
class ServiceRequestModel extends Equatable {
  final String id;
  final String userId;
  final String workerId;
  final String serviceType;
  final String status; // pending, accepted, declined, completed
  final double userLatitude;
  final double userLongitude;
  final String userAddress;
  final String? description;
  final DateTime createdAt;
  final DateTime? acceptedAt;
  final DateTime? completedAt;

  const ServiceRequestModel({
    required this.id,
    required this.userId,
    required this.workerId,
    required this.serviceType,
    required this.status,
    required this.userLatitude,
    required this.userLongitude,
    required this.userAddress,
    this.description,
    required this.createdAt,
    this.acceptedAt,
    this.completedAt,
  });

  factory ServiceRequestModel.fromMap(Map<String, dynamic> map, String id) {
    return ServiceRequestModel(
      id: id,
      userId: map['userId'] as String? ?? '',
      workerId: map['workerId'] as String? ?? '',
      serviceType: map['serviceType'] as String? ?? '',
      status: map['status'] as String? ?? 'pending',
      userLatitude: (map['userLatitude'] as num?)?.toDouble() ?? 0.0,
      userLongitude: (map['userLongitude'] as num?)?.toDouble() ?? 0.0,
      userAddress: map['userAddress'] as String? ?? '',
      description: map['description'] as String?,
      createdAt: (map['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      acceptedAt: (map['acceptedAt'] as Timestamp?)?.toDate(),
      completedAt: (map['completedAt'] as Timestamp?)?.toDate(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'userId': userId,
      'workerId': workerId,
      'serviceType': serviceType,
      'status': status,
      'userLatitude': userLatitude,
      'userLongitude': userLongitude,
      'userAddress': userAddress,
      'description': description,
      'createdAt': Timestamp.fromDate(createdAt),
      'acceptedAt': acceptedAt != null ? Timestamp.fromDate(acceptedAt!) : null,
      'completedAt':
          completedAt != null ? Timestamp.fromDate(completedAt!) : null,
    };
  }

  ServiceRequestModel copyWith({
    String? id,
    String? userId,
    String? workerId,
    String? serviceType,
    String? status,
    double? userLatitude,
    double? userLongitude,
    String? userAddress,
    String? description,
    DateTime? createdAt,
    DateTime? acceptedAt,
    DateTime? completedAt,
  }) {
    return ServiceRequestModel(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      workerId: workerId ?? this.workerId,
      serviceType: serviceType ?? this.serviceType,
      status: status ?? this.status,
      userLatitude: userLatitude ?? this.userLatitude,
      userLongitude: userLongitude ?? this.userLongitude,
      userAddress: userAddress ?? this.userAddress,
      description: description ?? this.description,
      createdAt: createdAt ?? this.createdAt,
      acceptedAt: acceptedAt ?? this.acceptedAt,
      completedAt: completedAt ?? this.completedAt,
    );
  }

  @override
  List<Object?> get props => [
        id,
        userId,
        workerId,
        serviceType,
        status,
        userLatitude,
        userLongitude,
        userAddress,
        description,
        createdAt,
        acceptedAt,
        completedAt,
      ];
}
