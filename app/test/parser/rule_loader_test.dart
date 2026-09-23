/// Loading rules from an untrusted source.
///
/// The config server is convenient, not trusted. The invariant every test here
/// defends is the same one: the loader NEVER ends up with no rules. A pack
/// that does not compile, a pack from a future schema, a pack that is simply
/// empty - each of them leaves the previous pack, or the pack bundled in the
/// APK, running. That is what makes "works with the server permanently
/// unreachable" a structural property rather than a promise.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ledger/core/result.dart';
import 'package:ledger/models/models.dart';
import 'package:ledger/parser/parsing.dart';

import 'fixtures/rule_fixtures.dart';

Map<String, dynamic> rule(
  String id, {
  String body = r'(?:rs\.?)\s*(?<amount>[\d,]+)',
  String sender = r'.',
  int priority = 10,
  String direction = 'debit',
  String txnType = 'transaction',
}) =>
    <String, dynamic>{
      'id': id,
      'sender_pattern': sender,
      'body_pattern': body,
      'direction': direction,
      'txn_type': txnType,
      'priority': priority,
    };

void main() {
  group('compile', () {
    test('the shipped fixture pack compiles', () {
      final compiled = RuleCompiler.compile(fixtureRuleSet());
      expect(compiled.isOk, isTrue, reason: '${compiled.errorOrNull}');
      expect(compiled.valueOrNull!.rules, isNotEmpty);
      expect(compiled.valueOrNull!.version, 7);
    });

    test('rules come out highest priority first, ties broken by id', () {
      final compiled = RuleCompiler.compile(ruleSetOf(<Map<String, dynamic>>[
        rule('b.mid', priority: 50),
        rule('a.mid', priority: 50),
        rule('c.low', priority: 10),
        rule('d.high', priority: 90),
      ])).valueOrNull!;

      expect(
        compiled.rules.map((r) => r.id).toList(),
        <String>['d.high', 'a.mid', 'b.mid', 'c.low'],
      );
    });

    test('a rule with no amount group is a corrupt pack', () {
      final compiled = RuleCompiler.compile(ruleSetOf(<Map<String, dynamic>>[
        rule('no.amount', body: r'debited from a/c (?<account_tail>\d{4})'),
      ]));
      expect(compiled.isErr, isTrue);
      expect(compiled.errorOrNull!.code, ErrorCodes.corruptRules);
      expect(compiled.errorOrNull!.message, contains('no.amount'));
    });

    test('a pattern that does not compile is a corrupt pack', () {
      final compiled = RuleCompiler.compile(ruleSetOf(<Map<String, dynamic>>[
        rule('bad.regex', body: r'(?<amount>[\d,]+)((((['),
      ]));
      expect(compiled.isErr, isTrue);
      expect(compiled.errorOrNull!.code, ErrorCodes.corruptRules);
    });

    test('a duplicate rule id is a corrupt pack', () {
      final compiled = RuleCompiler.compile(ruleSetOf(<Map<String, dynamic>>[
        rule('same.id'),
        rule('same.id', priority: 20),
      ]));
      expect(compiled.isErr, isTrue);
      expect(compiled.errorOrNull!.message, contains('duplicate'));
    });

    test('a pack with no rules is a corrupt pack, not an empty one', () {
      final compiled = RuleCompiler.compile(ruleSetOf(<Map<String, dynamic>>[]));
      expect(compiled.isErr, isTrue);
    });

    test('a broken reject pattern is a corrupt pack', () {
      final set = RuleSet.fromDocuments(
        parserRules: <String, dynamic>{
          'version': 2,
          'reject_patterns': <String, dynamic>{
            'patterns': <String>[r'\bOTP\b', r'(((']
          },
          'rules': <Map<String, dynamic>>[rule('ok')],
        },
        categories: categoriesDocument(),
        merchants: merchantsDocument(),
      );
      expect(RuleCompiler.compile(set).isErr, isTrue);
    });

    test('a group name this build does not know is a warning, not a failure',
        () {
      final compiled = RuleCompiler.compile(ruleSetOf(<Map<String, dynamic>>[
        rule('future.groups',
            body: r'(?<amount>[\d,]+).{0,10}(?<counterparty_bic>[A-Z]{4})'),
      ]));
      expect(compiled.isOk, isTrue);
      expect(compiled.valueOrNull!.warnings,
          contains('unknown_group:future.groups:counterparty_bic'));
    });

    test('a lookbehind is not mistaken for a named group declaration', () {
      final compiled = RuleCompiler.compile(ruleSetOf(<Map<String, dynamic>>[
        rule('lookbehind', body: r'(?<=a/c )(?<amount>[\d,]+)'),
      ]));
      expect(compiled.isOk, isTrue);
      expect(compiled.valueOrNull!.rules.single.groupNames, <String>{'amount'});
    });

    test('direction words are longest-first so phrases are not shadowed', () {
      final compiled = RuleCompiler.compile(fixtureRuleSet()).valueOrNull!;
      expect(compiled.debitWords.first, 'transferred to');
      expect(compiled.debitWords, contains('debited'));
    });
  });

  group('salvage', () {
    test('keeps the rules that do compile and drops the ones that do not', () {
      final salvaged = RuleCompiler.salvage(ruleSetOf(<Map<String, dynamic>>[
        rule('good.one', priority: 30),
        rule('broken', body: r'(?<amount>[\d,]+)((((['),
        rule('no.amount.group', body: r'debited'),
        rule('good.two', priority: 20),
      ]));
      expect(salvaged, isNotNull);
      expect(
        salvaged!.rules.map((r) => r.id).toList(),
        <String>['good.one', 'good.two'],
      );
      expect(salvaged.warnings, contains('skip:broken'));
      expect(salvaged.warnings, contains('skip:no.amount.group'));
    });

    test('returns null when nothing usable survives', () {
      expect(
        RuleCompiler.salvage(ruleSetOf(<Map<String, dynamic>>[
          rule('broken', body: r'(?<amount>[\d,]+)((((['),
        ])),
        isNull,
      );
    });
  });

  group('RuleLoader', () {
    test('starts empty and is not ready', () {
      final loader = RuleLoader();
      expect(loader.isReady, isFalse);
      expect(loader.current.isEmpty, isTrue);
      expect(loader.version, 0);
    });

    test('adopting the bundled pack sets the recovery baseline', () {
      final loader = RuleLoader();
      expect(loader.adoptBundled(fixtureRuleSet()).isOk, isTrue);
      expect(loader.isReady, isTrue);
      expect(loader.bundled, isNotNull);
      expect(loader.version, 7);
    });

    test('a newer pack replaces the current one', () {
      final loader = RuleLoader()..adoptBundled(fixtureRuleSet());
      final next = ruleSetOf(<Map<String, dynamic>>[rule('v9.only')],
          version: 9);
      expect(loader.adopt(next).isOk, isTrue);
      expect(loader.version, 9);
      expect(loader.current.ruleById('v9.only'), isNotNull);
    });

    test('an unusable pack leaves the previous one in force', () {
      final loader = RuleLoader()..adoptBundled(fixtureRuleSet());
      final broken = ruleSetOf(<Map<String, dynamic>>[
        rule('broken', body: r'(?<amount>[\d,]+)((((['),
      ], version: 9);

      final outcome = loader.adopt(broken);
      expect(outcome.isErr, isTrue);
      expect(outcome.errorOrNull!.code, ErrorCodes.corruptRules);
      expect(loader.version, 7, reason: 'the old pack must still be running');
      expect(loader.isReady, isTrue);
    });

    test('a partly-broken newer pack is salvaged rather than refused', () {
      final loader = RuleLoader()..adoptBundled(fixtureRuleSet());
      final mixed = ruleSetOf(<Map<String, dynamic>>[
        rule('v9.good'),
        rule('v9.broken', body: r'(?<amount>[\d,]+)((((['),
      ], version: 9);

      expect(loader.adopt(mixed).isOk, isTrue);
      expect(loader.version, 9);
      expect(loader.current.ruleById('v9.good'), isNotNull);
      expect(loader.current.ruleById('v9.broken'), isNull);
      expect(loader.current.warnings, isNotEmpty);
    });

    test('resetToBundled undoes a bad adoption', () {
      final loader = RuleLoader()..adoptBundled(fixtureRuleSet());
      loader.adopt(ruleSetOf(<Map<String, dynamic>>[rule('v9')], version: 9));
      expect(loader.version, 9);

      expect(loader.resetToBundled().isOk, isTrue);
      expect(loader.version, 7);
    });

    test('resetToBundled fails cleanly when there is no baseline', () {
      expect(RuleLoader().resetToBundled().isErr, isTrue);
    });
  });

  group('parser load', () {
    test('a failed load leaves the parser parsing with the old pack', () {
      final parser = RuleBasedSmsParser();
      expect(parser.loadSync(fixtureRuleSet()).isOk, isTrue);

      final before = parser.parse(
        message('VM-HDFCBK-S',
            'Rs.100.00 spent on HDFC Bank Card 0000 at SHOP on 01-01-26',
            receivedAt: DateTime(2026, 1, 1)),
        now: DateTime(2026, 1, 1),
      );
      expect(before.status, ParseStatus.parsed);

      final bad = parser.loadSync(ruleSetOf(<Map<String, dynamic>>[
        rule('broken', body: r'(?<amount>[\d,]+)((((['),
      ], version: 99));
      expect(bad.isErr, isTrue);
      expect(parser.rulesVersion, 7);

      final after = parser.parse(
        message('VM-HDFCBK-S',
            'Rs.100.00 spent on HDFC Bank Card 0000 at SHOP on 01-01-26',
            receivedAt: DateTime(2026, 1, 1)),
        now: DateTime(2026, 1, 1),
      );
      expect(after, before);
    });

    test('load() is the async face of the same thing', () async {
      final parser = RuleBasedSmsParser();
      final outcome = await parser.load(fixtureRuleSet());
      expect(outcome.isOk, isTrue);
      expect(parser.isReady, isTrue);
      expect(parser.rulesVersion, 7);
    });

    test('a new pack changes the reject patterns in force', () {
      final parser = RuleBasedSmsParser()..loadSync(fixtureRuleSet());
      final body = 'Rs.100.00 spent on HDFC Bank Card 0000 at SUSPICIOUS SHOP '
          'on 01-01-26';
      final raw = message('VM-HDFCBK-S', body, receivedAt: DateTime(2026, 1, 1));
      expect(parser.parse(raw, now: DateTime(2026, 1, 1)).status,
          ParseStatus.parsed);

      final tightened = RuleSet.fromDocuments(
        parserRules: <String, dynamic>{
          ...parserRulesDocument(version: 8),
          'reject_patterns': <String, dynamic>{
            'patterns': <String>[r'\bSUSPICIOUS\b'],
          },
        },
        categories: categoriesDocument(),
        merchants: merchantsDocument(),
      );
      expect(parser.loadSync(tightened).isOk, isTrue);
      final outcome = parser.parse(raw, now: DateTime(2026, 1, 1));
      expect(outcome.status, ParseStatus.rejected);
      expect(outcome.reason, r'reject:\bSUSPICIOUS\b');
    });
  });

  group('changedRuleIds', () {
    final base = ruleSetOf(<Map<String, dynamic>>[
      rule('stable'),
      rule('retuned'),
      rule('dropped'),
    ]);

    test('an unchanged pack changes nothing', () {
      expect(RuleLoader.changedRuleIds(from: base, to: base), isEmpty);
    });

    test('a changed body pattern is a changed rule', () {
      final next = ruleSetOf(<Map<String, dynamic>>[
        rule('stable'),
        rule('retuned', body: r'(?:inr)\s*(?<amount>[\d,]+)'),
        rule('dropped'),
      ]);
      expect(RuleLoader.changedRuleIds(from: base, to: next), <String>{'retuned'});
    });

    test('a changed priority is a changed rule - it can change which rule wins',
        () {
      final next = ruleSetOf(<Map<String, dynamic>>[
        rule('stable', priority: 99),
        rule('retuned'),
        rule('dropped'),
      ]);
      expect(RuleLoader.changedRuleIds(from: base, to: next), <String>{'stable'});
    });

    test('added and removed rules both count', () {
      final next = ruleSetOf(<Map<String, dynamic>>[
        rule('stable'),
        rule('retuned'),
        rule('added'),
      ]);
      expect(
        RuleLoader.changedRuleIds(from: base, to: next),
        <String>{'dropped', 'added'},
      );
    });
  });
}
