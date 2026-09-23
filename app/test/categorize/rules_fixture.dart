import 'dart:convert';
import 'dart:io';

import 'package:ledger/models/models.dart';

/// Loads the REAL rule pack, because a categoriser tested against a toy
/// dictionary proves nothing about the dictionary that actually ships.
///
/// `../rules/` is the source of truth; `assets/rules/` is the copy the Compile
/// phase makes. Either will do for a test.
RuleSet loadRealRuleSet() {
  final parserRules = _readJson('parser_rules.json');
  final categories = _readJson('categories.json');
  final merchants = _readJson('merchants.json');
  return RuleSet.fromDocuments(
    parserRules: parserRules,
    categories: categories,
    merchants: merchants,
    loadedAt: DateTime.utc(2026, 9, 23),
  );
}

Map<String, dynamic> _readJson(String name) {
  for (final dir in <String>['../rules', 'assets/rules']) {
    final file = File('$dir/$name');
    if (file.existsSync()) {
      return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    }
  }
  throw StateError('Could not find $name in ../rules or assets/rules');
}

/// A parsed message with only the fields the categoriser reads.
ParsedMessage parsedMessage({
  String? merchantRaw,
  String? vpa,
  TxnChannel channel = TxnChannel.upi,
  TxnDirection direction = TxnDirection.debit,
  String? cardTail,
  String? accountTail,
  String? forcedCategoryPath,
  String? issuer,
  int paise = 25000,
  TxnType txnType = TxnType.transaction,
}) {
  return ParsedMessage(
    amount: Money(paise),
    direction: direction,
    occurredAt: DateTime.utc(2026, 9, 1, 10, 30),
    channel: channel,
    ruleId: 'test_rule',
    ruleVersion: 1,
    confidence: 0.95,
    txnType: txnType,
    merchantRaw: merchantRaw,
    vpa: vpa,
    cardTail: cardTail,
    accountTail: accountTail,
    forcedCategoryPath: forcedCategoryPath,
    issuer: issuer,
  );
}
