/// The rules pack in force, and the entirely optional business of fetching a
/// newer one.
///
/// This is the only file in `lib/` outside `native/` that can open a socket,
/// and the design goal is that it does not matter. The pack ships inside the
/// APK; [AssetRulesProvider.load] never touches the network; and with
/// `AppConfig.hasConfigServer == false` (the default build)
/// [AssetRulesProvider.checkForUpdate] returns `Err(ErrorCodes.offline)`
/// without constructing an HTTP client at all.
///
/// A downloaded pack is adopted only when it validates AND its version is
/// strictly greater. A bad server response can never break parsing on a phone.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show AssetBundle, rootBundle;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../config.dart';
import '../contracts/rules_provider.dart';
import '../core/result.dart';
import '../models/models.dart';
import '../parser/rule_loader.dart';

/// Where an adopted download is kept between launches.
///
/// An interface rather than a bare `File` so the provider is testable with no
/// platform channels: `path_provider` needs a real device.
abstract interface class RulesCache {
  Future<String?> read();

  Future<void> write(String contents);

  Future<void> clear();
}

/// [RulesCache] over one file in the app-support directory, which is
/// app-private on Android.
class FileRulesCache implements RulesCache {
  const FileRulesCache({this.fileName = AppConfig.cachedRulesFileName});

  final String fileName;

  Future<File> _file() async {
    final Directory dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$fileName');
  }

  @override
  Future<String?> read() async {
    try {
      final File file = await _file();
      if (!await file.exists()) return null;
      return await file.readAsString();
    } on Object {
      // An unreadable cache is not an error condition: it means "use the
      // bundled pack", which is always correct.
      return null;
    }
  }

  @override
  Future<void> write(String contents) async {
    final File file = await _file();
    await file.parent.create(recursive: true);
    await file.writeAsString(contents, flush: true);
  }

  @override
  Future<void> clear() async {
    try {
      final File file = await _file();
      if (await file.exists()) await file.delete();
    } on Object {
      // Nothing to do. The next load falls back to bundled anyway.
    }
  }
}

/// A cache that keeps nothing. The default for a build with no config server:
/// there is never anything to cache.
class NullRulesCache implements RulesCache {
  const NullRulesCache();

  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String contents) async {}

  @override
  Future<void> clear() async {}
}

/// [RulesProvider] backed by the bundled assets, with an optional cached
/// download layered on top.
class AssetRulesProvider implements RulesProvider {
  AssetRulesProvider({
    AssetBundle? bundle,
    RulesCache? cache,
    http.Client Function()? httpClientFactory,
    DateTime Function()? clock,
  })  : _bundle = bundle ?? rootBundle,
        _cache = cache ?? const FileRulesCache(),
        _httpClientFactory = httpClientFactory ?? http.Client.new,
        _clock = clock ?? DateTime.now;

  final AssetBundle _bundle;
  final RulesCache _cache;
  final http.Client Function() _httpClientFactory;
  final DateTime Function() _clock;

  final StreamController<RuleSet> _changes = StreamController<RuleSet>.broadcast();

  RuleSet _current = RuleSet.empty;
  RuleSet? _bundled;

  @override
  RuleSet get current => _current;

  @override
  int get version => _current.version;

  @override
  Stream<RuleSet> get changes async* {
    // The contract says listeners see the current value immediately, so a
    // screen that subscribes after startup is never blank.
    yield _current;
    yield* _changes.stream;
  }

  /// Releases the change stream. The app holds one provider for its lifetime,
  /// so this is for tests and for a clean shutdown.
  Future<void> dispose() => _changes.close();

  // --------------------------------------------------------------- loading

  @override
  Future<Result<RuleSet>> load() async {
    final Result<RuleSet> bundled = await loadBundled();
    if (bundled case Err<RuleSet>(error: final AppError error)) {
      return Err<RuleSet>(error);
    }
    final RuleSet base = bundled.valueOrNull!;

    final RuleSet? cached = await _readCache();
    // Strictly greater, or the bundled pack wins. A cache from an older APK
    // must never hold back a newer bundled pack after an app update.
    final RuleSet chosen =
        cached != null && cached.version > base.version ? cached : base;

    _publish(chosen);
    return Ok<RuleSet>(chosen);
  }

  @override
  Future<Result<RuleSet>> loadBundled() async {
    final RuleSet? memo = _bundled;
    if (memo != null) return Ok<RuleSet>(memo);

    try {
      final List<String> raw = await Future.wait(<Future<String>>[
        _bundle.loadString(AppConfig.bundledParserRules),
        _bundle.loadString(AppConfig.bundledCategories),
        _bundle.loadString(AppConfig.bundledMerchants),
      ]);
      final RuleSet set = RuleSet.fromDocuments(
        parserRules: _decode(raw[0]),
        categories: _decode(raw[1]),
        merchants: _decode(raw[2]),
        loadedAt: _clock(),
      );
      if (set.categories.isEmpty || set.rules.isEmpty) {
        return Result<RuleSet>.err(
          AppError.corruptRules(
            'The rules pack bundled in this build has no '
            '${set.categories.isEmpty ? 'categories' : 'parser rules'}. '
            'This is a broken build, not a device problem.',
          ),
        );
      }
      _bundled = set;
      return Ok<RuleSet>(set);
    } on Object catch (error, stack) {
      return Result<RuleSet>.err(
        AppError.corruptRules(
          'The rules bundled in this build could not be read.',
          cause: error,
        ).copyWith(stackTrace: stack),
      );
    }
  }

  @override
  Future<Result<RuleSet>> resetToBundled() async {
    await _cache.clear();
    final Result<RuleSet> bundled = await loadBundled();
    if (bundled case Ok<RuleSet>(value: final RuleSet set)) {
      _publish(set);
    }
    return bundled;
  }

  // ---------------------------------------------------------------- update

  @override
  Future<Result<RuleSet?>> checkForUpdate({
    Duration timeout = AppConfig.networkTimeout,
  }) async {
    final Uri? manifest = AppConfig.endpoint(AppConfig.manifestPath);
    if (manifest == null) {
      // No server in this build. Not a failure: the app is designed to run
      // this way forever, and the UI renders `offline` as a plain sentence.
      return Result<RuleSet?>.err(
        AppError.offline('This build has no update server configured.'),
      );
    }

    final http.Client client = _httpClientFactory();
    try {
      final http.Response head = await client.get(
        manifest,
        headers: _headers(),
      ).timeout(timeout);
      if (head.statusCode != 200) {
        return Result<RuleSet?>.err(
          AppError.network('The update server answered ${head.statusCode}.'),
        );
      }

      final int? serverVersion = _manifestVersion(head.body);
      // The manifest says what the server has. If it is not newer we stop
      // here, having transferred a few hundred bytes.
      if (serverVersion == null || serverVersion <= version) {
        return const Ok<RuleSet?>(null);
      }

      final List<http.Response> docs = await Future.wait(<Future<http.Response>>[
        client.get(AppConfig.endpoint(AppConfig.parserRulesPath)!, headers: _headers()),
        client.get(AppConfig.endpoint(AppConfig.categoriesPath)!, headers: _headers()),
        client.get(AppConfig.endpoint(AppConfig.merchantsPath)!, headers: _headers()),
      ]).timeout(timeout);

      for (final http.Response r in docs) {
        if (r.statusCode != 200) {
          return Result<RuleSet?>.err(
            AppError.network('The update server answered ${r.statusCode}.'),
          );
        }
      }

      final RuleSet candidate = RuleSet.fromDocuments(
        parserRules: _decode(docs[0].body),
        categories: _decode(docs[1].body),
        merchants: _decode(docs[2].body),
        origin: RulesOrigin.remote,
        loadedAt: _clock(),
      );

      final AppError? invalid = validate(candidate);
      if (invalid != null) return Result<RuleSet?>.err(invalid);
      return Ok<RuleSet?>(candidate);
    } on TimeoutException {
      return Result<RuleSet?>.err(
        AppError.timeout('The update server did not answer in time.'),
      );
    } on SocketException {
      return Result<RuleSet?>.err(AppError.offline());
    } on http.ClientException {
      return Result<RuleSet?>.err(AppError.offline());
    } on FormatException catch (error) {
      return Result<RuleSet?>.err(
        AppError.corruptRules(
          'The update server sent something that is not a rules pack.',
          cause: error,
        ),
      );
    } on Object catch (error) {
      return Result<RuleSet?>.err(
        AppError.network('The update check failed.', cause: error),
      );
    } finally {
      client.close();
    }
  }

  @override
  Future<Result<void>> applyUpdate(RuleSet rules) async {
    final AppError? invalid = validate(rules);
    if (invalid != null) return Err<void>(invalid);

    final RuleSet adopted = rules.copyWith(
      origin: RulesOrigin.remote,
      loadedAt: _clock(),
    );
    try {
      await _cache.write(jsonEncode(adopted.toJson()));
    } on Object catch (error) {
      // The pack is good; only persisting it failed. Adopt it for this
      // session rather than throwing away a valid update.
      _publish(adopted);
      return Result<void>.err(
        AppError.io(
          'The new rules are in use but could not be saved, so the app will '
          'go back to its built-in rules next launch.',
          cause: error,
        ),
      );
    }
    _publish(adopted);
    return okVoid;
  }

  /// The same checks `tools/validate_rules.dart` runs in CI, repeated here
  /// because the server is not trusted. Returns `null` when [candidate] is
  /// safe to adopt.
  AppError? validate(RuleSet candidate) {
    if (candidate.version <= version) {
      return AppError.corruptRules(
        'That pack is version ${candidate.version} and this app already has '
        'version $version.',
      );
    }
    if (candidate.categories.isEmpty) {
      return AppError.corruptRules(
        'That pack has no categories, so every transaction would land in '
        'Uncategorized.',
      );
    }
    if (candidate.rules.isEmpty) {
      return AppError.corruptRules('That pack has no parser rules.');
    }

    // Every pattern has to compile HERE, once, rather than throwing once per
    // message on the ingest path six hours from now.
    final Result<CompiledRules> compiled = RuleCompiler.compile(candidate);
    if (compiled case Err<CompiledRules>(error: final AppError error)) {
      return AppError.corruptRules(error.message, cause: error.cause);
    }

    final Set<String> paths = candidate.categoryPaths;
    for (final MerchantEntry merchant in candidate.merchants) {
      if (!paths.contains(merchant.categoryPath)) {
        return AppError.corruptRules(
          'The merchant "${merchant.name}" points at the category '
          '"${merchant.categoryPath}", which that pack does not define.',
        );
      }
    }
    for (final ParserRuleDef rule in candidate.rules) {
      final String? forced = rule.forcedCategoryPath;
      if (forced != null && !paths.contains(forced)) {
        return AppError.corruptRules(
          'The rule "${rule.id}" forces the category "$forced", which that '
          'pack does not define.',
        );
      }
    }
    return null;
  }

  // --------------------------------------------------------------- helpers

  Map<String, String> _headers() => <String, String>{
        // The entire payload of every request this app can make. No device id,
        // no user id, no transaction, no message text.
        'Accept': 'application/json',
        'X-Ledger-App-Version': AppConfig.appVersion,
        'X-Ledger-Rules-Version': '$version',
      };

  Future<RuleSet?> _readCache() async {
    final String? raw = await _cache.read();
    if (raw == null || raw.isEmpty) return null;
    try {
      final RuleSet cached = RuleSet.fromJson(_decode(raw));
      if (cached.categories.isEmpty || cached.rules.isEmpty) return null;
      // A cached pack still has to compile. If a previously good download has
      // been corrupted on disk, the bundled pack takes over silently.
      if (RuleCompiler.compile(cached).isErr) return null;
      return cached;
    } on Object {
      return null;
    }
  }

  void _publish(RuleSet set) {
    _current = set;
    if (!_changes.isClosed) _changes.add(set);
  }

  static Map<String, dynamic> _decode(String source) {
    final Object? decoded = jsonDecode(source);
    if (decoded is Map<String, dynamic>) return decoded;
    throw const FormatException('Expected a JSON object');
  }

  static int? _manifestVersion(String body) {
    try {
      final Map<String, dynamic> json = _decode(body);
      final Map<String, dynamic> documents = jMap(json['documents']);
      final Map<String, dynamic> parserRules = jMap(documents['parser-rules']);
      final int found = jInt(parserRules['version']);
      return found == 0 ? null : found;
    } on Object {
      return null;
    }
  }
}
