import 'package:better_player/src/hls/hls_parser/variant_info.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart'; // ✅ use this instead of rendering

class HlsTrackMetadataEntry {
  HlsTrackMetadataEntry({this.groupId, this.name, this.variantInfos});

  /// The GROUP-ID value of this track, if the track is derived from an EXT-X-MEDIA tag.
  /// Null if the track is not derived from an EXT-X-MEDIA TAG.
  final String? groupId;

  /// The NAME value of this track, if the track is derived from an EXT-X-MEDIA tag.
  /// Null if the track is not derived from an EXT-X-MEDIA TAG.
  final String? name;

  /// The EXT-X-STREAM-INF tag attributes associated with this track.
  /// Empty if this track is derived from an EXT-X-MEDIA tag.
  final List<VariantInfo>? variantInfos;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is HlsTrackMetadataEntry &&
        other.groupId == groupId &&
        other.name == name &&
        const ListEquality<VariantInfo>().equals(other.variantInfos, variantInfos);
  }

  @override
  int get hashCode => Object.hash(
        groupId,
        name,
        const ListEquality<VariantInfo>().hash(variantInfos),
      );
}
