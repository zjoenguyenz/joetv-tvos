/// Bundled debrid token slots + the MediaFusion link slot.
/// The committed values are EMPTY on purpose: the owner's
/// real values are injected at build time by the
/// build-joetv workflow from the RD_TOKEN, TORBOX_TOKEN,
/// PREMIUMIZE_TOKEN and MF_URL Actions secrets, so the
/// secrets never live in this repository. TorrentSettings
/// falls back to these values when nothing has been typed
/// in Settings — the owner ordered (2026-11-14, extended
/// 2026-11-16) that anything Muse can fill in itself must
/// never be left for him to type, least of all with a TV
/// remote, and never re-typed after a reinstall.
/// Premiumize joined as the third resolver on the owner's
/// order of 2026-11-16. The MediaFusion link joined on
/// 2026-11-18 (2.0.34): Signulous cannot install over the
/// existing app, so the owner deletes the app before every
/// install and the sandbox — every value typed in Settings
/// — dies with it; the 2.0.33 device log proved every user
/// value absent on a fresh install with only the bundled
/// tokens present. MediaFusion was the one credential with
/// no bundled fallback, so its link is bundled the same
/// way (the MF_URL secret) and TorrentSettings resolves it
/// through effectiveMfURL, exactly like the tokens.
enum BundledTokens {
    static let rdToken = ""
    static let torboxToken = ""
    static let premiumizeToken = ""
    static let mfURL = ""
}
