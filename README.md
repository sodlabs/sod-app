<p align="center">
  <img src="assets/images/source/sod_launcher.svg" width="112" alt="Sod logo">
</p>

<h1 align="center">Sod</h1>

<p align="center">
  A beginner-friendly proxy client that discovers, tests, and selects working routes on your device.
</p>

<p align="center">
  <a href="https://github.com/sodlabs/sod-app/releases"><img alt="Latest release" src="https://img.shields.io/github/v/release/sodlabs/sod-app?include_prereleases&style=flat-square"></a>
  <a href="https://github.com/sodlabs/sod-app/releases"><img alt="Downloads" src="https://img.shields.io/github/downloads/sodlabs/sod-app/total?style=flat-square"></a>
  <a href="LICENSE.md"><img alt="License" src="https://img.shields.io/badge/license-Hiddify_Extended_GPLv3-a82448?style=flat-square"></a>
</p>

<p align="center"><strong>Community beta for Android and Windows</strong> · <a href="README_ru.md">Русская версия</a></p>

> [!WARNING]
> Public proxies are operated by third parties. They can disappear, become slow, or behave dishonestly. Do not use public routes for banking, passwords, private work, or other sensitive activity. Sod improves route validation; it cannot make an unknown proxy trustworthy.

## Why Sod exists

Most proxy clients expect users to already understand subscriptions, protocols, and routing. Sod keeps those advanced tools, but adds a simple default path:

- fetch a public candidate list on the device;
- reject routes that only appear alive but cannot sustain incoming traffic;
- rank the remaining routes and connect with one tap;
- run a deeper manual refresh when the available routes become stale;
- import and retain a personal subscription for experienced users.

The public list is a starting point, not a centralized Sod VPN service. Route discovery and validation happen locally on the user's device.

Open ports and latency results are only candidates. A usable public route must pass two fresh HTTPS downloads from distinct hosts, payload checks (including fixed SHA-256 fingerprints for static files), a 16 KiB upload, and a test of the configured DNS transport. Probes use an authenticated loopback inbound with explicit per-candidate routing; they cannot fall back to the live route or a direct connection.

Sod seeks up to five verified routes on Wi-Fi/Ethernet and three on mobile data. Payload proofs have a shared budget of 8 MiB/120 seconds or 4 MiB/60 seconds respectively, excluding feed downloads, protocol overhead and native latency checks. The first verified route is selected once; reserve tests do not switch it. Refresh stays manual and is blocked while connecting or connected. Availability proofs are not persisted as trusted results and are invalidated when the connection or reported network type changes.

## Download

Use the [GitHub Releases page](https://github.com/sodlabs/sod-app/releases). The first public build is a prerelease so that connection quality can be evaluated in real networks before a stable release.

| Platform | Package | Status |
| --- | --- | --- |
| Android | Universal APK | Beta |
| Windows | x64 portable ZIP and installer | Beta |

Only install files published by the `sodlabs/sod-app` repository. Android beta builds may use a development signing key until the permanent Sod signing identity is established; changing that identity can require uninstalling an earlier beta.

## Privacy and trust

- Sod currently collects no analytics or usage statistics.
- Candidate fetching, handshakes, and sustained-transfer checks run on the device.
- No central Sod database receives a user's browsing history or selected proxy.
- Imported subscriptions are stored locally by the application.
- Third-party proxy and subscription operators remain outside Sod's control.

Please inspect the source and build workflow before relying on the application. Never post subscription URLs, credentials, or complete configuration files in a public issue.

## Beta feedback

Open a [GitHub issue](https://github.com/sodlabs/sod-app/issues/new/choose) and include:

- country and internet provider;
- Android/Windows version and device model;
- Sod version;
- whether discovery, sustained download, reconnect, and manual refresh worked;
- sanitized logs when relevant.

Do not include proxy passwords, UUIDs, subscription links, or other secrets.

## Development

Sod is a Flutter application. The release workflow currently targets Android and Windows.

```shell
flutter pub get
flutter test
make android-prepare   # or: make windows-prepare
flutter run
```

Public binaries are built by [GitHub Actions](.github/workflows/release.yml), as required by the project license. See [CONTRIBUTING.md](CONTRIBUTING.md) for the contribution flow.

## Origin, license, and changes

Sod is an independently maintained, non-commercial fork of [Hiddify App](https://github.com/hiddify/hiddify-app) and uses the Hiddify/sing-box core stack. Sod is not affiliated with or endorsed by the Hiddify project.

The source is distributed under the [Hiddify Extended GNU General Public License v3](LICENSE.md). The GitHub fork relationship is intentionally preserved.

Compared with the upstream application, this fork currently changes the product identity and interface, provides a beginner-first default discovery flow, adds local false-positive and sustained-download validation, supports manual deep refresh, removes upstream analytics/community links from the interface, and limits public release targets to Android and Windows. The Git history contains the complete change record.
