import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:basic_utils/basic_utils.dart';
import 'package:hiddify/features/gfp/gfp_probe_session.dart';

// Ephemeral keys exist only in the test process; no private key is committed.
final _fixtureKeyPair = CryptoUtils.generateRSAKeyPair();
final _fixturePrivateKey = _fixtureKeyPair.privateKey as RSAPrivateKey;
final _fixturePublicKey = _fixtureKeyPair.publicKey as RSAPublicKey;
final fixtureCertificate = X509Utils.generateSelfSignedCertificate(
  _fixturePrivateKey,
  X509Utils.generateRsaCsrPem({'CN': 'localhost'}, _fixturePrivateKey, _fixturePublicKey),
  30,
  sans: ['localhost', 'one.test', 'two.test', 'three.test'],
  notBefore: DateTime.now().toUtc().subtract(const Duration(days: 1)),
);
final fixtureKey = CryptoUtils.encodeRSAPrivateKeyToPem(_fixturePrivateKey);

SecurityContext fixtureServerContext() => SecurityContext()
  ..useCertificateChainBytes(utf8.encode(fixtureCertificate))
  ..usePrivateKeyBytes(utf8.encode(fixtureKey));

HttpClient fixtureClient() =>
    HttpClient(context: SecurityContext()..setTrustedCertificatesBytes(utf8.encode(fixtureCertificate)));

GfpProbeSession fixtureSession(int port, {List<String> tags = const ['route']}) =>
    GfpProbeSession(port: port, password: 'fixture-password', users: {for (final tag in tags) tag: tag}, config: {});

class LoopbackProxy {
  LoopbackProxy._(this.server, this.authenticate) {
    _serverSubscription = server.listen(_handle);
  }
  final ServerSocket server;
  final bool authenticate;
  final sockets = <Socket>{};
  final seenUsers = <String>[];
  StreamSubscription<Socket>? _serverSubscription;
  int connects = 0;

  static Future<LoopbackProxy> start({bool authenticate = true}) async {
    return LoopbackProxy._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0), authenticate);
  }

  void _handle(Socket local) {
    sockets.add(local);
    final pending = <int>[];
    Socket? remote;
    var ready = false;
    late StreamSubscription<List<int>> subscription;
    subscription = local.listen(
      (chunk) {
        if (ready) {
          remote!.add(chunk);
          return;
        }
        pending.addAll(chunk);
        final text = latin1.decode(pending);
        final end = text.indexOf('\r\n\r\n');
        if (end < 0) {
          if (pending.length > 16384) local.destroy();
          return;
        }
        subscription.pause();
        unawaited(() async {
          try {
            final lines = text.substring(0, end).split('\r\n');
            final authorization = lines
                .where((line) => line.toLowerCase().startsWith('proxy-authorization:'))
                .map((line) => line.substring(line.indexOf(':') + 1).trim())
                .firstOrNull;
            final expected = 'Basic ${base64Encode(utf8.encode('route:fixture-password'))}';
            if (authenticate && authorization != expected) {
              local.write(
                'HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm="fixture"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n',
              );
              await local.close();
              return;
            }
            if (authorization != null) {
              seenUsers.add(utf8.decode(base64Decode(authorization.split(' ').last)).split(':').first);
            }
            final first = lines.first.split(' ');
            if (first.first != 'CONNECT') {
              local.destroy();
              return;
            }
            final authority = first[1];
            final port = int.parse(authority.substring(authority.lastIndexOf(':') + 1));
            remote = await Socket.connect(InternetAddress.loopbackIPv4, port);
            sockets.add(remote!);
            connects++;
            local.write('HTTP/1.1 200 Connection Established\r\n\r\n');
            ready = true;
            if (pending.length > end + 4) remote!.add(pending.sublist(end + 4));
            remote!.listen(
              local.add,
              onDone: () => unawaited(local.flush().then((_) => local.close()).catchError((_) => local)),
              onError: (_) => local.destroy(),
            );
            subscription.resume();
          } catch (_) {
            remote?.destroy();
            local.destroy();
          }
        }());
      },
      onDone: () {
        remote?.destroy();
        unawaited(subscription.cancel());
      },
      onError: (_) => remote?.destroy(),
    );
  }

  Future<void> close() async {
    for (final socket in sockets) {
      socket.destroy();
    }
    await _serverSubscription?.cancel();
    await server.close();
  }
}
