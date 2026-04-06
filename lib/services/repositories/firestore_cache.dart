// lib/services/repositories/firestore_cache.dart

import 'dart:collection' show LinkedHashMap;
import 'package:flutter/foundation.dart';

// ============================================================================
// CACHED ITEM
// ============================================================================

class _CachedItem<T> {
  final T item;
  final DateTime cachedAt;

  _CachedItem(this.item) : cachedAt = DateTime.now();

  bool isExpired(Duration ttl) =>
      DateTime.now().difference(cachedAt) > ttl;
}

// ============================================================================
// CACHE
// ============================================================================

/// In-memory TTL cache backed by a [LinkedHashMap].
///
/// FIX (A6): replaced `Map<String, _CachedItem<T>>` with [LinkedHashMap]
/// preserving insertion order. This makes _evictOldest() O(1) — simply
/// remove the first key — instead of the previous O(n) full scan on every
/// cache-full write.
///
/// Eviction strategy: insertion-order LRU (oldest inserted entry first).
/// Access does not promote an entry; use [touch] if you need true LRU.
/// For a read-heavy cache where recency-of-write is a better TTL proxy
/// than recency-of-read (the common case here), insertion order is correct.
class FirestoreCache<T> {
  final Duration ttl;
  final int maxSize;
  final String _tag;

  // FIX (A6): LinkedHashMap preserves insertion order, enabling O(1) oldest
  // entry removal via _store.keys.first without a full scan.
  final LinkedHashMap<String, _CachedItem<T>> _store =
      LinkedHashMap<String, _CachedItem<T>>();

  FirestoreCache({
    required this.ttl,
    required this.maxSize,
    required String tag,
  }) : _tag = tag;

  // --------------------------------------------------------------------------
  // Read
  // --------------------------------------------------------------------------

  T? get(String key) {
    final item = _store[key];
    if (item == null) return null;
    if (item.isExpired(ttl)) {
      _store.remove(key);
      return null;
    }
    return item.item;
  }

  // --------------------------------------------------------------------------
  // Write
  // --------------------------------------------------------------------------

  void set(String key, T value) {
    // Remove first so a re-insert moves the key to the end (newest position).
    // This keeps insertion order accurate when updating an existing entry.
    _store.remove(key);
    if (_store.length >= maxSize) _evictOldest();
    _store[key] = _CachedItem(value);
  }

  void update(String key, T Function(T existing) updater) {
    final existing = _store[key];
    if (existing != null) {
      // Keep key at its current position — do not promote on update.
      _store[key] = _CachedItem(updater(existing.item));
    }
  }

  // --------------------------------------------------------------------------
  // Cleanup
  // --------------------------------------------------------------------------

  void cleanExpired() {
    _store.removeWhere((_, v) => v.isExpired(ttl));
    if (_store.length > maxSize) _store.clear();
    if (kDebugMode) {
      debugPrint('$_tag Cache cleaned — ${_store.length} entries remaining');
    }
  }

  void clear() => _store.clear();

  int get length => _store.length;

  // --------------------------------------------------------------------------
  // Private
  // --------------------------------------------------------------------------

  /// O(1) eviction — removes the oldest-inserted entry.
  ///
  /// FIX (A6): the previous implementation iterated all entries to find the
  /// minimum cachedAt timestamp — O(n) on every cache-full write. With a
  /// LinkedHashMap the oldest entry is always first; removal is O(1).
  void _evictOldest() {
    if (_store.isEmpty) return;
    // LinkedHashMap.keys.first is the oldest inserted key — O(1).
    _store.remove(_store.keys.first);
  }
}
