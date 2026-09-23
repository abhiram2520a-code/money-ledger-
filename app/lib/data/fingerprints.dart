import 'package:ledger/models/models.dart';

import 'ids.dart';

/// The identities the ledger de-duplicates on.
///
/// Every number the user sees depends on these being stable. The same money
/// event reaches the app up to four times:
///
/// * live, from the SMS broadcast;
/// * again, from the inbox backfill, with a slightly different timestamp and a
///   `providerId` the live copy never had;
/// * a third time on a dual-SIM phone, delivered to both slots;
/// * and sometimes from two senders at once - the bank and the card issuer
///   both announce one payment.
///
/// A fingerprint that changed between runs would turn each of those into a
/// second transaction. So these functions are deliberately boring: no clock,
/// no randomness, no locale, no rules-pack version.
abstract final class Fingerprints {
  /// How far apart two deliveries of the same SMS may be and still be one
  /// message.
  ///
  /// Kept tight on purpose. Two genuine ten-rupee payments to the same
  /// merchant in the same minute do happen, and `providerId` is the
  /// authoritative tiebreak when it is known.
  static const Duration duplicateWindow = Duration(minutes: 3);

  /// Bucket used by the `(body_hash, sender_header, received_minute)` index.
  static int receivedMinute(DateTime receivedAt) =>
      receivedAt.toUtc().millisecondsSinceEpoch ~/ 60000;

  /// A hash of the message body, normalised so that the same text delivered
  /// twice hashes the same.
  ///
  /// Normalisation strips the zero-width and bidi marks Indian bank SMS carry
  /// surprisingly often, collapses whitespace and upper-cases - all of which
  /// differ between the broadcast copy and the inbox copy of one message.
  static String bodyHash(String body) => LedgerIds.stableHash(normalizeBody(body));

  static String normalizeBody(String body) {
    final StringBuffer out = StringBuffer();
    bool lastWasSpace = true;
    for (final int unit in body.codeUnits) {
      if (_isInvisible(unit)) continue;
      final bool isSpace = unit == 0x20 ||
          unit == 0x09 ||
          unit == 0x0A ||
          unit == 0x0D ||
          unit == 0xA0;
      if (isSpace) {
        if (!lastWasSpace) out.write(' ');
        lastWasSpace = true;
        continue;
      }
      lastWasSpace = false;
      out.writeCharCode(_toUpper(unit));
    }
    return out.toString().trim();
  }

  /// `VM-HDFCBK-S` -> `HDFCBK`.
  ///
  /// The two-letter prefix is assigned by the delivering telco, not by the
  /// bank, and the `-S`/`-T`/`-P` suffix is the TCCCPR content category. Both
  /// vary for the same sender, so neither may take part in an identity.
  static String normalizeSender(String sender) {
    final StringBuffer out = StringBuffer();
    for (final int unit in sender.codeUnits) {
      if (_isInvisible(unit)) continue;
      final int u = _toUpper(unit);
      final bool alnum = (u >= 0x30 && u <= 0x39) || (u >= 0x41 && u <= 0x5A);
      if (alnum || u == 0x2D) out.writeCharCode(u);
    }
    String s = out.toString();
    if (s.length > 3 && s[2] == '-') s = s.substring(3);
    if (s.length > 2 && s[s.length - 2] == '-') s = s.substring(0, s.length - 2);
    return s.replaceAll('-', '');
  }

  /// Merchant text, reduced to something two messages about the same merchant
  /// agree on. Acquirer prefixes and terminal ids are what make raw merchant
  /// strings useless as an identity.
  static String normalizeMerchant(String? raw) {
    if (raw == null) return '';
    final StringBuffer out = StringBuffer();
    for (final int unit in raw.codeUnits) {
      if (_isInvisible(unit)) continue;
      final int u = _toUpper(unit);
      final bool alnum = (u >= 0x30 && u <= 0x39) || (u >= 0x41 && u <= 0x5A);
      out.writeCharCode(alnum ? u : 0x20);
    }
    String s = out.toString().trim().replaceAll(RegExp(r'\s+'), ' ');
    for (final String prefix in _acquirerPrefixes) {
      if (s.startsWith('$prefix ')) {
        s = s.substring(prefix.length + 1);
      } else if (s.startsWith(prefix) && s.length > prefix.length + 2) {
        s = s.substring(prefix.length);
      }
    }
    s = s.replaceAll(RegExp(r'\s*\d{4,}$'), '').trim();
    return s;
  }

  static const List<String> _acquirerPrefixes = <String>[
    'RAZ',
    'PAYU',
    'BILLDESK',
    'CCAVENUE',
    'PYTM',
    'PAYTM',
    'PHONEPE',
    'GPAY',
    'BHARATPE',
    'EAZYDINE',
    'PAYZAPP',
    'BBPS',
  ];

  /// The identity of a money event.
  ///
  /// When the message carried a reference - a UPI RRN, a UTR, a card auth code
  /// - that reference IS the event, and amount plus direction is enough to
  /// make it unique. Without one, the fingerprint falls back to the fields a
  /// second copy of the same message would repeat verbatim.
  ///
  /// The date is deliberately part of the fallback key: two identical ninety
  /// rupee chai payments on two different days are two transactions, and the
  /// user would notice one of them missing far sooner than a duplicate.
  static String transaction(Transaction txn) {
    final String? ref = _cleanRef(txn.ref);
    if (ref != null) {
      return LedgerIds.hashParts(<Object?>[
        'ref',
        txn.direction.wire,
        txn.amount.abs.paise,
        ref,
      ]);
    }
    return LedgerIds.hashParts(<Object?>[
      'fields',
      txn.direction.wire,
      txn.amount.abs.paise,
      txn.bookingDate,
      Account.normalizeTail(txn.accountTail) ?? '',
      Account.normalizeTail(txn.cardTail) ?? '',
      txn.channel.wire,
      normalizeMerchant(txn.merchantName ?? txn.merchantRaw),
      (txn.vpa ?? '').toLowerCase(),
    ]);
  }

  /// Bill idempotency. Reminders for one bill are re-sent several times and
  /// every one of them must land on the same row.
  static String billCycle({
    String? billerKey,
    String? consumerRef,
    String? accountTail,
    required DateTime cycleDate,
  }) {
    final String cycle =
        '${cycleDate.toLocal().year}-${cycleDate.toLocal().month.toString().padLeft(2, '0')}';
    return LedgerIds.hashParts(<Object?>[
      (billerKey ?? '').toUpperCase(),
      (consumerRef ?? Account.normalizeTail(accountTail) ?? 'na').toUpperCase(),
      cycle,
    ]);
  }

  static String? _cleanRef(String? ref) {
    if (ref == null) return null;
    final String s = ref.replaceAll(RegExp(r'[^0-9A-Za-z]'), '').toUpperCase();
    // Short references are not references. A three-digit "ref" collides across
    // unrelated payments and would merge two real transactions into one, which
    // is worse than a duplicate.
    return s.length >= 6 ? s : null;
  }

  static bool _isInvisible(int unit) =>
      (unit >= 0x200B && unit <= 0x200F) ||
      (unit >= 0x202A && unit <= 0x202E) ||
      (unit >= 0x2066 && unit <= 0x2069) ||
      unit == 0xFEFF;

  static int _toUpper(int unit) =>
      (unit >= 0x61 && unit <= 0x7A) ? unit - 32 : unit;
}
