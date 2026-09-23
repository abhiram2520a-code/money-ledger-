import 'package:flutter/foundation.dart';

/// What the LOCAL part of a UPI address looks like.
///
/// The handle (`@ybl`, `@okaxis`) is deliberately absent from this decision:
/// it names the payment APP, never the payee. All of the signal in a VPA
/// lives to the left of the `@`.
enum VpaShape {
  /// No VPA at all.
  none,

  /// A named merchant: `swiggystores@icici`. Should already have resolved in
  /// the dictionary stage; if it did not, the merchant is simply unknown to
  /// us by name.
  merchantNamed,

  /// A dynamic QR / acquirer code: `paytmqr2810050501@paytm`,
  /// `q9876543210@ybl`, `bharatpe.9012345@fbpe`.
  ///
  /// This is strong evidence that money was SPENT at a shop, and no evidence
  /// at all about which shop. The two facts are different, and conflating
  /// them is how a tea stall becomes "Shopping".
  merchantQrOpaque,

  /// `9876543210@ybl` - a person, addressed by phone number.
  personPhone,

  /// `rahul.sharma@okaxis` - a person, addressed by name.
  personName,

  /// Anything else.
  ambiguous,
}

/// A parsed UPI address.
@immutable
class VpaParts {
  const VpaParts({
    required this.full,
    required this.local,
    required this.handle,
    required this.shape,
  });

  static const VpaParts none = VpaParts(
    full: '',
    local: '',
    handle: '',
    shape: VpaShape.none,
  );

  /// The whole address, lower-cased: `swiggy@axisbank`.
  final String full;

  /// Everything before the `@`.
  final String local;

  /// Everything from the `@` onwards, including it: `@ybl`. Never used to
  /// decide a category.
  final String handle;

  final VpaShape shape;

  bool get isEmpty => full.isEmpty;

  bool get isPerson =>
      shape == VpaShape.personPhone || shape == VpaShape.personName;

  bool get isOpaqueMerchant => shape == VpaShape.merchantQrOpaque;

  /// The payment app behind [handle], when we recognise it. For the UI only:
  /// "paid via PhonePe" is true and useful; "PhonePe is the merchant" is not.
  String? get paymentApp => VpaHeuristics.appForHandle(handle);

  @override
  String toString() => 'VpaParts($full, ${shape.name})';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VpaParts &&
          other.full == full &&
          other.local == local &&
          other.handle == handle &&
          other.shape == shape;

  @override
  int get hashCode => Object.hash(full, local, handle, shape);
}

/// UPI address heuristics.
///
/// The one rule that matters: **a PSP handle is not a merchant.** `@ybl` means
/// the payer or payee happens to use PhonePe. Categorising on it would file
/// every UPI payment in the country under three buckets, which is exactly the
/// bug that makes users say "this app thinks everything is PhonePe".
abstract final class VpaHeuristics {
  /// Handles that identify a payment service provider or a sponsor bank.
  /// Mirrors `psp_handles` in `rules/merchants.json`, plus the long tail.
  static const Set<String> pspHandles = <String>{
    '@ybl', '@ibl', '@axl', '@axisb', '@axisbank',
    '@okaxis', '@okhdfcbank', '@okicici', '@oksbi', '@okbizaxis',
    '@paytm', '@ptys', '@ptaxis', '@ptsbi', '@pthdfc',
    '@apl', '@yapl', '@rapl',
    '@upi', '@abfspay', '@superyes', '@jupiteraxis', '@naviaxis',
    '@icici', '@hdfcbank', '@sbi', '@kotak', '@fbl', '@federal',
    '@yesbank', '@yesbankltd', '@idfcbank', '@idfcfirst', '@indus',
    '@fam', '@slice', '@jio', '@freecharge', '@waaxis', '@wahdfcbank',
    '@fbpe', '@bharatpe', '@timecosmos', '@airtel', '@mbk', '@dbs',
  };

  /// Display names, for explanations only.
  static const Map<String, String> _apps = <String, String>{
    '@ybl': 'PhonePe',
    '@ibl': 'PhonePe',
    '@axl': 'PhonePe',
    '@okaxis': 'Google Pay',
    '@okhdfcbank': 'Google Pay',
    '@okicici': 'Google Pay',
    '@oksbi': 'Google Pay',
    '@okbizaxis': 'Google Pay',
    '@paytm': 'Paytm',
    '@ptys': 'Paytm',
    '@ptaxis': 'Paytm',
    '@ptsbi': 'Paytm',
    '@pthdfc': 'Paytm',
    '@apl': 'Amazon Pay',
    '@yapl': 'Amazon Pay',
    '@upi': 'BHIM',
    '@waaxis': 'WhatsApp Pay',
    '@wahdfcbank': 'WhatsApp Pay',
    '@fbpe': 'BharatPe',
    '@bharatpe': 'BharatPe',
    '@slice': 'Slice',
    '@fam': 'Fampay',
    '@jupiteraxis': 'Jupiter',
    '@naviaxis': 'Navi',
    '@freecharge': 'Freecharge',
  };

  /// Acquirer prefixes that mark a dynamic or static merchant QR code. These
  /// are the payment RAIL's own codes: they identify a terminal, not a shop.
  static const Set<String> acquirerQrPrefixes = <String>{
    'paytmqr', 'bharatpe', 'bpay', 'gpay-', 'razorpay', 'payu', 'billdesk',
    'ccavenue', 'cashfree', 'pinelabs', 'worldline', 'merchantpay',
  };

  static final RegExp _qrPrefix = RegExp(
    r'^(paytmqr|bharatpe|bpay|gpay-|merchantpay|razorpay|payu|'
    r'billdesk|ccavenue|cashfree|pinelabs|worldline)[a-z0-9._-]{4,}$',
  );

  /// `q9876543210`, `mab0012345` - a letter or two and then a terminal id.
  static final RegExp _qrNumeric = RegExp(r'^(q|mab|bp|pz|sq)[0-9]{6,}$');

  static final RegExp _phone = RegExp(r'^[6-9][0-9]{9}$');

  static final RegExp _dottedName =
      RegExp(r'^[a-z]{2,}[._-][a-z][a-z0-9._-]*$');

  static final RegExp _nameWithDigits = RegExp(r'^[a-z]{3,20}[0-9]{1,6}$');

  static final RegExp _hasDigit = RegExp(r'[0-9]');

  static final RegExp _alphaOnly = RegExp(r'^[a-z]+$');

  /// Splits and classifies [vpa]. Total: never throws.
  static VpaParts parse(String? vpa) {
    if (vpa == null) return VpaParts.none;
    final full = vpa.trim().toLowerCase();
    if (full.isEmpty) return VpaParts.none;

    final at = full.indexOf('@');
    if (at < 0) {
      // No handle at all - treat the whole string as the payee name.
      return VpaParts(
        full: full,
        local: full,
        handle: '',
        shape: classifyLocal(full),
      );
    }
    // A bare handle (`@ybl`) carries no payee at all.
    if (at == 0) {
      return VpaParts(
        full: full,
        local: '',
        handle: full,
        shape: VpaShape.ambiguous,
      );
    }

    final local = full.substring(0, at);
    final handle = full.substring(at);
    return VpaParts(
      full: full,
      local: local,
      handle: handle,
      shape: classifyLocal(local),
    );
  }

  /// Classifies the local part. Order matters: acquirer QR codes first,
  /// because `q9876543210@ybl` also looks like a phone number with a letter
  /// in front of it.
  static VpaShape classifyLocal(String local) {
    if (local.isEmpty) return VpaShape.ambiguous;

    if (_qrPrefix.hasMatch(local) || _qrNumeric.hasMatch(local)) {
      return VpaShape.merchantQrOpaque;
    }

    // A long opaque alphanumeric blob with digits in it is an acquirer code,
    // not a name. `swiggystores` is long but has no digits, so it is safe.
    if (local.length >= 12 && _hasDigit.hasMatch(local) && !local.contains('.')) {
      return VpaShape.merchantQrOpaque;
    }

    if (_phone.hasMatch(local)) return VpaShape.personPhone;

    if (_dottedName.hasMatch(local)) return VpaShape.personName;

    if (_nameWithDigits.hasMatch(local)) return VpaShape.personName;

    if (_alphaOnly.hasMatch(local)) return VpaShape.merchantNamed;

    return VpaShape.ambiguous;
  }

  /// True when [value] is nothing but a PSP handle. Such a string must never
  /// reach a merchant lookup.
  static bool isPspHandle(String? value) {
    if (value == null) return false;
    final needle = value.trim().toLowerCase();
    if (needle.isEmpty) return false;
    return pspHandles.contains(needle.startsWith('@') ? needle : '@$needle');
  }

  /// True when [prefix] is a payment-rail acquirer code rather than a
  /// merchant's own VPA prefix. `swiggy@` is a merchant; `paytmqr` is a QR
  /// terminal that could belong to any shop in the country.
  static bool isAcquirerPrefix(String? prefix) {
    if (prefix == null) return false;
    final needle = prefix.trim().toLowerCase();
    if (needle.isEmpty) return false;
    for (final acquirer in acquirerQrPrefixes) {
      if (needle.startsWith(acquirer)) return true;
    }
    return false;
  }

  /// The payment app behind a handle, for explanations. Null when unknown.
  static String? appForHandle(String handle) {
    if (handle.isEmpty) return null;
    final needle = handle.startsWith('@') ? handle : '@$handle';
    return _apps[needle.toLowerCase()];
  }
}
