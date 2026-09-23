import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ledger/ui/theme/theme.dart';

import 'disclosure_screen.dart';
import 'import_screen.dart';
import 'onboarding_controller.dart';
import 'permission_screen.dart';
import 'value_screen.dart';

/// The first-run flow. There is no login, so this is what a cold first launch
/// opens on.
///
/// It is a single [Scaffold] whose body swaps between steps rather than a
/// navigator stack, for one specific reason: the disclosure must not be
/// dismissible by a back gesture, and the cleanest way to guarantee that is for
/// there to be nothing behind it to go back to.
class OnboardingFlow extends ConsumerWidget {
  const OnboardingFlow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final OnboardingFlowState state = ref.watch(onboardingControllerProvider);
    final OnboardingController controller =
        ref.read(onboardingControllerProvider.notifier);

    return Scaffold(
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: Motion.normal,
          child: KeyedSubtree(
            key: ValueKey<OnboardingStep>(state.step),
            child: switch (state.step) {
              OnboardingStep.value => ValueScreen(
                  onContinue: controller.toDisclosure,
                ),
              OnboardingStep.disclosure => DisclosureScreen(
                  busy: state.busy,
                  // Accepting the disclosure and showing the Android dialog are
                  // one action, so the disclosure immediately precedes the
                  // runtime request with nothing in between.
                  onAccept: () {
                    controller.acceptDisclosure();
                    controller.requestSmsAccess();
                  },
                  onDecline: controller.continueWithoutSms,
                ),
              OnboardingStep.permission => PermissionScreen(
                  busy: state.busy,
                  error: state.error,
                  onRequest: controller.requestSmsAccess,
                  onSkip: controller.continueWithoutSms,
                ),
              OnboardingStep.importing => ImportScreen(
                  onDone: controller.finish,
                ),
              OnboardingStep.declined => SmsDeclinedScreen(
                  permanentlyDenied: state.isPermanentlyDenied,
                  onOpenSettings: controller.openSystemSettings,
                  onRecheck: controller.refreshPermission,
                  onContinue: controller.finish,
                ),
              OnboardingStep.done => const _HandingOver(),
            },
          ),
        ),
      ),
    );
  }
}

/// A single frame between "finish" and the dashboard appearing. Deliberately
/// not a branded splash: the user has waited enough.
class _HandingOver extends StatelessWidget {
  const _HandingOver();

  @override
  Widget build(BuildContext context) {
    return const Center(child: CircularProgressIndicator());
  }
}
