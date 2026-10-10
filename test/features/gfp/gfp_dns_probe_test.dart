import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/gfp/gfp_dns_probe.dart';
import 'package:hiddify/features/gfp/gfp_payload_probe.dart';

import 'probe_test_support.dart';

List<int> answer(List<int> query) =>
    ([...query]
        ..[2] = 0x81
        ..[3] = 0x80
        ..[7] = 1)
      ..addAll([0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 192, 0, 2, 1]);

void main() {
  test('UDP DNS uses authenticated SOCKS association and validates the returned answer', () async {
    final relay = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <Socket>[];
    final credentials = <int>[];
    var packets = 0;
    server.listen((socket) {
      sockets.add(socket);
      final pending = <int>[];
      var stage = 0;
      socket.listen((chunk) {
        pending.addAll(chunk);
        if (stage == 0 && pending.length >= 3) {
          expect(pending.sublist(0, 3), [5, 1, 2]);
          pending.removeRange(0, 3);
          socket.add([5, 2]);
          stage++;
        }
        if (stage == 1 && pending.length >= 2) {
          final usernameLength = pending[1];
          if (pending.length < 3 + usernameLength) return;
          final passwordLength = pending[2 + usernameLength];
          final count = 3 + usernameLength + passwordLength;
          if (pending.length < count) return;
          credentials.addAll(pending.sublist(0, count));
          pending.removeRange(0, count);
          socket.add([1, 0]);
          stage++;
        }
        if (stage == 2 && pending.length >= 10) {
          expect(pending.sublist(0, 4), [5, 3, 0, 1]);
          socket.add([5, 0, 0, 1, 127, 0, 0, 1, relay.port >> 8, relay.port & 255]);
          stage++;
        }
      });
    });
    relay.listen((event) {
      if (event != RawSocketEvent.read) return;
      final packet = relay.receive();
      if (packet == null) return;
      packets++;
      expect(packet.data.sublist(0, 8), [0, 0, 0, 1, 127, 0, 0, 1]);
      relay.send([...packet.data.sublist(0, 10), ...answer(packet.data.sublist(10))], packet.address, packet.port);
    });
    final session = fixtureSession(server.port);
    final attempt = GfpProbeAttempt(session, GfpProbeBudget());
    try {
      expect(await const GfpDnsProbe('udp://127.0.0.1:5353').verify(attempt, 'route', GfpPayloadProbe()), isTrue);
      expect(credentials.sublist(2, 7), 'route'.codeUnits);
      expect(credentials.sublist(8), 'fixture-password'.codeUnits);
      expect(packets, 1);
    } finally {
      attempt.close();
      for (final socket in sockets) {
        socket.destroy();
      }
      relay.close();
      await server.close();
    }
  });

  test('DoH checks the wire answer through the candidate, not an HTML HTTP 200', () async {
    final proxy = await LoopbackProxy.start();
    final server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, fixtureServerContext());
    server.listen((request) async {
      expect(request.headers.value(HttpHeaders.proxyAuthorizationHeader), isNull);
      expect(request.headers.contentType?.mimeType, 'application/dns-message');
      final body = await request.expand((chunk) => chunk).toList();
      request.response.add(request.uri.path == '/dns-query' ? answer(body) : '<html>not DNS</html>'.codeUnits);
      await request.response.close();
    });
    final session = fixtureSession(proxy.server.port);
    final attempt = GfpProbeAttempt(session, GfpProbeBudget());
    final payload = GfpPayloadProbe(clientFactory: fixtureClient);
    try {
      expect(await GfpDnsProbe('https://localhost:${server.port}/dns-query').verify(attempt, 'route', payload), isTrue);
      expect(await GfpDnsProbe('https://localhost:${server.port}/html').verify(attempt, 'route', payload), isFalse);
      expect(proxy.seenUsers, ['route', 'route']);
    } finally {
      attempt.close();
      await server.close(force: true);
      await proxy.close();
    }
  });
}
