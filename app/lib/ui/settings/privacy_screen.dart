import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ledger/core/result.dart';
import 'package:ledger/models/models.dart';
import 'package:ledger/ui/theme/theme.dart';

import 'export_controller.dart';

/// The current SMS permission, read without prompting.
final FutureProvider<PermissionState> smsPermissionProvider =
    FutureProvider<PermissionState>((Ref ref) async {
  final Result<PermissionState> result =
      await ref.watch(messageSourceProvider).permissionStatus();
  return result.getOrElse(PermissionState.unknown);
});

/// What this app reads, stated plainly and truthfully.
///
/// Written to be read by a person who is deciding whether to trust an app with
/// their bank messages. Every claim on this screen is one the code actually
/// keeps: the sender gate in `MessageSource`, the single network call in
/// `RulesProvider.checkForUpdate`, the absence of any analytics dependency in
/// `pubspec.yaml`. If any of those change, this screen is wrong and has to
/// change with them.
class PrivacyScreen extends ConsumerWidget {
  const PrivacyScreen({super.key});

  static const String routeName = '/settings/privacy';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<PermissionState> permission = ref.watch(smsPermissionProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('What this app reads')),
      body: ContentWidth(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
              Insets.xl, Insets.lg, Insets.xl, Insets.huge),
          children: <Widget>[
            Text(
              'The short version',
              style: context.texts.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: Insets.sm),
            Text(
              'This app reads bank and UPI text messages on this phone and '
              'turns them into a ledger. Nothing it reads is sent anywhere. '
              'There is no account, no sync and no cloud copy, which also '
              'means there is nothing to restore if you lose the phone - '
              'export a CSV from Settings if that matters to you.',
              style: context.texts.bodyMedium?.copyWith(height: 1.45),
            ),
            const SizedBox(height: Insets.xl),

            const _Claim(
              icon: Icons.filter_alt_outlined,
              title: 'Only messages from financial senders',
              body: 'A message is checked against the list of bank and UPI '
                  'sender IDs before anything is stored. A message from a '
                  'person never reaches the database at all - it is dropped '
                  'before its text is written anywhere.',
            ),
            const _Claim(
              icon: Icons.phone_android_outlined,
              title: 'Stored on this phone, in this app',
              body: 'Message text, transactions and your rules live in a '
                  'database inside this app\'s private storage. No other app '
                  'can read it.',
            ),
            const _Claim(
              icon: Icons.cloud_off_outlined,
              title: 'Message text is never uploaded',
              body: 'Not for parsing, not for categorising, not for a merchant '
                  'the app does not recognise. When the app does not know a '
                  'payee it asks you, because the alternative is sending your '
                  'bank messages to a server.',
            ),
            const _Claim(
              icon: Icons.wifi_tethering_off,
              title: 'One network request, and it is optional',
              body: 'The app asks a server whether a newer version of its '
                  'reading rules exists. That request carries the rules '
                  'version and the app version, and nothing else - no device '
                  'ID, no phone number, no transactions. Block it and the app '
                  'keeps working exactly as it does today.',
            ),
            const _Claim(
              icon: Icons.analytics_outlined,
              title: 'No analytics and no crash reporting',
              body: 'There is no analytics SDK and no crash reporter in this '
                  'app, so no usage data and no error report containing your '
                  'messages can be collected.',
            ),
            const _Claim(
              icon: Icons.no_accounts_outlined,
              title: 'No account, ever',
              body: 'Nothing to sign up for, nothing to sign in to, no email '
                  'address, no phone number collected.',
            ),

            const SizedBox(height: Insets.lg),
            const Divider(),
            const SizedBox(height: Insets.lg),

            Text('SMS permission',
                style: context.texts.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: Insets.sm),
            permission.when(
              loading: () => Text('Checking...', style: context.texts.bodyMedium),
              error: (Object _, StackTrace _) => Text(
                'The permission state could not be read on this device.',
                style: context.texts.bodyMedium,
              ),
              data: (PermissionState value) => _PermissionRow(state: value),
            ),

            const SizedBox(height: Insets.xl),
            Text('Stored message text',
                style: context.texts.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: Insets.sm),
            Text(
              'The app keeps the text of the messages it read so it can read '
              'them again correctly after a rules update, and so it can show '
              'you the message behind any transaction. You can delete that '
              'text at any time - the transactions stay.',
              style: context.texts.bodyMedium?.copyWith(height: 1.45),
            ),
            const SizedBox(height: Insets.md),
            const _PurgeButtons(),
          ],
        ),
      ),
    );
  }
}

class _Claim extends StatelessWidget {
  const _Claim({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 20, color: context.colors.primary),
          ),
          const SizedBox(width: Insets.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title,
                    style: context.texts.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: Insets.xxs),
                Text(body,
                    style: context.texts.bodyMedium?.copyWith(
                      height: 1.4,
                      color: context.colors.onSurfaceVariant,
                    )),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PermissionRow extends StatelessWidget {
  const _PermissionRow({required this.state});

  final PermissionState state;

  @override
  Widget build(BuildContext context) {
    final (IconData icon, String text) = switch (state) {
      PermissionState.granted => (
          Icons.check_circle_outline,
          'Granted. The app is reading new bank messages as they arrive.'
        ),
      PermissionState.denied => (
          Icons.pause_circle_outline,
          'Not granted. The app cannot read messages, so nothing new will be '
              'added. Anything already recorded is still here.'
        ),
      PermissionState.permanentlyDenied => (
          Icons.block_outlined,
          'Turned off permanently. Android will not ask again, so it has to be '
              'turned back on from the system app settings.'
        ),
      PermissionState.restricted => (
          Icons.lock_outline,
          'Restricted by a device policy on this phone.'
        ),
      PermissionState.unsupported => (
          Icons.phonelink_off,
          'This platform does not let apps read SMS. Transactions can still be '
              'added by hand.'
        ),
      PermissionState.unknown => (
          Icons.help_outline,
          'The permission state could not be determined.'
        ),
    };

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, size: 18, color: context.colors.onSurfaceVariant),
        const SizedBox(width: Insets.sm),
        Expanded(
          child: Text(text, style: context.texts.bodyMedium),
        ),
      ],
    );
  }
}

class _PurgeButtons extends ConsumerWidget {
  const _PurgeButtons();

  Future<void> _purge(BuildContext context, WidgetRef ref, Duration age,
      String label) async {
    final Result<int> result =
        await ref.read(exportControllerProvider.notifier).purgeMessageText(age);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            result.fold(
              (int purged) => purged == 0
                  ? 'There was no stored message text $label.'
                  : '${Fmt.plural(purged, 'message', 'messages')} cleared. '
                      'Their transactions are untouched.',
              (AppError error) =>
                  'Nothing was cleared: ${error.message}',
            ),
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool busy = ref.watch(exportControllerProvider);
    return Wrap(
      spacing: Insets.sm,
      runSpacing: Insets.sm,
      children: <Widget>[
        OutlinedButton(
          onPressed: busy
              ? null
              : () => _purge(context, ref, const Duration(days: 90),
                  'older than 90 days'),
          child: const Text('Clear text older than 90 days'),
        ),
        OutlinedButton(
          onPressed: busy
              ? null
              : () => _purge(context, ref, Duration.zero, 'stored'),
          child: const Text('Clear all message text'),
        ),
      ],
    );
  }
}
