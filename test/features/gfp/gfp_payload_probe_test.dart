import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/gfp/gfp_payload_probe.dart';

import 'probe_test_support.dart';

void main() {
  late HttpServer origin;
  late LoopbackProxy proxy;
  late GfpProbeAttempt attempt;
  final bytes = Uint8List.fromList(List.generate(GfpPayloadProbe.minimumBytes, (index) => index % 251));
  final hash = sha256.convert(bytes).toString();
  final nonces = <String>[];
  final originCredentials = <String?>[];
  var uploaded = 0;

  setUp(() async {
    nonces.clear();
    originCredentials.clear();
    uploaded = 0;
    origin = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, fixtureServerContext());
    origin.listen((request) async {
      try {
        nonces.add(request.uri.queryParameters['_sod_probe'] ?? '');
        originCredentials.add(request.headers.value(HttpHeaders.proxyAuthorizationHeader));
        request.response.headers.contentType = ContentType.binary;
        switch (request.uri.path) {
          case '/good':
            request.response.add(bytes);
          case '/html':
            request.response.headers.contentType = ContentType.html;
            request.response.add(List.filled(bytes.length, 65));
          case '/short-chunked':
            for (var index = 0; index < 40; index++) {
              request.response.add(bytes.sublist(0, 1024));
              await request.response.flush();
            }
          case '/trickle':
            for (var index = 0; index < 100; index++) {
              request.response.add(bytes.sublist(0, 1024));
              await request.response.flush();
              await Future<void>.delayed(const Duration(milliseconds: 30));
            }
          case '/echo':
            final content = await utf8.decoder.bind(request).join();
            uploaded += content.length;
            request.response.write(jsonEncode({'data': content}));
          case '/wrong-echo':
            await request.drain<void>();
            request.response.write(jsonEncode({'data': 'wrong'}));
          case '/redirect':
            request.response.statusCode = HttpStatus.found;
            request.response.headers.set(HttpHeaders.locationHeader, '/good');
          default:
            request.response.statusCode = HttpStatus.serviceUnavailable;
        }
        await request.response.close();
      } catch (_) {}
    });
    proxy = await LoopbackProxy.start();
    attempt = GfpProbeAttempt(fixtureSession(proxy.server.port), GfpProbeBudget());
  });

  tearDown(() async {
    attempt.close();
    await proxy.close();
    await origin.close(force: true);
  });

  String url(String path, [String host = 'one.test']) => 'https://$host:${origin.port}/$path';
  GfpPayloadProbe probe({List<GfpProbeEndpoint> endpoints = const []}) => GfpPayloadProbe(
    endpoints: endpoints,
    clientFactory: fixtureClient,
    continuityInterval: Duration.zero,
    echoUrl: url('echo'),
    uploadFallbackUrl: url('unavailable'),
  );

  test('accepts the expected decoded bytes through an authenticated HTTPS tunnel', () async {
    expect(await probe().download(attempt, 'route', GfpProbeEndpoint(url('good'), prefixSha256: hash)), isTrue);
    expect(proxy.seenUsers, contains('route'));
    expect(nonces.single, isNotEmpty);
    expect(originCredentials, [null]);
  });

  test('rejects an oversized portal page despite HTTP 200', () async {
    expect(await probe().download(attempt, 'route', GfpProbeEndpoint(url('html'), prefixSha256: hash)), isFalse);
  });

  test('rejects a transfer that stops after 40 KiB, including chunk framing', () async {
    expect(
      await probe().download(attempt, 'route', GfpProbeEndpoint(url('short-chunked'), prefixSha256: hash)),
      isFalse,
    );
  });

  test('rejects an untrusted TLS certificate', () async {
    expect(
      await GfpPayloadProbe().download(attempt, 'route', GfpProbeEndpoint(url('good'), prefixSha256: hash)),
      isFalse,
    );
  });

  test('rejects redirects instead of following them to a working destination', () async {
    expect(await probe().download(attempt, 'route', GfpProbeEndpoint(url('redirect'), prefixSha256: hash)), isFalse);
  });

  test('refuses cleartext HTTP even when a correct body is available', () async {
    final endpoint = GfpProbeEndpoint(url('good').replaceFirst('https:', 'http:'), prefixSha256: hash);
    expect(await probe().download(attempt, 'route', endpoint), isFalse);
    expect(proxy.connects, 0);
  });

  test('requires two hosts, fresh nonces, and separate connections', () async {
    final endpoints = [
      GfpProbeEndpoint(url('unavailable'), prefixSha256: hash),
      GfpProbeEndpoint(url('good', 'two.test'), prefixSha256: hash),
      GfpProbeEndpoint(url('good', 'three.test'), prefixSha256: hash),
    ];
    expect(await probe(endpoints: endpoints).verifyDownloads(attempt, 'route'), isTrue);
    expect(proxy.connects, 3);
    expect(nonces.toSet(), hasLength(3));
  });

  test('two paths on the same host do not count as two destinations', () async {
    final endpoint = GfpProbeEndpoint(url('good'), prefixSha256: hash);
    expect(await probe(endpoints: [endpoint, endpoint]).verifyDownloads(attempt, 'route'), isFalse);
  });

  test('checks an actual 16 KiB upload and its echo', () async {
    expect(await probe().verifyUpload(attempt, 'route'), isTrue);
    expect(uploaded, 16 * 1024);
  });

  test('rejects a wrong upload echo and failed fallback', () async {
    final payload = GfpPayloadProbe(
      clientFactory: fixtureClient,
      echoUrl: url('wrong-echo'),
      uploadFallbackUrl: url('unavailable'),
    );
    expect(await payload.verifyUpload(attempt, 'route'), isFalse);
  });

  test('a hard deadline stops trickle traffic that never reaches the idle timeout', () async {
    attempt.close();
    attempt = GfpProbeAttempt(
      fixtureSession(proxy.server.port),
      GfpProbeBudget(),
      timeout: const Duration(milliseconds: 150),
    );
    final elapsed = Stopwatch()..start();
    expect(await probe().download(attempt, 'route', GfpProbeEndpoint(url('trickle'), prefixSha256: hash)), isFalse);
    expect(elapsed.elapsed, lessThan(const Duration(seconds: 2)));
    expect(attempt.closed, isTrue);
  });

  test('a shared data budget closes the request instead of accepting partial data', () async {
    attempt.close();
    attempt = GfpProbeAttempt(fixtureSession(proxy.server.port), GfpProbeBudget(maximumBytes: 32 * 1024));
    expect(await probe().download(attempt, 'route', GfpProbeEndpoint(url('good'), prefixSha256: hash)), isFalse);
    expect(attempt.budget.exhausted, isTrue);
  });

  test('cancelling a session closes an in-flight transfer', () async {
    final transfer = probe().download(attempt, 'route', GfpProbeEndpoint(url('trickle'), prefixSha256: hash));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    attempt.session.cancel();
    expect(await transfer, isFalse);
    expect(attempt.closed, isTrue);
  });
}
