import 'dart:typed_data';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

class SchemeData {
  SchemeData({
    this.licenseServerUrl,
    required this.mimeType,
    this.data,
    this.requiresSecureDecryption,
  });

  /// The URL of the server to which license requests should be made. May be null if unknown.
  final String? licenseServerUrl;

  /// The mimeType of [data].
  final String mimeType;

  /// The initialization base data.
  /// You should build pssh manually for use.
  final Uint8List? data;

  /// Whether secure decryption is required.
  final bool? requiresSecureDecryption;

  SchemeData copyWithData(Uint8List? newData) => SchemeData(
        licenseServerUrl: licenseServerUrl,
        mimeType: mimeType,
        data: newData,
        requiresSecureDecryption: requiresSecureDecryption,
      );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! SchemeData) return false;

    return other.mimeType == mimeType &&
        other.licenseServerUrl == licenseServerUrl &&
        other.requiresSecureDecryption == requiresSecureDecryption &&
        const ListEquality<int>().equals(other.data, data);
  }

  @override
  int get hashCode => Object.hash(
        licenseServerUrl,
        mimeType,
        requiresSecureDecryption,
        data == null ? null : Object.hashAll(data!),
      );
}
