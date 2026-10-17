# SunMate ANCS bridge

Upstream: flutter_blue_plus_darwin 7.0.3, pub.dev archive SHA-256
`682982862c1d964f4d54a3fb5fccc9e59a066422b93b7e22079aeecd9c0d38f8`.
The upstream BSD license is retained in LICENSE.

The native implementation adds `sunmate/ble_connection` (methods) and
`sunmate/ble_connection_events` (events). Both use the existing plugin instance
and CBCentralManager; no additional central manager or swizzling is used.

- `configure`: per-peripheral RequiresANCS option, applied before connect.
- `diagnostics`: current ANCS authorization and latest native connection event.
- Events: connect, ANCS authorization change, disconnect and connect failure,
  with NSError domain/code/description and native timestamp. No userInfo or
  characteristic payloads are exported.

The iOS-only public ANCS APIs are availability guarded. macOS continues using
the upstream connection behavior. Keep this override and the exact parent
flutter_blue_plus version together when updating dependencies.
