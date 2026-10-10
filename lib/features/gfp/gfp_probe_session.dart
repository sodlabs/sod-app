import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Credentials and results are local to one core start. They are never a
/// subscription, an account identifier, or a persisted proof of availability.
class GfpProbeSession {
  GfpProbeSession({
    required this.port,
    required this.password,
    required this.users,
    required this.config,
    this.remoteDnsAddress = 'tcp://8.8.8.8',
    this.observeOnly = false,
  });

  static const inboundTag = 'sod-validation-in';
  final int port;
  final String password;
  final Map<String, String> users;
  final Map<String, dynamic> config;
  final String remoteDnsAddress;
  final bool observeOnly;

  final validatedTags = <String>{};
  final rejectedTags = <String>{};
  bool locked = false;
  String? initialSelection;
  bool cancelled = false;
  final _onCancel = <void Function()>{};

  void Function() onCancel(void Function() callback) {
    if (cancelled) {
      callback();
      return () {};
    }
    _onCancel.add(callback);
    return () => _onCancel.remove(callback);
  }

  void cancel() {
    if (cancelled) return;
    cancelled = true;
    for (final callback in _onCancel.toList()) {
      callback();
    }
    _onCancel.clear();
  }

  /// Patch an already-built configuration, keeping native DNS, transport,
  /// chaining and custom routing options. Tests match before those rules.
  factory GfpProbeSession.fromBuiltConfig(
    Map<String, dynamic> built, {
    required int port,
    String remoteDnsAddress = 'tcp://8.8.8.8',
  }) {
    final config = (jsonDecode(jsonEncode(built)) as Map).cast<String, dynamic>();
    final outbounds = (config['outbounds'] as List).cast<Map>();
    final emptyDirectTags = outbounds
        .where(
          (outbound) => outbound['type'] == 'direct' && outbound.keys.every((key) => key == 'type' || key == 'tag'),
        )
        .map((outbound) => outbound['tag'])
        .toSet();
    final dnsServers = (((config['dns'] as Map?)?['servers'] as List?) ?? const []).cast<Map>();
    for (final server in dnsServers) {
      if (emptyDirectTags.contains(server['detour'])) server.remove('detour');
    }
    final selector = outbounds.firstWhere((outbound) => outbound['tag'] == 'select');
    final types = {for (final outbound in outbounds) outbound['tag']: outbound['type']};
    final endpoints = (config['endpoints'] as List?) ?? const [];
    for (final endpoint in endpoints.cast<Map>()) {
      types[endpoint['tag']] = endpoint['type'];
    }
    const groups = {'selector', 'urltest', 'balancer', 'direct', 'block', 'dns'};
    final tags = (selector['outbounds'] as List)
        .whereType<String>()
        .where((tag) => types.containsKey(tag) && !groups.contains(types[tag]) && !tag.contains('§hide§'))
        .toList();
    if (tags.isEmpty) throw const FormatException('No concrete public routes in the generated configuration');
    selector['interrupt_exist_connections'] = false;

    final random = Random.secure();
    final password = base64UrlEncode(List.generate(24, (_) => random.nextInt(256))).replaceAll('=', '');
    final users = {for (var index = 0; index < tags.length; index++) tags[index]: 'route-$index'};
    final inbounds = (config['inbounds'] as List?) ?? <dynamic>[];
    config['inbounds'] = [
      ...inbounds.where((inbound) => (inbound as Map)['tag'] != inboundTag),
      {
        'type': 'mixed',
        'tag': inboundTag,
        'listen': '127.0.0.1',
        'listen_port': port,
        'users': [
          for (final user in users.values) {'username': user, 'password': password},
        ],
      },
    ];
    final route = (config['route'] as Map).cast<String, dynamic>();
    route['rules'] = [
      for (final entry in users.entries)
        {
          'inbound': [inboundTag],
          'auth_user': [entry.value],
          'action': 'route',
          'outbound': entry.key,
        },
      // An unmatched probe must never fall through to direct or to the live
      // selector. A startup/configuration mismatch therefore fails closed.
      {
        'inbound': [inboundTag],
        'action': 'reject',
      },
      ...((route['rules'] as List?) ?? const []),
    ];
    return GfpProbeSession(
      port: port,
      password: password,
      users: users,
      config: config,
      remoteDnsAddress: remoteDnsAddress,
    );
  }

  static Future<int> availablePort() async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = listener.port;
    await listener.close();
    return port;
  }

  // Recover an already running channel without changing the tunnel.
  static GfpProbeSession? recover(Map<String, dynamic> config, {required String remoteDnsAddress}) {
    final inbounds = ((config['inbounds'] as List?) ?? const []).cast<Map>();
    final matches = inbounds.where((inbound) => inbound['tag'] == inboundTag);
    if (matches.length != 1) return null;
    final inbound = matches.single;
    if (inbound['listen'] != '127.0.0.1') return null;
    final accounts = ((inbound['users'] as List?) ?? const []).cast<Map>();
    if (accounts.isEmpty) return null;
    final password = accounts.first['password'] as String;
    if (accounts.any((account) => account['password'] != password)) return null;
    final names = accounts.map((account) => account['username']).toSet();
    final rules = (((config['route'] as Map?)?['rules'] as List?) ?? const []).cast<Map>();
    final users = <String, String>{};
    for (final rule in rules) {
      final auth = rule['auth_user'];
      if (rule['inbound'] is List &&
          (rule['inbound'] as List).contains(inboundTag) &&
          auth is List &&
          auth.length == 1 &&
          names.contains(auth.single) &&
          rule['outbound'] is String) {
        users[rule['outbound'] as String] = auth.single as String;
      }
    }
    if (users.isEmpty) return null;
    return GfpProbeSession(
      port: inbound['listen_port'] as int,
      password: password,
      users: users,
      config: config,
      remoteDnsAddress: remoteDnsAddress,
      observeOnly: true,
    );
  }
}
