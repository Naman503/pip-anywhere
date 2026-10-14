import Foundation
import PiPCore
import WebKit

/// Ad and tracker blocking for the floating browser, the way Safari content blockers work:
/// EasyList + EasyPrivacy are converted to WebKit content rules and compiled once
/// (WebKit caches the compiled lists on disk). Blocking happens inside WebKit itself,
/// before a request is made, so it costs essentially nothing per page.
@MainActor
final class AdBlocker {
    static let shared = AdBlocker()

    private static let lists = [
        URL(string: "https://easylist.to/easylist/easylist.txt")!,
        URL(string: "https://easylist.to/easylist/easyprivacy.txt")!,
    ]
    private static let refreshInterval: TimeInterval = 4 * 24 * 3600
    private static let networkID = "pipanywhere-network"
    private static let cosmeticID = "pipanywhere-cosmetic"

    private let store = WKContentRuleListStore.default()!
    private var cached: [WKContentRuleList]?
    private var building: Task<[WKContentRuleList], Never>?

    private var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PiP Anywhere/AdBlock", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The compiled rule lists: from WebKit's cache when available (instant), otherwise
    /// downloaded and compiled. Refreshes stale lists in the background.
    func ruleLists() async -> [WKContentRuleList] {
        if let cached { return cached }
        if let building { return await building.value }
        let task = Task<[WKContentRuleList], Never> {
            var lists: [WKContentRuleList] = []
            for id in [Self.networkID, Self.cosmeticID] {
                if let list = try? await store.contentRuleList(forIdentifier: id) { lists.append(list) }
            }
            let stale = (UserDefaults.standard.object(forKey: "adblockUpdated") as? Date)
                .map { Date().timeIntervalSince($0) > Self.refreshInterval } ?? true
            if lists.count == 2 {
                if stale { Task { await self.rebuild() } }
                return lists
            }
            return await rebuild()
        }
        building = task
        let lists = await task.value
        building = nil
        cached = lists
        return lists
    }

    /// Downloads the filter lists, converts and compiles them.
    @discardableResult
    func rebuild() async -> [WKContentRuleList] {
        var texts: [String] = []
        for url in Self.lists {
            let file = folder.appendingPathComponent(url.lastPathComponent)
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if (response as? HTTPURLResponse)?.statusCode == 200 { try data.write(to: file) }
            } catch {
                log("adblock: download of \(url.lastPathComponent) failed: \(error.localizedDescription); using the saved copy")
            }
            if let text = try? String(contentsOf: file, encoding: .utf8) { texts.append(text) }
        }
        guard !texts.isEmpty else {
            log("adblock: no filter lists available yet")
            return []
        }
        let started = Date()
        let result = await Task.detached(priority: .utility) { ContentBlocker.convert(texts) }.value
        var lists: [WKContentRuleList] = []
        for (id, rules) in [(Self.networkID, result.network), (Self.cosmeticID, result.cosmetic)] {
            do {
                if let list = try await store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: result.json(rules)) {
                    lists.append(list)
                }
            } catch {
                log("adblock: compiling \(id) failed: \(error)")
            }
        }
        UserDefaults.standard.set(Date(), forKey: "adblockUpdated")
        log("adblock: \(result.network.count) network + \(result.cosmetic.count) hiding rules (\(result.skipped) skipped) compiled in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        cached = lists
        return lists
    }

    /// YouTube serves its ads from its own domains, so lists can't block them: skip them
    /// in the page instead (mute, jump to the end, press "Skip"), and remove ad slots.
    static let youTubeAdSkipper = WKUserScript(source: """
    (() => {
      if (!/(^|\\.)youtube\\.com$/.test(location.hostname)) return;
      let mutedByUs = false;
      const tick = () => {
        const player = document.querySelector('.html5-video-player');
        const video = player && player.querySelector('video');
        if (player && video && player.classList.contains('ad-showing')) {
          if (!video.muted) { video.muted = true; mutedByUs = true; }
          if (Number.isFinite(video.duration) && video.duration > 0) video.currentTime = video.duration;
        } else if (video && mutedByUs) {
          video.muted = false; mutedByUs = false;
        }
        document.querySelectorAll('.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button, .ytp-ad-overlay-close-button')
          .forEach((b) => b.click());
        document.querySelectorAll('ytd-ad-slot-renderer, ytd-in-feed-ad-layout-renderer, ytd-promoted-sparkles-web-renderer, ytd-banner-promo-renderer, #player-ads, #masthead-ad, ytd-rich-item-renderer:has(ytd-ad-slot-renderer)')
          .forEach((e) => e.remove());
      };
      setInterval(tick, 250);
    })();
    """, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
}
