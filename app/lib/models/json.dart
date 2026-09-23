/// Tolerant JSON readers shared by every `fromJson` in `lib/models`.
///
/// They exist because three different producers feed these models - the
/// bundled `assets/rules/*.json`, the config server, and rows read back out of
/// drift - and a single unexpected `null` or a number arriving as a string
/// must never take the app down. Every reader is total: it returns a value or
/// the documented fallback, and never throws.
library;

/// `null` unless [v] is a non-empty string (after trimming).
String? jStringOrNull(Object? v) {
  if (v == null) return null;
  final s = v is String ? v : v.toString();
  final t = s.trim();
  return t.isEmpty ? null : t;
}

/// [fallback] unless [v] is a non-empty string (after trimming).
String jString(Object? v, {String fallback = ''}) => jStringOrNull(v) ?? fallback;

/// Accepts `int`, `double` (truncated) and numeric strings. `null` otherwise.
int? jIntOrNull(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is double) return v.isFinite ? v.toInt() : null;
  if (v is bool) return v ? 1 : 0;
  if (v is String) return int.tryParse(v.trim()) ?? double.tryParse(v.trim())?.toInt();
  return null;
}

int jInt(Object? v, {int fallback = 0}) => jIntOrNull(v) ?? fallback;

/// Accepts `num` and numeric strings. `null` otherwise.
double? jDoubleOrNull(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.trim());
  return null;
}

double jDouble(Object? v, {double fallback = 0}) => jDoubleOrNull(v) ?? fallback;

/// Accepts `bool`, `0`/`1` (drift stores booleans as ints) and the strings
/// `'true'`/`'false'`/`'1'`/`'0'`.
bool jBool(Object? v, {bool fallback = false}) {
  if (v == null) return fallback;
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) {
    final s = v.trim().toLowerCase();
    if (s == 'true' || s == '1' || s == 'yes') return true;
    if (s == 'false' || s == '0' || s == 'no') return false;
  }
  return fallback;
}

/// A `List<String>` with blanks dropped. Accepts a JSON list or a single
/// string. Always returns a new, unmodifiable-safe list.
List<String> jStringList(Object? v) {
  if (v == null) return const <String>[];
  if (v is String) {
    final s = v.trim();
    return s.isEmpty ? const <String>[] : <String>[s];
  }
  if (v is Iterable) {
    final out = <String>[];
    for (final e in v) {
      final s = jStringOrNull(e);
      if (s != null) out.add(s);
    }
    return out;
  }
  return const <String>[];
}

/// Accepts epoch milliseconds (int) or an ISO-8601 string.
///
/// ALWAYS returns a UTC [DateTime], to match [jMillis]. This is not cosmetic:
/// Dart's `DateTime ==` compares `isUtc` as well as the instant, so a model
/// read back from JSON would otherwise never equal the one that was written,
/// and every round-trip test would fail for no visible reason.
///
/// Convert with `.toLocal()` at the point of DISPLAY, and use [jDateKey] for
/// anything grouped by calendar day.
DateTime? jDateOrNull(Object? v) {
  if (v == null) return null;
  if (v is DateTime) return v.toUtc();
  if (v is int) return DateTime.fromMillisecondsSinceEpoch(v, isUtc: true);
  if (v is double && v.isFinite) {
    return DateTime.fromMillisecondsSinceEpoch(v.toInt(), isUtc: true);
  }
  if (v is String) {
    final s = v.trim();
    if (s.isEmpty) return null;
    final asInt = int.tryParse(s);
    if (asInt != null) return DateTime.fromMillisecondsSinceEpoch(asInt, isUtc: true);
    return DateTime.tryParse(s)?.toUtc();
  }
  return null;
}

DateTime jDate(Object? v, {DateTime? fallback}) =>
    jDateOrNull(v) ?? fallback ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

/// An empty map instead of a crash when the key is missing or the wrong shape.
Map<String, dynamic> jMap(Object? v) {
  if (v is Map<String, dynamic>) return v;
  if (v is Map) return v.map((Object? k, Object? val) => MapEntry<String, dynamic>('$k', val));
  return const <String, dynamic>{};
}

/// A list of maps, skipping any element that is not a map.
List<Map<String, dynamic>> jMapList(Object? v) {
  if (v is! Iterable) return const <Map<String, dynamic>>[];
  final out = <Map<String, dynamic>>[];
  for (final e in v) {
    if (e is Map) out.add(jMap(e));
  }
  return out;
}

/// Epoch milliseconds, for writing a [DateTime] back to JSON or a drift
/// column. Times are stored as UTC millis everywhere in this app.
int jMillis(DateTime v) => v.toUtc().millisecondsSinceEpoch;

/// Instant equality for model `==`, at MILLISECOND resolution.
///
/// Two things would otherwise break every round trip:
/// * Dart's `DateTime ==` also compares `isUtc`, so `DateTime.now()` (local)
///   never equals the same instant read back from storage (always UTC).
/// * `DateTime.now()` carries microseconds, and [jMillis] stores milliseconds,
///   so the value that comes back is a truncated copy.
///
/// Milliseconds is the resolution the app actually persists, so it is the
/// resolution models compare at. Nothing in a bank SMS is finer than a minute.
bool jTimeEquals(DateTime? a, DateTime? b) {
  if (a == null || b == null) return a == null && b == null;
  return a.millisecondsSinceEpoch == b.millisecondsSinceEpoch;
}

/// The hash partner of [jTimeEquals]: same resolution, zone-independent.
int jTimeHash(DateTime? a) => a?.millisecondsSinceEpoch.hashCode ?? 0;

/// `'YYYY-MM-DD'` in the supplied [date]'s own zone. Used for
/// `Transaction.bookingDate`, which exists so month/day grouping needs no date
/// arithmetic in SQL.
///
/// PASS A LOCAL TIME. A transaction at 00:30 IST is 19:00 UTC on the PREVIOUS
/// day, so calling this on a UTC value would file late-evening and small-hours
/// spending under the wrong date - and in the wrong month, twelve times a
/// year.
String jDateKey(DateTime date) {
  final y = date.year.toString().padLeft(4, '0');
  final m = date.month.toString().padLeft(2, '0');
  final d = date.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}
