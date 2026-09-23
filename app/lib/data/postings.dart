import 'package:flutter/foundation.dart';
import 'package:ledger/models/models.dart';

import 'ids.dart';

/// Which side of the user's net worth an account sits on.
///
/// This is what makes double-counting structurally impossible rather than
/// heuristically unlikely: a spend total is the sum of postings against
/// [AccountClass.expense], and a credit-card bill payment produces no such
/// posting, so no rename, no new SMS template and no mis-parsed payee can
/// make it enter a spend total.
enum AccountClass {
  asset('asset'),
  liability('liability'),
  expense('expense'),
  income('income'),
  equity('equity');

  const AccountClass(this.wire);

  final String wire;

  static AccountClass fromWire(String? wire) {
    for (final AccountClass v in AccountClass.values) {
      if (v.wire == wire) return v;
    }
    return AccountClass.asset;
  }

  bool get isRealMoney => this == AccountClass.asset || this == AccountClass.liability;
}

/// Which role a posting plays inside its transaction.
enum PostingLeg {
  source('source'),
  dest('dest'),
  fee('fee'),
  tax('tax');

  const PostingLeg(this.wire);

  final String wire;

  static PostingLeg fromWire(String? wire) {
    for (final PostingLeg v in PostingLeg.values) {
      if (v.wire == wire) return v;
    }
    return PostingLeg.source;
  }
}

/// One signed movement against one account.
///
/// Debits are positive, credits are negative, and the postings of a
/// transaction always sum to zero. That invariant is asserted on every write
/// ([PostingEngine.build] refuses to return an unbalanced set) and is the only
/// reason account balances and the reconciliation engine can be trusted.
@immutable
class Posting {
  const Posting({
    required this.id,
    required this.txnId,
    required this.accountId,
    required this.accountClass,
    required this.amountPaise,
    required this.occurredAt,
    required this.bookingDate,
    this.leg = PostingLeg.source,
  });

  factory Posting.fromJson(Map<String, dynamic> json) => Posting(
        id: jString(json['id']),
        txnId: jString(json['txnId']),
        accountId: jString(json['accountId']),
        accountClass: AccountClass.fromWire(jStringOrNull(json['accountClass'])),
        amountPaise: jInt(json['amountPaise']),
        occurredAt: jDate(json['occurredAt']),
        bookingDate: jString(json['bookingDate']),
        leg: PostingLeg.fromWire(jStringOrNull(json['leg'])),
      );

  final String id;
  final String txnId;
  final String accountId;
  final AccountClass accountClass;

  /// SIGNED paise. Positive is a debit (value arrives at this account),
  /// negative is a credit (value leaves it).
  final int amountPaise;

  final DateTime occurredAt;
  final String bookingDate;
  final PostingLeg leg;

  bool get isDebit => amountPaise > 0;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'txnId': txnId,
        'accountId': accountId,
        'accountClass': accountClass.wire,
        'amountPaise': amountPaise,
        'occurredAt': jMillis(occurredAt),
        'bookingDate': bookingDate,
        'leg': leg.wire,
      };

  @override
  String toString() =>
      'Posting($accountId ${amountPaise > 0 ? '+' : ''}$amountPaise ${leg.wire})';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Posting &&
          other.id == id &&
          other.txnId == txnId &&
          other.accountId == accountId &&
          other.accountClass == accountClass &&
          other.amountPaise == amountPaise &&
          jTimeEquals(other.occurredAt, occurredAt) &&
          other.bookingDate == bookingDate &&
          other.leg == leg;

  @override
  int get hashCode => Object.hash(
        id,
        txnId,
        accountId,
        accountClass,
        amountPaise,
        jTimeHash(occurredAt),
        bookingDate,
        leg,
      );
}

/// Stable ids for the accounts the app owns rather than the user.
///
/// They are string constants, not generated ids, because they are written into
/// stored postings and must mean the same thing after a reinstall.
abstract final class LedgerAccounts {
  /// Cash in hand. An ATM withdrawal moves money here; it is not spending
  /// until the user says what the cash went on.
  static const String cash = 'sys:cash';

  /// One leg of a self-transfer whose other leg has not arrived yet. A
  /// non-zero balance here older than a day means we saw money leave an
  /// account and never saw it land.
  static const String inTransit = 'sys:intransit';

  /// The honesty plug. Reconciliation drift the user chose not to explain
  /// lands here, where it can never reach a category or a budget.
  static const String unreconciled = 'sys:unreconciled';

  /// The other side of an opening-balance anchor.
  static const String opening = 'sys:opening';

  /// An account the user has not told us about, identified only by its tail.
  static String forTail(String tail, {required bool card}) =>
      '${card ? 'card' : 'bank'}:$tail';

  /// The account that represents a spend category. Categories ARE accounts:
  /// that is what lets "spent on food" and "moved to savings" share one shape.
  static String forCategory(String categoryPath) => 'cat:$categoryPath';

  /// The asset an investment buys. A SIP debit is a purchase, not a spend.
  static String forInvestment(String categoryPath) => 'inv:$categoryPath';

  static bool isSystem(String accountId) => accountId.startsWith('sys:');

  static bool isCategory(String accountId) => accountId.startsWith('cat:');
}

/// Category paths that carry structural meaning. They must exist in
/// `rules/categories.json`; the validator in `tools/validate_rules.dart` is
/// what keeps that true.
abstract final class TransferPaths {
  static const String selfTransfer = 'transfers/self_transfer';
  static const String creditCardPayment = 'transfers/credit_card_payment';
  static const String atmWithdrawal = 'transfers/atm_withdrawal';
  static const String walletTopup = 'transfers/wallet_topup';
  static const String p2pSent = 'transfers/p2p_sent';
  static const String p2pReceived = 'transfers/p2p_received';
  static const String loanRepayment = 'transfers/loan_repayment_principal';
}

/// Turns one [Transaction] into a balanced set of [Posting]s.
///
/// This is the load-bearing piece of the whole ledger. Everything that must
/// never be counted twice is handled here, once:
///
/// * a **credit-card spend** debits an expense account and credits the CARD,
///   so net worth falls at swipe time;
/// * the later **card bill payment** debits the card and credits the bank -
///   there is NO expense posting, so it cannot appear in a spend total;
/// * an **ATM withdrawal** moves value into [LedgerAccounts.cash];
/// * a **wallet top-up** moves value into the wallet;
/// * a **self-transfer** posts through [LedgerAccounts.inTransit], so the two
///   halves of one movement - which arrive as two separate SMS from two
///   different senders - cancel instead of showing up as an expense plus an
///   income;
/// * an **investment** debits an asset, never an expense.
abstract final class PostingEngine {
  /// The postings for [txn]. Always balanced, always at least two legs.
  ///
  /// [moneyAccountType] and [counterAccountType] refine the account class when
  /// the caller has already resolved the [Account] rows; without them the
  /// class is inferred from the transaction, which is correct for every
  /// template in `rules/parser_rules.json`.
  static List<Posting> build(
    Transaction txn, {
    AccountType? moneyAccountType,
    AccountType? counterAccountType,
    String? counterAccountOverride,
    Money? statedFee,
  }) {
    final int amount = txn.amount.abs.paise;
    if (amount <= 0) return const <Posting>[];

    final String moneyId = moneyAccountId(txn);
    final AccountClass moneyClass = _classForMoneyAccount(txn, moneyAccountType);
    // The card a bill payment pays down is identified in the message by its
    // tail. When the user actually has that card as an account, the posting
    // MUST land on that account's id - otherwise the spend and the payment
    // accumulate on two different accounts and neither balance is real.
    final String counterId = counterAccountOverride ?? counterAccountId(txn);
    final AccountClass counterClass = _classForCounterAccount(txn, counterAccountType);

    // A debit moves value OUT of the money account and INTO the counter
    // account; a credit does the reverse. Expressing it once, here, is what
    // keeps a refund from being booked as income.
    final bool debit = txn.direction.isDebit;
    final List<Posting> postings = <Posting>[
      _posting(txn, counterId, counterClass, debit ? amount : -amount,
          debit ? PostingLeg.dest : PostingLeg.source, 0),
      _posting(txn, moneyId, moneyClass, debit ? -amount : amount,
          debit ? PostingLeg.source : PostingLeg.dest, 1),
    ];

    // An ATM fee, when the message states one, is a third and fourth leg. It
    // IS an expense - unlike the withdrawal itself.
    final int fee = statedFee?.abs.paise ?? 0;
    if (fee > 0) {
      postings
        ..add(_posting(txn, LedgerAccounts.forCategory('fees_charges/atm_fee'),
            AccountClass.expense, fee, PostingLeg.fee, 2))
        ..add(_posting(txn, moneyId, moneyClass, -fee, PostingLeg.fee, 3));
    }

    assert(
      postings.fold<int>(0, (int a, Posting p) => a + p.amountPaise) == 0,
      'postings for ${txn.id} do not balance',
    );
    return postings;
  }

  /// The account the money physically left or arrived in.
  static String moneyAccountId(Transaction txn) {
    final String? explicit = txn.accountId;
    if (explicit != null && explicit.isNotEmpty) return explicit;
    if (isCardBillPayment(txn)) {
      final String? bank = Account.normalizeTail(txn.accountTail);
      if (bank != null) return LedgerAccounts.forTail(bank, card: false);
      return LedgerAccounts.unreconciled;
    }
    final String? card = Account.normalizeTail(txn.cardTail);
    if (card != null) return LedgerAccounts.forTail(card, card: true);
    final String? bank = Account.normalizeTail(txn.accountTail);
    if (bank != null) return LedgerAccounts.forTail(bank, card: false);
    return LedgerAccounts.unreconciled;
  }

  /// The other side of the movement: a category, an asset, or another account
  /// the user owns.
  static String counterAccountId(Transaction txn) => switch (txn.kind) {
        CategoryKind.expense ||
        CategoryKind.income =>
          LedgerAccounts.forCategory(txn.categoryPath),
        CategoryKind.investment => LedgerAccounts.forInvestment(txn.categoryPath),
        CategoryKind.transfer => _transferCounterAccount(txn),
      };

  /// True for the message that pays a credit-card bill - the single most
  /// expensive thing to get wrong, because the card's spends were already
  /// counted when each one happened.
  static bool isCardBillPayment(Transaction txn) =>
      txn.kind == CategoryKind.transfer &&
      txn.categoryPath == TransferPaths.creditCardPayment;

  static String _transferCounterAccount(Transaction txn) {
    switch (txn.categoryPath) {
      case TransferPaths.creditCardPayment:
        final String? card = Account.normalizeTail(txn.cardTail);
        if (card != null) return LedgerAccounts.forTail(card, card: true);
        // A payment confirmation that names no card still is not spending. It
        // parks against the plug until the card side of the pair arrives.
        return LedgerAccounts.unreconciled;
      case TransferPaths.atmWithdrawal:
        return LedgerAccounts.cash;
      case TransferPaths.walletTopup:
        final String name = (txn.merchantName ?? 'wallet').toLowerCase();
        return 'wallet:$name';
      case TransferPaths.loanRepayment:
        final String? tail = Account.normalizeTail(txn.cardTail ?? txn.accountTail);
        return tail == null
            ? LedgerAccounts.unreconciled
            : 'loan:$tail';
      default:
        // Self-transfers and P2P legs: one SMS is one half of the movement, so
        // the other half goes to the in-transit account until its partner
        // shows up. See TransferMatcher.
        return LedgerAccounts.inTransit;
    }
  }

  static AccountClass _classForMoneyAccount(Transaction txn, AccountType? type) {
    if (type != null) {
      return type.isLiability ? AccountClass.liability : AccountClass.asset;
    }
    if (isCardBillPayment(txn)) return AccountClass.asset;
    return txn.cardTail != null ? AccountClass.liability : AccountClass.asset;
  }

  static AccountClass _classForCounterAccount(Transaction txn, AccountType? type) =>
      switch (txn.kind) {
        CategoryKind.expense => AccountClass.expense,
        CategoryKind.income => AccountClass.income,
        CategoryKind.investment => AccountClass.asset,
        CategoryKind.transfer => _transferAccountClass(txn, type),
      };

  static AccountClass _transferAccountClass(Transaction txn, AccountType? type) {
    if (type != null) {
      return type.isLiability ? AccountClass.liability : AccountClass.asset;
    }
    if (txn.categoryPath == TransferPaths.creditCardPayment ||
        txn.categoryPath == TransferPaths.loanRepayment) {
      return AccountClass.liability;
    }
    return AccountClass.asset;
  }

  static Posting _posting(
    Transaction txn,
    String accountId,
    AccountClass accountClass,
    int amountPaise,
    PostingLeg leg,
    int ordinal,
  ) {
    return Posting(
      // Derived from the transaction id, so re-posting the same transaction
      // replaces its postings instead of adding a second balanced pair.
      id: '${txn.id}:$ordinal',
      txnId: txn.id,
      accountId: accountId,
      accountClass: accountClass,
      amountPaise: amountPaise,
      occurredAt: txn.occurredAt,
      bookingDate: txn.bookingDate,
      leg: leg,
    );
  }

  /// The spend total, computed from postings rather than from transaction
  /// rows.
  ///
  /// `Transaction.countsAsSpend` is the contract's single predicate and is
  /// what the repository uses. This function exists so a test can prove the
  /// two agree - if they ever disagree, one of them is double-counting.
  static Money spendFromPostings(Iterable<Posting> postings) {
    int total = 0;
    for (final Posting p in postings) {
      if (p.accountClass == AccountClass.expense) total += p.amountPaise;
    }
    return Money(total);
  }

  /// Balance of one account: every posting against it, signed.
  static Money balanceOf(String accountId, Iterable<Posting> postings, {DateTime? asOf}) {
    int total = 0;
    for (final Posting p in postings) {
      if (p.accountId != accountId) continue;
      if (asOf != null && p.occurredAt.isAfter(asOf)) continue;
      total += p.amountPaise;
    }
    return Money(total);
  }

  /// Generates the id [build] would use, so callers can delete the old
  /// postings of a transaction without reading them first.
  static String postingIdPrefix(String txnId) => '$txnId:';

  /// A deterministic id for a posting that is not derived from a transaction.
  static String syntheticId() => LedgerIds.generate();
}
