import 'package:flutter/foundation.dart';

import '../models/models.dart';

/// A category decided by the rail the money travelled on rather than by who
/// was paid.
@immutable
class ChannelSignal {
  const ChannelSignal({
    required this.categoryPath,
    required this.confidence,
    required this.explanation,
    required this.matchedOn,
  });

  final String categoryPath;
  final double confidence;

  /// One human sentence for the UI.
  final String explanation;

  /// The token that decided it, for debugging.
  final String matchedOn;

  /// Whether this may be applied without asking the user.
  bool get canAutoApply => confidence >= CategoryResult.autoApplyThreshold;

  @override
  String toString() => 'ChannelSignal($categoryPath @$confidence via $matchedOn)';
}

/// Rail and instrument heuristics.
///
/// **There is no MCC in an SMS.** The card network's merchant category code
/// never reaches the handset. What a message does carry is the rail (UPI, ATM,
/// NACH, POS) and the instrument (account or card), and those are mostly an
/// oracle for *what kind of money movement this is*, not for *what was
/// bought*. So this stage is deliberately narrow: it fires only where the rail
/// is decisive, and stays silent everywhere else.
///
/// Why that matters more than the pie chart: an ATM withdrawal filed as an
/// expense makes the user's spending total wrong by the whole withdrawal, and
/// the same rupees get counted again when they are actually spent.
abstract final class ChannelSignals {
  /// The rail signals, in priority order. Each is a regex over the merchant /
  /// counterparty string plus, when the pipeline has it, the message body.
  static final RegExp _atm =
      RegExp(r'\b(ATM|ATW|CASH\s*WDL|CASH\s*WITHDRAWAL|WITHDRAWAL\s*AT)\b');

  static final RegExp _cardBill = RegExp(
    r'(CREDIT\s*CARD|\bCC\s*(BILL|PAYMENT|PMT)|CARD\s*(BILL|PAYMENT)|'
    r'CARDPAY|BILLPAY\s*CC|PAYMENT\s*TOWARDS\s*CARD)',
  );

  static final RegExp _mandate =
      RegExp(r'\b(NACH|ACH\s*-?\s*D|ACHD|E-?MANDATE|MANDATE|ECS|SIP)\b');

  static final RegExp _investmentOriginator = RegExp(
    r'(INDIAN\s*CLEARING|ICCL|BSE\s*(LTD|LIMITED)|NSE\s*CLEARING|\bISIP\b|'
    r'\bSIP\b|MUTUAL\s*FUND|\bAMC\b|ZERODHA|GROWW|BILLIONBRAINS|UPSTOX|'
    r'KUVERA|COIN\s*BY|NIPPON\s*INDIA|SBI\s*FUNDS|HDFC\s*AMC|ICICI\s*PRU)',
  );

  static final RegExp _emi =
      RegExp(r'\b(EMI|INSTALMENT|INSTALLMENT|LOAN\s*REPAY|LOAN\s*EMI)\b');

  static final RegExp _walletTopUp =
      RegExp(r'(\bWALLET\b|ADD\s*MONEY|ADDMONEY|WALLET\s*LOAD|LOAD\s*MONEY)');

  /// Taxonomy paths this stage can produce. Every one of them exists in
  /// `rules/categories.json`; the caller validates anyway.
  static const String atmWithdrawalPath = 'transfers/atm_withdrawal';
  static const String selfTransferPath = 'transfers/self_transfer';
  static const String cardBillPath = 'transfers/credit_card_payment';
  static const String walletTopUpPath = 'transfers/wallet_topup';
  static const String sipPath = 'investments/mutual_fund_sip';
  static const String consumerEmiPath = 'emi_loans/consumer_emi';
  static const String personalLoanPath = 'emi_loans/personal_loan';
  static const String untrackedCardSpendPath = 'miscellaneous/other_expense';

  /// Excluding a transaction from the spend total is the expensive mistake:
  /// the user under-counts, blows a budget and blames the app, and there is
  /// nothing on screen to correct. Including one is visible and fixable. So a
  /// transfer or investment verdict must clear this bar; anything weaker falls
  /// through and is counted as spend in the Uncategorized queue instead.
  static const double minConfidenceToExcludeFromSpend = 0.85;

  /// Resolves the rail signals for one message.
  ///
  /// [text] must already be upper-cased. Pass the merchant / counterparty
  /// string, plus the message body when the caller has one.
  ///
  /// [cardIsTracked] answers "have we seen this card's own transactions?".
  /// A credit-card bill payment is a transfer ONLY when the app already
  /// counted the swipes; if the card is invisible to us, the bill payment is
  /// the only evidence that the money was spent at all, and calling it a
  /// transfer would silently under-count the whole month.
  static ChannelSignal? resolve({
    required TxnChannel channel,
    required TxnDirection direction,
    required String text,
    required bool isCardTransaction,
    bool cardIsTracked = true,
  }) {
    final signal = _resolveInner(
      channel: channel,
      direction: direction,
      text: text,
      isCardTransaction: isCardTransaction,
      cardIsTracked: cardIsTracked,
    );
    if (signal == null) return null;

    // A card transaction is a purchase on a credit line. It is never a
    // movement between the user's own accounts, whatever the merchant string
    // happens to say.
    if (channel == TxnChannel.card && signal.categoryPath.startsWith('transfers/')) {
      return null;
    }
    return signal;
  }

  static ChannelSignal? _resolveInner({
    required TxnChannel channel,
    required TxnDirection direction,
    required String text,
    required bool isCardTransaction,
    required bool cardIsTracked,
  }) {
    final isAtm = channel == TxnChannel.atm || _atm.hasMatch(text);
    if (isAtm) {
      if (direction.isDebit) {
        return const ChannelSignal(
          categoryPath: atmWithdrawalPath,
          confidence: 0.95,
          explanation:
              'ATM withdrawal - moved to Cash, not counted as spending until '
              'you say what the cash went on',
          matchedOn: 'ATM',
        );
      }
      return const ChannelSignal(
        categoryPath: selfTransferPath,
        confidence: 0.88,
        explanation: 'Cash paid in at an ATM - your own money, not income',
        matchedOn: 'ATM',
      );
    }

    // A credit-card bill is paid FROM the bank account, so the message that
    // announces it is an account debit, never a card debit.
    if (direction.isDebit && !isCardTransaction && _cardBill.hasMatch(text)) {
      if (cardIsTracked) {
        return const ChannelSignal(
          categoryPath: cardBillPath,
          confidence: 0.92,
          explanation:
              'Credit card bill payment - the card spends were already counted, '
              'so this is not counted again',
          matchedOn: 'CREDIT CARD',
        );
      }
      return const ChannelSignal(
        categoryPath: untrackedCardSpendPath,
        confidence: 0.75,
        explanation:
            'Credit card bill for a card we never see messages from - counted '
            'as spending, because this is the only record of it',
        matchedOn: 'CREDIT CARD',
      );
    }

    final isMandate = channel == TxnChannel.nach || _mandate.hasMatch(text);

    if (isMandate && _investmentOriginator.hasMatch(text)) {
      return const ChannelSignal(
        categoryPath: sipPath,
        confidence: 0.90,
        explanation:
            'Auto-debit to a mutual fund - savings, not spending, so it stays '
            'out of your spend total',
        matchedOn: 'SIP',
      );
    }

    if (_emi.hasMatch(text)) {
      // An EMI is spending (the interest certainly is), so this never removes
      // money from the total - only the loan it belongs to is a guess, which
      // is why it sits below the auto-apply threshold and asks.
      return ChannelSignal(
        categoryPath: isCardTransaction ? consumerEmiPath : personalLoanPath,
        confidence: 0.60,
        explanation: 'Auto-debit that mentions an EMI - confirm which loan '
            'this belongs to',
        matchedOn: 'EMI',
      );
    }

    if (direction.isDebit && _walletTopUp.hasMatch(text)) {
      return const ChannelSignal(
        categoryPath: walletTopUpPath,
        confidence: 0.88,
        explanation:
            'Wallet top-up - your own money moved into a wallet, counted when '
            'you spend it',
        matchedOn: 'WALLET',
      );
    }

    return null;
  }
}
