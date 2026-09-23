import 'dart:math';

/// Identity for stored rows, and the stable hashes the ledger de-duplicates on.
///
/// Two independent problems live here, and both are correctness problems
/// rather than conveniences:
///
/// * **Ids must sort by creation time.** Timeline paging is keyset paging on
///   `(bookingDate DESC, id DESC)`; if ids were random, two rows booked on the
///   same date would page in an arbitrary, unstable order.
/// * **Fingerprints must be stable across runs and across app versions.** The
///   same SMS arrives once live and again in the inbox backfill. The only
///   thing that stops the ledger doubling every number the user sees is a
///   fingerprint that hashes to the same value the second time.
///
/// [stableHash] is deliberately NOT a cryptographic hash and is never used as
/// one. It is a 64-bit FNV-1a computed in two 32-bit halves, so the value does
/// not depend on 64-bit integer overflow, and it never leaves the device.
abstract final class LedgerIds {
  /// Crockford base32: no `I`, `L`, `O` or `U`, so an id is safe to read out
  /// loud in a bug report and still sorts in byte order.
  static const String _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  static final Random _random = Random.secure();

  static int _lastMillis = -1;
  static int _counter = 0;

  /// A 26-character sortable id: 48 bits of millisecond time, 30 bits of
  /// per-millisecond counter, 50 bits of randomness.
  ///
  /// The counter is what makes a batch insert of 200 backfilled messages, all
  /// created inside the same millisecond, keep its order.
  static String generate({DateTime? now}) {
    final int ms = (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch;
    if (ms == _lastMillis) {
      _counter = (_counter + 1) & 0x3FFFFFFF;
    } else {
      _lastMillis = ms;
      _counter = 0;
    }
    final StringBuffer out = StringBuffer();
    _encodeInto(out, ms, 10);
    _encodeInto(out, _counter, 6);
    _encodeInto(out, _random.nextInt(1 << 25), 5);
    _encodeInto(out, _random.nextInt(1 << 25), 5);
    return out.toString();
  }

  /// A deterministic 16-hex-character digest of [input].
  ///
  /// Used for fingerprints and bill cycle keys. Same input, same output, on
  /// every device and every build - that property is the whole point.
  static String stableHash(String input) {
    final int a = _fnv1a(input, 0x811C9DC5);
    final int b = _fnv1a(input, 0x01000193);
    return _hex8(a) + _hex8(b);
  }

  /// Joins [parts] with a separator that cannot occur inside a part, so
  /// `['a', 'bc']` and `['ab', 'c']` never collide.
  static String hashParts(Iterable<Object?> parts) {
    final StringBuffer buf = StringBuffer();
    for (final Object? p in parts) {
      buf
        ..write(p == null ? '' : p.toString())
        ..writeCharCode(1);
    }
    return stableHash(buf.toString());
  }

  static void _encodeInto(StringBuffer out, int value, int chars) {
    int v = value;
    final List<String> tmp = List<String>.filled(chars, '0');
    for (int i = chars - 1; i >= 0; i--) {
      tmp[i] = _alphabet[v & 31];
      v = v >> 5;
    }
    for (final String c in tmp) {
      out.write(c);
    }
  }

  static int _fnv1a(String input, int offsetBasis) {
    int hash = offsetBasis & 0xFFFFFFFF;
    for (final int unit in input.codeUnits) {
      // Both bytes of every UTF-16 unit are hashed separately, so the digest
      // does not change if a string is later re-encoded.
      hash = _mix(hash, unit & 0xFF);
      hash = _mix(hash, (unit >> 8) & 0xFF);
    }
    return hash;
  }

  static int _mix(int hash, int byte) {
    int h = (hash ^ byte) & 0xFFFFFFFF;
    // h * 16777619, expanded into shifts so it stays inside 32 bits.
    h = (h +
            ((h << 1) & 0xFFFFFFFF) +
            ((h << 4) & 0xFFFFFFFF) +
            ((h << 7) & 0xFFFFFFFF) +
            ((h << 8) & 0xFFFFFFFF) +
            ((h << 24) & 0xFFFFFFFF)) &
        0xFFFFFFFF;
    return h;
  }

  static String _hex8(int value) =>
      (value & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
}
