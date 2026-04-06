// lib/models/user_model.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:equatable/equatable.dart';

const _kUndefined = Object();

class UserModel extends Equatable {
  final String id;
  final String name;
  final String email;
  final String phoneNumber;
  final double? latitude;
  final double? longitude;
  final DateTime lastUpdated;
  final String? profileImageUrl;

  final String? cellId;
  final int? wilayaCode;
  final String? geoHash;

  // FIX (Backend Audit): fcmToken was updated in Firestore via
  // updateFcmToken() but never mapped back from the document. Any service
  // that read the UserModel to get the FCM token would silently receive null.
  final String? fcmToken;

  const UserModel({
    required this.id,
    required this.name,
    required this.email,
    required this.phoneNumber,
    this.latitude,
    this.longitude,
    required this.lastUpdated,
    this.profileImageUrl,
    this.cellId,
    this.wilayaCode,
    this.geoHash,
    this.fcmToken,
  });

  factory UserModel.fromMap(Map<String, dynamic> map, String id) {
    return UserModel(
      id: id,
      name: map['name'] as String? ?? '',
      email: map['email'] as String? ?? '',
      phoneNumber: map['phoneNumber'] as String? ?? '',
      latitude: (map['latitude'] as num?)?.toDouble(),
      longitude: (map['longitude'] as num?)?.toDouble(),
      lastUpdated:
          (map['lastUpdated'] as Timestamp?)?.toDate() ?? DateTime.now(),
      profileImageUrl: map['profileImageUrl'] as String?,
      cellId: map['cellId'] as String?,
      wilayaCode: map['wilayaCode'] as int?,
      geoHash: map['geoHash'] as String?,
      fcmToken: map['fcmToken'] as String?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'email': email,
      'phoneNumber': phoneNumber,
      'latitude': latitude,
      'longitude': longitude,
      'lastUpdated': Timestamp.fromDate(lastUpdated),
      'profileImageUrl': profileImageUrl,
      'cellId': cellId,
      'wilayaCode': wilayaCode,
      'geoHash': geoHash,
      'fcmToken': fcmToken,
    };
  }

  // Sentinel pattern: pass null explicitly to clear a nullable field,
  // omit the param entirely to keep the existing value.
  UserModel copyWith({
    String? id,
    String? name,
    String? email,
    String? phoneNumber,
    Object? latitude         = _kUndefined,
    Object? longitude        = _kUndefined,
    DateTime? lastUpdated,
    Object? profileImageUrl  = _kUndefined,
    Object? cellId           = _kUndefined,
    Object? wilayaCode       = _kUndefined,
    Object? geoHash          = _kUndefined,
    Object? fcmToken         = _kUndefined,
  }) {
    return UserModel(
      id:          id          ?? this.id,
      name:        name        ?? this.name,
      email:       email       ?? this.email,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      latitude: identical(latitude, _kUndefined)
          ? this.latitude
          : latitude as double?,
      longitude: identical(longitude, _kUndefined)
          ? this.longitude
          : longitude as double?,
      lastUpdated: lastUpdated ?? this.lastUpdated,
      profileImageUrl: identical(profileImageUrl, _kUndefined)
          ? this.profileImageUrl
          : profileImageUrl as String?,
      cellId: identical(cellId, _kUndefined)
          ? this.cellId
          : cellId as String?,
      wilayaCode: identical(wilayaCode, _kUndefined)
          ? this.wilayaCode
          : wilayaCode as int?,
      geoHash: identical(geoHash, _kUndefined)
          ? this.geoHash
          : geoHash as String?,
      fcmToken: identical(fcmToken, _kUndefined)
          ? this.fcmToken
          : fcmToken as String?,
    );
  }

  @override
  List<Object?> get props => [
        id,
        name,
        email,
        phoneNumber,
        latitude,
        longitude,
        lastUpdated,
        profileImageUrl,
        cellId,
        wilayaCode,
        geoHash,
        fcmToken,
      ];
}
