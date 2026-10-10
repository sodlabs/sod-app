# Sod 1.0.1 — functional and privacy audit

Audit updated: 10 October 2026. This describes the prototype branch, not every
historical Hiddify build.

## What a beginner sees

- On first launch, Sod explains that public proxies are operated by third
  parties and asks the user to acknowledge the risk.
- A default **Sod public network** is fetched and tested on the user's device.
  No Sod account or Sod-hosted subscription is required.
- The main action starts or stops the system VPN tunnel. The scan status is
  shown while work is in progress and then collapses. It can remain visible
  through **Settings → General → Show connection details**.
- Refresh is manual and blocked while a tunnel is connecting or connected.
- **Add your own** accepts a URL, clipboard content, a local file, a QR code or
  manual proxy data. Profiles and their update interval are saved in the local
  SQLite database.

## How the default network is built

1. The device streams bounded portions of several public GitHub proxy feeds.
2. Entries are parsed, deduplicated and spread across protocols and hosts.
3. A bounded TCP/TLS reachability test removes endpoints that cannot be reached
   from the user's current network.
4. A diverse reserve is imported into the local core; reachability is not
   presented as usability.
5. A dedicated authenticated loopback inbound forces each proof through its
   candidate. Two fresh HTTPS downloads on distinct hosts, payload checks,
   a 16 KiB upload and the configured DNS transport must succeed.
6. Only candidate lists are cached. Fresh proofs are required per connection;
   reported network changes invalidate them without switching the live route.
   A normal scan tests up to 96
   candidates on Wi-Fi (48 on mobile); a user-triggered deep refresh tests up
   to 1,000 on Wi-Fi (240 on mobile).

Reachability is not permanent. Public servers can disappear or become blocked,
so a green result is evidence from this device at this time, not a guarantee.

## Advanced capabilities retained from Hiddify

- Local and remote profiles, multiple subscription formats and bulk updates.
- TUN/VPN, system proxy and local proxy service modes where supported.
- DNS selection and strategies, fake DNS, IPv6 routing and strict routing.
- Region rules, per-application routing on Android, bypass/block rules and
  selectable balancing strategies.
- Optional chaining through a profile or Psiphon, plus TLS fragmentation,
  padding and mixed-case SNI controls.
- Local traffic, delay and connection statistics; logs and export tools.
- Desktop window, tray, auto-start and silent-start integration.
- LAN sharing and local inbound ports when explicitly enabled.

These controls are powerful and can also break connectivity. They remain in
Settings for advanced users rather than being placed in the beginner flow.

## External contacts and stored data

The default flow contacts public GitHub raw-content hosts, candidate proxy
servers, the configured connection-test endpoint and HTTPS validation resources
at Cloudflare, GitHub and OVH, with an upload echo at httpbin.org and a Cloudflare
upload fallback. The configured DNS resolver is exercised through the candidate. A manual
update check contacts the Sod GitHub repository. A custom profile contacts the
URL and servers supplied by its operator.

Sod 1.0.1 forces analytics off and does not initialize Sentry transmission.
Application logs, preferences, cached routes and profiles stay on the device
unless the user exports or shares them. See [the privacy notice](../PRIVACY.md).

## Deliberately removed or hidden in this prototype

- Hiddify Telegram, terms and update links.
- The upstream free-profile catalogue and its network request.
- The analytics control; telemetry is hard-disabled in this build.
- The permanent red public-proxy banner after acknowledgement.

The Hiddify core and several open-source dependencies remain part of the code.
Their license notices must remain distributed with Sod.

## Test evidence

October changes have deterministic TLS, payload-integrity, short-transfer,
deadline, upload and cancellation tests. A bundled Windows core test verifies
forced candidate routing, DNS-over-TCP and preservation of the live selector.
The native preparation test also covers the bundled builder's redundant
empty-direct DNS detour, restoration of options and TUN configuration, and
refusal to stop an already verified or recovered connection. Loopback tests
exercise SOCKS UDP DNS, DoH and removal of local proxy credentials from origin
requests. No new Android runtime result is claimed until device testing.
The following Android observation predates these changes:

The Android prototype was installed side-by-side on a Samsung SM-S918B. It
fetched the public feeds, completed local validation, obtained a usable Trojan
route, established Android's VPN tunnel and transferred traffic. No earlier
`dns-remote-no-warp` empty-detour startup failure recurred in that test.

This is a functional smoke test, not a security audit of the Hiddify core,
sing-box, every supported protocol or any third-party proxy operator.
