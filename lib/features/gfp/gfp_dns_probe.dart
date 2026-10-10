import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:hiddify/features/gfp/gfp_payload_probe.dart';

/// Exercise the configured DNS transport through the same forced candidate.
/// In particular, a TCP-only proxy must not pass when the VPN needs UDP DNS.
class GfpDnsProbe {
  const GfpDnsProbe(this.address, {this.onFailure});
  final String address;
  final void Function(String stage)? onFailure;

  Future<bool> verify(GfpProbeAttempt attempt, String tag, GfpPayloadProbe payload) async {
    try {
      attempt.check();
      if (address == 'local') return (await InternetAddress.lookup('example.com')).isNotEmpty;
      final uri = Uri.parse(address.contains('://') ? address : 'udp://$address');
      final id = Random.secure().nextInt(65536);
      final query = <int>[id >> 8, id & 255, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0];
      for (final part in 'example.com'.split('.')) {
        query.addAll([part.length, ...ascii.encode(part)]);
      }
      query.addAll([0, 0, 1, 0, 1]);
      if (uri.scheme == 'https') {
        final response = await payload.requestBytes(
          attempt,
          tag,
          uri.replace(fragment: '').toString(),
          body: query,
          contentType: 'application/dns-message',
          maximumResponseBytes: 4096,
        );
        return response != null && validResponse(query, response);
      }
      if (uri.scheme == 'tcp') return _tcp(attempt, tag, uri.host, uri.hasPort ? uri.port : 53, query);
      if (uri.scheme == 'udp') return _udp(attempt, tag, uri.host, uri.hasPort ? uri.port : 53, query);
      return false;
    } catch (error) {
      onFailure?.call('dns-${error.runtimeType}');
      return false;
    }
  }

  static bool validResponse(List<int> query, List<int> response) {
    if (query.length < 12 || response.length < query.length || response[0] != query[0] || response[1] != query[1]) {
      return false;
    }
    if (response[2] & 0x80 == 0 || response[2] & 0x02 != 0 || response[3] & 0x0f != 0) return false;
    if (response[4] != 0 || response[5] != 1 || (response[6] == 0 && response[7] == 0)) return false;
    for (var index = 12; index < query.length; index++) {
      if (response[index] != query[index]) return false;
    }
    final answers = response[6] * 256 + response[7];
    if (answers > 64) return false;
    var offset = query.length;
    var hasAddress = false;
    for (var index = 0; index < answers; index++) {
      offset = _skipName(response, offset);
      if (offset < 0 || offset + 10 > response.length) return false;
      final type = response[offset] * 256 + response[offset + 1];
      final dnsClass = response[offset + 2] * 256 + response[offset + 3];
      final length = response[offset + 8] * 256 + response[offset + 9];
      offset += 10;
      if (offset + length > response.length) return false;
      if (type == 1 && dnsClass == 1 && length == 4) hasAddress = true;
      offset += length;
    }
    // An ANCOUNT header alone is not a DNS answer. Require a complete A record.
    return hasAddress;
  }

  static int _skipName(List<int> message, int start) {
    var offset = start;
    for (var labels = 0; labels < 128 && offset < message.length; labels++) {
      final length = message[offset++];
      if (length == 0) return offset;
      if (length & 0xc0 == 0xc0) {
        if (offset >= message.length || ((length & 0x3f) * 256 + message[offset]) >= message.length) return -1;
        return offset + 1;
      }
      if (length > 63 || offset + length > message.length) return -1;
      offset += length;
    }
    return -1;
  }

  Future<bool> _tcp(GfpProbeAttempt attempt, String tag, String host, int port, List<int> query) async {
    Socket? socket;
    void Function()? untrack;
    try {
      socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        attempt.session.port,
        timeout: const Duration(seconds: 5),
      );
      untrack = attempt.track(socket.destroy);
      final reader = _SocketReader(socket, attempt);
      final authority = host.contains(':') ? '[$host]:$port' : '$host:$port';
      final auth = base64Encode(utf8.encode('${attempt.session.users[tag]}:${attempt.session.password}'));
      socket.write('CONNECT $authority HTTP/1.1\r\nHost: $authority\r\nProxy-Authorization: Basic $auth\r\n\r\n');
      await socket.flush();
      final headers = <int>[];
      while (headers.length < 16 * 1024) {
        headers.add((await reader.read(1)).single);
        if (headers.length >= 4 && ascii.decode(headers.sublist(headers.length - 4)) == '\r\n\r\n') break;
      }
      if (!RegExp(r'^HTTP/1\.[01] 200(?: |\r)').hasMatch(ascii.decode(headers, allowInvalid: true))) {
        onFailure?.call('dns-connect-status');
        return false;
      }
      socket.add([query.length >> 8, query.length & 255, ...query]);
      attempt.budget.consume(query.length);
      await socket.flush();
      final lengthBytes = await reader.read(2);
      final length = lengthBytes[0] * 256 + lengthBytes[1];
      if (length < 12 || length > 4096) {
        onFailure?.call('dns-message-length');
        return false;
      }
      final valid = validResponse(query, await reader.read(length));
      if (!valid) onFailure?.call('dns-message-invalid');
      return valid;
    } catch (error) {
      onFailure?.call('dns-tcp-${error.runtimeType}');
      return false;
    } finally {
      untrack?.call();
      socket?.destroy();
    }
  }

  Future<bool> _udp(GfpProbeAttempt attempt, String tag, String host, int port, List<int> query) async {
    Socket? control;
    RawDatagramSocket? udp;
    final untrack = <void Function()>[];
    try {
      udp = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      untrack.add(attempt.track(udp.close));
      control = await Socket.connect(
        InternetAddress.loopbackIPv4,
        attempt.session.port,
        timeout: const Duration(seconds: 5),
      );
      untrack.add(attempt.track(control.destroy));
      final reader = _SocketReader(control, attempt);
      control.add([5, 1, 2]);
      if (!_same(await reader.read(2), [5, 2])) return false;
      final username = utf8.encode(attempt.session.users[tag]!);
      final password = utf8.encode(attempt.session.password);
      control.add([1, username.length, ...username, password.length, ...password]);
      if (!_same(await reader.read(2), [1, 0])) return false;
      control.add([5, 3, 0, 1, 127, 0, 0, 1, udp.port >> 8, udp.port & 255]);
      final header = await reader.read(4);
      if (header[0] != 5 || header[1] != 0 || header[3] != 1) return false;
      final relayAddress = await reader.read(4);
      if (!_same(relayAddress, [0, 0, 0, 0]) && !_same(relayAddress, [127, 0, 0, 1])) return false;
      final relayBytes = await reader.read(2);
      final relayPort = relayBytes[0] * 256 + relayBytes[1];
      final ip = InternetAddress.tryParse(host);
      final destination = <int>[
        if (ip == null) ...[
          3,
          utf8.encode(host).length,
          ...utf8.encode(host),
        ] else ...[
          if (ip.type == InternetAddressType.IPv4) 1 else 4,
          ...ip.rawAddress,
        ],
      ];
      final packet = [0, 0, 0, ...destination, port >> 8, port & 255, ...query];
      attempt.budget.consume(packet.length);
      udp.send(packet, InternetAddress.loopbackIPv4, relayPort);
      await for (final event in udp.timeout(const Duration(seconds: 5))) {
        attempt.check();
        if (event != RawSocketEvent.read) continue;
        final received = udp.receive();
        if (received == null || received.port != relayPort || !received.address.isLoopback) continue;
        final data = received.data;
        attempt.budget.consume(data.length);
        if (data.length < 10 || data[0] != 0 || data[1] != 0 || data[2] != 0) return false;
        final offset = switch (data[3]) {
          1 => 10,
          4 => 22,
          3 => 7 + data[4],
          _ => data.length + 1,
        };
        if (offset > data.length) return false;
        return validResponse(query, data.sublist(offset));
      }
      return false;
    } catch (_) {
      return false;
    } finally {
      for (final remove in untrack) {
        remove();
      }
      udp?.close();
      control?.destroy();
    }
  }

  static bool _same(List<int> left, List<int> right) =>
      left.length == right.length && List.generate(left.length, (index) => left[index] == right[index]).every((v) => v);
}

class _SocketReader {
  _SocketReader(Socket socket, this.attempt) : _events = StreamIterator(socket);
  final StreamIterator<Uint8List> _events;
  final GfpProbeAttempt attempt;
  List<int> _pending = const [];
  int _offset = 0;

  Future<List<int>> read(int count) async {
    final result = <int>[];
    while (result.length < count) {
      attempt.check();
      if (_offset == _pending.length) {
        if (!await _events.moveNext().timeout(const Duration(seconds: 5))) throw const GfpProbeStopped();
        _pending = _events.current;
        _offset = 0;
        attempt.budget.consume(_pending.length);
      }
      final take = min(count - result.length, _pending.length - _offset);
      result.addAll(_pending.sublist(_offset, _offset + take));
      _offset += take;
    }
    return result;
  }
}
