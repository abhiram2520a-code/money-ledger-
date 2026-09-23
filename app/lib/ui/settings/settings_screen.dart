import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ledger/core/result.dart';
import 'package:ledger/models/models.dart';
import 'package:ledger/ui/theme/theme.dart';

import 'about_screen.dart';
import 'export_controller.dart';
import 'privacy_screen.dart';
import 'rules_status_screen.dart';

/// Settings.
///
/// There is no account section, because there are no accounts. Nothing here
/// signs in, syncs, or restores from a server - the whole of the user's data
/// is on this phone, so the things worth offering are: what the app reads,
/// what rules it is using, how to get the data out, and how to destroy it.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  static const String routeName = '/settings';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<RuleSet> rules = ref.watch(ruleSetProvider);
    final bool busy = ref.watch(exportControllerProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ContentWidth(
        child: ListView(
          padding: const EdgeInsets.only(bottom: Insets.huge),
          children: <Widget>[
            const _SectionLabel('Privacy'),
            ListTile(
              leading: const Icon(Icons.lock_outline),
              title: const Text('What this app reads'),
              subtitle: const Text(
                  'Exactly which messages it looks at, and what it keeps'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (BuildContext _) => const PrivacyScreen(),
                ),
              ),
            ),
            const Divider(height: 1),

            const _SectionLabel('Reading rules'),
            ListTile(
              leading: const Icon(Icons.rule_folder_outlined),
              title: const Text('Rules pack'),
              subtitle: Text(
                rules.when(
                  loading: () => 'Loading...',
                  error: (Object _, StackTrace _) => 'Could not be read',
                  data: (RuleSet set) => _rulesSummary(set),
                ),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (BuildContext _) => const RulesStatusScreen(),
                ),
              ),
            ),
            const Divider(height: 1),

            const _SectionLabel('Your data'),
            ListTile(
              leading: const Icon(Icons.file_download_outlined),
              title: const Text('Export transactions as CSV'),
              subtitle: const Text(
                  'Written to a folder on this phone. Nothing is uploaded.'),
              enabled: !busy,
              onTap: busy ? null : () => _export(context, ref),
            ),
            ListTile(
              leading: Icon(Icons.delete_forever_outlined,
                  color: context.colors.error),
              title: Text('Delete all data',
                  style: TextStyle(color: context.colors.error)),
              subtitle: const Text(
                  'Erases every transaction, rule and stored message'),
              enabled: !busy,
              onTap: busy ? null : () => _confirmWipe(context, ref),
            ),
            const Divider(height: 1),

            const _SectionLabel('About'),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('About this app'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (BuildContext _) => const AboutScreen(),
                ),
              ),
            ),

            const SizedBox(height: Insets.xxl),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.xl),
              child: Text(
                'There is no account and nothing to sign in to. Everything '
                'this app knows is on this phone.',
                textAlign: TextAlign.center,
                style: context.texts.bodySmall
                    ?.copyWith(color: context.colors.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _rulesSummary(RuleSet set) {
    if (set.isEmpty) return 'Not loaded yet';
    final String origin = switch (set.origin) {
      RulesOrigin.bundled => 'built into the app',
      RulesOrigin.remote => 'downloaded',
      RulesOrigin.user => 'yours',
    };
    return 'Version ${set.version}, $origin';
  }

  Future<void> _export(BuildContext context, WidgetRef ref) async {
    final Result<ExportReceipt> result =
        await ref.read(exportControllerProvider.notifier).exportCsv();
    if (!context.mounted) return;

    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => result.fold(
        (ExportReceipt receipt) => AlertDialog(
          title: const Text('Export written'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('${Fmt.plural(receipt.rowCount, 'transaction', 'transactions')} '
                  'saved to this phone.'),
              const SizedBox(height: Insets.md),
              SelectableText(
                receipt.path,
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
              const SizedBox(height: Insets.md),
              const Text(
                'Message text is not included in the export. Open the file '
                'with a file manager to move or share it.',
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Done'),
            ),
          ],
        ),
        (AppError error) => AlertDialog(
          title: const Text('Export failed'),
          content: Text(
            '${error.message}\n\nNothing was changed and nothing left the '
            'phone.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmWipe(BuildContext context, WidgetRef ref) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => const _WipeConfirmDialog(),
    );
    if (confirmed != true || !context.mounted) return;

    final Result<void> result =
        await ref.read(exportControllerProvider.notifier).wipeEverything();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            result.isOk
                ? 'Everything was deleted. The app will start filling up again '
                    'from new messages.'
                : 'Nothing was deleted: ${result.errorOrNull?.message ?? 'unknown error'}',
          ),
        ),
      );
  }
}

/// A destructive action that cannot be taken by accident: the user types the
/// word. Two taps are not enough of a gate for "erase everything".
class _WipeConfirmDialog extends StatefulWidget {
  const _WipeConfirmDialog();

  @override
  State<_WipeConfirmDialog> createState() => _WipeConfirmDialogState();
}

class _WipeConfirmDialogState extends State<_WipeConfirmDialog> {
  static const String _word = 'DELETE';
  final TextEditingController _controller = TextEditingController();
  bool _matches = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Delete everything?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            'This erases every transaction, every rule you taught the app, '
            'and every stored message. There is no backup anywhere, so this '
            'cannot be undone.',
          ),
          const SizedBox(height: Insets.lg),
          TextField(
            controller: _controller,
            autocorrect: false,
            textCapitalization: TextCapitalization.characters,
            onChanged: (String v) =>
                setState(() => _matches = v.trim().toUpperCase() == _word),
            decoration: const InputDecoration(
              labelText: 'Type $_word to confirm',
              border: OutlineInputBorder(borderRadius: Radii.fieldBorder),
            ),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: context.colors.error,
            foregroundColor: context.colors.onError,
          ),
          onPressed: _matches ? () => Navigator.of(context).pop(true) : null,
          child: const Text('Delete everything'),
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          Insets.xl, Insets.xl, Insets.xl, Insets.sm),
      child: Text(
        text.toUpperCase(),
        style: context.texts.labelMedium?.copyWith(
          color: context.colors.primary,
          letterSpacing: 0.8,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
