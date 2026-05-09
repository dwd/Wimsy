class AvatarMetadata {
  AvatarMetadata({
    required this.hash,
    required this.mimeType,
    required this.bytes,
    required this.updatedAt,
  });

  /// Sentinel hash used to mark a JID as having no PEP user avatar
  /// (typically: server replied with `<error code="404"><item-not-found/>`).
  ///
  /// Persisted via `StorageService` so we don't refetch on every restart.
  /// See R3.3 in `doc/startup-fetch-review.md`.
  static const String noPepAvatarHash = '__no_pep_avatar__';

  /// Construct a sentinel marking [bareJid] as having no PEP avatar.
  /// `bareJid` is unused inside the entry itself, but kept in the
  /// signature for call-site readability.
  factory AvatarMetadata.noPepAvatar({DateTime? updatedAt}) {
    return AvatarMetadata(
      hash: noPepAvatarHash,
      mimeType: 'application/x-no-avatar',
      bytes: -1,
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }

  final String hash;
  final String mimeType;
  final int bytes;
  final DateTime updatedAt;

  /// True when this entry is the "no PEP avatar" sentinel produced by
  /// [AvatarMetadata.noPepAvatar]. Callers should treat such entries as a
  /// negative cache: skip both the metadata IQ and the data IQ.
  bool get isNoPepAvatar => hash == noPepAvatarHash;

  Map<String, dynamic> toMap() {
    return {
      'hash': hash,
      'mimeType': mimeType,
      'bytes': bytes,
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  static AvatarMetadata? fromMap(Map<String, dynamic>? map) {
    if (map == null) {
      return null;
    }
    final hash = map['hash']?.toString() ?? '';
    final mimeType = map['mimeType']?.toString() ?? '';
    final bytesRaw = map['bytes'];
    final updatedRaw = map['updatedAt']?.toString() ?? '';
    final bytes = bytesRaw is int
        ? bytesRaw
        : int.tryParse(bytesRaw?.toString() ?? '') ?? 0;
    final updatedAt = DateTime.tryParse(updatedRaw);
    if (updatedAt == null) {
      return null;
    }
    // Sentinel entry: round-trip even though bytes==-1 / mimeType is the
    // sentinel value. See [AvatarMetadata.noPepAvatar].
    if (hash == noPepAvatarHash) {
      return AvatarMetadata(
        hash: hash,
        mimeType: mimeType,
        bytes: bytes,
        updatedAt: updatedAt,
      );
    }
    if (hash.isEmpty || mimeType.isEmpty || bytes == 0) {
      return null;
    }
    return AvatarMetadata(
      hash: hash,
      mimeType: mimeType,
      bytes: bytes,
      updatedAt: updatedAt,
    );
  }
}
