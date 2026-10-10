import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:hiddify/features/gfp/gfp_probe_session.dart';

class GfpProbeBudget {
  GfpProbeBudget({this.maximumBytes = 8 * 1024 * 1024, this.maximumDuration = const Duration(minutes: 2)});
  final int maximumBytes;
  final Duration maximumDuration;
  final elapsed = Stopwatch()..start();
  int transferredBytes = 0;
  bool get exhausted => transferredBytes >= maximumBytes || elapsed.elapsed >= maximumDuration;

  void consume(int bytes) {
    transferredBytes += bytes;
    if (exhausted) throw const GfpProbeStopped();
  }
}

class GfpProbeStopped implements Exception {
  const GfpProbeStopped();
}

class GfpProbeEndpoint {
  const GfpProbeEndpoint(this.url, {this.prefixSha256, this.exactLength});
  final String url;
  final String? prefixSha256;
  final int? exactLength;
}

/// One bounded, cancellable route attempt. Closing resources on timeout is
/// essential: Future.timeout alone leaves downloads running in the background.
class GfpProbeAttempt {
  GfpProbeAttempt(this.session, this.budget, {Duration timeout = const Duration(seconds: 30)}) {
    _removeCancel = session.onCancel(close);
    if (!closed) _timer = Timer(timeout, close);
  }
  final GfpProbeSession session;
  final GfpProbeBudget budget;
  bool closed = false;
  Timer? _timer;
  void Function()? _removeCancel;
  final _closers = <void Function()>{};

  void check() {
    if (closed || session.cancelled || budget.exhausted) throw const GfpProbeStopped();
  }

  void Function() track(void Function() closer) {
    check();
    _closers.add(closer);
    return () => _closers.remove(closer);
  }

  void close() {
    if (closed) return;
    closed = true;
    _timer?.cancel();
    _removeCancel?.call();
    for (final closer in _closers.toList()) {
      closer();
    }
    _closers.clear();
  }
}

class GfpPayloadProbe {
  GfpPayloadProbe({
    this.endpoints = defaultEndpoints,
    this.continuityInterval = const Duration(seconds: 2),
    this.echoUrl = 'https://httpbin.org/post',
    this.uploadFallbackUrl = 'https://speed.cloudflare.com/__up?bytes=16384',
    HttpClient Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? HttpClient.new;

  static const minimumBytes = 128 * 1024;
  // GitHub is pinned to a commit, not a moving branch. OVH is an independent
  // fallback; a changed file fails its hash and can never validate a route.
  static const defaultEndpoints = [
    GfpProbeEndpoint('https://speed.cloudflare.com/__down?bytes=131072', exactLength: minimumBytes),
    GfpProbeEndpoint(
      'https://raw.githubusercontent.com/SagerNet/sing-geosite/9fa8691dd58baad5ba53575f192313c33ec81444/geosite-geolocation-!cn.srs',
      prefixSha256: 'e18a1af11ede9bc02975e2ac241f4a84de803e107c9988c799e6b05488dc48b6',
    ),
    GfpProbeEndpoint(
      'https://proof.ovh.net/files/1Mb.dat',
      prefixSha256: 'fa43239bcee7b97ca62f007cc68487560a39e19f74f3dde7486db3f98df8e471',
    ),
  ];
  final List<GfpProbeEndpoint> endpoints;
  final Duration continuityInterval;
  final String echoUrl;
  final String uploadFallbackUrl;
  final HttpClient Function() _clientFactory;

  HttpClient _client(GfpProbeAttempt attempt, String tag) {
    attempt.check();
    final user = attempt.session.users[tag];
    if (user == null) throw const GfpProbeStopped();
    final client = _clientFactory()
      ..connectionTimeout = const Duration(seconds: 5)
      ..autoUncompress = false
      ..userAgent = 'Mozilla/5.0'
      // A single authenticated local proxy, with no DIRECT fallback. Dart
      // applies these credentials to HTTPS CONNECT as well as HTTP requests.
      ..findProxy = (_) => 'PROXY $user:${attempt.session.password}@127.0.0.1:${attempt.session.port}';
    return client;
  }

  Uri _freshUri(String value) {
    final uri = Uri.parse(value);
    if (uri.scheme != 'https') throw const FormatException('Route proofs require HTTPS');
    return uri.replace(
      queryParameters: {
        ...uri.queryParameters,
        '_sod_probe': base64UrlEncode(List.generate(12, (_) => Random.secure().nextInt(256))),
      },
    );
  }

  Future<bool> download(GfpProbeAttempt attempt, String tag, GfpProbeEndpoint endpoint) async {
    final client = _client(attempt, tag);
    final untrack = attempt.track(() => client.close(force: true));
    try {
      final request = await client.getUrl(_freshUri(endpoint.url)).timeout(const Duration(seconds: 7));
      // CONNECT has already authenticated with the loopback channel. Dart also
      // copies proxy credentials onto the origin request; remove that copy.
      request.headers.removeAll(HttpHeaders.proxyAuthorizationHeader);
      request.followRedirects = false;
      request.persistentConnection = false;
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache, no-store');
      if (endpoint.prefixSha256 != null) request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-${minimumBytes - 1}');
      final response = await request.close().timeout(const Duration(seconds: 7));
      if (response.statusCode != HttpStatus.ok && response.statusCode != HttpStatus.partialContent) return false;
      if (endpoint.exactLength != null && response.contentLength != endpoint.exactLength) return false;
      if (response.statusCode == HttpStatus.partialContent &&
          !(response.headers.value(HttpHeaders.contentRangeHeader) ?? '').startsWith('bytes 0-')) {
        return false;
      }
      final type = response.headers.contentType?.mimeType ?? '';
      if (endpoint.prefixSha256 == null && type != 'application/octet-stream') return false;
      final prefix = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 5))) {
        attempt.check();
        attempt.budget.consume(chunk.length);
        final remaining = minimumBytes - prefix.length;
        prefix.add(chunk.length <= remaining ? chunk : chunk.sublist(0, remaining));
        if (prefix.length == minimumBytes) {
          return endpoint.prefixSha256 == null ||
              sha256.convert(prefix.takeBytes()).toString() == endpoint.prefixSha256;
        }
      }
      return false;
    } catch (_) {
      return false;
    } finally {
      untrack();
      client.close(force: true);
    }
  }

  Future<bool> verifyDownloads(GfpProbeAttempt attempt, String tag) async {
    final successfulHosts = <String>{};
    for (final endpoint in endpoints) {
      attempt.check();
      final host = Uri.parse(endpoint.url).host;
      if (successfulHosts.contains(host)) continue;
      if (successfulHosts.isNotEmpty) {
        await Future<void>.delayed(continuityInterval);
        attempt.check();
      }
      if (await download(attempt, tag, endpoint)) successfulHosts.add(host);
      if (successfulHosts.length == 2) return true;
    }
    return false;
  }

  Future<List<int>?> requestBytes(
    GfpProbeAttempt attempt,
    String tag,
    String url, {
    List<int>? body,
    String contentType = 'application/octet-stream',
    int maximumResponseBytes = 64 * 1024,
  }) async {
    final client = _client(attempt, tag);
    final untrack = attempt.track(() => client.close(force: true));
    try {
      final request = await client
          .openUrl(body == null ? 'GET' : 'POST', _freshUri(url))
          .timeout(const Duration(seconds: 5));
      request.headers.removeAll(HttpHeaders.proxyAuthorizationHeader);
      request.followRedirects = false;
      request.persistentConnection = false;
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      request.headers.set(HttpHeaders.contentTypeHeader, contentType);
      if (body != null) {
        attempt.budget.consume(body.length);
        request.contentLength = body.length;
        request.add(body);
      }
      final response = await request.close().timeout(const Duration(seconds: 5));
      if (response.statusCode != HttpStatus.ok) return null;
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 5))) {
        attempt.check();
        attempt.budget.consume(chunk.length);
        if (bytes.length + chunk.length > maximumResponseBytes) return null;
        bytes.add(chunk);
      }
      return bytes.takeBytes();
    } catch (_) {
      return null;
    } finally {
      untrack();
      client.close(force: true);
    }
  }

  Future<bool> verifyUpload(GfpProbeAttempt attempt, String tag) async {
    final nonce = base64UrlEncode(List.generate(24, (_) => Random.secure().nextInt(256)));
    final payload = '$nonce${'0' * (16 * 1024 - nonce.length)}';
    final response = await requestBytes(attempt, tag, echoUrl, body: utf8.encode(payload), contentType: 'text/plain');
    if (response != null) {
      try {
        if ((jsonDecode(utf8.decode(response)) as Map)['data'] == payload) return true;
      } catch (_) {}
    }
    // Cloudflare's upload endpoint is independent of the echo service. A
    // successful authenticated TLS response confirms completion of the POST.
    final fallback = await requestBytes(
      attempt,
      tag,
      uploadFallbackUrl,
      body: utf8.encode(payload),
      maximumResponseBytes: 1024,
    );
    return fallback != null && fallback.isEmpty;
  }
}
