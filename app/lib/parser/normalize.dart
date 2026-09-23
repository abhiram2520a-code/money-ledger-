/// Text normalisation and field extraction primitives shared by the trust
/// gate, the rule matcher and the deduplicator.
///
/// Everything here is a pure, total function: same input, same output, never
/// throws, no I/O, no clock read that is not passed in. That is what makes a
/// re-parse after a rules update reproducible.
library;

import 'package:flutter/foundation.dart';

import '../models/models.dart';

// ---------------------------------------------------------------------------
// Body normalisation
// ---------------------------------------------------------------------------

/// Characters that are invisible but break regexes silently.
///
/// Bank SMS routinely carry zero-width joiners (inserted by DLT scrubbing) and
/// non-breaking spaces (inserted by templating engines). `Rs<NBSP>500` looks
/// identical to `Rs 500` on screen and does not match `Rs\s*\d`.
final RegExp _zeroWidthPattern = RegExp(
  r'[\u200b-\u200f\u202a-\u202e\u2060-\u206f\ufeff\u00ad]',
);

/// Space-like characters that are not U+0020.
final RegExp _spaceLikePattern = RegExp(
  r'[\u00a0\u1680\u2000-\u200a\u202f\u205f\u3000\u2028\u2029]',
);

final RegExp _whitespaceRun = RegExp(r'\s+');

/// The longest body the matcher will run a regex over.
///
/// A concatenated SMS tops out around 1 530 characters. Anything longer is an
/// MMS body or a pasted document, and feeding 50 KB to a backtracking regex is
/// how a parser hangs the ingestion loop. Truncation is deliberate and is
/// reported through [ParseOutcome.reason] rather than hidden.
const int maxMatchableBodyChars = 2000;

/// Collapses a raw SMS body into the single-line, single-spaced form every
/// pattern in this module expects.
///
/// Newlines become spaces because a third of the real templates are
/// newline-delimited blocks (HDFC `Sent Rs...\nFrom...\nTo...`) and writing
/// every rule twice is how rule packs rot. Case is NOT folded: the rules are
/// matched case-insensitively at the comparison site instead, so merchant
/// strings survive with their original casing for display.
String normalizeBody(String raw) {
  if (raw.isEmpty) return '';
  final cleaned = raw
      .replaceAll(_zeroWidthPattern, '')
      .replaceAll(_spaceLikePattern, ' ')
      .replaceAll(_whitespaceRun, ' ')
      .trim();
  return cleaned;
}

/// [normalizeBody] plus a length cap, for feeding to a regex.
String matchableBody(String raw) {
  final normalized = normalizeBody(raw);
  return normalized.length <= maxMatchableBodyChars
      ? normalized
      : normalized.substring(0, maxMatchableBodyChars);
}

/// A case-folded, punctuation-stable key for exact re-delivery detection.
///
/// Dual-SIM handsets and operator retries deliver byte-identical bodies; this
/// plus the sender's principal entity is the layer-0 dedupe key.
String dedupBodyKey(String raw) => normalizeBody(raw).toLowerCase();

// ---------------------------------------------------------------------------
// Sender headers (TRAI / DLT grammar)
// ---------------------------------------------------------------------------

/// A parsed TRAI DLT sender header.
///
/// The delivered originating address is `<OP><LSA>-<PRINCIPAL>[-<CATEGORY>]`,
/// e.g. `VM-HDFCBK-S`. The two-character prefix is assigned by the *delivering
/// telco*, not the bank, so the same HDFC template arrives as `VM-HDFCBK-S`,
/// `AD-HDFCBK-S` or `JM-HDFCBK-S` depending on the circle. Keying a rule on the
/// prefix is the single most common mistake in SMS parsers; [principal] is what
/// identifies the sender.
@immutable
class SenderId {
  const SenderId({
    required this.raw,
    required this.principal,
    this.operatorPrefix,
    this.category,
  });

  /// The address exactly as the platform reported it.
  final String raw;

  /// The DLT-registered principal entity header, upper-cased: `HDFCBK`,
  /// `SBIUPI`, `AXISBK`. Never empty.
  final String principal;

  /// The two-character telco routing prefix, upper-cased, when present.
  /// Informational only - never match on it.
  final String? operatorPrefix;

  /// The TCCCPR category suffix, upper-cased: `P` promotional, `S` service,
  /// `T` transactional, `G` government. Frequently absent.
  final String? category;

  /// `-P` is the one category that is a reliable reject: a promotional header
  /// cannot legitimately carry a settled money movement. `-S` and `-T` do NOT
  /// separate alerts from OTPs, so they are ignored.
  bool get isPromotional => category == 'P';

  /// Every spelling a rule's `sender_pattern` may reasonably be written
  /// against, most-normalised first.
  ///
  /// Packs in the wild are written both ways - `^HDFCBK$` and
  /// `^[A-Z]{2}-HDFCBK[A-Z]?$` - and a pack that silently matches nothing is
  /// worse than accepting both spellings.
  List<String> get matchCandidates {
    final upperRaw = raw.trim().toUpperCase();
    final prefixed =
        operatorPrefix == null ? null : '$operatorPrefix-$principal';
    return <String>[
      principal,
      if (prefixed != null && prefixed != principal) prefixed,
      if (upperRaw != principal && upperRaw != prefixed) upperRaw,
    ];
  }

  /// Parses an originating address, or returns `null` when it is not a
  /// registered alphabetic header.
  ///
  /// `null` means "do not parse this message at all". A 10-digit MSISDN, a
  /// numeric shortcode or a purely numeric DLT header is spoof and promo
  /// territory: under DLT a random person cannot send from `VM-HDFCBK`, but
  /// anyone can send from a phone number.
  static SenderId? parse(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim().replaceAll(_whitespaceRun, '');
    if (trimmed.isEmpty) return null;

    final withSuffix = _senderWithSuffix.firstMatch(trimmed);
    if (withSuffix != null) {
      return SenderId(
        raw: raw,
        operatorPrefix: withSuffix.group(1)!.toUpperCase(),
        principal: withSuffix.group(2)!.toUpperCase(),
        category: withSuffix.group(3)!.toUpperCase(),
      );
    }

    final withPrefix = _senderWithPrefix.firstMatch(trimmed);
    if (withPrefix != null) {
      return SenderId(
        raw: raw,
        operatorPrefix: withPrefix.group(1)!.toUpperCase(),
        principal: withPrefix.group(2)!.toUpperCase(),
      );
    }

    final bare = _senderBare.firstMatch(trimmed);
    if (bare != null) {
      return SenderId(raw: raw, principal: bare.group(1)!.toUpperCase());
    }

    return null;
  }

  @override
  String toString() => 'SenderId($principal, cat=${category ?? '-'})';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SenderId &&
          other.raw == raw &&
          other.principal == principal &&
          other.operatorPrefix == operatorPrefix &&
          other.category == category;

  @override
  int get hashCode => Object.hash(raw, principal, operatorPrefix, category);

  // A principal entity header must start with a letter; a purely numeric
  // middle token is the promotional shortcode class and never carries alerts.
  // Mixed case is real traffic (VK-AxisBk-T, AX-axioFS-S) so match loosely and
  // upper-case afterwards.
  static final RegExp _senderWithSuffix =
      RegExp(r'^([A-Za-z]{2})-([A-Za-z][A-Za-z0-9]{1,10})-([A-Za-z])$');
  static final RegExp _senderWithPrefix =
      RegExp(r'^([A-Za-z]{2})-([A-Za-z][A-Za-z0-9]{1,10})$');
  static final RegExp _senderBare = RegExp(r'^([A-Za-z][A-Za-z0-9]{2,10})$');
}

/// The principal entity token of [senderRaw], or `null` when the address is not
/// a DLT header. This is what `RawMessage.senderHeader` should hold.
String? normalizeSenderHeader(String? senderRaw) =>
    SenderId.parse(senderRaw)?.principal;

// ---------------------------------------------------------------------------
// Amounts
// ---------------------------------------------------------------------------

/// Reads a captured `amount` group into integer paise.
///
/// Delegates to [Money.tryParse], which already handles every Indian spelling:
/// `Rs.1,24,500.00` (lakh grouping, not western), `INR 2000`, `Rs:151.00`
/// (Union Bank's colon), `Rs634.53` (no space), `₹450/-`, `3800.0` (one
/// decimal) and a bare `150.0` with no currency token at all.
///
/// Returns `null` - never zero - when there is no number, because a
/// zero-rupee transaction is indistinguishable from a real one in a total.
Money? parseAmount(String? captured, {String currency = Money.inr}) {
  if (captured == null) return null;
  final money = Money.tryParse(captured, currency: currency);
  if (money == null) return null;
  final magnitude = money.abs;
  if (magnitude.isZero) return null;
  return magnitude;
}

/// Words that bind an amount to a balance, a credit limit or an outstanding
/// due rather than to the money that moved.
///
/// Almost every real template carries two to four amounts; ICICI's refund SMS
/// carries three. Booking `Avl Bal Rs 43,210.55` as a spend is the loudest
/// possible failure, so the amount a rule captured is re-checked against the
/// text immediately in front of it.
final RegExp _balanceBoundPattern = RegExp(
  r'(?:avl|avlb|avbl|available|new|clear|closing|ledger|updated|current|'
  r'revised|total\s*due|min(?:imum)?\s*due|outstanding|limit|lmt|'
  r'bal(?:ance)?)'
  r'\s*(?:is|of|amt)?\s*[:.\-]?\s*(?:rs\.?|inr|₹)?\s*$',
  caseSensitive: false,
);

/// True when [amountText] sits immediately after a balance / limit / due
/// marker in [body].
///
/// [searchFrom] should be the start of the rule's overall match so the lookup
/// cannot stray to an earlier, unrelated copy of the same digits.
bool amountLooksBalanceBound(String body, String amountText, {int searchFrom = 0}) {
  if (amountText.isEmpty) return false;
  final from = searchFrom.clamp(0, body.length);
  final index = body.indexOf(amountText, from);
  if (index < 0) return false;
  final start = index - 40 < 0 ? 0 : index - 40;
  return _balanceBoundPattern.hasMatch(body.substring(start, index));
}

// ---------------------------------------------------------------------------
// Account and card tails
// ---------------------------------------------------------------------------

/// Digits of a masked account or card, in every mask dialect seen in the wild:
/// `X1234`, `XX1234`, `xx1234`, `*1234`, `**5678`, `*XX0000`, `xxXX6438`,
/// `000***000000`, `...1055`, `4xxx0000`.
///
/// Returns at most the last six digits, or `null` when there are none -
/// matching on an empty tail would attach every message to every account.
String? normalizeTail(String? raw) => Account.normalizeTail(raw);

/// The last four digits of a tail, which is the only width every issuer agrees
/// on. Used for dedupe comparisons, never for display.
String? tailKey(String? raw) {
  final digits = normalizeTail(raw);
  if (digits == null) return null;
  return digits.length <= 4 ? digits : digits.substring(digits.length - 4);
}

/// True when two tails may refer to the same instrument. Unknown on either
/// side is not a match - it is an absence of evidence.
bool tailsMatch(String? a, String? b) {
  final left = tailKey(a);
  final right = tailKey(b);
  if (left == null || right == null) return false;
  return left == right;
}

// ---------------------------------------------------------------------------
// Merchant strings
// ---------------------------------------------------------------------------

/// Payment-aggregator prefixes glued onto the acquirer descriptor. `RAZ*`
/// is Razorpay, `PYU*`/`PAYU*` PayU, `BIL*` a biller aggregator. None of them
/// is the merchant.
final RegExp _aggregatorPrefix = RegExp(
  r'^(?:raz|pyu|payu|bil|mmt|inf|ach|nach|atom|ccav|pos|pur|ecom|upi|p2m|p2a|'
  r'vps|sq|tpv)[*/\-]\s*',
  caseSensitive: false,
);

/// Boilerplate that follows the counterparty when a rule's capture runs on too
/// far. Axis writes `.../RAHUL SHARMA Not you? SMS BLOCKUPI ...` with no
/// delimiter at all, so the merchant capture has to be cut by content.
final RegExp _merchantStopPattern = RegExp(
  r'\b(?:not\s*you|not\s*done\s*by\s*you|if\s*not\s*(?:you|done)|to\s*dispute|'
  r'for\s*dispute|to\s*report|report\s*at|dispute|helpline|sms\s*block|'
  r'call\s*\d|tap\s*https?|click|view\s*(?:updated\s*)?balance|'
  r'avl\b|avlbal|avbl|available\s*(?:bal|limit)|avl\s*(?:bal|lmt|limit)|'
  r'new\s*bal|upi\s*ref|ref\s*no|refno|rrn\b|utr\b|txn\s*no|'
  r'reward\s*points|convert\s*to\s*emi|t&c)\b',
  caseSensitive: false,
);

/// A run of four or more digits welded to the end of an acquirer descriptor
/// (`EAZYDINE0000000`, `PZCREDIT0000000`). Terminal noise, not part of a name.
/// Three digits or fewer are kept, because `CAFE 24` and `99 STORE` are real.
final RegExp _trailingDigitNoise = RegExp(r'[\s\-_]*\d{4,}$');

final RegExp _edgePunctuation = RegExp(r'^[\s.,;:\-_/*#|~]+|[\s.,;:\-_/*#|~]+$');

/// The longest merchant string worth keeping. Anything beyond this is a
/// runaway capture, not a shop name.
const int maxMerchantChars = 96;

/// Cleans a captured counterparty string into something the categoriser can
/// look up: aggregator prefix stripped, trailing reference digits stripped,
/// boilerplate cut, whitespace collapsed.
///
/// Returns `null` when nothing recognisable survives - an empty or all-digit
/// merchant is worse than no merchant, because it becomes a permanent phantom
/// entry in the merchant dictionary.
String? cleanMerchant(String? raw) {
  if (raw == null) return null;
  var text = normalizeBody(raw);
  if (text.isEmpty) return null;

  final stop = _merchantStopPattern.firstMatch(text);
  if (stop != null) text = text.substring(0, stop.start);

  text = text.replaceFirst(_aggregatorPrefix, '');
  text = text.replaceAll(_edgePunctuation, '');
  text = text.replaceFirst(_trailingDigitNoise, '');
  text = text.replaceAll(_edgePunctuation, '');
  text = text.replaceAll(_whitespaceRun, ' ').trim();

  if (text.isEmpty) return null;
  if (text.length > maxMerchantChars) {
    text = text.substring(0, maxMerchantChars).trim();
  }
  // An all-digit or single-character leftover carries no information.
  if (text.length < 2) return null;
  if (RegExp(r'^[\d\s.,\-]+$').hasMatch(text)) return null;
  return text;
}

// ---------------------------------------------------------------------------
// VPAs
// ---------------------------------------------------------------------------

/// `swiggy@axisbank`, `9999999999@ybl`, `paytmqr2810...@paytm`.
final RegExp _vpaPattern =
    RegExp(r'\b([A-Za-z0-9](?:[A-Za-z0-9._\-]{1,63}))@([A-Za-z][A-Za-z0-9.\-]{1,32})\b');

/// Suffixes that make a token an e-mail address rather than a VPA.
final RegExp _emailDomainTail =
    RegExp(r'\.(?:com|in|org|net|co|io|gov|edu)$', caseSensitive: false);

/// Handles that identify no merchant at all: a Paytm dynamic QR, or the opaque
/// 32-hex mandate handles UPI AutoPay uses. Writing these into the merchant
/// field turns every QR code into a distinct permanent "merchant".
final RegExp _opaqueVpaLocalPart =
    RegExp(r'^(?:paytmqr\d+|[0-9a-f]{24,64}|\d{10})$', caseSensitive: false);

/// The first VPA in [body], or `null`.
String? extractVpa(String body) {
  for (final match in _vpaPattern.allMatches(body)) {
    final domain = match.group(2)!;
    if (_emailDomainTail.hasMatch(domain)) continue;
    return match.group(0);
  }
  return null;
}

/// True when [vpa] is a machine handle that names nobody.
bool isOpaqueVpa(String? vpa) {
  if (vpa == null) return false;
  final at = vpa.indexOf('@');
  if (at <= 0) return false;
  return _opaqueVpaLocalPart.hasMatch(vpa.substring(0, at));
}

/// A display name derived from a VPA, or `null` when the handle is opaque.
/// `swiggy@axisbank` -> `swiggy`; `paytmqr28100...@paytm` -> `null`.
String? merchantFromVpa(String? vpa) {
  if (vpa == null || isOpaqueVpa(vpa)) return null;
  final at = vpa.indexOf('@');
  if (at <= 0) return null;
  final local = vpa.substring(0, at);
  if (local.length < 3) return null;
  if (RegExp(r'^\d+$').hasMatch(local)) return null;
  return local;
}

// ---------------------------------------------------------------------------
// Reference numbers (RRN / UTR / IMPS ref / auth code)
// ---------------------------------------------------------------------------

/// `UPI/P2M/431234567890/MERCHANT` - Axis packs the rail, the counterparty
/// class and the RRN into one slash-delimited token.
final RegExp _railUpiToken =
    RegExp(r'\bUPI/(P2[MA])/(\d{12})\b', caseSensitive: false);

/// Everything that introduces a reference in a real template.
final RegExp _refMarkerPattern = RegExp(
  r'(?:upi\s*ref(?:erence)?\s*(?:no\.?|number|id)?|imps\s*ref(?:\s*(?:no\.?|#))?|'
  r'\brrn\b|\butr\b|ref(?:erence)?\s*(?:no\.?|number|id)?|ref#|refno|'
  r'txn\s*(?:no\.?|id)|transaction\s*(?:id|number)|\bupi\b)'
  r'\s*[:#.\-/]?\s*([A-Za-z0-9]{6,24})',
  caseSensitive: false,
);

/// Numbers that look like references but are not: the cyber-fraud helpline,
/// toll-free card-block numbers, mobile numbers, and the 11-character app hash
/// Android's SMS Retriever appends to OTPs.
final RegExp _refBlacklist = RegExp(
  r'^(?:1930|1800\d{4,}|18002586161|9\d{9}|\d{10})$',
);

/// True when [token] can serve as the identity of a money *event*.
///
/// An RRN is exactly 12 digits and is identical on the payer's message, the
/// payee's message and the PSP's message - the strongest key available. A
/// NEFT/RTGS UTR is 16-22 alphanumerics. A four-to-six digit ATM slip number
/// is NOT a reference: it is not unique across days.
bool isPlausibleRef(String? token) {
  if (token == null) return false;
  final t = token.trim();
  if (t.length < 6 || t.length > 24) return false;
  if (_refBlacklist.hasMatch(t)) return false;
  if (RegExp(r'^\d+$').hasMatch(t)) {
    // Numeric references are RRN/IMPS (12) or a vendor sequence; reject the
    // short slip numbers and the over-long account numbers.
    return t.length >= 8 && t.length <= 20;
  }
  // Alphanumeric: a UTR, a card auth code or a vendor txn id.
  return RegExp(r'^[A-Za-z0-9]+$').hasMatch(t) && RegExp(r'\d').hasMatch(t);
}

/// Upper-cases and trims a reference. Leading zeros are preserved: an RRN is
/// fixed-width and `012345678901` is not `12345678901`.
String? normalizeRef(String? raw) {
  if (raw == null) return null;
  final t = raw.trim().replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
  return isPlausibleRef(t) ? t : null;
}

/// Finds the transaction reference in [body], preferring a 12-digit RRN.
///
/// This is the highest-leverage field in the whole parser: it is what makes a
/// retried UPI payment distinguishable from a duplicate delivery, and it is
/// the only thing that links a card-bill debit to the issuer's "payment
/// received" alert.
String? findRefInBody(String body) {
  final rail = _railUpiToken.firstMatch(body);
  if (rail != null) return rail.group(2);

  String? alphanumericFallback;
  for (final match in _refMarkerPattern.allMatches(body)) {
    var token = match.group(1)!;
    // 'UPI/P2M/4312...' - the marker swallowed the counterparty class.
    if (RegExp(r'^p2[ma]$', caseSensitive: false).hasMatch(token)) continue;
    token = token.toUpperCase();
    if (!isPlausibleRef(token)) continue;
    if (RegExp(r'^\d{12}$').hasMatch(token)) return token;
    alphanumericFallback ??= token;
  }
  return alphanumericFallback;
}

// ---------------------------------------------------------------------------
// Dates
// ---------------------------------------------------------------------------

/// A date read out of a message, with an honest record of how much of it the
/// message actually stated.
@immutable
class ParsedDate {
  const ParsedDate(this.value, this.precision, this.format);

  final DateTime value;
  final DatePrecision precision;

  /// The pattern that matched, for debugging a rule pack.
  final String format;

  @override
  String toString() => 'ParsedDate($value, ${precision.wire}, $format)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ParsedDate &&
          jTimeEquals(other.value, value) &&
          other.precision == precision &&
          other.format == format;

  @override
  int get hashCode => Object.hash(jTimeHash(value), precision, format);
}

/// Formats tried when a rule declares none, ordered most specific first.
///
/// Every entry is a shape observed in a real bank SMS. `yyyy-MM-dd:HH:mm:ss`
/// is HDFC's non-ISO colon join; `yyyy:MM:dd` is Bank of Baroda using colons as
/// *date* separators; `ddMMMyy` is SBI with no separators at all; `dd-MM` is
/// HDFC's credit-card-via-UPI alert with no year.
const List<String> defaultDateFormats = <String>[
  'yyyy-MM-dd:HH:mm:ss',
  'yyyy-MM-dd HH:mm:ss',
  'yyyy:MM:dd HH:mm:ss',
  'dd-MM-yyyy HH:mm:ss',
  'dd/MM/yyyy HH:mm:ss',
  'dd-MM-yy HH:mm:ss',
  'dd/MM/yy HH:mm:ss',
  'dd-MMM-yyyy HH:mm:ss',
  'dd-MMM-yy HH:mm:ss',
  'dd-MM-yyyy HH:mm',
  'dd/MM/yyyy HH:mm',
  'dd-MM-yy HH:mm',
  'dd/MM/yy HH:mm',
  'MMMM d, yyyy',
  'MMM d, yyyy',
  'ddMMMyyyy',
  'ddMMMyy',
  'dd-MMM-yyyy',
  'dd/MMM/yyyy',
  'dd-MMM-yy',
  'dd/MMM/yy',
  'dd-MM-yyyy',
  'dd/MM/yyyy',
  'dd-MM-yy',
  'dd/MM/yy',
  'yyyy-MM-dd',
  'yyyy:MM:dd',
  'dd-MM',
  'dd/MM',
];

/// A date token sitting behind a preposition, used only when the matching rule
/// declared no `date` group. Requiring `on`/`dated` keeps the scan off phone
/// numbers and card masks.
final RegExp _prepositionedDatePattern = RegExp(
  r'\b(?:on|dated|date)\s+'
  r'([0-3]?\d[-/][A-Za-z0-9]{2,4}(?:[-/]\d{2,4})?(?:[ :]\d{1,2}:\d{2}(?::\d{2})?)?'
  r'|\d{4}[-:]\d{1,2}[-:]\d{1,2}(?:[ :]\d{1,2}:\d{2}(?::\d{2})?)?'
  r'|[0-3]?\d[A-Za-z]{3}\d{2,4}'
  r'|[A-Za-z]{3,9}\s+\d{1,2},\s*\d{4})',
  caseSensitive: false,
);

/// Reads [token] using [formats] (falling back to [defaultDateFormats]).
///
/// [reference] is the message receipt time and is used for year inference, so
/// the result is deterministic in tests instead of depending on the wall clock.
/// Returns `null` when nothing matched - the caller then falls back to
/// [reference] with `DatePrecision.receivedFallback`, which is honest.
ParsedDate? parseDateToken(
  String? token, {
  required DateTime reference,
  List<String> formats = const <String>[],
}) {
  if (token == null) return null;
  final text = normalizeBody(token);
  if (text.isEmpty) return null;

  final ordered = <String>[
    ...formats,
    ...defaultDateFormats.where((f) => !formats.contains(f)),
  ];
  for (final format in ordered) {
    final spec = _DateSpec.of(format);
    if (spec == null) continue;
    final parsed = spec.parse(text, reference);
    if (parsed != null) return parsed;
  }
  return null;
}

/// Scans [body] for a date introduced by `on` / `dated`.
ParsedDate? findDateInBody(
  String body, {
  required DateTime reference,
  List<String> formats = const <String>[],
}) {
  for (final match in _prepositionedDatePattern.allMatches(body)) {
    final parsed =
        parseDateToken(match.group(1), reference: reference, formats: formats);
    if (parsed != null) return parsed;
  }
  return null;
}

/// A compiled date pattern.
///
/// Written by hand rather than using `intl`'s `DateFormat` because the formats
/// here must be total (never throw), must support a token with no year at all,
/// and must be anchored so `05-06-26` cannot half-match `dd-MM-yyyy`.
class _DateSpec {
  _DateSpec._(this.format, this.regex, this.fields);

  final String format;
  final RegExp regex;
  final List<String> fields;

  static final Map<String, _DateSpec?> _cache = <String, _DateSpec?>{};

  static _DateSpec? of(String format) =>
      _cache.putIfAbsent(format, () => _compile(format));

  static _DateSpec? _compile(String format) {
    final buffer = StringBuffer('^');
    final fields = <String>[];
    var i = 0;
    var seen = 0;
    while (i < format.length) {
      final rest = format.substring(i);
      String? token;
      for (final candidate in _tokens) {
        if (rest.startsWith(candidate)) {
          token = candidate;
          break;
        }
      }
      if (token == null) {
        final ch = format[i];
        buffer.write(ch == ' ' ? r'[\s,]+' : RegExp.escape(ch));
        i += 1;
        continue;
      }
      final name = 'g$seen';
      seen += 1;
      fields.add('$token:$name');
      buffer.write('(?<$name>${_tokenPatterns[token]})');
      i += token.length;
    }
    buffer.write(r'$');
    try {
      return _DateSpec._(format, RegExp(buffer.toString(), caseSensitive: false), fields);
    } on FormatException {
      return null;
    }
  }

  // Longest first so 'yyyy' is not read as 'yy' + 'yy'.
  static const List<String> _tokens = <String>[
    'yyyy', 'MMMM', 'MMM', 'yy', 'MM', 'dd', 'HH', 'hh', 'mm', 'ss', 'M', 'd',
    'H', 'h', 'a',
  ];

  static const Map<String, String> _tokenPatterns = <String, String>{
    'yyyy': r'\d{4}',
    'yy': r'\d{2}',
    'MMMM': r'[A-Za-z]{3,9}',
    'MMM': r'[A-Za-z]{3}',
    'MM': r'\d{2}',
    'M': r'\d{1,2}',
    'dd': r'\d{2}',
    'd': r'\d{1,2}',
    'HH': r'\d{2}',
    'H': r'\d{1,2}',
    'hh': r'\d{2}',
    'h': r'\d{1,2}',
    'mm': r'\d{2}',
    'ss': r'\d{2}',
    'a': r'[AaPp]\.?[Mm]\.?',
  };

  static const Map<String, int> _monthByPrefix = <String, int>{
    'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
    'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
  };

  ParsedDate? parse(String text, DateTime reference) {
    final match = regex.firstMatch(text);
    if (match == null) return null;

    int? year;
    int? month;
    int? day;
    var hour = 0;
    var minute = 0;
    var second = 0;
    var hasTime = false;
    var twelveHour = false;
    String? meridiem;

    for (final field in fields) {
      final split = field.indexOf(':');
      final token = field.substring(0, split);
      final name = field.substring(split + 1);
      final raw = match.namedGroup(name);
      if (raw == null) continue;
      switch (token) {
        case 'yyyy':
          year = int.tryParse(raw);
        case 'yy':
          final two = int.tryParse(raw);
          if (two == null) return null;
          final candidate = 2000 + two;
          year = candidate > reference.year + 1 ? 1900 + two : candidate;
        case 'MMMM':
        case 'MMM':
          final key = raw.toLowerCase();
          if (key.length < 3) return null;
          month = _monthByPrefix[key.substring(0, 3)];
          if (month == null) return null;
        case 'MM':
        case 'M':
          month = int.tryParse(raw);
        case 'dd':
        case 'd':
          day = int.tryParse(raw);
        case 'HH':
        case 'H':
          hour = int.tryParse(raw) ?? 0;
          hasTime = true;
        case 'hh':
        case 'h':
          hour = int.tryParse(raw) ?? 0;
          hasTime = true;
          twelveHour = true;
        case 'mm':
          minute = int.tryParse(raw) ?? 0;
          hasTime = true;
        case 'ss':
          second = int.tryParse(raw) ?? 0;
          hasTime = true;
        case 'a':
          meridiem = raw.toLowerCase().replaceAll('.', '');
      }
    }

    if (month == null || day == null) return null;
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    if (hour > 23 || minute > 59 || second > 59) return null;

    if (twelveHour && meridiem != null) {
      if (meridiem.startsWith('p') && hour < 12) hour += 12;
      if (meridiem.startsWith('a') && hour == 12) hour = 0;
    }

    final inferredYear = year == null;
    final resolvedYear =
        year ?? _inferYear(month, day, hour, minute, second, reference);

    final value = DateTime(resolvedYear, month, day, hour, minute, second);
    // DateTime silently rolls 31 February over into March; reject instead.
    if (value.month != month || value.day != day) return null;

    final precision = inferredYear
        ? DatePrecision.inferredYear
        : (hasTime ? DatePrecision.dateTime : DatePrecision.date);
    return ParsedDate(value, precision, format);
  }

  /// Picks the year that puts the date closest to the message's receipt time
  /// without letting it drift more than two days into the future.
  ///
  /// A message received on 2 January quoting `31-12` is last year's; one
  /// received on 30 December quoting `01-01` is next year's.
  static int _inferYear(
    int month,
    int day,
    int hour,
    int minute,
    int second,
    DateTime reference,
  ) {
    final local = reference.toLocal();
    final horizon = local.add(const Duration(days: 2));
    int? best;
    Duration? bestDelta;
    for (final year in <int>[local.year - 1, local.year, local.year + 1]) {
      final candidate = DateTime(year, month, day, hour, minute, second);
      if (candidate.month != month || candidate.day != day) continue;
      if (candidate.isAfter(horizon)) continue;
      final delta = local.difference(candidate).abs();
      if (bestDelta == null || delta < bestDelta) {
        bestDelta = delta;
        best = year;
      }
    }
    return best ?? local.year;
  }
}
