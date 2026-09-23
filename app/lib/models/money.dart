import 'package:flutter/foundation.dart';

/// An amount of money.
///
/// ---------------------------------------------------------------------------
/// MONEY IS AN INTEGER COUNT OF PAISE. THIS IS NON-NEGOTIABLE.
///
/// Do not "helpfully" change [paise] to `double`, `num` or `Decimal`, and do
/// not add a `double` field beside it. Binary floating point cannot represent
/// 0.1, so `0.1 + 0.2 != 0.3`, and a ledger that sums thousands of amounts in
/// `double` drifts by rupees over a year and then disagrees with the bank. The
/// user notices, and the moment the total is wrong the app is worthless.
///
/// One rupee is 100 paise. Rs 1,24,500.00 is `Money(12450000)`.
/// [toRupeesDouble] exists for chart axes ONLY and is never used for
/// arithmetic that produces a stored value.
/// ---------------------------------------------------------------------------
@immutable
class Money implements Comparable<Money> {
  const Money(this.paise, {this.currency = inr});

  /// Rupees and (optionally) paise as separate integers, so no `double` ever
  /// enters: `Money.fromRupees(1245, 50)` is Rs 1,245.50.
  factory Money.fromRupees(int rupees, [int paisePart = 0]) =>
      Money(rupees * 100 + paisePart);

  factory Money.fromJson(Object? json) {
    if (json is int) return Money(json);
    if (json is Map) {
      final m = json.cast<Object?, Object?>();
      final p = m['paise'];
      final c = m['currency'];
      return Money(
        p is int ? p : (p is num ? p.toInt() : int.tryParse('$p') ?? 0),
        currency: c is String && c.trim().isNotEmpty ? c.trim().toUpperCase() : inr,
      );
    }
    if (json is String) return Money.tryParse(json) ?? zero;
    return zero;
  }

  /// Signed integer paise. Negative means money out when a caller chooses to
  /// use signs; the ledger itself stores magnitude plus a [TxnDirection].
  final int paise;

  /// ISO-4217 code. Only 'INR' is produced by the SMS pipeline today; the
  /// field exists so a foreign-currency card SMS is not silently mis-summed.
  final String currency;

  static const String inr = 'INR';
  static const String rupeeSymbol = '₹';
  static const Money zero = Money(0);

  /// Strips a currency token, grouping separators and a trailing `/-`, then
  /// reads the number with integer arithmetic only.
  ///
  /// Handles every shape seen in Indian bank SMS:
  /// `Rs.1,24,500.00`, `INR 2000`, `Rs 1,234.5`, `₹450/-`, `1,234,567.89`.
  /// Returns `null` when [input] contains no number at all, which is a parse
  /// failure the caller must surface - never a zero-rupee transaction.
  ///
  /// Give it the captured `amount` group, not a whole message body: on a full
  /// body it would read the first number it finds, which is as likely to be an
  /// account tail as an amount.
  static Money? tryParse(String? input, {String currency = inr}) {
    if (input == null) return null;
    final cleaned = input
        .replaceAll(' ', ' ')
        .replaceAll(_currencyTokenPattern, ' ')
        .replaceAll(_trailingDashPattern, ' ');
    final match = _numberPattern.firstMatch(cleaned);
    if (match == null) return null;

    final negative = _negativePattern.hasMatch(cleaned.substring(0, match.start));
    final token = match.group(0)!.replaceAll(',', '').replaceAll(' ', '');

    final dot = token.lastIndexOf('.');
    final String wholeText;
    final String fractionText;
    if (dot < 0) {
      wholeText = token;
      fractionText = '';
    } else {
      // Only one decimal point can survive the number pattern, so any further
      // dot would be a grouping artefact; strip it rather than fail.
      wholeText = token.substring(0, dot).replaceAll('.', '');
      fractionText = token.substring(dot + 1);
    }

    // 15 digits of rupees is already 1000x India's GDP; anything longer is a
    // reference number the regex grabbed by mistake.
    if (wholeText.length > 15) return null;
    final whole = wholeText.isEmpty ? 0 : int.tryParse(wholeText);
    if (whole == null) return null;

    var fraction = 0;
    if (fractionText.isNotEmpty) {
      final twoDigits = fractionText.padRight(2, '0').substring(0, 2);
      fraction = int.tryParse(twoDigits) ?? 0;
      if (fractionText.length > 2) {
        final third = int.tryParse(fractionText[2]) ?? 0;
        if (third >= 5) fraction += 1;
      }
    }

    final total = whole * 100 + fraction;
    return Money(negative ? -total : total, currency: currency.toUpperCase());
  }

  // 'Rs.', 'RS', 'INR', '₹', 'Rupees'. Word-bounded so it cannot eat the 'rs'
  // inside a merchant name.
  static final RegExp _currencyTokenPattern =
      RegExp(r'(?:₹|\bINR\b|\bRS\b\.?|\bRS\.|\bRUPEES?\b)', caseSensitive: false);
  static final RegExp _trailingDashPattern = RegExp(r'/\s*-');
  static final RegExp _numberPattern = RegExp(r'\d[\d,]*(?:\.\d+)?');
  static final RegExp _negativePattern = RegExp(r'-\s*$');

  /// Whole rupees, truncated toward zero. Loses the paise - display only.
  int get rupees => paise ~/ 100;

  /// The paise remainder, 0..99 in magnitude.
  int get paisePart => paise.remainder(100).abs();

  bool get isZero => paise == 0;

  bool get isNegative => paise < 0;

  bool get isPositive => paise > 0;

  Money get abs => paise < 0 ? Money(-paise, currency: currency) : this;

  /// Rupees as a `double`. FOR CHART AXES AND SORT KEYS ONLY. Never feed the
  /// result back into a stored amount - see the class doc.
  double toRupeesDouble() => paise / 100.0;

  Money operator +(Money other) {
    assert(currency == other.currency, 'Cannot add $currency to ${other.currency}');
    return Money(paise + other.paise, currency: currency);
  }

  Money operator -(Money other) {
    assert(currency == other.currency, 'Cannot subtract ${other.currency} from $currency');
    return Money(paise - other.paise, currency: currency);
  }

  /// Integer scaling only (split a bill three ways, apply a count).
  Money operator *(int factor) => Money(paise * factor, currency: currency);

  Money operator -() => Money(-paise, currency: currency);

  bool operator <(Money other) => paise < other.paise;

  bool operator <=(Money other) => paise <= other.paise;

  bool operator >(Money other) => paise > other.paise;

  bool operator >=(Money other) => paise >= other.paise;

  /// Splits into [parts] shares whose sum is exactly this amount - the
  /// remainder paise are spread over the first shares instead of being lost.
  List<Money> split(int parts) {
    assert(parts > 0, 'Cannot split into $parts parts');
    if (parts <= 0) return <Money>[this];
    final base = paise ~/ parts;
    var remainder = paise.remainder(parts);
    final step = remainder.isNegative ? -1 : 1;
    remainder = remainder.abs();
    return List<Money>.generate(parts, (i) {
      final extra = i < remainder ? step : 0;
      return Money(base + extra, currency: currency);
    });
  }

  /// Sums any iterable without an intermediate `double`.
  static Money sum(Iterable<Money> amounts, {String currency = inr}) {
    var total = 0;
    for (final a in amounts) {
      total += a.paise;
    }
    return Money(total, currency: currency);
  }

  /// Indian-grouped text: `₹1,24,500.00` - last three digits, then pairs.
  ///
  /// * [symbol] prefixes the currency symbol (₹ for INR, else the code).
  /// * [decimals] keeps the paise. Turn it off for dense lists.
  /// * [signed] forces a leading `+` on positive amounts.
  String format({bool symbol = true, bool decimals = true, bool signed = false}) {
    final negative = paise < 0;
    final magnitude = paise.abs();
    final whole = magnitude ~/ 100;
    final frac = magnitude.remainder(100);

    final buffer = StringBuffer();
    if (negative) {
      buffer.write('-');
    } else if (signed) {
      buffer.write('+');
    }
    if (symbol) buffer.write(currency == inr ? rupeeSymbol : '$currency ');
    buffer.write(groupIndian(whole));
    if (decimals) {
      buffer.write('.');
      buffer.write(frac.toString().padLeft(2, '0'));
    }
    return buffer.toString();
  }

  /// Short form for tiles and chart labels: `₹1.2L`, `₹12.5K`, `₹1.05Cr`.
  /// Rounded, so never use it where the exact amount matters.
  String formatCompact({bool symbol = true}) {
    final negative = paise < 0;
    final whole = (paise.abs() ~/ 100);
    final prefix = '${negative ? '-' : ''}${symbol ? (currency == inr ? rupeeSymbol : '$currency ') : ''}';
    String trim(double v) {
      final s = v.toStringAsFixed(v.abs() >= 100 ? 0 : (v.abs() >= 10 ? 1 : 2));
      return s.contains('.') ? s.replaceAll(RegExp(r'\.?0+$'), '') : s;
    }

    if (whole >= 10000000) return '$prefix${trim(whole / 10000000)}Cr';
    if (whole >= 100000) return '$prefix${trim(whole / 100000)}L';
    if (whole >= 1000) return '$prefix${trim(whole / 1000)}K';
    return '$prefix${groupIndian(whole)}';
  }

  /// Lakh/crore digit grouping: 1234500 -> `12,34,500`.
  static String groupIndian(int value) {
    final digits = value.abs().toString();
    if (digits.length <= 3) return digits;
    final last3 = digits.substring(digits.length - 3);
    var rest = digits.substring(0, digits.length - 3);
    final groups = <String>[];
    while (rest.length > 2) {
      groups.insert(0, rest.substring(rest.length - 2));
      rest = rest.substring(0, rest.length - 2);
    }
    if (rest.isNotEmpty) groups.insert(0, rest);
    return '${groups.join(',')},$last3';
  }

  Money copyWith({int? paise, String? currency}) =>
      Money(paise ?? this.paise, currency: currency ?? this.currency);

  /// Round-trips through [Money.fromJson]. Stored in drift as the [paise]
  /// integer alone; the map form is for asset/config JSON.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'paise': paise,
        'currency': currency,
      };

  @override
  int compareTo(Money other) => paise.compareTo(other.paise);

  @override
  String toString() => format();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Money && other.paise == paise && other.currency == currency;

  @override
  int get hashCode => Object.hash(paise, currency);
}
