/// What actually protects the ledger file on disk - stated honestly, because
/// a privacy claim the code does not implement is worse than no claim.
///
/// ## What IS in place
///
/// * **The database never leaves the device.** `LedgerRepository` has no
///   network code and no dependency that could add any. The only HTTP call in
///   the app is `RulesProvider.checkForUpdate()`, which downloads rules and
///   uploads nothing.
/// * **App-private storage.** The file lives in the app's own data directory.
///   On a non-rooted Android device no other app can read it, and a USB file
///   browser cannot either.
/// * **No cloud backup.** The manifest must set `android:allowBackup="false"`
///   with deny-all data-extraction rules, so Android's own backup never
///   carries a silent copy of the ledger off the phone.
/// * **Message bodies expire.** The text of every SMS is purged after
///   [defaultBodyRetention] by `LedgerRepository.purgeMessageBodies`, keeping
///   the parse metadata and dropping the words. What cannot be read cannot
///   leak.
/// * **Bodies are stored in one place only.** `RawMessage.body` is the single
///   field that holds message text, it is never logged, and no export path
///   writes it anywhere the user did not choose.
///
/// ## What is NOT in place, and why
///
/// **The database file itself is not encrypted.** Full-file encryption needs
/// SQLCipher, which means swapping `sqlite3_flutter_libs` for
/// `sqlcipher_flutter_libs` and holding the key in the Android Keystore. This
/// build ships plain SQLite, so [atRestEncryptionEnabled] is `false` and the
/// app must not tell the user otherwise.
///
/// In practice that means: on a locked, non-rooted phone the ledger is
/// protected by Android's own file-based encryption and by app sandboxing. On
/// a rooted phone, or one whose screen lock is off, someone with physical
/// access could read it. That is the true statement, and it is the one the
/// settings screen shows.
///
/// ## The upgrade path, already shaped
///
/// [sqlCipherPragmas] returns exactly the statements a keyed build must run
/// before its first query. When the dependency is swapped in, the store runs
/// them right after opening the file and [atRestEncryptionEnabled] becomes
/// `true` - no schema change, no migration, and the existing plaintext file is
/// converted once with SQLCipher's own `sqlcipher_export`.
library;

/// Honest facts about at-rest protection, for the UI and for tests.
abstract final class LedgerEncryption {
  /// Whether the database file itself is encrypted. `false` in this build.
  ///
  /// Everything the user is told about encryption is derived from this flag
  /// rather than written by hand, so the claim cannot outlive the
  /// implementation. It is `final` rather than `const` so the honest branch is
  /// never folded away at compile time.
  static final bool atRestEncryptionEnabled = _sqlCipherLinked;

  /// Flipped to `true` by the build that links `sqlcipher_flutter_libs`.
  static const bool _sqlCipherLinked = false;

  /// How long SMS text is kept before [purgeAfter] is due.
  ///
  /// Six months is long enough for a re-parse after a rules update to fix
  /// historical mistakes, and short enough that a phone that changes hands
  /// does not carry years of message text.
  static const Duration defaultBodyRetention = Duration(days: 180);

  /// The instant before which bodies should be purged.
  static DateTime purgeAfter(DateTime now, {Duration retention = defaultBodyRetention}) =>
      now.subtract(retention);

  /// One sentence for the privacy screen. Derived, never hand-written.
  static String describeProtection() {
    if (atRestEncryptionEnabled) {
      return 'Your ledger is encrypted on this device and never leaves it.';
    }
    return 'Your ledger is stored in this app’s private storage on this '
        'phone and never leaves it. It is protected by your phone’s own '
        'lock screen encryption, not by a separate password.';
  }

  /// The longer version, for the "how is my data protected" sheet.
  static List<String> protectionDetails() => <String>[
        'Nothing is uploaded. There is no account and no server holding your '
            'transactions.',
        'The database is in private app storage, which other apps cannot read.',
        'The text of your messages is deleted after '
            '${defaultBodyRetention.inDays} days; only the amounts and '
            'categories are kept.',
        if (!atRestEncryptionEnabled)
          'The database file is not separately encrypted, so keep a screen '
              'lock on your phone.',
      ];

  /// The statements a SQLCipher-backed build runs immediately after opening
  /// the file, before any other query.
  ///
  /// Returns an empty list when [atRestEncryptionEnabled] is `false`, so
  /// calling it in the open path today is a no-op rather than a lie.
  static List<String> sqlCipherPragmas(String? key) {
    if (!atRestEncryptionEnabled || key == null || key.isEmpty) {
      return const <String>[];
    }
    return <String>[
      "PRAGMA key = \"x'$key'\"",
      'PRAGMA cipher_page_size = 4096',
      'PRAGMA kdf_iter = 256000',
      // WAL must be set AFTER keying, or the header write races the key.
      'PRAGMA journal_mode = WAL',
    ];
  }
}
