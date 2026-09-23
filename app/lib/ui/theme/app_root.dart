import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ledger/ui/dashboard/home_shell.dart';
import 'package:ledger/ui/onboarding/onboarding_flow.dart';
import 'package:ledger/ui/onboarding/onboarding_store.dart';

import 'app_theme.dart';

/// The root widget.
///
/// Wire the platform layer by overriding the providers in
/// `app_dependencies.dart` in the [ProviderScope] above this widget:
///
/// ```dart
/// void main() {
///   runApp(ProviderScope(
///     overrides: <Override>[ /* repository, message source, parser, ... */ ],
///     child: const LedgerApp(),
///   ));
/// }
/// ```
///
/// There is no login and no route table: the app has exactly one decision to
/// make on launch, which is whether this person has been through onboarding.
class LedgerApp extends StatelessWidget {
  const LedgerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ledger',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      home: const AppEntry(),
    );
  }
}

/// Chooses between onboarding and the dashboard.
class AppEntry extends ConsumerWidget {
  const AppEntry({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<bool> complete = ref.watch(onboardingCompleteProvider);
    return complete.when(
      // Reading one boolean out of shared_preferences. If this ever takes long
      // enough to see, something is wrong with the device, not the app.
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      // A flag that cannot be read is treated as "not onboarded". Showing the
      // disclosure again is harmless; skipping it would not be.
      error: (Object error, StackTrace stack) => const OnboardingFlow(),
      data: (bool done) => done ? const HomeShell() : const OnboardingFlow(),
    );
  }
}
