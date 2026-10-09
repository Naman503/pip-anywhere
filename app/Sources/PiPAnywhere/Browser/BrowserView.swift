import AppKit
import PiPCore
import SwiftUI
import WebKit

/// The floating browser: tab strip (drag it to move the window), toolbar, and the page.
struct BrowserView: View {
    static let tabStripHeight: CGFloat = 32
    static let toolbarHeight: CGFloat = 36

    @ObservedObject var model: PlayerModel
    @ObservedObject var browser: BrowserModel
    let actions: PanelActions
    var openInBrowser: (URL) -> Void = { _ in }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                tabStrip
                if let tab = browser.selected {
                    Toolbar(tab: tab, browser: browser, openInBrowser: openInBrowser)
                    ZStack(alignment: .top) {
                        WebViewHost(webView: tab.webView)
                        LoadingBar(tab: tab)
                    }
                } else {
                    Color(white: 0.1)
                }
            }
            if model.isStashed {
                // Slid into the edge: nothing of the page may show in the strip.
                LinearGradient(colors: [Color(white: 0.16), Color(white: 0.08)], startPoint: .top, endPoint: .bottom)
                StashHandle(edge: model.stashEdge, playing: true)
                    .contentShape(Rectangle())
                    .onTapGesture { actions.toggleStash() }
            } else if !model.ghost {
                ResizeHandles(onChange: actions.resizeChanged, onEnd: actions.resizeEnded,
                              edge: ResizeZones.live.edge, corner: ResizeZones.live.corner)
            }
        }
        .background(Color(white: 0.12))
        .clipShape(RoundedRectangle(cornerRadius: model.isStashed ? 8 : 10, style: .continuous))
    }

    private var tabStrip: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(browser.tabs) { tab in
                        TabPill(tab: tab, selected: tab.id == browser.selected?.id,
                                select: { browser.select(tab) }, close: { browser.close(tab) })
                    }
                    IconButton(symbol: "plus", size: 11, help: "New tab (⌘T)") { browser.newTab() }
                }
                .padding(.leading, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            IconButton(symbol: "arrow.right.to.line", size: 11, help: "Slide to the edge (⌃⌥P)", action: actions.toggleStash)
            IconButton(symbol: "xmark", size: 11, help: "Close the browser (tabs are kept)", action: actions.close)
        }
        .padding(.trailing, 6)
        .frame(height: Self.tabStripHeight)
        .background(
            // Empty strip = window drag handle; double-click = big/normal.
            Color(white: 0.08)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .global)
                        .onChanged { _ in actions.dragChanged() }
                        .onEnded { _ in actions.dragEnded() }
                )
        )
    }
}

private struct TabPill: View {
    @ObservedObject var tab: BrowserTab
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            if tab.isLoading {
                ProgressView().controlSize(.mini).frame(width: 12, height: 12)
            } else {
                Image(systemName: "globe").font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
            }
            Text(tab.title)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(.white.opacity(selected ? 0.95 : 0.65))
                .lineLimit(1)
            if hovering || selected {
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                        .frame(width: 14, height: 14).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close tab (⌘W)")
            }
        }
        .padding(.horizontal, 8)
        .frame(minWidth: 70, maxWidth: 170, minHeight: 24, maxHeight: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(selected ? 0.16 : hovering ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .help(tab.url?.absoluteString ?? tab.title)
    }
}

private struct Toolbar: View {
    @ObservedObject var tab: BrowserTab
    @ObservedObject var browser: BrowserModel
    let openInBrowser: (URL) -> Void
    @State private var address = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        HStack(spacing: 2) {
            IconButton(symbol: "chevron.left", size: 12, help: "Back (⌘[)") { tab.webView.goBack() }
                .opacity(tab.canGoBack ? 1 : 0.35)
            IconButton(symbol: "chevron.right", size: 12, help: "Forward (⌘])") { tab.webView.goForward() }
                .opacity(tab.canGoForward ? 1 : 0.35)
            IconButton(symbol: tab.isLoading ? "xmark" : "arrow.clockwise", size: 12, help: tab.isLoading ? "Stop" : "Reload (⌘R)") {
                if tab.isLoading { tab.webView.stopLoading() } else { tab.webView.reload() }
            }
            TextField("Search or enter address", text: $address)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(addressFocused ? 0.16 : 0.09)))
                .focused($addressFocused)
                .onSubmit {
                    browser.go(address)
                    addressFocused = false
                }
                .onExitCommand { addressFocused = false; address = tab.url?.absoluteString ?? "" }
            if let url = tab.url {
                IconButton(symbol: "arrow.up.forward.app", size: 12, help: "Open this page in your default browser") { openInBrowser(url) }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: BrowserView.toolbarHeight)
        .background(Color(white: 0.14))
        .onAppear { address = tab.url?.absoluteString ?? "" }
        .onChange(of: tab.url) { _, url in if !addressFocused { address = url?.absoluteString ?? "" } }
        .onChange(of: tab.id) { _, _ in address = tab.url?.absoluteString ?? "" }
        .onChange(of: browser.focusAddressBar) { _, _ in
            addressFocused = true
            address = tab.url?.absoluteString ?? ""
        }
    }
}

private struct LoadingBar: View {
    @ObservedObject var tab: BrowserTab

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: geo.size.width * tab.progress, height: 2)
                .opacity(tab.isLoading ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: tab.progress)
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }
}

/// Shows the selected tab's WKWebView (swapped in when the tab changes).
private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard webView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
}
