import 'package:flutter/material.dart';
import 'package:ledger/ui/theme/theme.dart';

/// Screen 3a. The moment the Android dialog is up, or the retry state if the
/// user dismissed it without answering.
///
/// The disclosure has already been accepted by this point; this screen exists
/// only so there is something coherent behind the system dialog and something
/// to tap if the dialog was swiped away.
class PermissionScreen extends StatelessWidget {
  const PermissionScreen({
    required this.busy,
    required this.onRequest,
    required this.onSkip,
    super.key,
    this.error,
  });

  final bool busy;
  final VoidCallback onRequest;
  final VoidCallback onSkip;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final String? failure = error;
    return ContentWidth(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Insets.xxl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Icon(Icons.lock_open_outlined, size: 40, color: context.colors.primary),
            const SizedBox(height: Insets.xl),
            Text(
              busy ? 'Waiting for your answer' : 'One tap to turn it on',
              style: context.texts.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: Insets.md),
            Text(
              busy
                  ? 'Android is asking whether this app may read the messages on '
                      'this phone.'
                  : 'Android will ask whether this app may read the messages on this '
                      'phone. Everything it reads stays here.',
              style: context.texts.bodyMedium?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            if (failure != null) ...<Widget>[
              const SizedBox(height: Insets.xl),
              AttentionBanner(
                title: 'That did not go through',
                message: failure,
              ),
            ],
            const SizedBox(height: Insets.xxxl),
            FilledButton(
              onPressed: busy ? null : onRequest,
              child: busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Allow SMS access'),
            ),
            const SizedBox(height: Insets.sm),
            TextButton(
              onPressed: busy ? null : onSkip,
              child: const Text('Skip for now'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Screen 3b. SMS access was declined, or Android will not ask again.
///
/// Play's permissions policy requires an app to respect a refusal and to make a
/// reasonable effort to accommodate users who do not grant a sensitive
/// permission. So this is not a wall: it explains what still works, offers a
/// one-tap route to system settings for the permanently-denied case, and its
/// primary button goes to the ledger.
class SmsDeclinedScreen extends StatelessWidget {
  const SmsDeclinedScreen({
    required this.permanentlyDenied,
    required this.onOpenSettings,
    required this.onRecheck,
    required this.onContinue,
    super.key,
  });

  final bool permanentlyDenied;
  final VoidCallback onOpenSettings;
  final VoidCallback onRecheck;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    return ContentWidth(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Insets.xxl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Icon(
              Icons.edit_note_outlined,
              size: 40,
              color: context.colors.onSurfaceVariant,
            ),
            const SizedBox(height: Insets.xl),
            Text(
              'No problem - manual mode it is',
              style: context.texts.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: Insets.md),
            Text(
              'Without SMS access the app cannot fill the ledger by itself, but '
              'everything else works: add a transaction in a few taps, categorise '
              'it, and see the same monthly breakdown. You will not be asked '
              'again - the switch lives in Settings whenever you want it.',
              style: context.texts.bodyMedium?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            if (permanentlyDenied) ...<Widget>[
              const SizedBox(height: Insets.xl),
              AttentionBanner(
                title: 'Android will not ask again',
                message: 'The permission was blocked, so the dialog no longer '
                    'appears. To turn it on: Settings > Permissions > SMS > Allow.',
                icon: Icons.settings_outlined,
                actionLabel: 'Open app settings',
                onAction: onOpenSettings,
              ),
              const SizedBox(height: Insets.md),
              OutlinedButton(
                onPressed: onRecheck,
                child: const Text('I turned it on - check again'),
              ),
            ],
            const SizedBox(height: Insets.xxxl),
            FilledButton(
              onPressed: onContinue,
              child: const Text('Go to my ledger'),
            ),
          ],
        ),
      ),
    );
  }
}
