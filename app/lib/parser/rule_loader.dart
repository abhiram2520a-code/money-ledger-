/// Compiling a [RuleSet] into something the matcher can run.
///
/// Every regex in a pack is compiled ONCE, here, at load time. A bad pattern
/// must fail in one place at startup and not once per message, and a pack that
/// does not compile must never become the pack in force: the previously loaded
/// rules stay, and if there are none the bundled pack is used. A rules update
/// arriving from the config server is untrusted input, so this file is where a
/// hostile or simply newer pack is made harmless.
library;

import 'package:flutter/foundation.dart';

import '../core/result.dart';
import '../models/models.dart';

/// A compiled reject pattern that remembers its own source text, so a
/// rejection reason can name the pattern without quoting the message.
@immutable
class NamedPattern {
  const NamedPattern(this.source, this.regex);

  final String source;
  final RegExp regex;

  /// `null` when [source] is not a valid regex.
  static NamedPattern? tryCompile(String source, {bool caseSensitive = false}) {
    if (source.trim().isEmpty) return null;
    try {
      return NamedPattern(source, RegExp(source, caseSensitive: caseSensitive));
    } on FormatException {
      return null;
    }
  }

  bool hasMatch(String input) => regex.hasMatch(input);

  @override
  String toString() => 'NamedPattern($source)';
}

/// One [ParserRuleDef] with its two regexes compiled and its named groups
/// enumerated.
@immutable
class CompiledRule {
  const CompiledRule({
    required this.def,
    required this.senderPattern,
    required this.bodyPattern,
    required this.groupNames,
  });

  final ParserRuleDef def;
  final RegExp senderPattern;
  final RegExp bodyPattern;

  /// The named groups the body pattern actually declares. Dart throws if you
  /// ask a match for a group the pattern does not contain, so every read goes
  /// through [group], which checks this set first.
  final Set<String> groupNames;

  String get id => def.id;

  int get priority => def.priority;

  /// True when any spelling of the sender matches. See
  /// `SenderId.matchCandidates` for why there is more than one.
  bool matchesSender(Iterable<String> candidates) {
    for (final candidate in candidates) {
      if (senderPattern.hasMatch(candidate)) return true;
    }
    return false;
  }

  RegExpMatch? matchBody(String body) => bodyPattern.firstMatch(body);

  /// The value of [name] in [match], or `null` when the rule does not declare
  /// that group or the group did not participate in the match.
  String? group(RegExpMatch match, String name) {
    if (!groupNames.contains(name)) return null;
    final value = match.namedGroup(name);
    if (value == null) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  @override
  String toString() => 'CompiledRule(${def.id}, p${def.priority})';
}

/// A whole pack, compiled and ordered, ready to run.
@immutable
class CompiledRules {
  const CompiledRules({
    required this.version,
    required this.rules,
    required this.rejectPatterns,
    required this.debitWords,
    required this.creditWords,
    required this.source,
    this.origin = RulesOrigin.bundled,
    this.warnings = const <String>[],
  });

  /// `parser_rules.json`'s `version`.
  final int version;

  /// Highest priority first, ties broken by id - the order the matcher walks.
  final List<CompiledRule> rules;

  /// `reject_patterns.patterns`, compiled. Checked before any rule.
  final List<NamedPattern> rejectPatterns;

  /// `direction_words.debit` / `.credit`, lower-cased, longest first so
  /// `transferred to` wins over `transferred`.
  final List<String> debitWords;
  final List<String> creditWords;

  /// The set this was compiled from, kept so the categoriser and the re-parse
  /// sweep can reach the merchants and categories.
  final RuleSet source;

  final RulesOrigin origin;

  /// Rules or patterns that were dropped during a salvage load, as short
  /// machine-ish notes. Never contains message text.
  final List<String> warnings;

  static const CompiledRules empty = CompiledRules(
    version: 0,
    rules: <CompiledRule>[],
    rejectPatterns: <NamedPattern>[],
    debitWords: <String>[],
    creditWords: <String>[],
    source: RuleSet.empty,
  );

  bool get isEmpty => rules.isEmpty;

  CompiledRule? ruleById(String id) {
    for (final rule in rules) {
      if (rule.id == id) return rule;
    }
    return null;
  }

  @override
  String toString() => 'CompiledRules(v$version, ${origin.wire}, '
      '${rules.length} rules, ${rejectPatterns.length} rejects, '
      '${warnings.length} warnings)';
}

/// Turns a [RuleSet] into [CompiledRules].
abstract final class RuleCompiler {
  /// The literal every `body_pattern` must contain. `tools/validate_rules.dart`
  /// enforces the same thing in CI; it is repeated here because the config
  /// server is not trusted.
  static const String amountGroupToken = '(?<amount>';

  /// The named groups this build understands. A newer pack may declare others;
  /// they are recorded as warnings and ignored rather than failing the load,
  /// so an old app keeps working against a new pack.
  static const Set<String> knownGroupNames = <String>{
    'amount',
    'direction_word',
    'date',
    'account_tail',
    'card_tail',
    'merchant',
    'vpa',
    'ref',
    'balance',
  };

  /// Matches `(?<name>` but not the lookbehind forms `(?<=` and `(?<!`.
  static final RegExp _namedGroupDeclaration =
      RegExp(r'\(\?<([A-Za-z_][A-Za-z0-9_]*)>');

  /// Compiles [set] strictly.
  ///
  /// Fails with `ErrorCodes.corruptRules` when the set has no rules, a pattern
  /// does not compile, or a rule lacks the `amount` group - a rule that cannot
  /// find the amount can only ever produce a broken ledger entry.
  static Result<CompiledRules> compile(RuleSet set) {
    if (set.rules.isEmpty) {
      return Result<CompiledRules>.err(
        AppError.corruptRules('rules pack v${set.version} declares no rules'),
      );
    }

    final warnings = <String>[];
    final compiled = <CompiledRule>[];
    final seenIds = <String>{};

    for (final def in set.orderedRules) {
      if (def.id.isEmpty) {
        return Result<CompiledRules>.err(
          AppError.corruptRules('rules pack v${set.version} has a rule with no id'),
        );
      }
      if (!seenIds.add(def.id)) {
        return Result<CompiledRules>.err(
          AppError.corruptRules('duplicate rule id ${def.id}'),
        );
      }
      final outcome = _compileRule(def, warnings);
      switch (outcome) {
        case Ok<CompiledRule>(value: final rule):
          compiled.add(rule);
        case Err<CompiledRule>(error: final error):
          return Result<CompiledRules>.err(error);
      }
    }

    final rejects = <NamedPattern>[];
    for (final source in set.rejectPatterns) {
      final pattern = NamedPattern.tryCompile(source);
      if (pattern == null) {
        return Result<CompiledRules>.err(
          AppError.corruptRules('reject pattern does not compile: $source'),
        );
      }
      rejects.add(pattern);
    }

    return Result<CompiledRules>.ok(
      CompiledRules(
        version: set.version,
        rules: List<CompiledRule>.unmodifiable(compiled),
        rejectPatterns: List<NamedPattern>.unmodifiable(rejects),
        debitWords: _orderedWords(set.debitWords),
        creditWords: _orderedWords(set.creditWords),
        source: set,
        origin: set.origin,
        warnings: List<String>.unmodifiable(warnings),
      ),
    );
  }

  /// Compiles as much of [set] as is usable, dropping the rest.
  ///
  /// This is the "the pack is newer than this build" path: a v9 pack may carry
  /// rules written against syntax this Dart does not have, and dropping those
  /// three rules is strictly better than refusing the whole pack or crashing.
  /// Returns `null` when nothing usable survives, which sends the caller back
  /// to the bundled pack.
  static CompiledRules? salvage(RuleSet set) {
    final warnings = <String>[];
    final compiled = <CompiledRule>[];
    final seenIds = <String>{};

    for (final def in set.orderedRules) {
      if (def.id.isEmpty || !seenIds.add(def.id)) {
        warnings.add('skip:duplicate_or_empty_id');
        continue;
      }
      final outcome = _compileRule(def, warnings);
      switch (outcome) {
        case Ok<CompiledRule>(value: final rule):
          compiled.add(rule);
        case Err<CompiledRule>():
          warnings.add('skip:${def.id}');
      }
    }
    if (compiled.isEmpty) return null;

    final rejects = <NamedPattern>[];
    for (final source in set.rejectPatterns) {
      final pattern = NamedPattern.tryCompile(source);
      if (pattern == null) {
        warnings.add('skip_reject_pattern');
        continue;
      }
      rejects.add(pattern);
    }

    return CompiledRules(
      version: set.version,
      rules: List<CompiledRule>.unmodifiable(compiled),
      rejectPatterns: List<NamedPattern>.unmodifiable(rejects),
      debitWords: _orderedWords(set.debitWords),
      creditWords: _orderedWords(set.creditWords),
      source: set,
      origin: set.origin,
      warnings: List<String>.unmodifiable(warnings),
    );
  }

  static Result<CompiledRule> _compileRule(
    ParserRuleDef def,
    List<String> warnings,
  ) {
    if (!def.bodyPattern.contains(amountGroupToken)) {
      return Result<CompiledRule>.err(
        AppError.corruptRules('${def.id} has no (?<amount>) group'),
      );
    }
    final RegExp sender;
    final RegExp body;
    try {
      sender = RegExp(def.senderPattern, caseSensitive: false);
    } on FormatException catch (e) {
      return Result<CompiledRule>.err(
        AppError.corruptRules('${def.id}.sender_pattern does not compile', cause: e),
      );
    }
    try {
      body = RegExp(def.bodyPattern, caseSensitive: false, dotAll: true);
    } on FormatException catch (e) {
      return Result<CompiledRule>.err(
        AppError.corruptRules('${def.id}.body_pattern does not compile', cause: e),
      );
    }

    final groups = <String>{};
    for (final match in _namedGroupDeclaration.allMatches(def.bodyPattern)) {
      groups.add(match.group(1)!);
    }
    for (final group in groups) {
      if (!knownGroupNames.contains(group)) {
        warnings.add('unknown_group:${def.id}:$group');
      }
    }
    if (def.direction != directionInferWire && def.resolvedDirection == null) {
      warnings.add('unknown_direction:${def.id}');
    }

    return Result<CompiledRule>.ok(
      CompiledRule(
        def: def,
        senderPattern: sender,
        bodyPattern: body,
        groupNames: Set<String>.unmodifiable(groups),
      ),
    );
  }

  /// Lower-cased and longest-first, so `transferred to` is tested before
  /// `transferred` and a two-word direction phrase is not shadowed.
  static List<String> _orderedWords(List<String> words) {
    final cleaned = words
        .map((w) => w.trim().toLowerCase())
        .where((w) => w.isNotEmpty)
        .toSet()
        .toList(growable: false);
    cleaned.sort((a, b) {
      final byLength = b.length.compareTo(a.length);
      return byLength != 0 ? byLength : a.compareTo(b);
    });
    return List<String>.unmodifiable(cleaned);
  }
}

/// Holds the pack in force and decides what to do with a candidate pack.
///
/// The invariant this exists to protect: **the loader never ends up with no
/// rules**. A malformed download, a pack from a future schema, or a pack that
/// compiles to nothing all leave the previous pack - or the bundled one -
/// running. The app keeps parsing SMS on a device that never reaches the
/// config server again.
class RuleLoader {
  RuleLoader({CompiledRules? bundled})
      : _bundled = bundled,
        _current = bundled ?? CompiledRules.empty;

  CompiledRules? _bundled;
  CompiledRules _current;

  /// The pack in force.
  CompiledRules get current => _current;

  /// The last pack that was adopted as the bundled baseline, if any. This is
  /// the recovery target.
  CompiledRules? get bundled => _bundled;

  bool get isReady => !_current.isEmpty;

  int get version => _current.version;

  /// Compiles [bundled] and makes it both the baseline and the pack in force.
  ///
  /// Fails only when the assets shipped inside the APK are themselves broken,
  /// which is a broken build rather than a runtime condition.
  Result<CompiledRules> adoptBundled(RuleSet bundled) {
    final outcome = RuleCompiler.compile(bundled);
    switch (outcome) {
      case Ok<CompiledRules>(value: final compiled):
        _bundled = compiled;
        _current = compiled;
        return Result<CompiledRules>.ok(compiled);
      case Err<CompiledRules>(error: final error):
        return Result<CompiledRules>.err(error);
    }
  }

  /// Adopts [candidate] if it is usable.
  ///
  /// Strict compile first. If that fails, a salvage pass keeps whatever
  /// compiles, because a mostly-good newer pack still beats a stale one. If
  /// nothing survives, the current pack stays in force and the error explains
  /// why - the caller treats that as routine, not as a broken app.
  Result<CompiledRules> adopt(RuleSet candidate) {
    final strict = RuleCompiler.compile(candidate);
    if (strict case Ok<CompiledRules>(value: final compiled)) {
      _current = compiled;
      return Result<CompiledRules>.ok(compiled);
    }

    final salvaged = RuleCompiler.salvage(candidate);
    if (salvaged != null) {
      _current = salvaged;
      return Result<CompiledRules>.ok(salvaged);
    }

    if (_bundled != null) {
      _current = _bundled!;
    }
    final error = strict.errorOrNull ??
        AppError.corruptRules('rules pack v${candidate.version} is unusable');
    return Result<CompiledRules>.err(error);
  }

  /// Discards whatever was adopted and goes back to the bundled pack.
  Result<CompiledRules> resetToBundled() {
    final bundled = _bundled;
    if (bundled == null) {
      return Result<CompiledRules>.err(
        AppError.corruptRules('no bundled pack has been loaded'),
      );
    }
    _current = bundled;
    return Result<CompiledRules>.ok(bundled);
  }

  /// Ids of rules whose behaviour differs between [from] and [to].
  ///
  /// The re-parse sweep uses this to re-run only the messages a pack actually
  /// changed instead of every message ever received. Added and removed rules
  /// count, and so does any field that can change the produced fields - not
  /// just the two patterns.
  static Set<String> changedRuleIds({required RuleSet from, required RuleSet to}) {
    final before = <String, ParserRuleDef>{
      for (final rule in from.rules) rule.id: rule,
    };
    final after = <String, ParserRuleDef>{
      for (final rule in to.rules) rule.id: rule,
    };
    final changed = <String>{};

    for (final entry in after.entries) {
      final old = before[entry.key];
      if (old == null || _behaviourDiffers(old, entry.value)) {
        changed.add(entry.key);
      }
    }
    for (final id in before.keys) {
      if (!after.containsKey(id)) changed.add(id);
    }
    return changed;
  }

  static bool _behaviourDiffers(ParserRuleDef a, ParserRuleDef b) =>
      a.senderPattern != b.senderPattern ||
      a.bodyPattern != b.bodyPattern ||
      a.direction != b.direction ||
      a.channel != b.channel ||
      a.txnType != b.txnType ||
      a.priority != b.priority ||
      a.forcedCategoryPath != b.forcedCategoryPath ||
      !listEquals(a.dateFormats, b.dateFormats);
}
