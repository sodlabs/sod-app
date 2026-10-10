import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:hiddify/features/gfp/gfp_probe_session.dart';
import 'package:hiddify/features/gfp/gfp_proxy_service.dart';
import 'package:hiddify/features/gfp/gfp_sustained_proxy_validator.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service_provider.dart';
import 'package:hiddify/singbox/model/core_status.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

final gfpHealthStatusProvider = NotifierProvider<GfpHealthStatus, String>(GfpHealthStatus.new);

// null = a personal profile; an empty set = no fresh proof on this connection.
// Latency-only candidates never acquire a green availability indicator.
final gfpVerifiedTagsProvider = NotifierProvider<GfpVerifiedTags, Set<String>?>(GfpVerifiedTags.new);

class GfpVerifiedTags extends Notifier<Set<String>?> {
  @override
  Set<String>? build() => null;

  void update(Set<String>? tags) {
    if (setEquals(state, tags)) return;
    state = tags == null ? null : Set.unmodifiable(tags);
  }
}

class GfpHealthStatus extends Notifier<String> {
  @override
  String build() => 'idle';

  void update(String nextValue) {
    if (state == nextValue) return;
    state = nextValue;
  }
}

final gfpHealthMonitorProvider = Provider<GfpHealthMonitor>((ref) {
  final monitor = GfpHealthMonitor(ref)..start();
  ref.onDispose(monitor.stop);
  return monitor;
});

class GfpHealthMonitor {
  GfpHealthMonitor(this.ref);

  final Ref ref;
  StreamSubscription<CoreStatus>? _subscription;
  StreamSubscription<List<ConnectivityResult>>? _networkSubscription;
  String? _network;
  GfpProbeSession? _session;
  var _generation = 0;

  void start() {
    final core = ref.read(hiddifyCoreServiceProvider);
    _subscription = core.statusController.stream.listen((coreStatus) {
      if (coreStatus is CoreStarting) {
        _generation++;
        _session?.cancel();
        _session = null;
        final profile = ref.read(activeProfileProvider).asData?.value;
        final isPublic = profile != null && isGfpProfileName(_profileName(profile));
        ref.read(gfpVerifiedTagsProvider.notifier).update(isPublic ? {} : null);
        _setStatus(isPublic ? 'checking real local transfer' : 'idle');
        return;
      }
      if (coreStatus is CoreStarted && _session != null && identical(_session, core.gfpProbeSession)) return;
      _generation++;
      _session?.cancel();
      _session = coreStatus is CoreStarted ? core.gfpProbeSession : null;
      if (coreStatus is! CoreStarted) {
        ref.read(gfpVerifiedTagsProvider.notifier).update(null);
        _setStatus('idle');
        return;
      }
      if (_session != null) ref.read(gfpVerifiedTagsProvider.notifier).update({});
      final runGeneration = _generation;
      unawaited(_findAndMonitorRoute(shouldContinue: () => _generation == runGeneration));
    });
    _networkSubscription = Connectivity().onConnectivityChanged.listen((networks) {
      final network = _networkKey(networks);
      if (_network != null && _network != network && _session != null) {
        // A proof on Wi-Fi is not a proof on mobile data. Invalidate results,
        // but leave the active selector and tunnel completely untouched.
        _generation++;
        _session?.cancel();
        ref.read(gfpVerifiedTagsProvider.notifier).update({});
        _setStatus('no locally verified route');
      }
      _network = network;
    });
  }

  void stop() {
    _generation++;
    _session?.cancel();
    unawaited(_subscription?.cancel());
    unawaited(_networkSubscription?.cancel());
  }

  Future<void> _findAndMonitorRoute({required bool Function() shouldContinue}) async {
    final activeProfile = await ref.read(activeProfileProvider.future);
    if (!shouldContinue() || activeProfile == null) return;
    if (!isGfpProfileName(_profileName(activeProfile))) {
      ref.read(gfpVerifiedTagsProvider.notifier).update(null);
      return;
    }

    try {
      final core = ref.read(hiddifyCoreServiceProvider);
      final session = _session ?? await core.recoverGfpProbeSession();
      if (!shouldContinue()) return;
      _session = session;
      if (session == null) {
        ref.read(gfpVerifiedTagsProvider.notifier).update({});
        _setStatus('no locally verified route');
        return;
      }
      final networks = await Connectivity().checkConnectivity();
      _network = _networkKey(networks);
      if (!shouldContinue() || session.cancelled) return;
      _setStatus('checking real local transfer');
      var publishedReady = false;
      await const GfpSustainedProxyValidator().validateAndLock(
        core,
        session,
        remoteDnsAddress: session.remoteDnsAddress,
        onMobile: !networks.contains(ConnectivityResult.wifi) && !networks.contains(ConnectivityResult.ethernet),
        shouldContinue: shouldContinue,
        onResultsChanged: () {
          if (!shouldContinue() || session.cancelled) return;
          ref.read(gfpVerifiedTagsProvider.notifier).update(session.validatedTags);
          if (session.locked) {
            _setStatus('using locally verified route');
            if (!publishedReady) {
              publishedReady = true;
              // Publish logical readiness once without rebuilding/replacing
              // the native status listener for each candidate result.
              core.statusController.add(core.currentState);
            }
          }
        },
      );
      if (!shouldContinue()) return;
      if (!session.locked) {
        // This is still the initial "Connecting" attempt, never a ready VPN.
        // An existing/recovered or manually changed connection is preserved.
        if (!session.cancelled) await core.abortUnverifiedGfpStart(session);
        _setStatus('no locally verified route');
        return;
      }

      // La route est maintenant un outbound concret, pas le groupe round-robin.
      // Elle reste verrouillée jusqu'à une action explicite de l'utilisateur ou
      // au prochain démarrage du tunnel. Aucun basculement en arrière-plan.
      _setStatus('using locally verified route');
    } catch (error, stackTrace) {
      if (!shouldContinue()) return;
      debugPrint('sodlab local route validation error: $error\n$stackTrace');
      _setStatus('no locally verified route');
    }
  }

  void _setStatus(String value) => ref.read(gfpHealthStatusProvider.notifier).update(value);
}

String _profileName(ProfileEntity profile) =>
    profile.map(remote: (profile) => profile.name, local: (profile) => profile.name);

String _networkKey(List<ConnectivityResult> networks) =>
    (networks
            .where((value) => value != ConnectivityResult.vpn && value != ConnectivityResult.other)
            .map((value) => value.name)
            .toList()
          ..sort())
        .join(',');
