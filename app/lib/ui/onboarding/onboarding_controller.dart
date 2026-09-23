import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ledger/contracts/contracts.dart';
import 'package:ledger/core/result.dart';
import 'package:ledger/models/models.dart';
import 'package:ledger/ui/theme/theme.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

import 'import_controller.dart';
import 'onboarding_store.dart';

/// The first-run steps, in the order Play's User Data policy requires them.
///
/// The ordering is not a design preference, it is the policy: the in-app
/// disclosure must *immediately precede* the runtime permission request, and
/// navigating away from the disclosure must never be read as consent. So
/// [disclosure] can only be left by an explicit button, and [permission] is the
/// only step that may show the Android dialog.
enum OnboardingStep {
  /// What the app is for. Skippable.
  value,

  /// The prominent disclosure. Not skippable, not auto-dismissing.
  disclosure,

  /// The Android SMS permission dialog, triggered by an explicit tap.
  permission,

  /// The historical import, with live counters and a Stop button.
  importing,

  /// SMS access was declined or blocked. The app still works.
  declined,

  /// Onboarding is over; the shell should show the dashboard.
  done,
}

@immutable
class OnboardingFlowState {
  const OnboardingFlowState({
    this.step = OnboardingStep.value,
    this.permission = PermissionState.unknown,
    this.busy = false,
    this.smsSupported = true,
    this.error,
  });

  final OnboardingStep step;
  final PermissionState permission;

  /// True while the Android dialog is up, so the button cannot be tapped twice.
  final bool busy;

  /// False on a platform with no SMS inbox to read. The app is still useful -
  /// it just never offers automatic tracking.
  final bool smsSupported;

  final String? error;

  bool get isPermanentlyDenied => permission == PermissionState.permanentlyDenied;

  OnboardingFlowState copyWith({
    OnboardingStep? step,
    PermissionState? permission,
    bool? busy,
    bool? smsSupported,
    String? error,
    bool clearError = false,
  }) {
    return OnboardingFlowState(
      step: step ?? this.step,
      permission: permission ?? this.permission,
      busy: busy ?? this.busy,
      smsSupported: smsSupported ?? this.smsSupported,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Drives the first-run flow.
///
/// Two rules this class exists to enforce:
/// 1. The Android permission dialog is never shown before the user has tapped
///    the accept button on the disclosure screen.
/// 2. Declining is a supported outcome, not a dead end. The user reaches the
///    dashboard either way, and the app never re-prompts on its own.
class OnboardingController extends Notifier<OnboardingFlowState> {
  @override
  OnboardingFlowState build() {
    // Fire-and-forget: the flow starts on the value screen regardless, and the
    // support check only decides what the later screens offer.
    Future<void>.microtask(_checkSupport);
    return const OnboardingFlowState();
  }

  Future<void> _checkSupport() async {
    try {
      final MessageSource source = ref.read(messageSourceProvider);
      final bool supported = await source.isSupported();
      final Result<PermissionState> status = await source.permissionStatus();
      state = state.copyWith(
        smsSupported: supported,
        permission: status.valueOrNull ?? PermissionState.unknown,
      );
    } on Object {
      // A platform layer that is not wired yet must not break the flow; the
      // permission step will surface the real failure when it is tapped.
      state = state.copyWith(smsSupported: false);
    }
  }

  /// Value screen -> disclosure.
  void toDisclosure() => state = state.copyWith(step: OnboardingStep.disclosure, clearError: true);

  /// The affirmative tap on the disclosure. This is the consent event, and it
  /// is the only thing that unlocks the permission request.
  void acceptDisclosure() =>
      state = state.copyWith(step: OnboardingStep.permission, clearError: true);

  /// Shows the Android dialog, then routes on the answer.
  Future<void> requestSmsAccess() async {
    if (state.busy) return;
    state = state.copyWith(busy: true, clearError: true);

    final MessageSource source = ref.read(messageSourceProvider);
    final Result<PermissionState> result = await source.requestPermission();
    final PermissionState permission = result.valueOrNull ?? PermissionState.unknown;

    if (permission.isGranted) {
      state = state.copyWith(
        busy: false,
        permission: permission,
        step: OnboardingStep.importing,
      );
      // Start the import with no extra tap. The gap between "granted" and
      // "something is happening" is where a first run is lost.
      await source.start();
      await ref.read(importControllerProvider.notifier).start();
      return;
    }

    state = state.copyWith(
      busy: false,
      permission: permission,
      step: OnboardingStep.declined,
      error: result.errorOrNull?.message,
    );
    await ref.read(onboardingStoreProvider).setSmsDeclined(true);
  }

  /// "Not now" on the permission screen, and the way out of [OnboardingStep.declined].
  Future<void> continueWithoutSms() async {
    await ref.read(onboardingStoreProvider).setSmsDeclined(true);
    await finish();
  }

  /// Opens the system settings page for this app, for the permanently-denied
  /// case where the Android dialog will never appear again.
  Future<void> openSystemSettings() async {
    await ph.openAppSettings();
  }

  /// Re-checks the permission after a trip to system settings.
  Future<void> refreshPermission() async {
    final Result<PermissionState> status =
        await ref.read(messageSourceProvider).permissionStatus();
    final PermissionState permission = status.valueOrNull ?? PermissionState.unknown;
    state = state.copyWith(
      permission: permission,
      step: permission.isGranted ? OnboardingStep.permission : state.step,
    );
  }

  /// Ends onboarding and hands over to the dashboard.
  Future<void> finish() async {
    await ref.read(onboardingStoreProvider).markComplete();
    if (state.permission.isGranted) {
      await ref.read(onboardingStoreProvider).setSmsDeclined(false);
    }
    state = state.copyWith(step: OnboardingStep.done);
    ref.invalidate(onboardingCompleteProvider);
  }
}

final NotifierProvider<OnboardingController, OnboardingFlowState> onboardingControllerProvider =
    NotifierProvider<OnboardingController, OnboardingFlowState>(OnboardingController.new);
