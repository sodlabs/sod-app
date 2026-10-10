import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dartx/dartx.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/router/bottom_sheets/bottom_sheets_notifier.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/gfp/gfp_health_monitor.dart';
import 'package:hiddify/features/gfp/gfp_proxy_service.dart';
import 'package:hiddify/features/home/widget/connection_button.dart';
import 'package:hiddify/features/home/widget/third_party_warning_banner.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/active/active_proxy_card.dart';
import 'package:hiddify/features/proxy/active/active_proxy_delay_indicator.dart';
import 'package:hiddify/gen/assets.gen.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class HomePage extends HookConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final t = ref.watch(translationsProvider).requireValue;
    final activeProfile = ref.watch(activeProfileProvider);

    final gfpError = useState<String?>(null);
    final gfpStatus = useState<String>('idle');
    ref.listen(gfpHealthStatusProvider, (_, next) {
      if (next != 'idle') gfpStatus.value = next;
    });

    useEffect(() {
      Future<void> run() async {
        try {
          gfpStatus.value = 'starting';
          final repo = await ref.read(profileRepositoryProvider.future);
          final service = GfpProxyService();

          List<ProfileEntity> allProfiles = [];
          try {
            final either = await repo.watchAll().first;
            allProfiles = either.getOrElse((_) => <ProfileEntity>[]);
          } catch (_) {}

          final existing = allProfiles
              .where(
                (profile) =>
                    isGfpProfileName(profile.map(remote: (profile) => profile.name, local: (profile) => profile.name)),
              )
              .firstOrNull;

          if (existing == null) {
            gfpStatus.value = 'fetching';
            final cached = await service.loadFreshCache();
            final content = cached ?? await _refreshForCurrentNetwork(service, gfpStatus);
            gfpStatus.value = 'adding profile';
            final result = await repo.addLocal(content).run();
            await result.match(
              (failure) {
                gfpError.value = 'addLocal a échoué: $failure';
                return Future<void>.value();
              },
              (_) async {
                if (cached == null) await service.saveCandidateCache(content);
                gfpStatus.value = 'done';
              },
            );
          } else {
            // Ne pas interrompre une connexion active pour actualiser la liste.
            final fresh = await service.loadFreshCache(maxAge: const Duration(hours: 3, minutes: 30));
            if (fresh == null) {
              gfpStatus.value = 'refresh recommended — tap the refresh button';
            } else {
              gfpStatus.value = 'done (existing)';
            }
          }
        } catch (e, st) {
          gfpError.value = '$e';
          debugPrint('sodlab gfp error: $e\n$st');
        }
      }

      run();
      return null;
    }, const []);

    Future<void> confirmAndRefresh() async {
      final connection = ref.read(connectionNotifierProvider).valueOrNull;
      if (connection != null && !connection.isDisconnected) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(t.connection.connected),
            content: Text(t.pages.home.refreshBlockedConnected),
            actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(t.common.ok))],
          ),
        );
        return;
      }

      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(t.pages.home.refreshTitle),
          content: Text(t.pages.home.refreshMessage),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t.common.cancel)),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(t.common.update)),
          ],
        ),
      );
      if (confirmed == true) {
        await _refreshGfpProfileManually(
          ref,
          gfpStatus,
          gfpError,
          connectedMessage: t.pages.home.refreshBlockedConnected,
        );
      }
    }

    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        scrolledUnderElevation: 0,
        title: Row(
          children: [
            Assets.images.logo.svg(height: 22),
            const Gap(10),
            Text(
              t.common.appTitle,
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -.4),
            ),
          ],
        ),
        actions: [
          Semantics(
            key: const ValueKey("profile_quick_settings"),
            label: t.pages.home.quickSettings,
            child: IconButton(
              tooltip: t.pages.home.quickSettings,
              icon: const Icon(Icons.tune_rounded),
              onPressed: () => ref.read(bottomSheetsNotifierProvider.notifier).showQuickSettings(),
            ),
          ),
          const Gap(4),
        ],
      ),
      body: ColoredBox(
        color: theme.colorScheme.surfaceContainerLowest,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: CustomScrollView(
              slivers: [
                const SliverPadding(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
                  sliver: SliverToBoxAdapter(child: ThirdPartyWarningBanner()),
                ),
                if (_showGfpStatus(gfpStatus.value, gfpError.value, ref.watch(Preferences.showConnectionDetails)))
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    sliver: SliverToBoxAdapter(
                      child: _ConnectionProgressCard(status: gfpStatus.value, error: gfpError.value),
                    ),
                  ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  sliver: SliverToBoxAdapter(
                    child: switch (activeProfile) {
                      AsyncData(value: final profile?) => _SourceCard(profile: profile, onRefresh: confirmAndRefresh),
                      _ => const SizedBox(height: 72),
                    },
                  ),
                ),
                const SliverPadding(
                  // RootScaffold draws its navigation bar over the page body.
                  // Reserve its height so the active proxy card stays fully
                  // visible instead of sliding underneath it.
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 88),
                  sliver: SliverFillRemaining(
                    hasScrollBody: false,
                    child: Column(
                      children: [
                        Expanded(child: _ConnectionStage()),
                        ActiveProxyFooter(),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

bool _showGfpStatus(String status, String? error, bool showDetails) {
  if (error != null || showDetails) return true;
  if (status == 'idle' || status == 'done' || status == 'done (existing)') return false;
  if (status == 'using locally verified route') return false;
  return true;
}

class _SourceCard extends ConsumerWidget {
  const _SourceCard({required this.profile, required this.onRefresh});

  final ProfileEntity profile;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final t = ref.watch(translationsProvider).requireValue;
    final automatic = isGfpProfileName(profile.name);

    return Material(
      color: theme.colorScheme.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: .8)),
      ),
      child: Column(
        children: [
          ListTile(
            minTileHeight: 84,
            contentPadding: const EdgeInsets.fromLTRB(18, 8, 12, 8),
            leading: CircleAvatar(
              backgroundColor: theme.colorScheme.primaryContainer,
              foregroundColor: theme.colorScheme.onPrimaryContainer,
              child: Icon(automatic ? Icons.route_outlined : Icons.link_rounded),
            ),
            title: Text(
              automatic ? t.pages.home.publicNetwork : profile.name,
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            subtitle: Text(
              automatic ? t.pages.home.publicNetworkSubtitle : t.pages.home.customSourceSubtitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => ref.read(bottomSheetsNotifierProvider.notifier).showProfilesOverview(),
          ),
          Divider(height: 1, indent: 16, endIndent: 16, color: theme.colorScheme.outlineVariant),
          Row(
            children: [
              Expanded(
                child: _SourceAction(
                  icon: Icons.swap_horiz_rounded,
                  label: t.pages.home.manageSources,
                  onTap: () => ref.read(bottomSheetsNotifierProvider.notifier).showProfilesOverview(),
                ),
              ),
              Expanded(
                child: _SourceAction(
                  icon: Icons.add_link_rounded,
                  label: t.pages.home.addCustomSource,
                  onTap: () => ref.read(bottomSheetsNotifierProvider.notifier).showAddProfile(),
                ),
              ),
              Expanded(
                child: _SourceAction(
                  key: const ValueKey('gfp_manual_refresh'),
                  icon: Icons.refresh_rounded,
                  label: t.pages.home.refreshAction,
                  onTap: onRefresh,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SourceAction extends StatelessWidget {
  const _SourceAction({super.key, required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        excludeFromSemantics: true,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 76),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 22, color: theme.colorScheme.primary),
                const Gap(5),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ConnectionStage extends ConsumerWidget {
  const _ConnectionStage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final connected = ref.watch(connectionNotifierProvider).valueOrNull is Connected;
    return Container(
      width: double.infinity,
      constraints: BoxConstraints(minHeight: connected ? 220 : 300),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(32),
        border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: .65)),
      ),
      child: const Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [ConnectionButton(), ActiveProxyDelayIndicator()]),
      ),
    );
  }
}

class _ConnectionProgressCard extends ConsumerWidget {
  const _ConnectionProgressCard({required this.status, this.error});

  final String status;
  final String? error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final t = ref.watch(translationsProvider).requireValue;
    final failed = error != null || status == 'no locally verified route';
    final ready = status == 'using locally verified route' || status.startsWith('refresh complete');
    final loading = !failed && !ready && !status.startsWith('refresh recommended') && status != 'done';

    final String label;
    if (error != null) {
      label = t.pages.home.scan.failed;
    } else if (status.startsWith('test ')) {
      label = '${t.pages.home.scan.testing} ${status.substring(5)}';
    } else if (status.startsWith('refresh recommended')) {
      label = t.pages.home.scan.refreshRecommended;
    } else if (status == 'waiting for local protocol tests' || status == 'checking real local transfer') {
      label = t.pages.home.scan.validating;
    } else if (status == 'using locally verified route') {
      label = t.pages.home.scan.ready;
    } else if (status == 'no locally verified route') {
      label = t.pages.home.scan.noRoute;
    } else if (status.startsWith('refresh complete')) {
      label = t.pages.home.scan.refreshComplete;
    } else {
      label = t.pages.home.scan.collecting;
    }

    final foreground = failed ? theme.colorScheme.onErrorContainer : theme.colorScheme.onSecondaryContainer;
    return Semantics(
      liveRegion: true,
      label: label,
      child: Card(
        color: failed ? theme.colorScheme.errorContainer : theme.colorScheme.secondaryContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              if (loading)
                SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: foreground))
              else
                Icon(failed ? Icons.error_outline_rounded : Icons.check_circle_outline_rounded, color: foreground),
              const Gap(12),
              Expanded(
                child: Text(label, style: theme.textTheme.bodyMedium?.copyWith(color: foreground)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<String> _refreshForCurrentNetwork(
  GfpProxyService service,
  ValueNotifier<String> status, {
  bool deepScan = false,
}) async {
  final networks = await Connectivity().checkConnectivity();
  final onWifi = networks.contains(ConnectivityResult.wifi) || networks.contains(ConnectivityResult.ethernet);

  // Le Wi-Fi permet un scan plus large sans charger inutilement le téléphone.
  return service.refresh(
    maxCandidatesToTest: deepScan ? (onWifi ? 1000 : 240) : (onWifi ? 96 : 48),
    concurrency: deepScan ? (onWifi ? 12 : 6) : (onWifi ? 8 : 4),
    // Keep a reserve for real protocol/payload proofs, not just the first
    // twelve open ports. Only routes passing those proofs will be offered.
    maxFinal: deepScan ? (onWifi ? 100 : 60) : (onWifi ? 60 : 30),
    onProgress: (done, total) => status.value = 'test $done/$total',
  );
}

/// Explicit user action only. This may restart the core while the refreshed
/// profile is imported, hence the confirmation shown by the refresh button.
Future<void> _refreshGfpProfileManually(
  WidgetRef ref,
  ValueNotifier<String> status,
  ValueNotifier<String?> error, {
  required String connectedMessage,
}) async {
  try {
    error.value = null;
    status.value = 'deep refresh: collecting and testing proxies';
    final repo = await ref.read(profileRepositoryProvider.future);
    final profiles = (await repo.watchAll().first).getOrElse((_) => <ProfileEntity>[]);
    final profile = profiles.where((entry) => isGfpProfileName(_profileName(entry))).firstOrNull;
    if (profile == null) {
      error.value = 'sodlab profile is not available yet';
      return;
    }

    final service = GfpProxyService();
    final content = await _refreshForCurrentNetwork(service, status, deepScan: true);

    // Le scan peut durer. Si l'utilisateur s'est connecté entre-temps, garder
    // le tunnel intact et ne jamais remplacer le profil actif sous ses pieds.
    final connection = ref.read(connectionNotifierProvider).valueOrNull;
    if (connection != null && !connection.isDisconnected) {
      error.value = connectedMessage;
      return;
    }

    final result = await repo.offlineUpdate(profile, content).run();
    await result.match(
      (failure) {
        error.value = 'refresh failed: $failure';
        return Future<void>.value();
      },
      (_) async {
        await service.saveCandidateCache(content);
        status.value = 'refresh complete — reconnect to validate a route';
      },
    );
  } catch (e, st) {
    debugPrint('sodlab manual refresh error: $e\n$st');
    error.value = 'refresh failed: $e';
  }
}

String _profileName(ProfileEntity profile) =>
    profile.map(remote: (profile) => profile.name, local: (profile) => profile.name);
