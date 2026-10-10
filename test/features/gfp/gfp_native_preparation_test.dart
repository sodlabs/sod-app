import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/directories/directories_provider.dart';
import 'package:hiddify/core/model/directories.dart';
import 'package:hiddify/core/model/optional_range.dart';
import 'package:hiddify/features/gfp/gfp_probe_session.dart';
import 'package:hiddify/features/log/model/log_level.dart';
import 'package:hiddify/hiddifycore/core_interface/core_interface_desktop.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcommon/common.pb.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart' hide LogLevel;
import 'package:hiddify/hiddifycore/hiddify_core_service.dart';
import 'package:hiddify/singbox/model/core_status.dart';
import 'package:hiddify/singbox/model/singbox_config_enum.dart';
import 'package:hiddify/singbox/model/singbox_config_option.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class FixtureDirectories extends AppDirectories {
  FixtureDirectories(this.directory);
  final Directory directory;
  @override
  Future<Directories> build() async => (baseDir: directory, workingDir: directory, tempDir: directory);
}

SingboxConfigOption _options(int mixedPort, int apiPort) => SingboxConfigOption(
  region: 'other',
  balancerStrategy: BalancerStrategy.roundRobin,
  useXrayCoreWhenPossible: false,
  executeConfigAsIs: false,
  logLevel: LogLevel.warn,
  resolveDestination: false,
  ipv6Mode: IPv6Mode.disable,
  remoteDnsAddress: 'tcp://8.8.8.8',
  remoteDnsDomainStrategy: DomainStrategy.auto,
  directDnsAddress: 'udp://1.1.1.1',
  directDnsDomainStrategy: DomainStrategy.auto,
  mixedPort: mixedPort,
  tproxyPort: 0,
  directPort: 0,
  redirectPort: 0,
  enableMixedPort: true,
  enableTproxyPort: false,
  enableDirectPort: false,
  enableRedirectPort: false,
  tunImplementation: TunImplementation.gvisor,
  mtu: 1500,
  strictRoute: true,
  connectionTestUrl: 'http://127.0.0.1:1',
  urlTestInterval: const Duration(hours: 1),
  enableClashApi: true,
  clashApiPort: apiPort,
  enableTun: true,
  setSystemProxy: false,
  allowConnectionFromLan: false,
  lanSharingPassword: '',
  enableFakeDns: false,
  independentDnsCache: true,
  routeRule: {},
  tlsTricks: const SingboxTlsTricks(
    enableFragment: false,
    fragmentSize: OptionalRange(min: 10, max: 30),
    fragmentSleep: OptionalRange(min: 2, max: 8),
    mixedSniCase: false,
    enablePadding: false,
    paddingSize: OptionalRange(min: 1, max: 1500),
  ),
  chainStatus: ChainStatus.off,
  extraSecurity: const SingboxExtraSecurityOption(
    mode: ChainMode.warp,
    warp: SingboxExtraSecurityWarpOption(licenseKey: ''),
    psiphon: SingboxExtraSecurityPsiphonOption(region: PsiphonRegion.auto, conduitPairingId: ''),
    profile: SingboxExtraSecurityProfileOption(id: ''),
  ),
  unblocker: const SingboxUnblockerOption(
    mode: ChainMode.psiphon,
    warp: SingboxUnblockerWarpOption(
      licenseKey: '',
      cleanIp: 'auto',
      cleanPort: 0,
      noise: OptionalRange(min: 0, max: 0),
      noiseMode: 'm1',
      noiseSize: OptionalRange(min: 0, max: 0),
      noiseDelay: OptionalRange(min: 0, max: 0),
    ),
    psiphon: SingboxUnblockerPsiphonOption(region: PsiphonRegion.auto, conduitPairingId: ''),
    profile: SingboxUnblockerProfileOption(id: ''),
  ),
);

void main() {
  final library = File('hiddify-core/hiddify-core.${Platform.isWindows ? 'dll' : 'so'}');
  test(
    'native preparation preserves settings, restores TUN, and refuses an active core',
    () async {
      final directory = await Directory.systemTemp.createTemp('sod-native-preparation-');
      final native = CoreInterfaceDesktop(port: await GfpProbeSession.availablePort());
      final container = ProviderContainer(
        overrides: [appDirectoriesProvider.overrideWith(() => FixtureDirectories(directory))],
      );
      final serviceProvider = Provider((ref) => HiddifyCoreService(ref, core: native));
      final service = container.read(serviceProvider);
      final options = _options(await GfpProbeSession.availablePort(), await GfpProbeSession.availablePort());
      try {
        final directories = await container.read(appDirectoriesProvider.future);
        expect(await native.setup(directories, false, 3), isEmpty);
        final profile = File('${directory.path}/profile.json');
        await profile.writeAsString(
          jsonEncode({
            'outbounds': [
              {'type': 'http', 'tag': 'route', 'server': '127.0.0.1', 'server_port': 1},
            ],
          }),
        );
        final original = await profile.readAsString();
        final session = await service.prepareGfpProbe(profile.path, options);
        final stopped = await native.fgClient.coreInfoListener(Empty()).first;
        expect(stopped.coreState, CoreStates.STOPPED);
        expect(session.users.keys, ['route']);
        expect((session.config['inbounds'] as List).cast<Map>().any((inbound) => inbound['type'] == 'tun'), isTrue);
        expect((session.config['dns'] as Map)['servers'], isNotEmpty);
        expect(await profile.readAsString(), original);

        // Start the exact augmented config with TUN removed for this loopback
        // fixture, then prove preparation cannot stop or alter a live instance.
        (session.config['inbounds'] as List).removeWhere((inbound) => (inbound as Map)['type'] == 'tun');
        final started = await native.bgClient.start(
          StartRequest(configContent: jsonEncode(session.config), enableRawConfig: true),
        );
        expect(started.messageType, MessageType.EMPTY);
        await expectLater(service.prepareGfpProbe(profile.path, options), throwsStateError);
        expect((await native.bgClient.coreInfoListener(Empty()).first).coreState, CoreStates.STARTED);

        service.currentState = const CoreStatus.started();
        service.gfpProbeSession = session;
        session.locked = true;
        expect(await service.abortUnverifiedGfpStart(session), isFalse);
        session.locked = false;
        final recovered = GfpProbeSession.recover(session.config, remoteDnsAddress: options.remoteDnsAddress)!;
        service.gfpProbeSession = recovered;
        expect(await service.abortUnverifiedGfpStart(recovered), isFalse);
        expect((await native.bgClient.coreInfoListener(Empty()).first).coreState, CoreStates.STARTED);
        service.gfpProbeSession = session;
        expect(await service.abortUnverifiedGfpStart(session), isTrue);
        expect((await native.bgClient.coreInfoListener(Empty()).first).coreState, CoreStates.STOPPED);
      } finally {
        try {
          await native.bgClient.stop(Empty());
        } finally {
          try {
            // Closing the owned server can tear down HTTP/2 before its reply.
            await native.fgClient.close(CloseRequest(mode: SetupMode.GRPC_NORMAL_INSECURE));
          } catch (_) {
            // This server belongs only to this fixture and has been stopped.
          } finally {
            container.dispose();
            try {
              await directory.delete(recursive: true);
            } on FileSystemException {
              // The Windows DLL retains its temporary log file until the test
              // host exits. It contains only this fixture's synthetic config.
            }
          }
        }
      }
    },
    skip: !library.existsSync() || !Platform.isWindows
        ? 'Native preparation fixture requires the Windows test library'
        : false,
  );
}
