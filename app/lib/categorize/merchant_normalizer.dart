import 'package:flutter/foundation.dart';

/// The result of normalising one raw merchant / counterparty string.
///
/// Three forms come out of one pass because the cascade needs all three:
/// [key] is what lookups and user rules are keyed on, [base] is the same
/// string before corporate-form tokens are dropped (so `PAYU PAYMENTS` and
/// `PAYU` can both be indexed), and [tokens] feeds the token stage.
@immutable
class NormalizedMerchant {
  const NormalizedMerchant({
    required this.raw,
    required this.base,
    required this.key,
    required this.tokens,
  });

  /// The input, upper-cased and trimmed. Kept for explanations only - it is
  /// never a lookup key, because the raw string carries terminal ids that
  /// change between two payments to the same shop.
  final String raw;

  /// Normalised, but with corporate-form tokens (`LTD`, `TECHNOLOGIES`, ...)
  /// still present: `PAYU PAYMENTS`.
  final String base;

  /// The canonical lookup key: `SWIGGY`, `BUNDL`, `PAYU PAYMENTS`.
  final String key;

  /// [key] split on spaces. Never empty when [key] is not empty.
  final List<String> tokens;

  static const NormalizedMerchant empty = NormalizedMerchant(
    raw: '',
    base: '',
    key: '',
    tokens: <String>[],
  );

  bool get isEmpty => key.isEmpty;

  bool get isNotEmpty => key.isNotEmpty;

  @override
  String toString() => 'NormalizedMerchant("$key")';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NormalizedMerchant &&
          other.raw == raw &&
          other.base == base &&
          other.key == key &&
          listEquals(other.tokens, tokens);

  @override
  int get hashCode => Object.hash(raw, base, key, Object.hashAll(tokens));
}

/// Turns `RAZ*SwiggyIN29481` into `SWIGGY`.
///
/// ## Why this class is version-stamped
///
/// Every `UserRule` the user creates is keyed on a string this class
/// produced. If the algorithm changes, every rule created under the old
/// algorithm has a pattern the new algorithm will never produce again -
/// nothing crashes, nothing logs, and every user's corrections silently stop
/// working on update day. That is the single most-complained-about bug in
/// competing apps.
///
/// Two structural defences, both of which have tests:
///
/// 1. [normalize] is IDEMPOTENT: `normalize(normalize(x).key).key ==
///    normalize(x).key`. That means a pattern stored under an older version
///    can always be re-normalised by a newer one without decaying, and
///    `UserRuleStore` re-normalises every pattern it loads.
/// 2. [version] must be bumped whenever the output changes, and
///    `test/categorize/merchant_normalizer_test.dart` pins a golden fixture
///    to that version, so changing the algorithm without acknowledging the
///    migration fails the build.
abstract final class MerchantNormalizer {
  /// Bump this ONLY together with the golden fixture in
  /// `test/categorize/merchant_normalizer_test.dart`. `UserRuleStore.loadAll`
  /// re-normalises stored patterns on every load, which is what makes a bump
  /// survivable.
  static const int version = 1;

  /// Acquirer / rail prefixes, each written WITH its delimiter so a merchant
  /// whose name merely starts with these letters is never mutilated
  /// (`PAYUSHA FOODS` must not become `SHA FOODS`).
  static const List<String> railPrefixes = <String>[
    'RAZORPAY*', 'RAZORPAY/', 'RAZ*', 'RAZP*',
    'PAYU*', 'PAYU_', 'PAYU/',
    'BILLDESK*', 'BILLDESK/',
    'CCAVENUE*', 'CCAV*',
    'CASHFREE*',
    'PAYTM-', 'PAYTM*', 'PYTM*', 'PTM*',
    'PAYZAPP*', 'PZCREDIT*',
    'EAZYDINE*',
    'ACH-D-', 'ACH-C-', 'ACH/', 'ACHD-',
    'NACH-', 'NACH/',
    'UPI/', 'UPI-', 'UPI*',
    'POS/', 'POS-', 'POS*',
    'INB/', 'INB-', 'INB*',
    'IMPS/', 'IMPS-',
    'NEFT/', 'NEFT-',
    'RTGS/', 'RTGS-',
    'MMT/', 'MMT-',
    'VPS*', 'VIN*',
    'SI/', 'SI-',
    'P2M/', 'P2M-', 'P2A/', 'P2A-',
    'ECOM/', 'NFS/', 'BIL/', 'TPT/', 'MOB/', 'ATW/', 'CWD/',
  ];

  /// Rail names that appear as a leading WORD rather than a prefix
  /// (`UPI SWIGGY`, `POS DMART`). Dropped only while another token survives.
  static const Set<String> railTokens = <String>{
    'UPI', 'POS', 'NEFT', 'IMPS', 'RTGS', 'ACH', 'NACH', 'ECS', 'INB', 'MOB',
    'TPT', 'BIL', 'VPS', 'MMT', 'P2M', 'P2A', 'SI', 'ECOM', 'NFS', 'ATW',
    'CWD', 'MPS',
  };

  /// Trailing city names. Card rails append the acquiring city to almost every
  /// POS string, and it is never part of the merchant identity.
  static const Set<String> geographyTokens = <String>{
    'BANGALORE', 'BENGALURU', 'MUMBAI', 'DELHI', 'HYDERABAD', 'CHENNAI',
    'PUNE', 'KOLKATA', 'GURGAON', 'GURUGRAM', 'NOIDA', 'AHMEDABAD', 'JAIPUR',
    'LUCKNOW', 'KOCHI', 'COIMBATORE', 'INDORE', 'NAGPUR', 'SURAT',
    'CHANDIGARH', 'BHOPAL', 'PATNA', 'VISAKHAPATNAM', 'VIJAYAWADA', 'MYSORE',
    'MYSURU', 'TRIVANDRUM', 'THIRUVANANTHAPURAM', 'GHAZIABAD', 'FARIDABAD',
  };

  /// Trailing country markers, stripped after [geographyTokens].
  static const Set<String> countryTokens = <String>{'IND', 'IN', 'INDIA'};

  /// Corporate-form noise. Dropped from anywhere in the string, because the
  /// legal entity on the card rail (`BUNDL TECHNOLOGIES PRIVATE LIMITED`) and
  /// the UPI handle (`BUNDLTECH`) must collapse to the same neighbourhood.
  ///
  /// Both the input string AND the dictionary aliases go through this, so
  /// dropping a token never loses a match - it only ever makes two spellings
  /// of the same merchant agree.
  static const Set<String> corporateTokens = <String>{
    'PVT', 'PRIVATE', 'LTD', 'LIMITED', 'LLP', 'INC', 'PLC',
    'INDIA', 'INDIAN', 'BHARAT',
    'TECHNOLOGIES', 'TECHNOLOGY', 'TECH', 'TECHNO',
    'SOLUTIONS', 'SOLUTION', 'SERVICES', 'SERVICE',
    'RETAIL', 'ENTERPRISES', 'ENTERPRISE', 'VENTURES', 'VENTURE',
    'CORP', 'CORPORATION', 'CO', 'COMPANY', 'AND', 'THE',
  };

  /// Control characters, no-break space, zero-width joiners and the
  /// bidirectional-override run. Written as escapes so no invisible byte
  /// ever sits in this source file.
  static final RegExp _invisible = RegExp(
    '[\u0000-\u001f\u007f\u00a0\u200b-\u200f'
    '\u202a-\u202e\ufeff]',
  );

  /// A trailing run of 4+ digits is a terminal / order / reference id, never
  /// part of the name: `EAZYDINE0000000`, `SWIGGY 4418822`.
  static final RegExp _trailingRef = RegExp(r'[\s*_#:./-]*[0-9]{4,}$');

  static final RegExp _nonAlnum = RegExp(r'[^A-Z0-9]+');

  static final RegExp _digitsOnly = RegExp(r'^[0-9]+$');

  /// Normalises [raw]. Total: never throws, and returns
  /// [NormalizedMerchant.empty] for null, empty or all-noise input.
  static NormalizedMerchant normalize(String? raw) {
    if (raw == null) return NormalizedMerchant.empty;
    final upper = raw.replaceAll(_invisible, ' ').trim().toUpperCase();
    if (upper.isEmpty) return NormalizedMerchant.empty;

    var work = upper;

    // 1. Acquirer / rail prefixes, possibly stacked (`UPI/RAZ*SHOP`).
    for (var pass = 0; pass < 4; pass++) {
      var stripped = false;
      for (final prefix in railPrefixes) {
        if (work.length > prefix.length && work.startsWith(prefix)) {
          work = work.substring(prefix.length).trim();
          stripped = true;
          break;
        }
      }
      if (!stripped) break;
    }

    // 2. Trailing terminal / reference digits. Never strip everything away.
    final trimmed = work.replaceFirst(_trailingRef, '').trim();
    if (trimmed.isNotEmpty) work = trimmed;

    // 3. Tokenise on anything that is not a letter or a digit.
    final tokens = work.split(_nonAlnum).where((t) => t.isNotEmpty).toList();
    if (tokens.isEmpty) return NormalizedMerchant.empty;

    // 4. Leading rail words.
    while (tokens.length > 1 && railTokens.contains(tokens.first)) {
      tokens.removeAt(0);
    }

    // 5. Trailing geography, then country.
    while (tokens.length > 1 &&
        (geographyTokens.contains(tokens.last) ||
            countryTokens.contains(tokens.last))) {
      tokens.removeLast();
    }

    final base = tokens.join(' ');

    // 6. Corporate-form tokens, unless they are all there is.
    final kept = tokens.where((t) => !corporateTokens.contains(t)).toList();
    final keyTokens = kept.isEmpty ? tokens : kept;

    return NormalizedMerchant(
      raw: upper,
      base: base,
      key: keyTokens.join(' '),
      tokens: List<String>.unmodifiable(keyTokens),
    );
  }

  /// Shorthand for `normalize(raw).key`.
  static String key(String? raw) => normalize(raw).key;

  /// Whether [token] is discriminative enough to drive a token-stage match on
  /// its own. Short tokens and bare numbers are how `JIO` ends up matching
  /// `JIOMART` and a terminal id ends up matching a merchant.
  static bool isUsableToken(String token) =>
      token.length >= 4 &&
      !_digitsOnly.hasMatch(token) &&
      !corporateTokens.contains(token) &&
      !railTokens.contains(token) &&
      !geographyTokens.contains(token) &&
      !countryTokens.contains(token);

  /// The usable subset of [tokens], order preserved.
  static List<String> usableTokens(Iterable<String> tokens) =>
      tokens.where(isUsableToken).toList(growable: false);
}
