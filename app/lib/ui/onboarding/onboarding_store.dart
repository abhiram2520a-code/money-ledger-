import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The handful of first-run flags that decide which screen the app opens on.
///
/// Flags only. No transaction ever touches `SharedPreferences` - that is
/// drift's job - and nothing here is ever sent anywhere.
abstract interface class OnboardingStore {
  Future<bool> isComplete();

  /// Recorded only after the user has seen the disclosure and made a choice,
  /// whether that choice was to grant SMS access or to decline it.
  Future<void> markComplete();

  /// True when the user got through onboarding without granting SMS access, so
  /// the app knows to keep offering the manual path instead of nagging.
  Future<bool> smsDeclined();

  Future<void> setSmsDeclined(bool declined);

  /// The last time a historical import finished, so the app does not rescan
  /// the whole inbox on every launch.
  Future<DateTime?> lastImportAt();

  Future<void> setLastImportAt(DateTime at);

  /// Used by "start over" in settings and by tests.
  Future<void> reset();
}

/// [OnboardingStore] backed by `shared_preferences`.
class SharedPrefsOnboardingStore implements OnboardingStore {
  const SharedPrefsOnboardingStore();

  static const String _completeKey = 'onboarding.complete';
  static const String _declinedKey = 'onboarding.sms_declined';
  static const String _lastImportKey = 'onboarding.last_import_millis';

  @override
  Future<bool> isComplete() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_completeKey) ?? false;
  }

  @override
  Future<void> markComplete() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_completeKey, true);
  }

  @override
  Future<bool> smsDeclined() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_declinedKey) ?? false;
  }

  @override
  Future<void> setSmsDeclined(bool declined) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_declinedKey, declined);
  }

  @override
  Future<DateTime?> lastImportAt() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final int? millis = prefs.getInt(_lastImportKey);
    return millis == null ? null : DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
  }

  @override
  Future<void> setLastImportAt(DateTime at) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_lastImportKey, at.toUtc().millisecondsSinceEpoch);
  }

  @override
  Future<void> reset() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_completeKey);
    await prefs.remove(_declinedKey);
    await prefs.remove(_lastImportKey);
  }
}

final Provider<OnboardingStore> onboardingStoreProvider =
    Provider<OnboardingStore>((Ref ref) => const SharedPrefsOnboardingStore());

/// Which screen the app opens on. There is no login, so the only question a
/// cold start has to answer is "has this person been through onboarding".
final FutureProvider<bool> onboardingCompleteProvider = FutureProvider<bool>(
  (Ref ref) => ref.watch(onboardingStoreProvider).isComplete(),
);
