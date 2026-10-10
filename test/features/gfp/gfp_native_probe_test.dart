import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/gfp/gfp_dns_probe.dart';
import 'package:hiddify/features/gfp/gfp_payload_probe.dart';
import 'package:hiddify/features/gfp/gfp_probe_session.dart';

import 'probe_test_support.dart';

void main() {
  final executable = File('hiddify-core/bin/${Platform.isWindows ? 'HiddifyCli.exe' : 'HiddifyCli'}').absolute;
  test(
    'bundled core forces authenticated proofs to their candidate without changing the live selector',
    () async {
      final directory = await Directory.systemTemp.createTemp('sod-native-probe-');
      final upstream = await LoopbackProxy.start(authenticate: false);
      final bytes = Uint8List.fromList(List.generate(GfpPayloadProbe.minimumBytes, (index) => index % 251));
      final origin = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, fixtureServerContext());
      origin.listen((request) async {
        request.response.add(bytes);
        await request.response.close();
      });
      final dnsServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final dnsSockets = <Socket>[];
      dnsServer.listen((socket) {
        dnsSockets.add(socket);
        final pending = <int>[];
        socket.listen((chunk) {
          pending.addAll(chunk);
          if (pending.length < 2 || pending.length < 2 + pending[0] * 256 + pending[1]) return;
          final query = pending.sublist(2, 2 + pending[0] * 256 + pending[1]);
          final answer = [...query]
            ..[2] = 0x81
            ..[3] = 0x80
            ..[7] = 1;
          answer.addAll([0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 192, 0, 2, 1]);
          socket.add([answer.length >> 8, answer.length & 255, ...answer]);
          pending.clear();
        });
      });
      final mainPort = await GfpProbeSession.availablePort();
      final apiPort = await GfpProbeSession.availablePort();
      final probePort = await GfpProbeSession.availablePort();
      final session = GfpProbeSession.fromBuiltConfig({
        'log': {'level': 'debug'},
        'inbounds': [
          {'type': 'mixed', 'tag': 'main', 'listen': '127.0.0.1', 'listen_port': mainPort},
        ],
        'outbounds': [
          {
            'type': 'selector',
            'tag': 'select',
            'outbounds': ['bad', 'good'],
            'default': 'bad',
          },
          {'type': 'http', 'tag': 'good', 'server': '127.0.0.1', 'server_port': upstream.server.port},
          {'type': 'http', 'tag': 'bad', 'server': '127.0.0.1', 'server_port': 1},
          {'type': 'direct', 'tag': 'direct'},
        ],
        // Deliberately working DIRECT fallback: a broken candidate must still
        // fail its proof even though the normal inbound can reach the origin.
        'route': {'final': 'direct', 'rules': []},
        'experimental': {
          'monitoring': {
            'urls': ['http://127.0.0.1:1'],
            'interval': '1h',
          },
          'clash_api': {'external_controller': '127.0.0.1:$apiPort', 'secret': 'fixture-only'},
        },
      }, port: probePort);
      final configuration = File('${directory.path}/probe.json');
      await configuration.writeAsString(jsonEncode(session.config));
      Process? process;
      GfpProbeAttempt? attempt;
      final diagnostics = StringBuffer();
      try {
        process = await Process.start(executable.path, ['srun', '-c', configuration.path, '-D', directory.path]);
        process.stdout.transform(utf8.decoder).listen(diagnostics.write);
        process.stderr.transform(utf8.decoder).listen(diagnostics.write);
        var ready = false;
        for (var index = 0; index < 50; index++) {
          try {
            final socket = await Socket.connect(
              InternetAddress.loopbackIPv4,
              probePort,
              timeout: const Duration(milliseconds: 100),
            );
            socket.destroy();
            ready = true;
            break;
          } catch (_) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }
        expect(ready, isTrue, reason: diagnostics.toString());
        final payload = GfpPayloadProbe(clientFactory: fixtureClient);
        final endpoint = GfpProbeEndpoint(
          'https://localhost:${origin.port}/good',
          prefixSha256: sha256.convert(bytes).toString(),
        );
        attempt = GfpProbeAttempt(session, GfpProbeBudget());
        expect(await payload.download(attempt, 'bad', endpoint), isFalse);
        expect(
          await payload.download(attempt, 'good', endpoint),
          isTrue,
          reason: '$diagnostics\nupstream connects: ${upstream.connects}',
        );
        expect(
          await GfpDnsProbe(
            'tcp://127.0.0.1:${dnsServer.port}',
            onFailure: diagnostics.writeln,
          ).verify(attempt, 'good', payload),
          isTrue,
          reason: '$diagnostics\nupstream connects: ${upstream.connects}',
        );
        expect(await GfpDnsProbe('tcp://127.0.0.1:${dnsServer.port}').verify(attempt, 'bad', payload), isFalse);

        final api = HttpClient();
        try {
          final request = await api.getUrl(Uri.parse('http://127.0.0.1:$apiPort/proxies/select'));
          request.headers.set(HttpHeaders.authorizationHeader, 'Bearer fixture-only');
          final selected = jsonDecode(await utf8.decoder.bind(await request.close()).join()) as Map;
          expect(selected['now'], 'bad');
        } finally {
          api.close(force: true);
        }
        expect(upstream.connects, greaterThanOrEqualTo(2));
      } finally {
        attempt?.close();
        session.cancel();
        process?.kill();
        if (process != null) await process.exitCode.timeout(const Duration(seconds: 5));
        await upstream.close();
        await origin.close(force: true);
        for (final socket in dnsSockets) {
          socket.destroy();
        }
        await dnsServer.close();
        await directory.delete(recursive: true);
      }
    },
    skip: !executable.existsSync() ? 'Bundled CLI unavailable on this test host' : false,
  );
}
