/// A rules pack for the parser tests.
///
/// This is deliberately a REAL pack, not a toy: every `body_pattern` here was
/// written against a verified bank SMS template and every one of them is
/// exercised by `parser_corpus_test.dart`. The seed pack in `rules/` carries
/// five generic rules; these are what a shipping pack has to look like, and
/// keeping them under test means a future pack can be diffed against a corpus
/// instead of against someone's memory.
///
/// `reject_patterns` and `direction_words` are copied verbatim from
/// `rules/parser_rules.json`, so a change to the shipped negative grammar
/// shows up here as a failing test rather than as a silent behaviour change.
library;

import 'package:ledger/models/models.dart';

/// The taxonomy the fixture rules' `forced_category` values point into.
/// Ids and kinds match `rules/categories.json`.
Map<String, dynamic> categoriesDocument() => <String, dynamic>{
      'categories': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'food_dining',
          'name': 'Food & Dining',
          'kind': 'expense',
          'subcategories': <Map<String, dynamic>>[
            <String, dynamic>{'id': 'food_delivery', 'name': 'Food Delivery'},
            <String, dynamic>{'id': 'restaurants', 'name': 'Restaurants'},
          ],
        },
        <String, dynamic>{
          'id': 'miscellaneous',
          'name': 'Miscellaneous',
          'kind': 'expense',
          'subcategories': <Map<String, dynamic>>[
            <String, dynamic>{'id': 'other_expense', 'name': 'Other'},
          ],
        },
        <String, dynamic>{
          'id': 'income',
          'name': 'Income',
          'kind': 'income',
          'subcategories': <Map<String, dynamic>>[
            <String, dynamic>{'id': 'refund', 'name': 'Refund'},
            <String, dynamic>{'id': 'salary', 'name': 'Salary'},
          ],
        },
        <String, dynamic>{
          'id': 'transfers',
          'name': 'Transfers',
          'kind': 'transfer',
          'subcategories': <Map<String, dynamic>>[
            <String, dynamic>{'id': 'self_transfer', 'name': 'Self Transfer'},
            <String, dynamic>{
              'id': 'credit_card_payment',
              'name': 'Credit Card Payment',
            },
            <String, dynamic>{'id': 'atm_withdrawal', 'name': 'ATM Withdrawal'},
            <String, dynamic>{'id': 'wallet_topup', 'name': 'Wallet Top-up'},
          ],
        },
        <String, dynamic>{
          'id': 'investments',
          'name': 'Investments',
          'kind': 'investment',
          'subcategories': <Map<String, dynamic>>[
            <String, dynamic>{'id': 'mutual_fund_sip', 'name': 'Mutual Fund SIP'},
          ],
        },
      ],
    };

Map<String, dynamic> merchantsDocument() => <String, dynamic>{
      'merchants': <Map<String, dynamic>>[],
    };

/// Verbatim from `rules/parser_rules.json`.
const List<String> shippedRejectPatterns = <String>[
  r'\bOTP\b',
  r'\bone[ -]?time[ -]?password\b',
  'do not share',
  r'\bnever share\b',
  r'\bwill expire in\b',
  r'\boffer\b.*\bvalid till\b',
  r'\bcongratulations\b',
  r'\bpre-?approved\b',
  r'\beligible for\b',
  r'\bclick (here|below)\b',
  r'\bapply now\b',
  r'\bT&C apply\b',
  r'\bget \d+% (off|cashback)\b',
  r'\bwin \b',
  r'\bfailed\b.*\btransaction\b',
  r'\bdeclined\b',
];

/// Verbatim from `rules/parser_rules.json`.
const Map<String, List<String>> shippedDirectionWords = <String, List<String>>{
  'debit': <String>[
    'debited',
    'debit',
    'spent',
    'paid',
    'withdrawn',
    'sent',
    'purchase',
    'deducted',
    'transferred to',
  ],
  'credit': <String>[
    'credited',
    'credit',
    'received',
    'deposited',
    'refund',
    'reversed',
    'added',
  ],
};

/// Any DLT header. Most rules here are shape-driven rather than issuer-driven,
/// which is what makes one rule cover eight banks.
const String anySender = r'.';

/// Amount, in every Indian spelling: `Rs.1,24,500.00`, `INR 2000`, `Rs:151.00`,
/// `Rs634.53`, `3800.0`.
const String _amount = r'(?<amount>[\d,]+(?:\.\d{1,2})?)';
const String _cur = r'(?:rs|inr|\u20b9)\s*[:.]?\s*';
const String _curOpt = r'(?:(?:rs|inr|\u20b9)\s*[:.]?\s*)?';
const String _acct = r'\b(?:a/c|ac|acct|account)\s*(?:no\.?)?\s*[x*.\u2026]{0,6}';
const String _dateTok = r'(?<date>[0-9A-Za-z/\-]{5,12})';

/// The fixture pack, in `parser_rules.json` shape.
Map<String, dynamic> parserRulesDocument({int version = 7}) => <String, dynamic>{
      'version': version,
      'direction_words': shippedDirectionWords,
      'reject_patterns': <String, dynamic>{'patterns': shippedRejectPatterns},
      'rules': <Map<String, dynamic>>[
        // --- ATM ------------------------------------------------------------
        <String, dynamic>{
          'id': 'atm.withdrawal.v1',
          'issuer': 'Generic Bank',
          'sender_pattern': anySender,
          'body_pattern': '$_cur$_amount'
              r'\s+withdrawn\s+from\s+'
              '$_acct'
              r'(?<account_tail>\d{3,6})'
              r'(?:.{0,40}?\bon\s+'
              '$_dateTok'
              r')?',
          'direction': 'debit',
          'channel': 'atm',
          'txn_type': 'transaction',
          'priority': 95,
          'forced_category': 'transfers/atm_withdrawal',
          '_comment': 'Cash leaving the bank into the Cash account is a '
              'transfer, never an expense. What the cash is spent on is '
              'invisible to SMS and must be asked, not guessed.',
        },

        // --- Credit-card bill payment ---------------------------------------
        <String, dynamic>{
          'id': 'card.bill.payment.v1',
          'issuer': 'Generic Card',
          'sender_pattern': anySender,
          'body_pattern': r'payment\s+of\s+'
              '$_cur$_amount'
              r'\s+.{0,60}?(?:credited|received|processed)\s*'
              r'(?:to\s+your\s+)?(?:.{0,24}?\bcredit\s*card|card)\b'
              r'\s*(?:ending(?:\s*in)?|no\.?|xx)?\s*[x*]{0,4}'
              r'(?<card_tail>\d{4})?',
          'direction': 'credit',
          'channel': 'card',
          'txn_type': 'transaction',
          'priority': 94,
          'forced_category': 'transfers/credit_card_payment',
          '_comment': 'The settlement half of a transfer whose other half is a '
              'debit on a bank account. Booking it as income plus booking the '
              'bank debit as an expense is what doubles the month.',
        },

        // --- Refunds and reversals ------------------------------------------
        <String, dynamic>{
          'id': 'card.refund.amount_first.v1',
          'issuer': 'Generic Card',
          'sender_pattern': anySender,
          'body_pattern': '$_cur$_amount'
              r'\s+(?:refunded|reversed)\s+(?:by|from|at)\s+'
              r"(?<merchant>[A-Za-z0-9][A-Za-z0-9 .&'\-]{1,40}?)"
              r'\s+on\s+(?<date>\d{1,2}[/\-][A-Za-z0-9]{2,4}[/\-]\d{2,4})'
              r'.{0,44}?\bcard\s*(?:no\.?|ending|xx)?\s*[x*]{0,4}'
              r'(?<card_tail>\d{4})',
          'direction': 'credit',
          'channel': 'card',
          'txn_type': 'transaction',
          'priority': 93,
          'forced_category': 'income/refund',
        },
        <String, dynamic>{
          'id': 'card.refund.merchant_first.v1',
          'issuer': 'Generic Card',
          'sender_pattern': anySender,
          'body_pattern':
              r"(?<merchant>[A-Za-z0-9][A-Za-z0-9 .&'\-]{1,40}?)\s+refund\s+of\s+"
                  '$_cur$_amount'
                  r'\s+credited\s+to\s+.{0,40}?\bcard\s*(?:no\.?|ending|xx)?\s*'
                  r'[x*]{0,4}(?<card_tail>\d{4})\s+on\s+'
                  r'(?<date>\d{1,2}[\-/][A-Za-z0-9]{2,4}[\-/]\d{2,4})',
          'direction': 'credit',
          'channel': 'card',
          'txn_type': 'transaction',
          'priority': 93,
          'forced_category': 'income/refund',
          '_comment': 'This template carries THREE amounts: the refund, the '
              'revised total due and the minimum due. The amount group is '
              'bound to the refund positionally, never scanned for.',
        },

        // --- Card spend ------------------------------------------------------
        <String, dynamic>{
          'id': 'card.spend.foreign.v1',
          'issuer': 'Generic Card',
          'sender_pattern': anySender,
          'body_pattern': r'\bcard\s*(?:no\.?|ending|xx)?\s*[x*]{0,4}'
              r'(?<card_tail>\d{4})\s+(?:used|spent)\s+(?:for|at|on)\s+'
              r'(?:usd|eur|gbp|aed|sgd|jpy)\s*'
              '$_amount'
              r'\s+at\s+(?<merchant>.{2,40}?)\s+on\s+'
              '$_dateTok',
          'direction': 'debit',
          'channel': 'card',
          'txn_type': 'transaction',
          'priority': 89,
          '_comment': 'Exists so an international spend is QUARANTINED rather '
              'than silently booked at 1:1. The rupee figure is genuinely not '
              'in the message; the parser refuses to invent it.',
        },
        <String, dynamic>{
          'id': 'card.spend.date_then_merchant.v1',
          'issuer': 'Generic Card',
          'sender_pattern': anySender,
          'body_pattern': '$_cur$_amount'
              r'\s+spent\s+(?:using|on|at|via|with)\s+[A-Za-z ]{0,24}?\bcard\b'
              r'\s*(?:no\.?|ending(?:\s*in)?|xx)?\s*[x*]{0,4}'
              r'(?<card_tail>\d{4})\s+on\s+'
              r'(?<date>\d{1,2}[\-/][A-Za-z0-9]{2,4}[\-/]\d{2,4})'
              r'\s+(?:on|at)\s+(?<merchant>[^.]{2,48}?)\s*\.',
          'direction': 'debit',
          'channel': 'card',
          'txn_type': 'transaction',
          'priority': 92,
          '_comment': 'ICICI puts the merchant AFTER the date and introduces '
              'both with the same preposition "on".',
        },
        <String, dynamic>{
          'id': 'card.spend.verb_first.v1',
          'issuer': 'Generic Card',
          'sender_pattern': anySender,
          'body_pattern': r'\b(?:spent|txn)\s+'
              '$_cur$_amount'
              r'\s+(?:on|from|at|via|using|with)\s+(?:your\s+)?[A-Za-z ]{0,24}?'
              r'\bcard\b\s*(?:no\.?|ending(?:\s*in)?|xx)?\s*[x*]{0,4}'
              r'(?<card_tail>\d{4})\s+(?:at|on)\s+(?<merchant>.{2,60}?)'
              r'\s+on\s+(?<date>[0-9A-Za-z:/\-]{6,24})',
          'direction': 'debit',
          'channel': 'card',
          'txn_type': 'transaction',
          'priority': 91,
        },
        <String, dynamic>{
          'id': 'card.spend.amount_first.v1',
          'issuer': 'Generic Card',
          'sender_pattern': anySender,
          'body_pattern': '$_cur$_amount'
              r'\s+(?:spent|charged|paid|debited)\s+'
              r'(?:on|from|at|via|using|with)\s+(?:your\s+)?[A-Za-z ]{0,24}?'
              r'\b(?:credit\s*card|debit\s*card|card)\b'
              r'\s*(?:no\.?|ending(?:\s*in)?|xx)?\s*[x*]{0,4}'
              r'(?<card_tail>\d{4})\s+(?:at|on)\s+(?<merchant>.{2,60}?)'
              r'\s+on\s+(?<date>[0-9A-Za-z:/\-]{6,24})',
          'direction': 'debit',
          'channel': 'card',
          'txn_type': 'transaction',
          'priority': 90,
        },

        <String, dynamic>{
          'id': 'card.spend.upi.v1',
          'issuer': 'HDFC Bank',
          'sender_pattern': anySender,
          'body_pattern': r'\b(?:txn|spent)\s+'
              '$_cur$_amount'
              r'\s+on\s+[A-Za-z ]{0,24}?\bcard\b\s*[x*]{0,4}'
              r'(?<card_tail>\d{4})\s+at\s+'
              r'(?<vpa>[A-Za-z0-9._\-]+@[A-Za-z0-9.\-]+)\s+by\s+upi\s+'
              r'(?<ref>\d{12})\s+on\s+(?<date>[0-9\-/]{4,10})',
          'direction': 'debit',
          'channel': 'card',
          'txn_type': 'transaction',
          'priority': 91,
          '_comment': 'A credit card charged over UPI. The counterparty is a '
              'VPA and nothing else, and the date carries NO YEAR.',
        },

        // --- Own-money movement ---------------------------------------------
        <String, dynamic>{
          'id': 'transfer.self.a2a.v1',
          'issuer': 'Generic Bank',
          'sender_pattern': anySender,
          'body_pattern': '$_cur$_amount'
              r'\s+debited\s+from\s+a/c\s*[x*]{0,4}'
              r'(?<account_tail>\d{3,6})\s+on\s+'
              '$_dateTok'
              r'\s+to\s+a/c\s*[x*]{0,6}\d{3,6}',
          'direction': 'debit',
          'channel': 'upi',
          'txn_type': 'transaction',
          'priority': 88,
          'forced_category': 'transfers/self_transfer',
          '_comment': 'Both ends are masked accounts with no counterparty '
              'name: money moving between things the user already owns.',
        },
        <String, dynamic>{
          'id': 'wallet.credit.v1',
          'issuer': 'Generic Wallet',
          'sender_pattern': anySender,
          'body_pattern': '$_cur$_amount'
              r'\s+credited\s+to\s+your\s+(?<merchant>[A-Za-z ]{2,24}?)\s*wallet'
              r'\s+on\s+(?<date>[0-9/\-]{8,10}(?:\s+\d{2}:\d{2}:\d{2})?)',
          'direction': 'credit',
          'channel': 'unknown',
          'txn_type': 'transaction',
          'priority': 87,
          'forced_category': 'transfers/wallet_topup',
          '_comment': 'Loading a wallet is not income. The spend happens later, '
              'from the wallet; counting both doubles it.',
        },

        // --- UPI -------------------------------------------------------------
        <String, dynamic>{
          'id': 'upi.debit.sent.merchant_date.v1',
          'issuer': 'Generic Bank',
          'sender_pattern': anySender,
          'body_pattern': r'\bsent\s+'
              '$_cur$_amount'
              r'\s+from\s+.{0,28}?'
              '$_acct'
              r'(?<account_tail>\d{3,6})\s+to\s+(?<merchant>.{2,48}?)\s+on\s+'
              '$_dateTok',
          'direction': 'debit',
          'channel': 'upi',
          'txn_type': 'transaction',
          'priority': 86,
        },
        <String, dynamic>{
          'id': 'upi.debit.sent.date_merchant.v1',
          'issuer': 'Generic Bank',
          'sender_pattern': anySender,
          'body_pattern': r'\bsent\s+'
              '$_cur$_amount'
              r'\s+from\s+.{0,28}?'
              '$_acct'
              r'(?<account_tail>\d{3,6})\s+on\s+'
              '$_dateTok'
              r'\s+to\s+(?<merchant>.{2,48}?)\s*[.,]',
          'direction': 'debit',
          'channel': 'upi',
          'txn_type': 'transaction',
          'priority': 85,
        },
        <String, dynamic>{
          'id': 'upi.credit.received.v1',
          'issuer': 'Generic Bank',
          'sender_pattern': anySender,
          'body_pattern': r'\breceived\s+'
              '$_cur$_amount'
              r'\s+from\s+(?<merchant>.{2,40}?)\s+in\s+your\s+.{0,20}?'
              '$_acct'
              r'(?<account_tail>\d{3,6})\s+on\s+'
              '$_dateTok',
          'direction': 'credit',
          'channel': 'upi',
          'txn_type': 'transaction',
          'priority': 84,
        },
        <String, dynamic>{
          'id': 'upi.debit.axis_rail.v1',
          'issuer': 'Axis Bank',
          'sender_pattern': r'^(?:[A-Za-z]{2}-)?AXISBK$',
          'body_pattern': '$_cur$_amount'
              r'\s+debited\s+a/c\s*(?:no\.?)?\s*[x*]{0,4}'
              r'(?<account_tail>\d{3,6})\s+'
              r'(?<date>\d{2}[\-/]\d{2}[\-/]\d{2,4},?\s*\d{2}:\d{2}:\d{2})'
              r'\s+UPI/(?:P2M|P2A)/(?<ref>\d{12})/(?<merchant>.{2,40}?)'
              r'\s+(?:not\s+you|sms\s+block)',
          'direction': 'debit',
          'channel': 'upi',
          'txn_type': 'transaction',
          'priority': 83,
          '_comment': 'Axis packs rail, counterparty class and RRN into one '
              'slash-delimited token, and the counterparty runs into "Not '
              'you?" with no delimiter at all.',
        },
        <String, dynamic>{
          'id': 'upi.debit.counterparty_credited.v1',
          'issuer': 'Generic Bank',
          'sender_pattern': anySender,
          'body_pattern': '$_acct'
              r'(?<account_tail>\d{3,6})\s+(?:is\s+|has\s+been\s+|was\s+)?'
              r'debited\s+(?:for|with|by)\s+'
              '$_cur$_amount'
              r'\s+on\s+'
              '$_dateTok'
              r'\s*[;,]\s*(?<merchant>.{2,40}?)\s+credited',
          'direction': 'debit',
          'channel': 'upi',
          'txn_type': 'transaction',
          'priority': 82,
          '_comment': 'ICICI and IDFC name the payee as "<name> credited" '
              'AFTER a semicolon. A keyword-only direction detector reads the '
              'word "credited" and books income.',
        },
        <String, dynamic>{
          'id': 'imps.debit.v1',
          'issuer': 'Generic Bank',
          'sender_pattern': anySender,
          'body_pattern': r'\bimps\s+'
              '$_cur$_amount'
              r'\s+sent\s+from\s+.{0,28}?'
              '$_acct'
              r'(?<account_tail>\d{3,6})\s+on\s+'
              '$_dateTok',
          'direction': 'debit',
          'channel': 'imps_neft',
          'txn_type': 'transaction',
          'priority': 82,
        },
        <String, dynamic>{
          'id': 'upi.credit.account.v1',
          'issuer': 'Generic Bank',
          'sender_pattern': anySender,
          'body_pattern': '$_cur$_amount'
              r'\s+credited\s+to\s+.{0,24}?'
              '$_acct'
              r'(?<account_tail>\d{3,6})\s+on\s+'
              '$_dateTok'
              r'(?:\s+(?:from|by)\s+(?:vpa\s+)?(?<merchant>[^(]{2,40}?)\s*\()?',
          'direction': 'credit',
          'channel': 'upi',
          'txn_type': 'transaction',
          'priority': 80,
        },
        <String, dynamic>{
          'id': 'account.debit.generic.v1',
          'issuer': 'Generic Bank',
          'sender_pattern': anySender,
          'body_pattern': '$_acct'
              r'(?<account_tail>\d{3,6})\s+(?:is\s+|has\s+been\s+|was\s+)?'
              r'debited\s+(?:by|for|with)?\s*'
              '$_cur$_amount'
              r'(?:\s+on\s+(?<date>[0-9A-Za-z/\-]{5,12}'
              r'(?:\s+\d{2}:\d{2}(?::\d{2})?)?))?'
              r'(?:.{0,40}?fvg:\s*(?<merchant>.{2,40}?)\s+(?:avl|not\s+you))?',
          'direction': 'debit',
          'channel': 'netbanking',
          'txn_type': 'transaction',
          'priority': 60,
          '_comment': 'The catch-all debit. Deliberately last: a real movement '
              'with no counterparty, no reference and sometimes no date must '
              'still be booked, or the month silently under-counts.',
        },
        <String, dynamic>{
          'id': 'account.credit.generic.v1',
          'issuer': 'Generic Bank',
          'sender_pattern': anySender,
          'body_pattern': '$_cur$_amount'
              r'\s+(?:deposited|credited)\s+(?:in|to)\s+.{0,24}?'
              '$_acct'
              r'(?<account_tail>\d{3,6})\s+on\s+'
              '$_dateTok',
          'direction': 'credit',
          'channel': 'netbanking',
          'txn_type': 'transaction',
          'priority': 60,
        },
        <String, dynamic>{
          'id': 'upi.credit.no_account.v1',
          'issuer': 'Bank of Baroda',
          'sender_pattern': anySender,
          'body_pattern': r'your\s+account\s+is\s+credited\s+(?:with\s+)?'
              '$_cur$_amount'
              r'\s+on\s+(?:date\s+)?'
              r'(?<date>\d{4}-\d{2}-\d{2}(?:\s+\d{2}:\d{2}:\d{2}\s*[AP]M)?)',
          'direction': 'credit',
          'channel': 'upi',
          'txn_type': 'transaction',
          'priority': 55,
          'date_formats': <String>['yyyy-MM-dd hh:mm:ss a', 'yyyy-MM-dd'],
          '_comment': 'No account mask and no payer at all. Still real money, '
              'so it is booked - with a lower confidence that says so.',
        },

        // --- Mandates and autopay -------------------------------------------
        <String, dynamic>{
          'id': 'nach.mandate.debit.v1',
          'issuer': 'Generic Bank',
          'sender_pattern': anySender,
          'body_pattern': r'\bmandate\s+of\s+'
              '$_cur$_amount'
              r'\s+raised\s+by\s+(?<merchant>.{2,40}?)\s+on\s+'
              '$_dateTok'
              r'.{0,40}?\b(?:rrn|ref)\s*(?:no\.?)?\s*[:#.]?\s*'
              r'(?<ref>[A-Za-z0-9]{8,20})',
          'direction': 'debit',
          'channel': 'nach',
          'txn_type': 'transaction',
          'priority': 84,
          '_comment': 'The word "debited" never appears: the mandate is '
              '"raised" and "redeemed". A keyword-only debit detector misses '
              'every EMI and SIP on this rail.',
        },
        <String, dynamic>{
          'id': 'autopay.upi.v1',
          'issuer': 'Generic Bank',
          'sender_pattern': anySender,
          'body_pattern': r'\bupi\s+autopay\s+'
              r'(?<vpa>[A-Za-z0-9._\-]+@[A-Za-z0-9.\-]+)\s+for\s+'
              r'(?<merchant>.{2,40}?)\s+debited\s+'
              '$_cur$_amount',
          'direction': 'debit',
          'channel': 'nach',
          'txn_type': 'transaction',
          'priority': 84,
          '_comment': 'Matches both the completed debit and the RBI-mandated '
              '24h pre-notice, which are the same template. The tense guard '
              'demotes the pre-notice; the rule must not try to.',
        },
        <String, dynamic>{
          'id': 'autopay.sip.v1',
          'issuer': 'Fi Money',
          'sender_pattern': anySender,
          'body_pattern': r'auto-?payment\s+successful.{0,24}?\byou\s+sent\s+'
              '$_curOpt$_amount'
              r'\s+to\s+(?<merchant>.{2,40}?)\s+on\s+'
              r'(?<date>[A-Za-z]{3,9}\s+\d{1,2},\s*\d{4})',
          'direction': 'debit',
          'channel': 'nach',
          'txn_type': 'transaction',
          'priority': 83,
          'date_formats': <String>['MMMM d, yyyy'],
          '_comment': 'No currency token at all: "You sent 1000.00".',
        },

        <String, dynamic>{
          'id': 'upi.debit.sbi.v1',
          'issuer': 'State Bank of India',
          'sender_pattern': anySender,
          'body_pattern': '$_acct'
              r'(?<account_tail>\d{3,6})\s+debited\s+by\s+'
              '$_curOpt$_amount'
              r'\s+on\s+(?:date\s+)?'
              '$_dateTok'
              r'\s+(?:trf\s+to|to)\s+(?<merchant>.{2,40}?)\s+(?:ref|rrn|upi)',
          'direction': 'debit',
          'channel': 'upi',
          'txn_type': 'transaction',
          'priority': 81,
          '_comment': 'SBI writes the amount with NO currency token at all '
              '("debited by 150.0") and the date with no separators '
              '("05Mar24").',
        },
        <String, dynamic>{
          'id': 'account.debit.deducted.v1',
          'issuer': 'HDFC Bank',
          'sender_pattern': anySender,
          'body_pattern': r'\b(?:amt|amount)\s+deducted[!.]?\s*'
              '$_cur$_amount'
              r'\s+from\s+your\s+.{0,24}?'
              '$_acct'
              r'(?<account_tail>\d{3,6})\s+for\s+(?<merchant>.{2,40}?)\s+via\b',
          'direction': 'debit',
          'channel': 'netbanking',
          'txn_type': 'transaction',
          'priority': 62,
          '_comment': 'No counterparty, no reference, no date, no balance - '
              'and still a real Rs 8,301 leaving the account. Refusing to '
              'book it is its own kind of wrong answer.',
        },

        // --- Bills ------------------------------------------------------------
        <String, dynamic>{
          'id': 'bill.card.statement.v1',
          'issuer': 'Generic Card',
          'sender_pattern': anySender,
          'body_pattern': r'statement\s+for\s+your\s+.{0,30}?\bcard\s*[x*]{0,4}'
              r'(?<card_tail>\d{4})\s+is\s+generated'
              r'.{0,24}?total\s+due:?\s*'
              '$_curOpt$_amount'
              r'.{0,60}?due\s+by:?\s*(?<date>[0-9/\-]{6,10})',
          'direction': 'debit',
          'channel': 'unknown',
          'txn_type': 'bill_reminder',
          'priority': 70,
          '_comment': 'Creates a Bill, never a spend. The ledger entry appears '
              'only when the matching payment SMS arrives.',
        },
      ],
    };

/// The fixture pack as a [RuleSet].
RuleSet fixtureRuleSet({int version = 7, RulesOrigin origin = RulesOrigin.bundled}) =>
    RuleSet.fromDocuments(
      parserRules: parserRulesDocument(version: version),
      categories: categoriesDocument(),
      merchants: merchantsDocument(),
      origin: origin,
    );

/// A [RuleSet] carrying exactly [rules], with the shipped negative grammar.
RuleSet ruleSetOf(List<Map<String, dynamic>> rules, {int version = 1}) =>
    RuleSet.fromDocuments(
      parserRules: <String, dynamic>{
        'version': version,
        'direction_words': shippedDirectionWords,
        'reject_patterns': <String, dynamic>{'patterns': shippedRejectPatterns},
        'rules': rules,
      },
      categories: categoriesDocument(),
      merchants: merchantsDocument(),
    );

/// Builds a [RawMessage] the way the ingestion layer would.
///
/// [sender] is the raw originating address; the normalised header is derived
/// the same way `MessageSource` derives it, so a test cannot accidentally
/// hand the parser a header the platform would never produce.
RawMessage message(
  String sender,
  String body, {
  required DateTime receivedAt,
  String id = 'm1',
  String? senderHeader,
  bool forceUntrusted = false,
  IngestSource source = IngestSource.smsRealtime,
  int? simSlot,
}) {
  final derived = forceUntrusted ? null : (senderHeader ?? _headerOf(sender));
  return RawMessage(
    id: id,
    senderRaw: sender,
    body: body,
    receivedAt: receivedAt,
    source: source,
    senderHeader: derived,
    simSlot: simSlot,
  );
}

String? _headerOf(String sender) {
  final match =
      RegExp(r'^(?:[A-Za-z]{2}-)?([A-Za-z][A-Za-z0-9]{1,10})(?:-[A-Za-z])?$')
          .firstMatch(sender.trim());
  return match?.group(1)?.toUpperCase();
}
