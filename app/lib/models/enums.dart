/// Every closed vocabulary in the app.
///
/// Each enum carries a `wire` string which is the ONLY form ever written to
/// JSON, to the database, or read from `rules/*.json`. Dart identifier names
/// are free to change; wire values are not - they are persisted user data.
///
/// Every `fromWire` is total: unknown input falls back to the enum's own
/// unknown/neutral member rather than throwing, because a rules pack pushed
/// from the config server can legitimately contain a value this build has
/// never heard of, and the app must keep working.
library;

T? _byWire<T>(List<T> values, String? wire, String Function(T) wireOf) {
  if (wire == null) return null;
  final needle = wire.trim().toLowerCase();
  if (needle.isEmpty) return null;
  for (final v in values) {
    if (wireOf(v).toLowerCase() == needle) return v;
  }
  return null;
}

/// Which way the money moved, from the account holder's point of view.
///
/// `parser_rules.json` also uses the literal `'infer'` for rules that read the
/// direction out of the message text; that is [directionInferWire] and is
/// deliberately NOT a member here, because an inferred direction must be
/// resolved to debit or credit before a [TxnDirection] exists at all.
enum TxnDirection {
  debit('debit'),
  credit('credit');

  const TxnDirection(this.wire);

  final String wire;

  static TxnDirection? fromWire(String? wire) =>
      _byWire(TxnDirection.values, wire, (v) => v.wire);

  bool get isDebit => this == TxnDirection.debit;

  bool get isCredit => this == TxnDirection.credit;

  TxnDirection get opposite =>
      this == TxnDirection.debit ? TxnDirection.credit : TxnDirection.debit;
}

/// The value `parser_rules.json` uses for "read the direction from the
/// message body" - see [TxnDirection].
const String directionInferWire = 'infer';

/// The rail the money travelled on. Mirrors the `channel` field of
/// `rules/parser_rules.json`.
enum TxnChannel {
  upi('upi'),
  card('card'),
  netbanking('netbanking'),
  atm('atm'),
  nach('nach'),
  impsNeft('imps_neft'),
  cash('cash'),
  unknown('unknown');

  const TxnChannel(this.wire);

  final String wire;

  /// Falls back to [TxnChannel.unknown] - never throws.
  static TxnChannel fromWire(String? wire) =>
      _byWire(TxnChannel.values, wire, (v) => v.wire) ?? TxnChannel.unknown;
}

/// What a category does to the user's net worth. Mirrors the `kind` field of
/// `rules/categories.json`, and the whole point of the app hangs on it:
/// ONLY [expense] counts as spending.
enum CategoryKind {
  /// Money left the user's net worth. Counts toward totals and budgets.
  expense('expense'),

  /// Money entered the user's net worth.
  income('income'),

  /// Money moved between accounts the user already owns (self-transfer, credit
  /// card bill payment, ATM withdrawal, wallet top-up). Net zero. NEVER spend.
  transfer('transfer'),

  /// Money moved into an asset the user still owns (SIP, FD, gold). Net zero
  /// for spend; reported separately as savings.
  investment('investment');

  const CategoryKind(this.wire);

  final String wire;

  static CategoryKind fromWire(String? wire) =>
      _byWire(CategoryKind.values, wire, (v) => v.wire) ?? CategoryKind.expense;

  /// The single predicate every spend total must filter on.
  bool get countsAsSpend => this == CategoryKind.expense;

  bool get countsAsIncome => this == CategoryKind.income;

  /// Transfers and investments move the user's own money and are excluded from
  /// both spend and income.
  bool get isNetZero =>
      this == CategoryKind.transfer || this == CategoryKind.investment;
}

/// What kind of message a parser rule matched. Mirrors the `txn_type` field of
/// `rules/parser_rules.json`.
///
/// This is the negative-grammar gate: an OTP that quotes an amount, a "spend
/// 5000 and get cashback" promo and a balance alert all look like debits, and
/// booking any of them invents money the user never spent.
enum TxnType {
  /// A settled money movement. Creates a ledger entry.
  transaction('transaction'),

  /// A bill / due-date notice. Creates a [Bill], not a spend.
  billReminder('bill_reminder'),

  /// "Avl Bal Rs 43,210.55". Updates an account balance, never a transaction.
  balanceInfo('balance_info'),

  /// Marketing. Discarded.
  promo('promo'),

  /// One-time password. Discarded, and never persisted in full.
  otp('otp'),

  /// A future-dated debit notice ("Rs 8,450 will be debited on 05/10").
  /// Not a transaction - booking it double-counts the EMI when it settles.
  preDebitNotice('pre_debit_notice'),

  /// Matched no rule, or the rule pack used a type this build does not know.
  unknown('unknown');

  const TxnType(this.wire);

  final String wire;

  static TxnType fromWire(String? wire) =>
      _byWire(TxnType.values, wire, (v) => v.wire) ?? TxnType.unknown;

  /// Only these two ever reach the ledger.
  bool get createsLedgerEntry =>
      this == TxnType.transaction || this == TxnType.billReminder;
}

/// How a [CategoryResult] was decided. Shown to the user so a wrong category
/// is always explainable and always correctable.
enum CategorySource {
  /// Exact or token match in `rules/merchants.json`.
  dictionary('dictionary'),

  /// Matched a VPA prefix such as `swiggy@`.
  vpa('vpa'),

  /// Derived from the rail alone (ATM withdrawal -> transfer, for example).
  channel('channel'),

  /// The matching parser rule carried a `forced_category`.
  parserRule('parser_rule'),

  /// A [UserRule] the user created on this device.
  userRule('user_rule'),

  /// The user picked the category by hand.
  manual('manual'),

  /// Nothing matched. Goes to the Uncategorized queue and asks the user.
  /// The app NEVER guesses and NEVER calls the cloud to decide this.
  unknown('unknown');

  const CategorySource(this.wire);

  final String wire;

  static CategorySource fromWire(String? wire) =>
      _byWire(CategorySource.values, wire, (v) => v.wire) ?? CategorySource.unknown;

  /// True when the user (not a rule pack) decided, which means reparsing must
  /// never overwrite it.
  bool get isUserAuthored =>
      this == CategorySource.manual || this == CategorySource.userRule;
}

/// How precisely the transaction date is known.
enum DatePrecision {
  /// Date and time both came from the message.
  dateTime('datetime'),

  /// Only a date came from the message.
  date('date'),

  /// The message gave a day and month but no year; the year was inferred.
  inferredYear('inferred_year'),

  /// The message carried no date at all, so the time it was received is used.
  receivedFallback('received_fallback');

  const DatePrecision(this.wire);

  final String wire;

  static DatePrecision fromWire(String? wire) =>
      _byWire(DatePrecision.values, wire, (v) => v.wire) ?? DatePrecision.receivedFallback;
}

/// Lifecycle of a ledger row.
enum TxnStatus {
  /// Settled and counted.
  posted('posted'),

  /// Authorised but not settled (card hold). Counted, but correctable.
  pending('pending'),

  /// Parsed, but the app cannot name the category on its own. Shown in the
  /// review queue - and still counted, see [countsInTotals].
  needsReview('needs_review'),

  /// Reversed by a later message. Excluded from totals; keeps the audit trail.
  reversed('reversed'),

  /// Deleted by the user. Excluded from everything.
  voided('void');

  const TxnStatus(this.wire);

  final String wire;

  static TxnStatus fromWire(String? wire) =>
      _byWire(TxnStatus.values, wire, (v) => v.wire) ?? TxnStatus.posted;

  /// The statuses that a spend or income total may include.
  ///
  /// [needsReview] IS included, deliberately. "We are not sure what to call
  /// this" is a labelling problem; the money still left the account. Leaving
  /// an unlabelled debit out of the total produces a number that is quietly
  /// too low, and a total that is too low is the one error the user cannot
  /// detect by looking at it - they have no second source to compare against.
  /// A wrongly-categorised rupee is visible and one tap from fixed; a missing
  /// rupee is invisible forever. Only [reversed] and [voided], where the money
  /// demonstrably did not stay gone, are excluded.
  bool get countsInTotals =>
      this == TxnStatus.posted ||
      this == TxnStatus.pending ||
      this == TxnStatus.needsReview;
}

/// Where a ledger row came from.
enum TxnSource {
  sms('sms'),
  notification('notification'),
  manual('manual'),
  imported('import'),

  /// Created by the app itself, e.g. the matching leg of a transfer.
  derived('derived');

  const TxnSource(this.wire);

  final String wire;

  static TxnSource fromWire(String? wire) =>
      _byWire(TxnSource.values, wire, (v) => v.wire) ?? TxnSource.sms;
}

/// What kind of thing an [Account] is. Drives the transfer rules: money moving
/// between two accounts the user owns is never spend.
enum AccountType {
  savings('savings'),
  current('current'),
  creditCard('credit_card'),
  wallet('wallet'),
  cash('cash'),
  loan('loan'),
  investment('investment'),
  unknown('unknown');

  const AccountType(this.wire);

  final String wire;

  static AccountType fromWire(String? wire) =>
      _byWire(AccountType.values, wire, (v) => v.wire) ?? AccountType.unknown;

  /// A liability's balance is money owed, so a debit on it increases the
  /// balance rather than decreasing it.
  bool get isLiability =>
      this == AccountType.creditCard || this == AccountType.loan;
}

/// Lifecycle of a [Bill].
enum BillStatus {
  upcoming('upcoming'),
  due('due'),
  overdue('overdue'),
  paid('paid'),

  /// The user dismissed it.
  skipped('skipped'),
  unknown('unknown');

  const BillStatus(this.wire);

  final String wire;

  static BillStatus fromWire(String? wire) =>
      _byWire(BillStatus.values, wire, (v) => v.wire) ?? BillStatus.unknown;
}

/// Where a [RawMessage] was ingested from.
enum IngestSource {
  /// Delivered live by the SMS broadcast receiver.
  smsRealtime('sms_realtime'),

  /// Read out of the device inbox during historical backfill.
  smsBackfill('sms_backfill'),

  /// Read from a posted notification.
  notification('notification'),

  /// Typed in by the user.
  manual('manual');

  const IngestSource(this.wire);

  final String wire;

  static IngestSource fromWire(String? wire) =>
      _byWire(IngestSource.values, wire, (v) => v.wire) ?? IngestSource.smsRealtime;
}

/// What the pipeline has done with a [RawMessage] so far. Drives the
/// re-parse sweep: when a rules pack updates, only messages in a non-final
/// state, or whose rule changed, are re-run.
enum ParseState {
  /// Ingested, not yet parsed.
  pending('pending'),

  /// Parsed into a transaction.
  parsed('parsed'),

  /// Deliberately not a transaction - see the matching [TxnType].
  rejectedPromo('rejected_promo'),
  rejectedOtp('rejected_otp'),
  rejectedNonFinancial('rejected_non_financial'),

  /// From a trusted sender, but no rule matched the body. This is the queue
  /// that new rule packs are written against.
  noRuleMatched('no_rule_matched'),

  /// Parsed, but from an untrusted sender (a 10-digit number, an unknown
  /// shortcode) or with contradictory fields. Never posted to the ledger.
  quarantined('quarantined');

  const ParseState(this.wire);

  final String wire;

  static ParseState fromWire(String? wire) =>
      _byWire(ParseState.values, wire, (v) => v.wire) ?? ParseState.pending;

  /// States a re-parse sweep should revisit after a rules update.
  bool get isReparseCandidate =>
      this == ParseState.pending || this == ParseState.noRuleMatched;
}

/// The outcome of one parse attempt. See `ParseOutcome`.
enum ParseStatus {
  /// A rule matched and produced a usable [ParsedMessage].
  parsed('parsed'),

  /// A reject pattern or a non-transaction rule matched. Not an error.
  rejected('rejected'),

  /// The sender was trusted but nothing matched the body.
  noRuleMatched('no_rule_matched'),

  /// A rule matched but the extracted fields contradict each other (two
  /// candidate amounts, no direction). Never posted silently.
  ambiguous('ambiguous'),

  /// The sender is not a known financial sender. The body is discarded.
  untrustedSender('untrusted_sender');

  const ParseStatus(this.wire);

  final String wire;

  static ParseStatus fromWire(String? wire) =>
      _byWire(ParseStatus.values, wire, (v) => v.wire) ?? ParseStatus.noRuleMatched;
}

/// How a [UserRule] decides whether it applies.
enum UserRuleMatch {
  /// Normalised merchant string equals the pattern.
  merchantExact('merchant_exact'),

  /// Normalised merchant string contains the pattern.
  merchantContains('merchant_contains'),

  /// Full VPA equals the pattern (`someone@okaxis`).
  vpaExact('vpa_exact'),

  /// VPA starts with the pattern (`swiggy@`). Handles alone (`@okaxis`)
  /// identify the payment app, never the merchant, and must not be used.
  vpaPrefix('vpa_prefix'),

  /// Normalised sender header equals the pattern (`HDFCBK`).
  senderExact('sender_exact'),

  /// Message body contains the pattern.
  bodyContains('body_contains');

  const UserRuleMatch(this.wire);

  final String wire;

  static UserRuleMatch fromWire(String? wire) =>
      _byWire(UserRuleMatch.values, wire, (v) => v.wire) ?? UserRuleMatch.merchantContains;
}

/// Runtime permission state, as reported by a [MessageSource]. Deliberately
/// platform-neutral so no contract leaks `permission_handler` types.
enum PermissionState {
  granted('granted'),
  denied('denied'),

  /// Denied with "don't ask again": only a trip to system settings can change
  /// it, so the UI must offer that instead of another prompt.
  permanentlyDenied('permanently_denied'),
  restricted('restricted'),

  /// The platform has no such permission (iOS, desktop).
  unsupported('unsupported'),
  unknown('unknown');

  const PermissionState(this.wire);

  final String wire;

  static PermissionState fromWire(String? wire) =>
      _byWire(PermissionState.values, wire, (v) => v.wire) ?? PermissionState.unknown;

  bool get isGranted => this == PermissionState.granted;
}

/// Where a loaded rules pack came from.
enum RulesOrigin {
  /// `assets/rules/*.json`, compiled into the APK. Always available, works on
  /// first launch with no network, and is the fallback whenever a downloaded
  /// pack fails to validate.
  bundled('bundled'),

  /// Downloaded from the config server and cached on disk. Optional: the app
  /// is fully functional without it.
  remote('remote'),

  /// Rules the user created on this device.
  user('user');

  const RulesOrigin(this.wire);

  final String wire;

  static RulesOrigin fromWire(String? wire) =>
      _byWire(RulesOrigin.values, wire, (v) => v.wire) ?? RulesOrigin.bundled;
}
