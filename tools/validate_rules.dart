// Validates rules/*.json against the runtime that actually parses them: Dart.
// Named groups here use the (?<name>...) form, which Dart/JS/Java accept and
// Python does not - Dart is the consumer, so Dart is the authority.
import 'dart:convert';
import 'dart:io';

int failures = 0;
void fail(String msg) { print('FAIL  $msg'); failures++; }

void main() {
  final root = Directory.current.path;
  final rules = jsonDecode(File('$root/rules/parser_rules.json').readAsStringSync());
  final cats = jsonDecode(File('$root/rules/categories.json').readAsStringSync());
  final merch = jsonDecode(File('$root/rules/merchants.json').readAsStringSync());

  for (final p in rules['reject_patterns']['patterns']) {
    try { RegExp(p, caseSensitive: false); } catch (e) { fail('reject pattern $p -> $e'); }
  }

  final ruleIds = <String>{};
  for (final r in rules['rules']) {
    if (!ruleIds.add(r['id'])) fail('duplicate rule id ${r['id']}');
    for (final k in ['sender_pattern', 'body_pattern']) {
      try { RegExp(r[k], caseSensitive: false); } catch (e) { fail('${r['id']}.$k -> $e'); }
    }
    if (!RegExp(r'^(debit|credit|infer)$').hasMatch(r['direction'])) {
      fail('${r['id']} bad direction ${r['direction']}');
    }
  }

  // Every body_pattern must capture an amount - a rule that cannot find the
  // amount can only ever produce a broken ledger entry.
  for (final r in rules['rules']) {
    if (!r['body_pattern'].contains('(?<amount>')) fail('${r['id']} has no amount group');
  }

  final validKinds = {'expense', 'income', 'transfer', 'investment'};
  final paths = <String>{};
  for (final c in cats['categories']) {
    if (!validKinds.contains(c['kind'])) fail('category ${c['id']} bad kind ${c['kind']}');
    for (final s in (c['subcategories'] ?? [])) {
      paths.add('${c['id']}/${s['id']}');
    }
  }

  final aliasOwner = <String, String>{};
  for (final m in merch['merchants']) {
    final cat = m['category'];
    if (cat != 'uncategorized' && !paths.contains(cat)) {
      fail('merchant ${m['name']} -> unknown category $cat');
    }
    for (final a in (m['aliases'] ?? [])) {
      final prev = aliasOwner[a];
      // A duplicate alias means two merchants fight over the same SMS string
      // and the winner depends on file order - a silent miscategorization.
      if (prev != null && prev != m['name']) fail('alias "$a" claimed by both $prev and ${m['name']}');
      aliasOwner[a] = m['name'];
    }
  }

  // Forced categories on rules must exist too.
  for (final r in rules['rules']) {
    final fc = r['forced_category'];
    if (fc != null && !paths.contains(fc)) fail('${r['id']} forced_category $fc not in taxonomy');
  }

  print('rules=${rules['rules'].length} rejects=${rules['reject_patterns']['patterns'].length} '
        'categories=${cats['categories'].length} paths=${paths.length} merchants=${merch['merchants'].length}');
  if (failures == 0) { print('ALL OK'); } else { print('$failures failure(s)'); exit(1); }
}
