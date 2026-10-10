import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hiddify/features/gfp/gfp_proxy_models.dart';
import 'package:hiddify/features/gfp/gfp_proxy_parser.dart';
import 'package:hiddify/features/gfp/gfp_proxy_tester.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Utilisé pour retrouver le profil lors des mises à jour.
const String kGfpProfileTitle = 'Sod public network';
const Set<String> kGfpLegacyProfileTitles = {'sodlab (auto, non verifie)'};

bool isGfpProfileName(String name) => name == kGfpProfileTitle || kGfpLegacyProfileTitles.contains(name);

// Ne pas reprendre l'ancien cache, construit avec un filtre moins strict.
const _cacheKeyContent = 'gfp_subscription_content_v10';
const _cacheKeyTimestamp = 'gfp_subscription_timestamp_v10';

class GfpNoReachableProxyException implements Exception {
  const GfpNoReachableProxyException();

  @override
  String toString() => 'Aucun proxy joignable n’a été trouvé sur ce réseau.';
}

const Map<String, String> _sources = {
  'multi-protocol': 'https://raw.githubusercontent.com/mahdibland/V2RayAggregator/master/sub/sub_merge.txt',
  'vless': 'https://raw.githubusercontent.com/wiki/gfpcom/free-proxy-list/lists/vless.txt',
  'vmess': 'https://raw.githubusercontent.com/wiki/gfpcom/free-proxy-list/lists/vmess.txt',
  'trojan': 'https://raw.githubusercontent.com/wiki/gfpcom/free-proxy-list/lists/trojan.txt',
  'mixed-base64': 'https://raw.githubusercontent.com/Au1rxx/free-vpn-subscriptions/main/output/v2ray-base64.txt',
};

const _base64Sources = {'mixed-base64'};

const _orderedPrefixSources = {'multi-protocol'};

class GfpProxyService {
  GfpProxyService({Dio? dio})
    : _dio =
          dio ??
          Dio(BaseOptions(connectTimeout: const Duration(seconds: 12), receiveTimeout: const Duration(seconds: 12)));

  final Dio _dio;

  Future<String?> loadFreshCache({Duration maxAge = const Duration(minutes: 45)}) async {
    final prefs = await SharedPreferences.getInstance();
    final ts = prefs.getInt(_cacheKeyTimestamp);
    final content = prefs.getString(_cacheKeyContent);
    if (ts == null || content == null) return null;

    final age = DateTime.now().millisecondsSinceEpoch - ts;
    if (age > maxAge.inMilliseconds) return null;
    return _containsProxy(content) ? content : null;
  }

  Future<String?> loadLastKnownGood() async {
    final prefs = await SharedPreferences.getInstance();
    final content = prefs.getString(_cacheKeyContent);
    return _containsProxy(content) ? content : null;
  }

  Future<void> saveCandidateCache(String content) async {
    if (!_containsProxy(content)) throw const GfpNoReachableProxyException();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cacheKeyContent, content);
    await prefs.setInt(_cacheKeyTimestamp, DateTime.now().millisecondsSinceEpoch);
  }

  Future<String> refresh({
    int maxCandidatesToTest = 96,
    int concurrency = 6,
    Duration testTimeout = const Duration(seconds: 3),
    int maxFinal = 60,
    void Function(int done, int total)? onProgress,
  }) async {
    // Les listes sont lues par flux pour limiter la mémoire utilisée.
    final perSourceLimit = maxCandidatesToTest * 2;
    final lists = await Future.wait(
      _sources.entries.map(
        (entry) => _readCandidatePrefix(
          entry.value,
          maxCandidates: perSourceLimit,
          base64Encoded: _base64Sources.contains(entry.key),
          reservoirSample: !_orderedPrefixSources.contains(entry.key),
        ),
      ),
    );
    final deduplicated = <String, GfpProxyCandidate>{};
    for (final candidate in lists.expand((list) => list)) {
      deduplicated.putIfAbsent(candidate.identityKey, () => candidate);
    }
    final all = selectDiverseCandidates(deduplicated.values, limit: maxCandidatesToTest);

    final tested = await testAll(all, concurrency: concurrency, timeout: testTimeout, onProgress: onProgress);

    // Un port TCP ouvert n'est pas une preuve de proxy fonctionnel. Tester tout
    // l'échantillon empêche les premiers Reality joignables de masquer les
    // protocoles de secours. Le moteur effectuera ensuite le handshake complet
    // et un vrai téléchargement avant de verrouiller une route.
    final selected = selectDiverseCandidates(tested.where((candidate) => candidate.reachable), limit: maxFinal);

    if (selected.isEmpty) throw const GfpNoReachableProxyException();

    final content = _buildSubscriptionContent(selected);
    return content;
  }

  bool _containsProxy(String? content) {
    if (content == null) return false;
    return parseProxyList(content).isNotEmpty;
  }

  Future<List<GfpProxyCandidate>> _readCandidatePrefix(
    String url, {
    required int maxCandidates,
    required bool base64Encoded,
    required bool reservoirSample,
    int maxCharacters = 8 * 1024 * 1024,
  }) async {
    try {
      final response = await _dio.get<ResponseBody>(url, options: Options(responseType: ResponseType.stream));
      final body = response.data;
      if (response.statusCode != 200 || body == null) return const [];

      // Échantillonne toute la source au lieu de garder uniquement son début.
      final candidates = <GfpProxyCandidate>[];
      final seen = <String>{};
      final perHost = <String, int>{};
      final random = Random();
      var eligibleCount = 0;
      var charactersRead = 0;

      void consider(GfpProxyCandidate candidate) {
        final key = candidate.identityKey;
        final hostKey = candidate.host.toLowerCase();
        final hostCount = perHost[hostKey] ?? 0;
        if (!seen.add(key) || hostCount >= 2) return;

        eligibleCount++;
        if (candidates.length < maxCandidates) {
          perHost[hostKey] = hostCount + 1;
          candidates.add(candidate);
          return;
        }

        if (!reservoirSample) return;

        final replacement = random.nextInt(eligibleCount);
        if (replacement < maxCandidates) {
          final previous = candidates[replacement];
          final previousHost = previous.host.toLowerCase();
          perHost[previousHost] = (perHost[previousHost] ?? 1) - 1;
          perHost[hostKey] = hostCount + 1;
          candidates[replacement] = candidate;
        }
      }

      if (base64Encoded) {
        final encoded = BytesBuilder(copy: false);
        await for (final bytes in body.stream) {
          charactersRead += bytes.length;
          if (charactersRead > maxCharacters) break;
          encoded.add(bytes);
        }
        final text = utf8.decode(base64Decode(base64.normalize(utf8.decode(encoded.takeBytes()))));
        for (final candidate in parseProxyList(text)) {
          consider(candidate);
        }
        return candidates;
      }

      await for (final line
          in body.stream.map<List<int>>((bytes) => bytes).transform(utf8.decoder).transform(const LineSplitter())) {
        charactersRead += line.length + 1;
        if (charactersRead > maxCharacters) break;

        for (final candidate in parseProxyList(line)) {
          consider(candidate);
        }
      }
      return candidates;
    } catch (_) {
      // Une source indisponible ne bloque pas les autres.
      return const [];
    }
  }

  String _buildSubscriptionContent(List<GfpProxyCandidate> candidates) {
    final header = ['#profile-title: $kGfpProfileTitle'].join('\n');
    final body = candidates.map((c) => c.raw).join('\n');
    return '$header\n$body\n';
  }
}

List<GfpProxyCandidate> selectDiverseCandidates(Iterable<GfpProxyCandidate> candidates, {required int limit}) {
  if (limit <= 0) return const [];

  final sorted = sortByPriority(candidates.toList());
  final selected = <GfpProxyCandidate>[];
  final selectedKeys = <String>{};
  final perHost = <String, int>{};

  void addSpread(Iterable<GfpProxyCandidate> pool, int target) {
    final list = pool.toList(growable: false);
    for (var allowedPerHost = 1; selected.length < target; allowedPerHost++) {
      var added = false;
      for (final candidate in list) {
        if (selected.length == target) break;
        final hostKey = candidate.host.toLowerCase();
        final key = candidate.identityKey;
        if (selectedKeys.contains(key) || (perHost[hostKey] ?? 0) >= allowedPerHost) continue;
        perHost[hostKey] = (perHost[hostKey] ?? 0) + 1;
        selectedKeys.add(key);
        selected.add(candidate);
        added = true;
      }
      if (!added) break;
    }
  }

  final reality = sorted.where((candidate) => candidate.reality).toList(growable: false);
  final vless = sorted.where((candidate) => !candidate.reality && candidate.scheme == 'vless').toList(growable: false);
  final awg = sorted.where((candidate) => candidate.scheme == 'awg').toList(growable: false);
  final quic = sorted
      .where((candidate) => {'hy2', 'hysteria2', 'tuic'}.contains(candidate.scheme))
      .toList(growable: false);
  final trojan = sorted.where((candidate) => candidate.scheme == 'trojan').toList(growable: false);
  final shadowsocks = sorted.where((candidate) => candidate.scheme == 'ss').toList(growable: false);
  final vmess = sorted.where((candidate) => candidate.scheme == 'vmess').toList(growable: false);
  final other = sorted
      .where(
        (candidate) =>
            !candidate.reality &&
            !{'vless', 'awg', 'hy2', 'hysteria2', 'tuic', 'trojan', 'ss', 'vmess'}.contains(candidate.scheme),
      )
      .toList(growable: false);

  // Reality reste majoritaire, mais les protocoles TCP éprouvés sont placés
  // avant les transports que seul le moteur peut tester. Pour une liste de 12,
  // on conserve normalement 6 Reality et 6 solutions de repli distinctes.
  final tiers = <({List<GfpProxyCandidate> candidates, double share})>[
    (candidates: reality, share: 0.50),
    (candidates: trojan, share: 0.15),
    (candidates: vmess, share: 0.10),
    (candidates: shadowsocks, share: 0.10),
    (candidates: vless, share: 0.05),
    (candidates: quic, share: 0.07),
    (candidates: awg, share: 0.03),
    (candidates: other, share: 0.0),
  ];
  for (final tier in tiers) {
    if (selected.length == limit) break;
    final quota = (limit * tier.share).round().clamp(1, limit);
    addSpread(tier.candidates, (selected.length + quota).clamp(0, limit));
  }
  addSpread(sorted, limit);
  return selected;
}
