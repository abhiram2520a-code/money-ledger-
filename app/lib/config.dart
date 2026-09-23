/// Build-time configuration. The whole file exists to answer one question:
/// what does this app do when there is no server?
///
/// The answer is: everything.
///
/// The rules pack is compiled into the APK at `assets/rules/`, so parsing,
/// categorising, the ledger, the rollups and every screen run from the phone.
/// [configServerBaseUrl] is the address of a read-only config server whose
/// only job is to hand out a *newer* rules pack. It is `null` by default, and
/// with it null [AppConfig.hasConfigServer] is false, no HTTP client is ever
/// constructed, and `RulesProvider.checkForUpdate()` returns
/// `Err(ErrorCodes.offline)` without opening a socket - which the UI already
/// treats as a routine fact, not an error.
///
/// To point a build at a deployed server:
///
/// ```
/// flutter build apk --release \
///   --dart-define=LEDGER_CONFIG_URL=https://money-ledger.up.railway.app
/// ```
///
/// Nothing else in the app changes. The server is an optional upgrade channel,
/// never a dependency.
///
/// PRIVACY: the only request this app can make is a GET against the four paths
/// below. No body, no user data, no device identifier, no analytics. See
/// `server/main.py`, which has no write endpoints at all.
library;

abstract final class AppConfig {
  /// Set at build time with `--dart-define=LEDGER_CONFIG_URL=...`.
  ///
  /// Empty (the default) means "there is no config server", which is a fully
  /// supported, permanent configuration.
  static const String _rawBaseUrl = String.fromEnvironment('LEDGER_CONFIG_URL');

  /// The config server root, or `null` when this build has none.
  static String? get configServerBaseUrl {
    final String trimmed = _rawBaseUrl.trim();
    if (trimmed.isEmpty) return null;
    // A trailing slash would turn '/v1/manifest' into '//v1/manifest' on some
    // proxies, which 404s. Normalise once, here.
    return trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }

  /// False for a default build. When false, nothing in the app opens a socket.
  static bool get hasConfigServer => configServerBaseUrl != null;

  /// The version this app reports when asking for a newer pack. It is the
  /// only thing the request carries besides the current rules version.
  static const String appVersion = '1.0.0';

  /// One cheap call that says which documents moved, so a launch that has
  /// nothing to do costs one small response.
  static const String manifestPath = '/v1/manifest';

  static const String parserRulesPath = '/v1/parser-rules';
  static const String categoriesPath = '/v1/categories';
  static const String merchantsPath = '/v1/merchants';

  /// How long a single request may take before it is abandoned. Short on
  /// purpose: an update check must never be something the user waits for.
  static const Duration networkTimeout = Duration(seconds: 10);

  /// The bundled pack. These paths are declared in `pubspec.yaml` and the
  /// Compile phase copies `../rules/*.json` into them.
  static const String bundledParserRules = 'assets/rules/parser_rules.json';
  static const String bundledCategories = 'assets/rules/categories.json';
  static const String bundledMerchants = 'assets/rules/merchants.json';

  /// Where an adopted download is cached, relative to the app-support
  /// directory. Deleting it reverts the app to the bundled pack, which is what
  /// `RulesProvider.resetToBundled()` does.
  static const String cachedRulesFileName = 'rules_pack.json';

  /// Resolves [path] against [configServerBaseUrl]. Returns `null` when this
  /// build has no server, so callers cannot accidentally build a request.
  static Uri? endpoint(String path) {
    final String? base = configServerBaseUrl;
    if (base == null) return null;
    return Uri.parse('$base$path');
  }
}
