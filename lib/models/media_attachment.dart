// lib/models/media_attachment.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:equatable/equatable.dart';
import 'message_enums.dart';

class MediaAttachment extends Equatable {
  final String id;
  final String url;
  final String localPath;
  final MediaType type;
  final DateTime uploadedAt;
  final int? fileSize; // en bytes

  const MediaAttachment({
    required this.id,
    required this.url,
    required this.localPath,
    required this.type,
    required this.uploadedAt,
    this.fileSize,
  });

  factory MediaAttachment.fromMap(Map<String, dynamic> map) {
    return MediaAttachment(
      id: map['id'] as String? ?? '',
      url: map['url'] as String? ?? '',
      localPath: map['localPath'] as String? ?? '',
      // FIX (QA P1): supports both legacy format ('MediaType.image' from
      // toString()) and new short format ('image' from .name). The short format
      // is written by toMap() going forward. All new documents use .name;
      // existing documents are transparently migrated on first read.
      type: MediaType.values.firstWhere(
        (e) => e.name == map['type'] || e.toString() == map['type'],
        orElse: () => MediaType.image,
      ),
      uploadedAt:
          (map['uploadedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      fileSize: map['fileSize'] as int?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'url': url,
      'localPath': localPath,
      // FIX (QA P1): use .name instead of .toString() so Firestore stores
      // 'image' rather than 'MediaType.image'. Robust to class renames.
      'type': type.name,
      'uploadedAt': Timestamp.fromDate(uploadedAt),
      'fileSize': fileSize,
    };
  }

  MediaAttachment copyWith({
    String? id,
    String? url,
    String? localPath,
    MediaType? type,
    DateTime? uploadedAt,
    int? fileSize,
  }) {
    return MediaAttachment(
      id: id ?? this.id,
      url: url ?? this.url,
      localPath: localPath ?? this.localPath,
      type: type ?? this.type,
      uploadedAt: uploadedAt ?? this.uploadedAt,
      fileSize: fileSize ?? this.fileSize,
    );
  }

  @override
  List<Object?> get props => [
        id,
        url,
        localPath,
        type,
        uploadedAt,
        fileSize,
      ];
}
