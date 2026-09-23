import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ledger/models/models.dart';
import 'package:ledger/ui/theme/theme.dart';
import 'package:ledger/ui/widgets/widgets.dart';

import 'rules_update_controller.dart';

/// The rules pack: what is in force, where it came from, and the optional
/// business of fetching a newer one.
///
/// The screen leads with the fact that matters: the rules are inside the app.
/// Everything below it is a convenience. A user who never lets this app touch
/// the network loses nothing except later additions to the merchant list.
class RulesStatusScreen extends ConsumerWidget {
  const RulesStatusScreen({super.key});

  static const String routeName = '/settings/rules';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<RuleSet> async = ref.watch(ruleSetProvider);
    final RulesUpdateState update = ref.watch(rulesUpdateControllerProvider);
    final RulesUpdateController controller =
        ref.read(rulesUpdateControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('Rules pack')),
      body: ContentWidth(
        child: async.when(
          loading: () => const SkeletonList(count: 4, showLeading: false),
          error: (Object _, StackTrace _) => const ErrorState(
            message: 'The rules pack could not be read. The app cannot parse '
                'messages until it loads, which usually means reinstalling.',
          ),
          data: (RuleSet set) => ListView(
            padding: const EdgeInsets.fromLTRB(
                Insets.xl, Insets.lg, Insets.xl, Insets.huge),
            children: <Widget>[
              _OfflineAssurance(version: set.version),
              const SizedBox(height: Insets.xl),
              _Facts(set: set),
              const Divider(height: Insets.xxxl),
              Text('Updates',
                  style: context.texts.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: Insets.sm),
              Text(
                'An update can only add or correct how messages are read. It '
                'never touches your transactions, and it never overwrites the '
                'rules you taught the app yourself.',
                style: context.texts.bodyMedium?.copyWith(height: 1.45),
              ),
              const SizedBox(height: Insets.md),
              if (update.message != null)
                _UpdateMessage(state: update),
              const SizedBox(height: Insets.md),
              Wrap(
                spacing: Insets.sm,
                runSpacing: Insets.sm,
                children: <Widget>[
                  FilledButton.tonalIcon(
                    onPressed: update.busy ? null : controller.check,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Check for updates'),
                  ),
                  if (update.available != null)
                    FilledButton.icon(
                      onPressed: update.busy ? null : controller.applyAvailable,
                      icon: const Icon(Icons.download_done, size: 18),
                      label: Text('Install version ${update.available!.version}'),
                    ),
                  if (set.origin != RulesOrigin.bundled)
                    OutlinedButton.icon(
                      onPressed: update.busy ? null : controller.resetToBundled,
                      icon: const Icon(Icons.settings_backup_restore, size: 18),
                      label: const Text('Restore the built-in rules'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The headline claim, first thing on the screen because it is the answer to
/// the question users actually have.
class _OfflineAssurance extends StatelessWidget {
  const _OfflineAssurance({required this.version});

  final int version;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(Insets.lg),
      decoration: BoxDecoration(
        color: context.palette.attentionContainer,
        borderRadius: Radii.cardBorder,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.offline_bolt_outlined,
              color: context.palette.onAttentionContainer),
          const SizedBox(width: Insets.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'The app works with no connection',
                  style: context.texts.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: context.palette.onAttentionContainer,
                  ),
                ),
                const SizedBox(height: Insets.xs),
                Text(
                  'Version $version of the reading rules is compiled into the '
                  'app, so reading messages, categorising them and every total '
                  'work offline, permanently. A server is only ever used to '
                  'offer a newer list, and it is never required.',
                  style: context.texts.bodySmall?.copyWith(
                    height: 1.4,
                    color: context.palette.onAttentionContainer,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Facts extends StatelessWidget {
  const _Facts({required this.set});

  final RuleSet set;

  @override
  Widget build(BuildContext context) {
    final String origin = switch (set.origin) {
      RulesOrigin.bundled => 'Built into the app',
      RulesOrigin.remote => 'Downloaded from the config server',
      RulesOrigin.user => 'Your own',
    };

    return Column(
      children: <Widget>[
        _Fact(label: 'Version', value: '${set.version}'),
        _Fact(label: 'Source', value: origin),
        _Fact(
          label: 'Loaded',
          value: set.loadedAt == null ? 'This session' : Fmt.dateTime(set.loadedAt!),
        ),
        _Fact(
          label: 'Message patterns',
          value: Fmt.count(set.rules.length),
        ),
        _Fact(
          label: 'Categories',
          value: Fmt.count(set.categories.length),
        ),
        _Fact(
          label: 'Known merchants',
          value: Fmt.count(set.merchants.length),
        ),
      ],
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.sm),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(label,
                style: context.texts.bodyMedium
                    ?.copyWith(color: context.colors.onSurfaceVariant)),
          ),
          Text(value,
              style: context.texts.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _UpdateMessage extends StatelessWidget {
  const _UpdateMessage({required this.state});

  final RulesUpdateState state;

  @override
  Widget build(BuildContext context) {
    final Color tone = state.isFailure
        ? context.colors.error
        : (state.isOffline
            ? context.colors.onSurfaceVariant
            : context.colors.primary);
    final IconData icon = state.busy
        ? Icons.hourglass_empty
        : (state.isFailure
            ? Icons.error_outline
            : (state.isOffline ? Icons.cloud_off_outlined : Icons.check_circle_outline));

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, size: 18, color: tone),
        const SizedBox(width: Insets.sm),
        Expanded(
          child: Text(
            state.message ?? '',
            style: context.texts.bodyMedium?.copyWith(color: tone),
          ),
        ),
      ],
    );
  }
}
