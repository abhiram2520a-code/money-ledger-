import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/models.dart';
import 'merchant_normalizer.dart';

/// One dictionary hit, with the exact surface form that produced it so the
/// UI can say WHY ("matched merchant SWIGGYUPI").
@immutable
class MerchantMatch {
  const MerchantMatch({
    required this.entry,
    required this.matchedOn,
    required this.score,
  });

  final MerchantEntry entry;

  /// The alias / VPA prefix that actually matched, as written in
  /// `rules/merchants.json`.
  final String matchedOn;

  /// 0.0 - 1.0 strength of THIS match, before the cascade turns it into a
  /// `CategoryResult.confidence`. Exact hits are 1.0.
  final double score;

  @override
  String toString() => 'MerchantMatch(${entry.name} via $matchedOn @$score)';
}

class _Alias {
  _Alias(this.entryIndex, this.surface, this.key, this.tokens);

  final int entryIndex;
  final String surface;
  final String key;
  final List<String> tokens;
}

class _TokenRef {
  _TokenRef(this.entryIndex, this.token, this.surface);

  final int entryIndex;
  final String token;
  final String surface;
}

class _VpaRef {
  _VpaRef(this.entryIndex, this.prefix);

  final int entryIndex;
  final String prefix;
}

/// An in-memory index over `rules/merchants.json`, built once per rules load.
///
/// Three lookups, cheapest first, all of them O(1)-ish so the whole cascade
/// stays well inside its per-message budget even at a few thousand entries:
///
/// * [lookupExact] - one hash lookup on the normalised key.
/// * [lookupVpa] - longest-prefix scan over the handful of entries that
///   declare a full VPA prefix. Bare PSP handles (`@ybl`) are refused at build
///   time, because they name the payment app and never the merchant.
/// * [lookupTokens] - prefix containment plus an IDF-weighted token-set
///   overlap over candidates drawn from an inverted index, never a scan.
///
/// Building normalises BOTH sides with [MerchantNormalizer], which is what
/// makes `BUNDL TECHNOLOGIES PRIVATE LIMITED` on the card rail meet
/// `BUNDLTECH` from a UPI message.
class MerchantIndex {
  MerchantIndex._(
    this.entries,
    this._exact,
    this._ambiguous,
    this._postings,
    this._prefixIndex,
    this._aliases,
    this._vpaPrefixes,
  );

  /// Builds the index. Total: malformed entries are skipped, never thrown on.
  factory MerchantIndex.build(List<MerchantEntry> merchants) {
    final entries = List<MerchantEntry>.unmodifiable(merchants);
    final exact = <String, int>{};
    final ambiguous = <String>{};
    final postings = <String, Set<int>>{};
    final prefixIndex = <String, List<_TokenRef>>{};
    final aliases = <_Alias>[];
    final vpaPrefixes = <_VpaRef>[];

    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];

      final surfaces = <String>{entry.name, ...entry.aliases};
      for (final surface in surfaces) {
        final normalized = MerchantNormalizer.normalize(surface);
        if (normalized.isEmpty) continue;

        for (final form in <String>{normalized.key, normalized.base}) {
          if (form.isEmpty) continue;
          final existing = exact[form];
          if (existing == null) {
            exact[form] = i;
          } else if (existing != i) {
            // Two merchants normalise to one key. Picking either would make
            // the answer depend on file order, so neither wins: the message
            // falls through to the Uncategorized queue and the app asks.
            ambiguous.add(form);
          }
        }

        aliases.add(_Alias(i, surface, normalized.key, normalized.tokens));

        for (final token in MerchantNormalizer.usableTokens(normalized.tokens)) {
          (postings[token] ??= <int>{}).add(i);
          if (token.length >= _minPrefixToken) {
            final bucket = token.substring(0, _prefixBucket);
            (prefixIndex[bucket] ??= <_TokenRef>[])
                .add(_TokenRef(i, token, surface));
          }
        }
      }

      for (final prefix in entry.vpaPrefixes) {
        final trimmed = prefix.trim().toLowerCase();
        // A bare handle names the payment app, not the merchant. Refusing it
        // here means no later code path can categorise on `@ybl` by accident.
        if (trimmed.length < 3 || trimmed.startsWith('@')) continue;
        vpaPrefixes.add(_VpaRef(i, trimmed));
      }
    }

    for (final key in ambiguous) {
      exact.remove(key);
    }

    vpaPrefixes.sort((a, b) {
      final byLength = b.prefix.length.compareTo(a.prefix.length);
      return byLength != 0 ? byLength : a.prefix.compareTo(b.prefix);
    });

    for (final refs in prefixIndex.values) {
      refs.sort((a, b) {
        final byLength = b.token.length.compareTo(a.token.length);
        return byLength != 0 ? byLength : a.entryIndex.compareTo(b.entryIndex);
      });
    }

    return MerchantIndex._(
      entries,
      exact,
      Set<String>.unmodifiable(ambiguous),
      <String, List<int>>{
        for (final e in postings.entries)
          e.key: List<int>.unmodifiable(e.value.toList()..sort()),
      },
      prefixIndex,
      aliases,
      vpaPrefixes,
    );
  }

  static final MerchantIndex empty = MerchantIndex.build(const <MerchantEntry>[]);

  /// Payment gateways and aggregators. Money went THROUGH them; the shop the
  /// user actually paid is not in the message. Categorising on a gateway would
  /// file half of e-commerce under one meaningless bucket, so a gateway hit is
  /// a hit that deliberately yields Uncategorized.
  ///
  /// Held here as well as in `merchants.json` so a rules pack that mislabels a
  /// gateway as a real merchant still cannot invent a category.
  static final Set<String> gatewayKeys = <String>{
    for (final name in <String>[
      'RAZORPAY',
      'RAZORPAY SOFTWARE',
      'PAYU',
      'PAYUBIZ',
      'PAYU PAYMENTS',
      'BILLDESK',
      'BILLDESK PAY',
      'CCAVENUE',
      'CASHFREE',
      'INSTAMOJO',
      'EASEBUZZ',
      'JUSPAY',
      'PINELABS',
      'PINE LABS',
      'WORLDLINE',
      'PAYGLOCAL',
      'PAYTM PAYMENT GATEWAY',
      'PHONEPE PAYMENT GATEWAY',
    ])
      MerchantNormalizer.key(name),
  }..remove('');

  static const int _prefixBucket = 5;
  static const int _minPrefixToken = 5;

  /// A containment hit must cover at least this much of the input token, so
  /// `OLA` inside `CHOLAMANDALAM` can never become a cab ride.
  static const double _minContainmentRatio = 0.5;

  /// How much of the MERCHANT's name the message has to contain before a
  /// token match counts. Anything less accepts half a brand name, which is how
  /// `ATM WDL HDFC` becomes `HDFC Life` and an ATM withdrawal turns into an
  /// insurance premium.
  static const double _minAliasCoverage = 0.85;

  /// A shared token has to be rare enough to mean something. Matching on a
  /// word half the dictionary uses is not a match.
  static const int _maxDiscriminativeDf = 3;

  final List<MerchantEntry> entries;

  final Map<String, int> _exact;
  final Set<String> _ambiguous;
  final Map<String, List<int>> _postings;
  final Map<String, List<_TokenRef>> _prefixIndex;
  final List<_Alias> _aliases;
  final List<_VpaRef> _vpaPrefixes;

  int get size => entries.length;

  /// Normalised keys claimed by more than one merchant. Excluded from
  /// [lookupExact] on purpose; surfaced so `tools/validate_rules.dart` and the
  /// developer screen can see them.
  Set<String> get ambiguousKeys => _ambiguous;

  bool get isEmpty => entries.isEmpty;

  /// True when [entry] is a payment gateway rather than a shop.
  ///
  /// Two independent signals: the dictionary pointing the entry at
  /// `uncategorized` (which is how `rules/merchants.json` says "known, but not
  /// identifying"), and the hard-coded [gatewayKeys] list.
  bool isGateway(MerchantEntry entry) =>
      entry.categoryPath == CategoryResult.uncategorizedPath ||
      isGatewayKey(MerchantNormalizer.key(entry.name));

  /// True when a normalised merchant key IS a gateway, whether or not the
  /// dictionary happens to carry it.
  bool isGatewayKey(String normalizedKey) =>
      normalizedKey.isNotEmpty && gatewayKeys.contains(normalizedKey);

  /// The entry behind a normalised key, for the UI. Null when unknown or
  /// ambiguous.
  MerchantEntry? entryForKey(String normalizedKey) {
    if (normalizedKey.isEmpty) return null;
    final index = _exact[normalizedKey] ?? _exact[normalizedKey.toUpperCase()];
    return index == null ? null : entries[index];
  }

  /// Stage 1: exact alias lookup on the normalised key, then on the form that
  /// still carries corporate tokens.
  MerchantMatch? lookupExact(NormalizedMerchant merchant) {
    if (merchant.isEmpty) return null;
    for (final form in <String>[merchant.key, merchant.base]) {
      if (form.isEmpty) continue;
      final index = _exact[form];
      if (index != null) {
        return MerchantMatch(
          entry: entries[index],
          matchedOn: _bestSurfaceFor(index, form),
          score: 1,
        );
      }
    }
    return null;
  }

  /// Stage 3a: full-VPA prefix lookup, longest prefix first.
  ///
  /// [vpa] must be the WHOLE address (`swiggy@axisbank`). Prefixes are full
  /// merchant prefixes such as `swiggy@`; a bare handle can never match,
  /// because it never appears at position zero.
  MerchantMatch? lookupVpa(String? vpa) {
    if (vpa == null) return null;
    final needle = vpa.trim().toLowerCase();
    if (needle.isEmpty) return null;
    for (final ref in _vpaPrefixes) {
      if (needle.startsWith(ref.prefix)) {
        return MerchantMatch(
          entry: entries[ref.entryIndex],
          matchedOn: ref.prefix,
          score: 1,
        );
      }
    }
    return null;
  }

  /// Stage 2: token match. Returns null far more often than it returns a hit,
  /// which is the intended behaviour - a wrong category costs more than an
  /// empty one.
  MerchantMatch? lookupTokens(NormalizedMerchant merchant) {
    if (merchant.isEmpty) return null;
    final query = MerchantNormalizer.usableTokens(merchant.tokens);
    if (query.isEmpty) return null;

    final contained = _containmentMatch(query);
    if (contained != null) return contained;

    return _overlapMatch(query);
  }

  /// `SWIGGYUPI` starts with the alias `SWIGGY`. Only fires when the alias
  /// covers at least half the token, so short aliases cannot hijack long
  /// names.
  MerchantMatch? _containmentMatch(List<String> query) {
    _TokenRef? best;
    var bestRatio = 0.0;
    String? bestToken;

    for (final token in query) {
      if (token.length < _minPrefixToken) continue;
      final bucket = _prefixIndex[token.substring(0, _prefixBucket)];
      if (bucket == null) continue;
      for (final ref in bucket) {
        if (ref.token.length >= token.length) continue;
        if (!token.startsWith(ref.token)) continue;
        final ratio = ref.token.length / token.length;
        if (ratio < _minContainmentRatio) continue;
        if (best == null ||
            ratio > bestRatio ||
            (ratio == bestRatio && ref.entryIndex < best.entryIndex)) {
          best = ref;
          bestRatio = ratio;
          bestToken = token;
        }
      }
    }

    if (best == null || bestToken == null) return null;
    return MerchantMatch(
      entry: entries[best.entryIndex],
      matchedOn: best.surface,
      score: bestRatio,
    );
  }

  /// IDF-weighted token-set overlap against candidates from the inverted
  /// index. Candidate generation comes from the two rarest query tokens, so
  /// this stays a few dozen comparisons however big the dictionary gets.
  MerchantMatch? _overlapMatch(List<String> query) {
    final ranked = List<String>.of(query)
      ..sort((a, b) {
        final byDf = _df(a).compareTo(_df(b));
        return byDf != 0 ? byDf : a.compareTo(b);
      });

    final candidates = <int>{};
    for (final token in ranked.take(2)) {
      final posting = _postings[token];
      if (posting != null) candidates.addAll(posting);
    }
    if (candidates.isEmpty) return null;

    final queryWeight = _weightOf(query);
    if (queryWeight <= 0) return null;

    _Alias? best;
    var bestScore = 0.0;

    for (final alias in _aliases) {
      if (!candidates.contains(alias.entryIndex)) continue;
      final aliasTokens = MerchantNormalizer.usableTokens(alias.tokens);
      if (aliasTokens.isEmpty) continue;

      final shared = <String>[];
      var discriminative = false;
      for (final token in aliasTokens) {
        if (!query.contains(token)) continue;
        shared.add(token);
        if (_df(token) <= _maxDiscriminativeDf) discriminative = true;
      }
      if (shared.isEmpty || !discriminative) continue;

      final aliasWeight = _weightOf(aliasTokens);
      if (aliasWeight <= 0) continue;
      final sharedWeight = _weightOf(shared);

      // The merchant's whole name has to be in the message, not a fragment of
      // it. The message may carry extra words; the merchant may not be missing
      // any.
      if (sharedWeight / aliasWeight < _minAliasCoverage) continue;

      final union = queryWeight + aliasWeight - sharedWeight;
      if (union <= 0) continue;
      final overlap = sharedWeight / union;

      final score = 0.75 * overlap + 0.25 * _prefixBonus(alias.key, query.join(' '));
      if (best == null || score > bestScore) {
        best = alias;
        bestScore = score;
      }
    }

    if (best == null) return null;
    return MerchantMatch(
      entry: entries[best.entryIndex],
      matchedOn: best.surface,
      score: bestScore,
    );
  }

  int _df(String token) => _postings[token]?.length ?? 0;

  /// `log(N / df)`, floored at a small positive value so a token every
  /// merchant shares still counts for something.
  double _idf(String token) {
    final df = _df(token);
    if (df <= 0) return _unknownTokenIdf;
    final n = math.max(entries.length, 1);
    return math.max(math.log(n / df), 0.05);
  }

  double _weightOf(Iterable<String> tokens) {
    var sum = 0.0;
    for (final token in tokens) {
      sum += _idf(token);
    }
    return sum;
  }

  /// A token no merchant uses is maximally discriminative in the query, but it
  /// can never appear in `shared`, so this only ever DEPRESSES the overlap.
  static const double _unknownTokenIdf = 2.5;

  static double _prefixBonus(String a, String b) {
    if (a.isEmpty || b.isEmpty) return 0;
    final limit = math.min(a.length, b.length);
    var common = 0;
    while (common < limit && a.codeUnitAt(common) == b.codeUnitAt(common)) {
      common++;
    }
    return common / math.max(a.length, b.length);
  }

  /// The alias to show the user for a hit on [form]: the surface spelling that
  /// normalises to it, preferring the exact spelling from the file.
  String _bestSurfaceFor(int entryIndex, String form) {
    for (final alias in _aliases) {
      if (alias.entryIndex == entryIndex && alias.key == form) {
        return alias.surface;
      }
    }
    return form;
  }
}
