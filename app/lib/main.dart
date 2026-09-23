/// App entry.
///
/// Three things happen here and nothing else: the bindings come up, the
/// composition root in `di.dart` builds and loads every module, and the
/// result is handed to the UI through a `ProviderScope`.
///
/// **There is no network call on this path.** The rules pack is compiled into
/// the APK, so the app parses, categorises, stores and reports with no
/// connection at all - on first launch, on a phone that never has one, and
/// with the config server permanently gone. The only method in the whole app
/// that can open a socket is `RulesProvider.checkForUpdate()`, which the user
/// triggers from Settings and which only ever supplies a *newer* rules pack.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/result.dart';
import 'di.dart';
import 'ui/theme/app_root.dart';
import 'ui/theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final Result<AppDependencies> boot = await bootstrapAppDependencies();

  switch (boot) {
    case Ok<AppDependencies>(value: final AppDependencies deps):
      runApp(
        ProviderScope(
          overrides: deps.overrides,
          child: const _LedgerRoot(),
        ),
      );
    case Err<AppDependencies>(error: final AppError error):
      // Startup can only fail for two reasons, and both are the build's fault
      // rather than the device's: a rules pack missing from the APK, or a
      // database that will not open. Say which, rather than showing a white
      // screen or a ledger that appears to be empty.
      runApp(_StartupFailureApp(error: error));
  }
}

/// Wraps the UI and starts ingestion once, after the first frame.
///
/// This lives here rather than inside a screen because ingestion is not a
/// screen's concern: the live receiver and the catch-up scan must run whether
/// the user is looking at the dashboard, the settings page or nothing at all.
class _LedgerRoot extends ConsumerStatefulWidget {
  const _LedgerRoot();

  @override
  ConsumerState<_LedgerRoot> createState() => _LedgerRootState();
}

class _LedgerRootState extends ConsumerState<_LedgerRoot> {
  @override
  void initState() {
    super.initState();
    // After the first frame, so the dashboard paints immediately instead of
    // waiting on a scan of a 20,000-message inbox.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(ref.read(ingestServiceProvider).startIfPermitted());
    });
  }

  @override
  Widget build(BuildContext context) => const LedgerApp();
}

/// The one screen that exists outside the app's own theme system, because it
/// has to work when the thing that failed to load might be the theme's own
/// rules pack.
class _StartupFailureApp extends StatelessWidget {
  const _StartupFailureApp({required this.error});

  final AppError error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ledger',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(
                    Icons.report_gmailerrorred_outlined,
                    size: 48,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Ledger could not start',
                    style: Theme.of(context).textTheme.titleLarge,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    error.message,
                    style: Theme.of(context).textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'This is a problem with this build of the app, not with '
                    'your phone or your connection. Reinstalling the app is '
                    'the fix.',
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
