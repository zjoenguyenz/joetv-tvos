# JoeTV (tvOS)

Joe TV for Apple TV — split out of the `dabanh-ios` monorepo on
2026-11-18 so the app migrates and ships on its own track.

- Project: XcodeGen (`project.yml`) — run `xcodegen generate`,
  then build scheme `JoeTV` (plus its `JoeTVTopShelf` extension).
- KSPlayer is the torrent (FFmpeg/MKV) playback engine,
  pinned exactly in `project.yml`.
- CI: `.github/workflows/build-joetv.yml` (manual dispatch)
  builds an unsigned IPA; the owner signs it himself.
- The workflow injects the TMDB key and debrid tokens from
  Actions secrets (`TMDB_API_KEY`, `RD_TOKEN`, `TORBOX_TOKEN`,
  `PREMIUMIZE_TOKEN`) at build time — the committed
  `JoeTV/TMDBKey.swift`, `JoeTV/BundledTokens.swift` and
  `JoeTVTopShelf/TMDBShelfKey.swift` files are intentionally
  empty placeholders. These four secrets must be configured on
  THIS repository for builds to carry live keys.
