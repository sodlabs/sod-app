import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/gfp/gfp_dns_probe.dart';
import 'package:hiddify/features/gfp/gfp_payload_probe.dart';
import 'package:hiddify/features/gfp/gfp_probe_session.dart';
import 'package:hiddify/features/gfp/gfp_route_scanner.dart';

import 'probe_test_support.dart';

void main() {
  test('concurrent winners select the live route exactly once', () async {
    final session = fixtureSession(1, tags: ['first', 'second', 'third']);
    final selections = <String>[];
    await const GfpRouteScanner(targetRoutes: 3, concurrency: 3).scan(
      session: session,
      candidates: session.users.keys.toList(),
      budget: GfpProbeBudget(),
      verify: (_, _) async => true,
      onFirstVerified: (tag) async {
        selections.add(tag);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return true;
      },
      onResultsChanged: () {},
      shouldContinue: () => true,
    );
    expect(session.validatedTags, hasLength(3));
    expect(session.locked, isTrue);
    expect(selections, hasLength(1));
  });

  test('continues beyond failed leading candidates to build a verified reserve', () async {
    final session = fixtureSession(1, tags: ['bad-1', 'bad-2', 'good-1', 'good-2']);
    await const GfpRouteScanner(targetRoutes: 2).scan(
      session: session,
      candidates: session.users.keys.toList(),
      budget: GfpProbeBudget(),
      verify: (tag, _) async => tag.startsWith('good'),
      onFirstVerified: (_) async => true,
      onResultsChanged: () {},
      shouldContinue: () => true,
    );
    expect(session.validatedTags, {'good-1', 'good-2'});
    expect(session.rejectedTags, {'bad-1', 'bad-2'});
  });

  test('disconnecting before a proof completes never selects a route', () async {
    final session = fixtureSession(1);
    final pending = Completer<bool>();
    var active = true;
    var selections = 0;
    final scan = const GfpRouteScanner().scan(
      session: session,
      candidates: ['route'],
      budget: GfpProbeBudget(),
      verify: (_, _) => pending.future,
      onFirstVerified: (_) async {
        selections++;
        return true;
      },
      onResultsChanged: () {},
      shouldContinue: () => active,
    );
    active = false;
    session.cancel();
    pending.complete(true);
    await scan;
    expect(selections, 0);
    expect(session.validatedTags, isEmpty);
  });

  test('a refused or failed commit never triggers another automatic selection', () async {
    for (final throws in [false, true]) {
      final session = fixtureSession(1, tags: ['one', 'two']);
      var selections = 0;
      await const GfpRouteScanner().scan(
        session: session,
        candidates: session.users.keys.toList(),
        budget: GfpProbeBudget(),
        verify: (_, _) async => true,
        onFirstVerified: (_) async {
          selections++;
          if (throws) throw StateError('changed');
          return false;
        },
        onResultsChanged: () {},
        shouldContinue: () => true,
      );
      expect(selections, 1);
      expect(session.locked, isFalse);
      expect(session.cancelled, isTrue);
    }
  });

  test('session cancellation closes all active probe resources', () {
    final session = fixtureSession(1);
    final attempt = GfpProbeAttempt(session, GfpProbeBudget());
    var closed = 0;
    attempt.track(() => closed++);
    session.cancel();
    session.cancel();
    expect(closed, 1);
    expect(attempt.closed, isTrue);
  });

  test('a proof completing after its attempt closes can never validate a route', () async {
    final session = fixtureSession(1);
    var selections = 0;
    await const GfpRouteScanner().scan(
      session: session,
      candidates: ['route'],
      budget: GfpProbeBudget(),
      verify: (_, attempt) async {
        attempt.close();
        return true;
      },
      onFirstVerified: (_) async {
        selections++;
        return true;
      },
      onResultsChanged: () {},
      shouldContinue: () => true,
    );
    expect(session.validatedTags, isEmpty);
    expect(selections, 0);
  });

  test('probe routes precede bypass and DNS rules and fail closed', () {
    final original = <String, dynamic>{
      'inbounds': [
        {'type': 'mixed', 'tag': 'mixed-in', 'listen_port': 12334},
      ],
      'dns': {
        'servers': [
          {'type': 'tcp', 'tag': 'dns-remote', 'server': '8.8.8.8', 'detour': 'select'},
        ],
      },
      'outbounds': [
        {
          'type': 'selector',
          'tag': 'select',
          'outbounds': ['balance', 'good', 'bad'],
          'default': 'balance',
        },
        {
          'type': 'balancer',
          'tag': 'balance',
          'outbounds': ['good', 'bad'],
        },
        {'type': 'http', 'tag': 'good', 'server': '127.0.0.1', 'server_port': 8080},
        {'type': 'http', 'tag': 'bad', 'server': '127.0.0.1', 'server_port': 8081},
      ],
      'route': {
        'final': 'select',
        'rules': [
          {
            'domain': ['one.test'],
            'outbound': 'direct',
          },
        ],
      },
    };
    final session = GfpProbeSession.fromBuiltConfig(original, port: 23456);
    final rules = (session.config['route'] as Map)['rules'] as List;
    expect(session.users.keys, ['good', 'bad']);
    expect((rules.first as Map)['auth_user'], [session.users['good']]);
    expect((rules.first as Map)['outbound'], 'good');
    expect((rules[2] as Map)['action'], 'reject');
    expect((rules.last as Map)['domain'], ['one.test']);
    expect(session.config['dns'], original['dns']);
    expect(original['inbounds'] as List, hasLength(1));
    expect((original['route'] as Map)['rules'] as List, hasLength(1));
    final recovered = GfpProbeSession.recover(session.config, remoteDnsAddress: 'tcp://8.8.8.8')!;
    expect(recovered.observeOnly, isTrue);
    expect(recovered.port, session.port);
    expect(recovered.password, session.password);
    expect(recovered.users, session.users);
    expect(recovered.validatedTags, isEmpty);
    final inbound = (session.config['inbounds'] as List).cast<Map>().firstWhere(
      (inbound) => inbound['tag'] == GfpProbeSession.inboundTag,
    );
    for (final account in (inbound['users'] as List).cast<Map>()) {
      account['Password'] = account.remove('password');
      account['Username'] = account.remove('username');
    }
    // Reproduce the native dump's canonical scalar representation.
    for (final rule in rules.cast<Map>()) {
      if (rule['inbound'] is List && (rule['inbound'] as List).length == 1) {
        rule['inbound'] = (rule['inbound'] as List).single;
      }
      if (rule['auth_user'] is List && (rule['auth_user'] as List).length == 1) {
        rule['auth_user'] = (rule['auth_user'] as List).single;
      }
    }
    final restored = GfpProbeSession.recover(session.config, remoteDnsAddress: 'tcp://8.8.8.8')!;
    expect(restored.observeOnly, isTrue);
    expect(restored.validatedTags, isEmpty);
    expect(restored.password, session.password);
    (inbound['users'] as List).cast<Map>().first.remove('Password');
    expect(GfpProbeSession.recover(session.config, remoteDnsAddress: 'tcp://8.8.8.8'), isNull);
  });

  test('DNS proof rejects a wrong transaction, truncated response, and NXDOMAIN', () {
    final query = [0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1, 97, 0, 0, 1, 0, 1];
    final good = [...query]
      ..[2] = 0x81
      ..[7] = 1;
    expect(GfpDnsProbe.validResponse(query, good), isFalse);
    good.addAll([0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 192, 0, 2, 1]);
    expect(GfpDnsProbe.validResponse(query, good), isTrue);
    expect(GfpDnsProbe.validResponse(query, good.sublist(0, good.length - 1)), isFalse);
    expect(GfpDnsProbe.validResponse(query, [...good]..[0] = 0), isFalse);
    expect(GfpDnsProbe.validResponse(query, [...good]..[2] = 0x83), isFalse);
    expect(GfpDnsProbe.validResponse(query, [...good]..[3] = 3), isFalse);
  });

  test('removes only redundant empty-direct DNS detours in a generated config', () {
    final session = GfpProbeSession.fromBuiltConfig({
      'outbounds': [
        {
          'type': 'selector',
          'tag': 'select',
          'outbounds': ['route'],
        },
        {'type': 'http', 'tag': 'route', 'server': '127.0.0.1', 'server_port': 1},
        {'type': 'direct', 'tag': 'empty-direct'},
        {'type': 'direct', 'tag': 'custom-direct', 'bind_interface': 'fixture'},
      ],
      'dns': {
        'servers': [
          {'tag': 'dns-remote', 'detour': 'select'},
          {'tag': 'dns-remote-no-warp', 'detour': 'empty-direct'},
          {'tag': 'custom-dns', 'detour': 'custom-direct'},
        ],
      },
      'route': {'rules': []},
    }, port: 23456);
    final servers = ((session.config['dns'] as Map)['servers'] as List).cast<Map>();
    expect(servers[0]['detour'], 'select');
    expect(servers[1].containsKey('detour'), isFalse);
    expect(servers[2]['detour'], 'custom-direct');
  });
}
