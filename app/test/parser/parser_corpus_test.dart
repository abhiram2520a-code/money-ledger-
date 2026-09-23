/// The corpus. This file is the reason to believe the parser works.
///
/// Every entry is a verified Indian bank / card / wallet / UPI template, and
/// every expectation is the RIGHT answer for that message - including the
/// entries whose right answer is "reject this, it is not a transaction".
/// A parser that books 95% of messages correctly and invents money on the
/// other 5% is worse than no parser, because the user cannot tell which 5%.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ledger/models/models.dart';
import 'package:ledger/parser/parsing.dart';

import 'fixtures/rule_fixtures.dart';

/// One corpus row: a real message and the outcome it must produce.
class Case {
  const Case(
    this.name, {
    required this.sender,
    required this.body,
    required this.receivedAt,
    this.status = ParseStatus.parsed,
    this.classifiedAs,
    this.ruleId,
    this.paise,
    this.direction,
    this.channel,
    this.txnType,
    this.accountTail,
    this.cardTail,
    this.merchant,
    this.vpa,
    this.ref,
    this.forcedCategory,
    this.occurredAt,
    this.dueDate,
    this.precision,
    this.reason,
    this.minConfidence,
    this.noMerchant = false,
    this.noRef = false,
    this.partialField,
  });

  final String name;
  final String sender;
  final String body;
  final DateTime receivedAt;

  final ParseStatus status;
  final TxnType? classifiedAs;
  final String? ruleId;
  final int? paise;
  final TxnDirection? direction;
  final TxnChannel? channel;
  final TxnType? txnType;
  final String? accountTail;
  final String? cardTail;
  final String? merchant;
  final String? vpa;
  final String? ref;
  final String? forcedCategory;
  final DateTime? occurredAt;
  final DateTime? dueDate;
  final DatePrecision? precision;
  final String? reason;
  final double? minConfidence;
  final bool noMerchant;
  final bool noRef;
  final MapEntry<String, String>? partialField;
}

/// Fixed so year inference and every assertion are deterministic.
final DateTime kNow = DateTime(2026, 9, 20, 12);

final List<Case> corpus = <Case>[
  // =========================================================================
  // Ordinary money movement, across the shapes the banks actually use.
  // =========================================================================
  Case(
    'SBI UPI debit - no currency token, no date separators',
    sender: 'AD-SBIUPI-S',
    body: 'Dear UPI user A/C X1234 debited by 150.0 on date 05Mar24 '
        'trf to SWIGGY Refno 406512345678',
    receivedAt: DateTime(2024, 3, 5, 10),
    ruleId: 'upi.debit.sbi.v1',
    paise: 15000,
    direction: TxnDirection.debit,
    channel: TxnChannel.upi,
    accountTail: '1234',
    merchant: 'SWIGGY',
    ref: '406512345678',
    occurredAt: DateTime(2024, 3, 5),
    precision: DatePrecision.date,
  ),
  Case(
    'HDFC UPI debit - newline-delimited block',
    sender: 'VM-HDFCBK-S',
    body: 'Sent Rs.100.00\nFrom HDFC Bank A/C *0000\nTo CUSTOMER NAME\n'
        'On 17/05/26\nRef 000000000000\nNot You?\n'
        'Call 18002586161/SMS BLOCK UPI to 7308080808',
    receivedAt: DateTime(2026, 5, 17, 9, 30),
    ruleId: 'upi.debit.sent.merchant_date.v1',
    paise: 10000,
    direction: TxnDirection.debit,
    accountTail: '0000',
    merchant: 'CUSTOMER NAME',
    ref: '000000000000',
    occurredAt: DateTime(2026, 5, 17),
  ),
  Case(
    'ICICI UPI debit - payee named as "<name> credited" after a semicolon',
    sender: 'AD-ICICIT-S',
    body: 'ICICI Bank Acct XX000 debited for Rs 14.00 on 09-May-26; '
        'Pune Metro credited. UPI:000000000000. Call 18002662 for dispute. '
        'SMS BLOCK 000 to 9215676766.',
    receivedAt: DateTime(2026, 5, 9, 18),
    ruleId: 'upi.debit.counterparty_credited.v1',
    paise: 1400,
    direction: TxnDirection.debit,
    accountTail: '000',
    merchant: 'Pune Metro',
    ref: '000000000000',
    occurredAt: DateTime(2026, 5, 9),
  ),
  Case(
    'Axis UPI debit - slash-delimited rail token, counterparty runs into '
    '"Not you?"',
    sender: 'JD-AXISBK-S',
    body: 'INR 726.00 debited A/c no. XX1234 05-09-26, 10:19:49 '
        'UPI/P2M/431234567890/RAHUL SHARMA Not you? SMS BLOCKUPI Cust ID to '
        '919900000000 Axis Bank',
    receivedAt: DateTime(2026, 9, 5, 10, 20),
    ruleId: 'upi.debit.axis_rail.v1',
    paise: 72600,
    direction: TxnDirection.debit,
    accountTail: '1234',
    merchant: 'RAHUL SHARMA',
    ref: '431234567890',
    occurredAt: DateTime(2026, 9, 5, 10, 19, 49),
    precision: DatePrecision.dateTime,
  ),
  Case(
    'Kotak UPI credit',
    sender: 'JD-KOTAKD-S',
    body: 'Received Rs.100.00 from RAHUL SHARMA in your Kotak811 a/c XX1234 '
        'on 03-Sep-26. UPI ref no. 000000000000. '
        'View balance: https://kotak.bank.in/KBANKT/Fraud -Kotak',
    receivedAt: DateTime(2026, 9, 3, 11),
    ruleId: 'upi.credit.received.v1',
    paise: 10000,
    direction: TxnDirection.credit,
    accountTail: '1234',
    merchant: 'RAHUL SHARMA',
    occurredAt: DateTime(2026, 9, 3),
  ),
  Case(
    'HDFC UPI credit - counterparty is only a VPA',
    sender: 'VM-HDFCBK-S',
    body: 'Credit Alert! Rs.1.00 credited to HDFC Bank A/c XX0000 on 09-05-26 '
        'from VPA customer@bank (UPI 000000000000)',
    receivedAt: DateTime(2026, 5, 9, 8),
    ruleId: 'upi.credit.account.v1',
    paise: 100,
    direction: TxnDirection.credit,
    accountTail: '0000',
    vpa: 'customer@bank',
    merchant: 'customer',
    ref: '000000000000',
  ),
  Case(
    'HDFC IMPS - Indian lakh grouping is 1,00,000.00 and not 1.00',
    sender: 'VM-HDFCBK-S',
    body: 'IMPS INR 1,00,000.00\nsent from HDFC Bank A/c XX0000 on 26-05-26\n'
        'To A/c xxxxxxxxxx0000\nRef-000000000001\n'
        'Not you?Call 18002586161/SMS BLOCK OB to 7308080808',
    receivedAt: DateTime(2026, 5, 26, 15),
    ruleId: 'imps.debit.v1',
    paise: 10000000,
    direction: TxnDirection.debit,
    channel: TxnChannel.impsNeft,
    accountTail: '0000',
    ref: '000000000001',
    occurredAt: DateTime(2026, 5, 26),
  ),
  Case(
    'Union Bank - "Rs:" with a colon, and a balance that is NOT the amount',
    sender: 'AD-UNIONB-S',
    body: 'Union Bank of India A/c *0000 Debited Rs:151.00 on '
        '25-08-2026 09:50:01 by Mob Bk ref no 000000000000, Fvg: RAHUL SHARMA '
        'Avl Bal Rs:7138.46. Not you?Call 18002333/SMS BLOCK 0000 to '
        '9900000000',
    receivedAt: DateTime(2026, 8, 25, 9, 51),
    ruleId: 'account.debit.generic.v1',
    paise: 15100,
    direction: TxnDirection.debit,
    accountTail: '0000',
    merchant: 'RAHUL SHARMA',
    ref: '000000000000',
    occurredAt: DateTime(2026, 8, 25, 9, 50, 1),
    precision: DatePrecision.dateTime,
  ),
  Case(
    'IndusInd - no date in the body at all, counterparty is a mobile VPA',
    sender: 'TM-INDUSB-S',
    body: 'A/C *XX0000 debited by Rs 46500.00 towards 9999999999@bank. '
        'RRN:000000000000. Avl Bal:0.00. Not you? Call 18602677777 - '
        'IndusInd bank',
    receivedAt: DateTime(2026, 7, 2, 16, 45),
    ruleId: 'account.debit.generic.v1',
    paise: 4650000,
    direction: TxnDirection.debit,
    accountTail: '0000',
    vpa: '9999999999@bank',
    noMerchant: true,
    ref: '000000000000',
    precision: DatePrecision.receivedFallback,
  ),
  Case(
    'HDFC "Amt Deducted!" - no counterparty, no ref, no date, still real money',
    sender: 'VM-HDFCBK-S',
    body: 'Amt Deducted! Rs.8301 from your HDFC Bank A/c XX0601 for Money '
        'Transfer via HDFC Bank Online Banking. '
        'Not you?Call 18002586161/SMS BLOCK OB to 7308080808',
    receivedAt: DateTime(2026, 6, 11, 12),
    ruleId: 'account.debit.deducted.v1',
    paise: 830100,
    direction: TxnDirection.debit,
    accountTail: '0601',
    merchant: 'Money Transfer',
    noRef: true,
    precision: DatePrecision.receivedFallback,
    minConfidence: 0.70,
  ),
  Case(
    'Bank of Baroda credit - no account mask and no payer at all',
    sender: 'AX-BOBTXN-S',
    body: 'Dear BOB UPI User, your account is credited INR 15179.00 on Date '
        '2026-08-19 02:10:08 PM by UPI Ref No 000000000000 - BOB',
    receivedAt: DateTime(2026, 8, 19, 14, 11),
    ruleId: 'upi.credit.no_account.v1',
    paise: 1517900,
    direction: TxnDirection.credit,
    ref: '000000000000',
    occurredAt: DateTime(2026, 8, 19, 14, 10, 8),
    precision: DatePrecision.dateTime,
    minConfidence: 0.70,
  ),

  // =========================================================================
  // Cards.
  // =========================================================================
  Case(
    'HDFC card spend - acquirer descriptor with trailing reference digits',
    sender: 'VM-HDFCBK-S',
    body: 'Spent Rs.10290 On HDFC Bank Card 0000 At EAZYDINE0000000 On '
        '2026-05-02:22:26:01.Not You? To Block+Reissue Call '
        '18002586161/SMS BLOCK CC 0000 to 7308080808',
    receivedAt: DateTime(2026, 5, 2, 22, 27),
    ruleId: 'card.spend.verb_first.v1',
    paise: 1029000,
    direction: TxnDirection.debit,
    channel: TxnChannel.card,
    cardTail: '0000',
    merchant: 'EAZYDINE',
    occurredAt: DateTime(2026, 5, 2, 22, 26, 1),
    precision: DatePrecision.dateTime,
  ),
  Case(
    'SBI Card spend - no reference anywhere in the template',
    sender: 'VM-SBICRD-T',
    body: 'Rs.123.45 spent on your SBI Credit Card ending 0000 at SAMPLE MART '
        'on 19/07/26. Trxn. not done by you? Report at '
        'https://sbicard.com/Dispute',
    receivedAt: DateTime(2026, 7, 19, 13),
    ruleId: 'card.spend.amount_first.v1',
    paise: 12345,
    direction: TxnDirection.debit,
    cardTail: '0000',
    merchant: 'SAMPLE MART',
    noRef: true,
    occurredAt: DateTime(2026, 7, 19),
  ),
  Case(
    'ICICI card spend - merchant comes AFTER the date, same preposition',
    sender: 'AD-ICICIT-S',
    body: 'INR 1,604.00 spent using ICICI Bank Card XX0000 on 01-May-26 on '
        'ONYX BAR. Avl Limit: INR 99,99,999.99. If not you, call 1800 '
        '2662/SMS BLOCK 0000 to 9215676766.',
    receivedAt: DateTime(2026, 5, 1, 21),
    ruleId: 'card.spend.date_then_merchant.v1',
    paise: 160400,
    direction: TxnDirection.debit,
    cardTail: '0000',
    merchant: 'ONYX BAR',
    occurredAt: DateTime(2026, 5, 1),
  ),
  Case(
    'Kotak debit card - four-digit year where the same bank uses two elsewhere',
    sender: 'JD-KOTAKD-S',
    body: 'Rs.1234.56 spent via Kotak Debit Card XX0000 at SAMPLE MERCHANT on '
        '16/07/2026. Avl bal Rs.9999.99 Not you?Tap '
        'https://kotak.com/KBANKT/Fraud',
    receivedAt: DateTime(2026, 7, 16, 19),
    ruleId: 'card.spend.amount_first.v1',
    paise: 123456,
    direction: TxnDirection.debit,
    cardTail: '0000',
    merchant: 'SAMPLE MERCHANT',
    occurredAt: DateTime(2026, 7, 16),
  ),
  Case(
    'slice forex - two currencies, the INR one is the one that happened',
    sender: 'JD-SLCBNK-S',
    body: 'USD 12.00 | Rs. 1,000.00 spent on your credit card xx0000 at '
        'SAMPLEVENDOR, INC        NEW YORK       US on 07-Sep-26.',
    receivedAt: DateTime(2026, 9, 7, 20),
    ruleId: 'card.spend.amount_first.v1',
    paise: 100000,
    direction: TxnDirection.debit,
    cardTail: '0000',
    merchant: 'SAMPLEVENDOR, INC NEW YORK US',
    occurredAt: DateTime(2026, 9, 7),
  ),
  Case(
    'HDFC credit card over UPI - VPA counterparty and a date with NO YEAR',
    sender: 'VM-HDFCBK-S',
    body: 'Txn Rs.100.00\nOn HDFC Bank Card 0000\nAt sample.vpa@hdfcbank\n'
        'by UPI 000000000000\nOn 23-05\nNot You?\n'
        'Call 18002586161/SMS BLOCK CC 0000 to 7308080808',
    receivedAt: DateTime(2026, 5, 23, 14),
    ruleId: 'card.spend.upi.v1',
    paise: 10000,
    direction: TxnDirection.debit,
    cardTail: '0000',
    vpa: 'sample.vpa@hdfcbank',
    ref: '000000000000',
    occurredAt: DateTime(2026, 5, 23),
    precision: DatePrecision.inferredYear,
  ),

  // =========================================================================
  // The awkward cases: money that is not an expense, and messages that are
  // not money.
  // =========================================================================
  Case(
    'ATM withdrawal - forced to a transfer, four-digit slip ref is NOT a ref',
    sender: 'AX-BOBSMS-S',
    body: 'Rs.8000.00 withdrawn from A/c ...1055 at ATM TID 6BXxxxm02 '
        'Ref.6952 Avlbal Amt:Rs.9234.31(17-09-2026 11:32:48).In case your a/c '
        'is debited but cash is not dispensed from the ATM, the transaction '
        'will be automatically reversed',
    receivedAt: DateTime(2026, 9, 17, 11, 32, 48),
    ruleId: 'atm.withdrawal.v1',
    paise: 800000,
    direction: TxnDirection.debit,
    channel: TxnChannel.atm,
    accountTail: '1055',
    forcedCategory: 'transfers/atm_withdrawal',
    noRef: true,
    minConfidence: 0.70,
  ),
  Case(
    'slice ATM - no terminal, no ref, no balance',
    sender: 'JD-SLCBNK-S',
    body: 'Rs.10000 withdrawn from a/c xx4735 on 08-Aug-26. For queries, '
        'please contact us at 08048329999 -slice',
    receivedAt: DateTime(2026, 8, 8, 17),
    ruleId: 'atm.withdrawal.v1',
    paise: 1000000,
    direction: TxnDirection.debit,
    accountTail: '4735',
    forcedCategory: 'transfers/atm_withdrawal',
    occurredAt: DateTime(2026, 8, 8),
  ),
  Case(
    'Credit-card bill payment - a transfer leg, never income',
    sender: 'VM-HDFCBK-S',
    body: 'HDFC Bank Cardmember, Online Payment of Rs.1000 vide Ref# '
        '000XXXXXXXXXXXX was credited to your card ending 0000 On 08/MAY/2026'
        '_value Date 08/MAY/2026',
    receivedAt: DateTime(2026, 5, 8, 10),
    ruleId: 'card.bill.payment.v1',
    paise: 100000,
    direction: TxnDirection.credit,
    cardTail: '0000',
    forcedCategory: 'transfers/credit_card_payment',
    occurredAt: DateTime(2026, 5, 8),
  ),
  Case(
    'HDFC self-transfer - both ends are the user, net effect zero',
    sender: 'VM-HDFCBK-S',
    body: 'HDFC Bank:Rs. 1.00 debited from a/c *1234 on 07/09/26 to a/c '
        '**5678 (UPI Ref No. 000000000000). Not you? Call on 18002586161 to '
        'report',
    receivedAt: DateTime(2026, 9, 7, 13),
    ruleId: 'transfer.self.a2a.v1',
    paise: 100,
    direction: TxnDirection.debit,
    accountTail: '1234',
    forcedCategory: 'transfers/self_transfer',
    ref: '000000000000',
    occurredAt: DateTime(2026, 9, 7),
  ),
  Case(
    'PayZapp wallet top-up - loading a wallet is not income',
    sender: 'AX-PAYZAP-S',
    body: 'Rs.530\ncredited to your PayZapp Wallet\nOn 03-06-2026 10:42:43\n'
        'Bal:Rs.551\nNot you? Report:https://1.hdfc.bank.in/HDFCBK/s/lqn8oJY9 '
        '-HDFC Bank',
    receivedAt: DateTime(2026, 6, 3, 10, 43),
    ruleId: 'wallet.credit.v1',
    paise: 53000,
    direction: TxnDirection.credit,
    merchant: 'PayZapp',
    forcedCategory: 'transfers/wallet_topup',
    occurredAt: DateTime(2026, 6, 3, 10, 42, 43),
    precision: DatePrecision.dateTime,
  ),
  Case(
    'ICICI EMI mandate - the word "debited" never appears',
    sender: 'AD-ICICIT-S',
    body: 'Dear Customer, the mandate of INR 1,234.56 raised by SAMPLE FUND '
        'MANAGER on 18-Jul-26 and is successfully redeemed through RRN '
        '000000000000 -ICICI Bank.',
    receivedAt: DateTime(2026, 7, 18, 6),
    ruleId: 'nach.mandate.debit.v1',
    paise: 123456,
    direction: TxnDirection.debit,
    channel: TxnChannel.nach,
    merchant: 'SAMPLE FUND MANAGER',
    ref: '000000000000',
    occurredAt: DateTime(2026, 7, 18),
  ),
  Case(
    'Fi SIP auto-payment - no currency token, long-form English date',
    sender: 'VK-FiMony-S',
    body: 'Auto-payment successful! You sent 1000.00 to Ppfas Management Ltd '
        'on February 1, 2026, as per auto-payment rules set by you. Check '
        'your app for details. - Fi',
    receivedAt: DateTime(2026, 2, 1, 9),
    ruleId: 'autopay.sip.v1',
    paise: 100000,
    direction: TxnDirection.debit,
    channel: TxnChannel.nach,
    merchant: 'Ppfas Management Ltd',
    occurredAt: DateTime(2026, 2, 1),
    minConfidence: 0.70,
  ),
  Case(
    'HDFC card refund - links back to a spend, not income in its own right',
    sender: 'VM-HDFCBK-S',
    body: 'Alert! Rs. 262.56 refunded by SampleMerchant Payments BANGALORE '
        'IND on 17/MAY/2026 & adjusted against HDFC Bank Credit Card 0000 '
        'View updated balance here: https://hdfcbk.io/HDFCBK/s/0000000A',
    receivedAt: DateTime(2026, 5, 17, 11),
    ruleId: 'card.refund.amount_first.v1',
    paise: 26256,
    direction: TxnDirection.credit,
    cardTail: '0000',
    merchant: 'SampleMerchant Payments BANGALORE IND',
    forcedCategory: 'income/refund',
    occurredAt: DateTime(2026, 5, 17),
  ),
  Case(
    'ICICI card refund - THREE amounts, only one of them moved',
    sender: 'AD-ICICIT-S',
    body: 'SAMPLE MERCHANT AI refund of Rs 2.00 credited to ICICI Bank Credit '
        'Card XX0000 on 06-SEP-26. Revised total due Rs 99,999.00, minimum '
        'due Rs 4,999.00',
    receivedAt: DateTime(2026, 9, 6, 15),
    ruleId: 'card.refund.merchant_first.v1',
    paise: 200,
    direction: TxnDirection.credit,
    cardTail: '0000',
    merchant: 'SAMPLE MERCHANT AI',
    forcedCategory: 'income/refund',
    occurredAt: DateTime(2026, 9, 6),
  ),
  Case(
    'Equitas statement - a Bill, never a spend',
    sender: 'AD-EQTASB-S',
    body: 'Statement for your Equitas Credit Card 0000 is generated. '
        'Total Due: 12345.67 Min Due: 1234.56 Due by: 09/06/26. '
        'Pls pay by due date.',
    receivedAt: DateTime(2026, 5, 20, 8),
    ruleId: 'bill.card.statement.v1',
    txnType: TxnType.billReminder,
    paise: 1234567,
    direction: TxnDirection.debit,
    cardTail: '0000',
    dueDate: DateTime(2026, 6, 9),
    occurredAt: DateTime(2026, 5, 20, 8),
    precision: DatePrecision.receivedFallback,
  ),

  // =========================================================================
  // Correctly rejected. These are the entries that keep the ledger honest.
  // =========================================================================
  Case(
    'OTP quoting an amount, a merchant AND a card tail',
    sender: 'VM-HDFCBK-T',
    body: 'OTP 483920 for txn of Rs 4,999 at AMAZON on card XX4455. '
        'Do not share this OTP with anyone. -HDFC Bank',
    receivedAt: DateTime(2026, 9, 12, 19),
    status: ParseStatus.rejected,
    classifiedAs: TxnType.otp,
    reason: 'guard:otp',
  ),
  Case(
    'Promo from the same registered bank header',
    sender: 'VM-HDFCBK-S',
    body: 'Get up to Rs 1,500 cashback! Spend Rs 5,000 on your HDFC Bank '
        'Credit Card and get assured rewards. T&C apply.',
    receivedAt: DateTime(2026, 9, 12, 11),
    status: ParseStatus.rejected,
    classifiedAs: TxnType.promo,
    reason: 'guard:promo',
  ),
  Case(
    'Balance enquiry reply - an account mask and an amount, but no money verb',
    sender: 'VM-HDFCBK-S',
    body: 'Available balance in your A/c XX1234 is Rs 9,500.00 as on '
        '12-09-26. -HDFC Bank',
    receivedAt: DateTime(2026, 9, 12, 9),
    status: ParseStatus.rejected,
    classifiedAs: TxnType.balanceInfo,
    reason: 'guard:balance_only',
  ),
  Case(
    'Canara failed txn - identical to a debit except for one word, placed '
    'after the merchant',
    sender: 'AX-CANBNK-S',
    body: 'Dear Customer, txn of Rs.637.70 thru A/C XX1234 on 18-8-26 at '
        '14:16:16 to ACME STORE failed due to INSUFFICIENT FUNDS-Canara Bank',
    receivedAt: DateTime(2026, 8, 18, 14, 17),
    status: ParseStatus.rejected,
    classifiedAs: TxnType.unknown,
    reason: 'guard:failed',
  ),
  Case(
    'Airtel UPI AutoPay pre-notice - "scheduled on" is not "debited"',
    sender: 'AD-AIRBNK-S',
    body: 'UPI AutoPay d4da379700914856af8320ffd283c9ad@ibl for Jar Gold\n'
        'Debited Rs.30.00\nscheduled on 19/04/2026\nAirtel Payments Bank',
    receivedAt: DateTime(2026, 4, 18, 7),
    status: ParseStatus.rejected,
    classifiedAs: TxnType.preDebitNotice,
    reason: 'demote:pre_debit_notice',
    ruleId: 'autopay.upi.v1',
  ),
  Case(
    'Smishing from a 10-digit number - body content is irrelevant',
    sender: '9876543210',
    body: 'Rs 25,000.00 has been credited to your bank account. '
        'Claim your amount here: http://bit.ly/x',
    receivedAt: DateTime(2026, 9, 12, 22),
    status: ParseStatus.untrustedSender,
  ),
  Case(
    'RBI e-mandate pre-notice from an insurer - an amount, a date range, '
    'no money',
    sender: 'VM-UIICLT-S',
    body: 'KINDLY MAINTAIN SUFFICIENT BALANCE FOR AUTO DEBIT OF PREMIUM OF '
        'RS.20/- FOR PMSBY BETWEEN 25/05/2026 AND 01/06/2026-UNITED INDIA '
        'INSURANCE COMPANY LIMITED',
    receivedAt: DateTime(2026, 5, 24, 10),
    status: ParseStatus.noRuleMatched,
  ),

  // =========================================================================
  // Quarantined rather than guessed.
  // =========================================================================
  Case(
    'International card spend - the rupee figure is not in the message',
    sender: 'VM-HDFCBK-S',
    body: 'Card XX4455 used for USD 42.50 at OPENAI on 12-09-26. -HDFC Bank',
    receivedAt: DateTime(2026, 9, 12, 20),
    status: ParseStatus.ambiguous,
    ruleId: 'card.spend.foreign.v1',
    reason: 'amount:foreign_currency',
    partialField: MapEntry<String, String>('currency', 'USD'),
  ),
];

void main() {
  late RuleBasedSmsParser parser;

  setUp(() {
    parser = RuleBasedSmsParser();
    final loaded = parser.loadSync(fixtureRuleSet());
    expect(loaded.isOk, isTrue, reason: 'fixture pack must compile');
  });

  group('corpus', () {
    for (final c in corpus) {
      test(c.name, () {
        final outcome = parser.parse(
          message(c.sender, c.body, receivedAt: c.receivedAt),
          now: kNow,
        );

        expect(outcome.status, c.status,
            reason: '${c.name}\n  got: $outcome');

        if (c.classifiedAs != null) {
          expect(outcome.classifiedAs, c.classifiedAs);
        }
        if (c.reason != null) {
          expect(outcome.reason, contains(c.reason!));
        }
        if (c.ruleId != null) {
          expect(outcome.ruleId, c.ruleId);
        }
        if (c.partialField != null) {
          expect(outcome.partialFields[c.partialField!.key],
              c.partialField!.value);
        }

        if (c.status != ParseStatus.parsed) {
          expect(outcome.message, isNull,
              reason: 'a non-parsed outcome must carry no ParsedMessage');
          return;
        }

        final parsed = outcome.message!;
        if (c.paise != null) expect(parsed.amount.paise, c.paise);
        expect(parsed.amount.currency, Money.inr);
        if (c.direction != null) expect(parsed.direction, c.direction);
        if (c.channel != null) expect(parsed.channel, c.channel);
        if (c.txnType != null) expect(parsed.txnType, c.txnType);
        if (c.accountTail != null) expect(parsed.accountTail, c.accountTail);
        if (c.cardTail != null) expect(parsed.cardTail, c.cardTail);
        if (c.merchant != null) expect(parsed.merchantRaw, c.merchant);
        if (c.noMerchant) expect(parsed.merchantRaw, isNull);
        if (c.vpa != null) expect(parsed.vpa, c.vpa);
        if (c.ref != null) expect(parsed.ref, c.ref);
        if (c.noRef) expect(parsed.ref, isNull);
        if (c.forcedCategory != null) {
          expect(parsed.forcedCategoryPath, c.forcedCategory);
        }
        if (c.occurredAt != null) expect(parsed.occurredAt, c.occurredAt);
        if (c.dueDate != null) expect(parsed.dueDate, c.dueDate);
        if (c.precision != null) expect(parsed.datePrecision, c.precision);
        if (c.minConfidence != null) {
          expect(parsed.confidence, greaterThanOrEqualTo(c.minConfidence!));
        }
        expect(parsed.rawMessageId, 'm1');
        expect(parsed.ruleVersion, 7);
      });
    }
  });

  test('every corpus case is named uniquely', () {
    final names = corpus.map((c) => c.name).toSet();
    expect(names.length, corpus.length);
  });

  test('parsing is deterministic - the same message twice gives the same '
      'outcome', () {
    for (final c in corpus) {
      final raw = message(c.sender, c.body, receivedAt: c.receivedAt);
      expect(parser.parse(raw, now: kNow), parser.parse(raw, now: kNow),
          reason: c.name);
    }
  });

  test('parseAll preserves order', () {
    final messages = <RawMessage>[
      for (var i = 0; i < corpus.length; i++)
        message(corpus[i].sender, corpus[i].body,
            receivedAt: corpus[i].receivedAt, id: 'm$i'),
    ];
    final outcomes = parser.parseAll(messages, now: kNow);
    expect(outcomes.length, corpus.length);
    for (var i = 0; i < corpus.length; i++) {
      expect(outcomes[i].status, corpus[i].status, reason: corpus[i].name);
    }
  });

  group('totality', () {
    test('a 50 KB body is truncated, not run through a backtracking regex', () {
      final huge = 'Rs.100.00 debited from a/c XX1234 '
          '${'padding ' * 8000}';
      final outcome = parser.parse(
        message('VM-HDFCBK-S', huge, receivedAt: kNow),
        now: kNow,
      );
      expect(outcome.status, ParseStatus.noRuleMatched);
      expect(outcome.reason, 'no_rule:body_truncated');
    });

    test('an empty body is rejected, not parsed', () {
      final outcome = parser.parse(
        message('VM-HDFCBK-S', '   ', receivedAt: kNow),
        now: kNow,
      );
      expect(outcome.status, ParseStatus.rejected);
      expect(outcome.reason, 'body:empty');
    });

    test('nothing throws, whatever the body', () {
      const hostile = <String>[
        '',
        '   ',
        'Rs. debited from a/c',
        r'(((((((((((((((((((((((',
        '​​​Rs.100 credited to a/c XX1234 on 01-01-26',
        'Rs.,,,,,,, debited from a/c XX1234 on 99-99-99',
      ];
      for (final body in hostile) {
        expect(
          () => parser.parse(
            message('VM-HDFCBK-S', body, receivedAt: kNow),
            now: kNow,
          ),
          returnsNormally,
          reason: body,
        );
      }
    });

    test('before a pack is loaded, everything queues for re-parse', () {
      final cold = RuleBasedSmsParser();
      expect(cold.isReady, isFalse);
      final outcome = cold.parse(
        message('VM-HDFCBK-S', 'Rs.100.00 debited from a/c XX1234 on 01-01-26',
            receivedAt: kNow),
        now: kNow,
      );
      expect(outcome.status, ParseStatus.noRuleMatched);
      expect(outcome.resultingState.isReparseCandidate, isTrue);
    });
  });

  group('sender matching', () {
    test('an issuer-scoped rule ignores the telco prefix', () {
      const axisBody = 'INR 726.00 debited A/c no. XX1234 05-09-26, 10:19:49 '
          'UPI/P2M/431234567890/RAHUL SHARMA Not you? SMS BLOCKUPI Cust ID to '
          '919900000000 Axis Bank';
      for (final sender in <String>[
        'JD-AXISBK-S',
        'AD-AXISBK-S',
        'AX-AXISBK',
        'VK-AxisBk-T',
      ]) {
        final outcome = parser.parse(
          message(sender, axisBody, receivedAt: DateTime(2026, 9, 5, 10, 20)),
          now: kNow,
        );
        expect(outcome.ruleId, 'upi.debit.axis_rail.v1', reason: sender);
      }
    });

    test('an issuer-scoped rule does not fire for another bank', () {
      final onlyAxis = ruleSetOf(<Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'axis.only.v1',
          'sender_pattern': r'^(?:[A-Za-z]{2}-)?AXISBK$',
          'body_pattern':
              r'(?:rs|inr)\s*(?<amount>[\d,]+(?:\.\d{1,2})?)\s+debited',
          'direction': 'debit',
          'txn_type': 'transaction',
          'priority': 10,
        },
      ]);
      final scoped = RuleBasedSmsParser()..loadSync(onlyAxis);
      const body = 'INR 726.00 debited A/c no. XX1234 on 05-09-26';

      expect(
        scoped
            .parse(message('JD-AXISBK-S', body, receivedAt: kNow), now: kNow)
            .status,
        ParseStatus.parsed,
      );
      expect(
        scoped
            .parse(message('VM-HDFCBK-S', body, receivedAt: kNow), now: kNow)
            .status,
        ParseStatus.noRuleMatched,
      );
    });
  });

  group('the amount that moved', () {
    test('a rule that captures the balance is quarantined, not booked', () {
      // A deliberately wrong rule - the kind a rushed pack ships.
      final badPack = ruleSetOf(<Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'bad.grabs.balance.v1',
          'sender_pattern': r'.',
          'body_pattern': r'avl\s*bal\s*(?:rs\.?)\s*'
              r'(?<amount>[\d,]+(?:\.\d{1,2})?)',
          'direction': 'debit',
          'txn_type': 'transaction',
          'priority': 99,
        },
      ]);
      final bad = RuleBasedSmsParser()..loadSync(badPack);
      final outcome = bad.parse(
        message(
          'VM-HDFCBK-S',
          'Spent Rs.3000 From HDFC Bank Card x0000 At PZCREDIT0000000 On '
              '2026-05-02:00:17:56 Avl Bal Rs.142.26 Not You?',
          receivedAt: DateTime(2026, 5, 2, 0, 18),
        ),
        now: kNow,
      );
      expect(outcome.status, ParseStatus.ambiguous);
      expect(outcome.reason, 'amount:balance_bound');
      expect(outcome.message, isNull);
    });

    test('a rule with no readable amount is quarantined, not booked as zero',
        () {
      final pack = ruleSetOf(<Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'optional.amount.v1',
          'sender_pattern': r'.',
          'body_pattern': r'debited(?:\s+rs\.?\s*(?<amount>[\d,]+))?',
          'direction': 'debit',
          'txn_type': 'transaction',
          'priority': 99,
        },
      ]);
      final p = RuleBasedSmsParser()..loadSync(pack);
      final outcome = p.parse(
        message('VM-HDFCBK-S', 'Your a/c XX1234 was debited today',
            receivedAt: kNow),
        now: kNow,
      );
      expect(outcome.status, ParseStatus.ambiguous);
      expect(outcome.reason, 'amount:missing');
    });
  });

  group('direction', () {
    test('"infer" reads the captured word, not the first word in the body', () {
      final pack = ruleSetOf(<Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'infer.v1',
          'sender_pattern': r'.',
          'body_pattern': r'(?:rs\.?)\s*(?<amount>[\d,]+(?:\.\d{1,2})?)\s+'
              r'(?<direction_word>credited|debited)\s+to\s+a/c\s*'
              r'[x*]{0,4}(?<account_tail>\d{3,6})',
          'direction': 'infer',
          'txn_type': 'transaction',
          'priority': 50,
        },
      ]);
      final p = RuleBasedSmsParser()..loadSync(pack);

      final credit = p.parse(
        message('VM-HDFCBK-S', 'Rs.500.00 credited to a/c XX1234',
            receivedAt: kNow),
        now: kNow,
      );
      expect(credit.message!.direction, TxnDirection.credit);

      final debit = p.parse(
        message('VM-HDFCBK-S', 'Rs.500.00 debited to a/c XX1234',
            receivedAt: kNow),
        now: kNow,
      );
      expect(debit.message!.direction, TxnDirection.debit);
    });

    test('an undeterminable direction is quarantined', () {
      final pack = ruleSetOf(<Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'infer.blank.v1',
          'sender_pattern': r'.',
          'body_pattern':
              r'amount\s+(?:rs\.?)\s*(?<amount>[\d,]+(?:\.\d{1,2})?)',
          'direction': 'infer',
          'txn_type': 'transaction',
          'priority': 50,
        },
      ]);
      final p = RuleBasedSmsParser()..loadSync(pack);
      final outcome = p.parse(
        message('VM-HDFCBK-S', 'Amount Rs.500.00 processed on your account',
            receivedAt: kNow),
        now: kNow,
      );
      expect(outcome.status, ParseStatus.ambiguous);
      expect(outcome.reason, 'direction:undetermined');
    });
  });

  group('re-parse targeting', () {
    test('changedRuleIds names added, removed and altered rules', () {
      final from = fixtureRuleSet();
      final altered = parserRulesDocument(version: 8);
      final rules =
          (altered['rules']! as List<Map<String, dynamic>>).toList();
      rules.removeWhere((r) => r['id'] == 'atm.withdrawal.v1');
      rules.firstWhere((r) => r['id'] == 'imps.debit.v1')['body_pattern'] =
          r'\bimps\s+(?<amount>[\d,]+)';
      rules.add(<String, dynamic>{
        'id': 'brand.new.v1',
        'sender_pattern': r'.',
        'body_pattern': r'(?<amount>[\d,]+)',
        'direction': 'debit',
        'txn_type': 'transaction',
        'priority': 1,
      });
      final to = RuleSet.fromDocuments(
        parserRules: <String, dynamic>{...altered, 'rules': rules},
        categories: categoriesDocument(),
        merchants: merchantsDocument(),
      );

      final changed = parser.changedRuleIds(from: from, to: to);
      expect(changed, contains('atm.withdrawal.v1'));
      expect(changed, contains('imps.debit.v1'));
      expect(changed, contains('brand.new.v1'));
      expect(changed, isNot(contains('card.spend.verb_first.v1')));
    });
  });
}
