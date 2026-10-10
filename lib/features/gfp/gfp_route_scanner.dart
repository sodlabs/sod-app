import 'dart:async';

import 'package:hiddify/features/gfp/gfp_payload_probe.dart';
import 'package:hiddify/features/gfp/gfp_probe_session.dart';

typedef GfpRouteProof = Future<bool> Function(String tag, GfpProbeAttempt attempt);

/// Only the first successful proof can commit a live route. All reserve tests
/// remain on the authenticated probe inbound, even after the VPN is usable.
class GfpRouteScanner {
  const GfpRouteScanner({this.concurrency = 2, this.targetRoutes = 5});
  final int concurrency;
  final int targetRoutes;

  Future<void> scan({
    required GfpProbeSession session,
    required List<String> candidates,
    required GfpProbeBudget budget,
    required GfpRouteProof verify,
    required Future<bool> Function(String tag) onFirstVerified,
    required void Function() onResultsChanged,
    required bool Function() shouldContinue,
  }) async {
    var index = 0;
    Future<bool>? selection;
    final attempts = <GfpProbeAttempt>{};
    bool canContinue() =>
        shouldContinue() && !session.cancelled && !budget.exhausted && session.validatedTags.length < targetRoutes;

    Future<void> worker() async {
      while (canContinue() && index < candidates.length) {
        final tag = candidates[index++];
        final remaining = budget.maximumDuration - budget.elapsed.elapsed;
        final attempt = GfpProbeAttempt(
          session,
          budget,
          timeout: remaining < const Duration(seconds: 30) ? remaining : const Duration(seconds: 30),
        );
        attempts.add(attempt);
        try {
          final valid = await verify(tag, attempt);
          attempt.check();
          if (!canContinue()) return;
          if (!valid) {
            session.rejectedTags.add(tag);
            onResultsChanged();
            continue;
          }
          session.validatedTags.add(tag);
          // Assign before awaiting: concurrent winners cannot select twice.
          selection ??= Future<bool>.sync(() => onFirstVerified(tag));
          if (!await selection!.catchError((_) => false)) {
            session.cancel();
            return;
          }
          if (!shouldContinue() || session.cancelled) return;
          session.locked = true;
          onResultsChanged();
        } catch (_) {
          if (canContinue()) {
            session.rejectedTags.add(tag);
            onResultsChanged();
          }
        } finally {
          attempt.close();
          attempts.remove(attempt);
        }
      }
    }

    try {
      await Future.wait(List.generate(concurrency, (_) => worker()));
    } finally {
      for (final attempt in attempts) {
        attempt.close();
      }
    }
  }
}
