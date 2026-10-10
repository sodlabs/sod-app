import 'dart:async';
import 'dart:io';

import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/features/gfp/gfp_dns_probe.dart';
import 'package:hiddify/features/gfp/gfp_payload_probe.dart';
import 'package:hiddify/features/gfp/gfp_probe_session.dart';
import 'package:hiddify/features/gfp/gfp_route_scanner.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcommon/common.pb.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service.dart';

class GfpSustainedProxyValidator {
  const GfpSustainedProxyValidator();

  Future<void> validateAndLock(
    HiddifyCoreService core,
    GfpProbeSession session, {
    required String remoteDnsAddress,
    required bool onMobile,
    required bool Function() shouldContinue,
    required void Function() onResultsChanged,
  }) async {
    if (!await _waitForProxy(session, shouldContinue)) return;
    final selector = await _waitForSelector(core, session, shouldContinue);
    if (selector == null) return;
    final initialSelection = selector.selected;
    session.initialSelection = initialSelection;
    if (session.observeOnly && !session.users.containsKey(initialSelection)) return;
    final ordered = selector.items.where((item) => session.users.containsKey(item.tag)).toList()
      ..sort((left, right) => _delay(left).compareTo(_delay(right)));
    final candidates = [
      // Re-test the last chosen concrete route first; cached latency is only
      // ordering information, never a fresh availability proof.
      if (session.users.containsKey(initialSelection)) initialSelection,
      ...ordered.map((item) => item.tag).where((tag) => tag != initialSelection),
      ...session.users.keys.where((tag) => tag != initialSelection && !ordered.any((item) => item.tag == tag)),
    ];
    final payload = GfpPayloadProbe();
    if (session.observeOnly) candidates.removeWhere((tag) => tag != initialSelection);
    final dns = GfpDnsProbe(remoteDnsAddress);
    final budget = GfpProbeBudget(
      maximumBytes: (onMobile ? 4 : 8) * 1024 * 1024,
      maximumDuration: Duration(seconds: onMobile ? 60 : 120),
    );
    await GfpRouteScanner(
      concurrency: session.observeOnly ? 1 : 2,
      targetRoutes: session.observeOnly ? 1 : (onMobile ? 3 : 5),
    ).scan(
      session: session,
      candidates: candidates,
      budget: budget,
      shouldContinue: shouldContinue,
      verify: (tag, attempt) async =>
          await payload.verifyDownloads(attempt, tag) &&
          await payload.verifyUpload(attempt, tag) &&
          await dns.verify(attempt, tag, payload),
      onFirstVerified: (tag) async {
        if (!shouldContinue() || session.cancelled || !identical(core.gfpProbeSession, session)) return false;
        final latest = await core.core.bgClient.outboundsInfo(Empty()).first.timeout(const Duration(seconds: 3));
        final current = latest.items.firstWhere((group) => group.tag == 'select');
        // Respect a user selection made during discovery.
        if (!shouldContinue() || session.cancelled || current.selected != initialSelection) return false;
        if (current.selected == tag) return true;
        if (session.observeOnly) return false;
        final result = await core.selectOutbound('select', tag).run().timeout(const Duration(seconds: 3));
        return shouldContinue() && !session.cancelled && result.match((_) => false, (_) => true);
      },
      onResultsChanged: onResultsChanged,
    );
  }

  int _delay(OutboundInfo item) => ConnectionConst.isValidDelay(item.urlTestDelay) ? item.urlTestDelay : 1 << 30;

  Future<OutboundGroup?> _waitForSelector(
    HiddifyCoreService core,
    GfpProbeSession session,
    bool Function() shouldContinue,
  ) async {
    final elapsed = Stopwatch()..start();
    while (shouldContinue() && !session.cancelled && elapsed.elapsed < const Duration(seconds: 12)) {
      final groups = await core.core.bgClient.outboundsInfo(Empty()).first.timeout(const Duration(seconds: 3));
      for (final group in groups.items) {
        if (group.tag == 'select' && group.items.isNotEmpty) return group;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return null;
  }

  Future<bool> _waitForProxy(GfpProbeSession session, bool Function() shouldContinue) async {
    final elapsed = Stopwatch()..start();
    while (shouldContinue() && !session.cancelled && elapsed.elapsed < const Duration(seconds: 12)) {
      Socket? socket;
      try {
        socket = await Socket.connect(
          InternetAddress.loopbackIPv4,
          session.port,
          timeout: const Duration(milliseconds: 500),
        );
        return true;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      } finally {
        socket?.destroy();
      }
    }
    return false;
  }
}
