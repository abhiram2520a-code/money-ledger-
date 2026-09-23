import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ledger/ui/theme/theme.dart';

import 'import_controller.dart';

/// Screen 4. The historical import, with real counters.
///
/// The numbers on this screen are the live output of the pipeline: messages the
/// reader has looked at, and transactions actually written to the ledger. There
/// is no simulated progress bar, because the first thing this app has to earn
/// is the belief that its numbers mean what they say.
///
/// Stop is always available and always honest: whatever has already landed is
/// kept, and the summary reflects it.
class ImportScreen extends ConsumerWidget {
  const ImportScreen({required this.onDone, super.key});

  final VoidCallback onDone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ImportProgress progress = ref.watch(importControllerProvider);
    final ImportController controller = ref.read(importControllerProvider.notifier);

    return ContentWidth(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Insets.xxl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const SizedBox(height: Insets.huge),
            Text(
              progress.isRunning ? 'Reading your messages' : _headline(progress),
              style: context.texts.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: Insets.sm),
            Text(
              _subhead(progress),
              style: context.texts.bodyMedium?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: Insets.xxxl),
            Row(
              children: <Widget>[
                Expanded(
                  child: _Counter(
                    value: progress.scanned,
                    label: 'messages scanned',
                  ),
                ),
                Expanded(
                  child: _Counter(
                    value: progress.found,
                    label: 'transactions found',
                    emphasised: true,
                  ),
                ),
              ],
            ),
            const SizedBox(height: Insets.xxl),
            if (progress.isRunning)
              const LinearProgressIndicator()
            else
              Container(
                height: 6,
                decoration: BoxDecoration(
                  color: context.palette.chartTrack,
                  borderRadius: Radii.pill,
                ),
              ),
            const SizedBox(height: Insets.xl),
            _Details(progress: progress),
            const SizedBox(height: Insets.xxxl),
            if (progress.phase == ImportPhase.failed)
              AttentionBanner(
                title: 'The scan stopped early',
                message: progress.error ?? 'Something went wrong while reading the '
                    'inbox. Anything already found has been kept.',
              ),
            if (progress.isThinInbox)
              const AttentionBanner(
                title: 'Not much history on this phone',
                message: 'This phone is only holding a few recent messages, so there '
                    'was little to import. The ledger will fill in as new bank '
                    'messages arrive.',
                icon: Icons.inbox_outlined,
              ),
            const SizedBox(height: Insets.lg),
            if (progress.isRunning) ...<Widget>[
              OutlinedButton(
                onPressed: controller.cancel,
                child: const Text('Stop and keep what you found'),
              ),
              const SizedBox(height: Insets.sm),
              Text(
                'You can keep using the app while this finishes.',
                style: context.texts.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ] else
              FilledButton(
                onPressed: onDone,
                child: Text(
                  progress.found > 0 ? 'See my ledger' : 'Continue',
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String _headline(ImportProgress progress) => switch (progress.phase) {
        ImportPhase.done => progress.found > 0 ? 'Your ledger is ready' : 'All done',
        ImportPhase.cancelled => 'Stopped',
        ImportPhase.failed => 'Partly done',
        ImportPhase.idle || ImportPhase.running => 'Reading your messages',
      };

  static String _subhead(ImportProgress progress) {
    if (progress.isRunning) {
      return 'Everything here is happening on this phone. Nothing is being '
          'uploaded.';
    }
    if (progress.found == 0) {
      return 'No bank messages were found to import. New ones will be picked up '
          'as they arrive.';
    }
    final int uncategorized = progress.needsReview;
    if (uncategorized > 0) {
      return '${Fmt.count(uncategorized)} of them could not be matched to a '
          'merchant. They are waiting in Uncategorized - one tap each and the app '
          'will remember.';
    }
    return 'Every transaction was matched to a category. You can change any of '
        'them.';
  }
}

class _Counter extends StatelessWidget {
  const _Counter({required this.value, required this.label, this.emphasised = false});

  final int value;
  final String label;
  final bool emphasised;

  @override
  Widget build(BuildContext context) {
    final Color color =
        emphasised ? context.colors.primary : context.colors.onSurface;
    return Column(
      children: <Widget>[
        TweenAnimationBuilder<int>(
          tween: IntTween(begin: 0, end: value),
          duration: Motion.counterTick,
          builder: (BuildContext context, int shown, Widget? child) => Text(
            Fmt.count(shown),
            style: AppTheme.tabular(context.texts.displaySmall).copyWith(color: color),
          ),
        ),
        const SizedBox(height: Insets.xs),
        Text(
          label,
          style: context.texts.bodySmall?.copyWith(
            color: context.colors.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _Details extends StatelessWidget {
  const _Details({required this.progress});

  final ImportProgress progress;

  @override
  Widget build(BuildContext context) {
    final List<Widget> chips = <Widget>[];
    final DateTime? oldest = progress.oldest;
    final DateTime? newest = progress.newest;
    if (oldest != null && newest != null) {
      chips.add(MetaChip(
        icon: Icons.date_range_outlined,
        label: '${Fmt.monthShort(oldest.toLocal())} - ${Fmt.monthShort(newest.toLocal())}',
      ));
    }
    if (progress.needsReview > 0) {
      chips.add(MetaChip(
        icon: Icons.help_outline,
        label: '${Fmt.count(progress.needsReview)} uncategorized',
        tone: context.palette.attention,
      ));
    }
    if (progress.duplicates > 0) {
      chips.add(MetaChip(
        icon: Icons.copy_all_outlined,
        label: '${Fmt.count(progress.duplicates)} already imported',
      ));
    }
    if (chips.isEmpty) return const SizedBox.shrink();
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: Insets.sm,
      runSpacing: Insets.sm,
      children: chips,
    );
  }
}
