import SwiftUI
import CefSwiftUI

/// A browser session's content: a Safari-style bar over its Chromium page, and a start page
/// while nothing is loaded.
struct BrowserPane: View {
    let browser: AgentBrowser
    let model: CefWebViewModel
    let label: String
    @ObservedObject var store: SessionStore
    /// False until the tile is first shown (or an agent asks): no Chromium page exists yet.
    var isLive = true

    private var isBlank: Bool { model.url == nil || model.url?.absoluteString == "about:blank" }

    var body: some View {
        VStack(spacing: 0) {
            BrowserBar(browser: browser, model: model, label: label)
            ZStack {
                if isLive && browser.isRunning {
                    CefWebView(model: model)
                }
                if isLive && (isBlank || !browser.isRunning) {
                    // Hosted as its own AppKit view: Chromium's view would otherwise draw over it.
                    AppKitLayer {
                        BrowserStartPage(label: label, error: browser.isRunning ? nil : browser.startError,
                                         servers: servers, open: { model.load($0) })
                    }
                }
            }
        }
        .background(Color(nsColor: Theme.terminalBackground))
    }

    /// Dev servers running in Kuronami, offered as one-click destinations.
    private var servers: [(label: String, port: Int)] {
        store.sessions.flatMap { session in session.ports.map { (label: session.label, port: $0) } }
    }
}

// MARK: - Bar

private struct BrowserBar: View {
    let browser: AgentBrowser
    let model: CefWebViewModel
    let label: String
    @State private var address = ""
    @State private var editing = false
    @FocusState private var fieldFocused: Bool

    /// Only actions on this browser: several agents may be driving browsers at once.
    private var activity: AgentBrowser.Activity? { browser.activity.flatMap { $0.browser == label ? $0 : nil } }
    private var currentURL: URL? { model.url?.absoluteString == "about:blank" ? nil : model.url }

    var body: some View {
        HStack(spacing: 2) {
            BarButton(symbol: "chevron.left", help: "Back") { model.goBack() }
                .disabled(!model.canGoBack)
            BarButton(symbol: "chevron.right", help: "Forward") { model.goForward() }
                .disabled(!model.canGoForward)
            BarButton(symbol: model.isLoading ? "xmark" : "arrow.clockwise", help: model.isLoading ? "Stop" : "Reload") {
                model.isLoading ? model.stopLoading() : model.reload()
            }
            .disabled(currentURL == nil)
            addressField
                .padding(.horizontal, 6)
            if let activity {
                AgentActivityPill(activity: activity)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            menu
        }
        .padding(.horizontal, 8)
        .frame(height: 42)
        .animation(.easeOut(duration: 0.2), value: activity)
        .overlay(alignment: .bottom) { LoadProgress(progress: model.isLoading ? model.estimatedProgress : nil) }
        .onChange(of: model.url) { _, _ in if !editing { address = currentURL?.absoluteString ?? "" } }
    }

    // MARK: Address

    private var addressField: some View {
        ZStack {
            TextField("", text: $address, prompt: Text("Search or enter address"))
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($fieldFocused)
                .onSubmit(navigate)
                .onExitCommand { fieldFocused = false }
                .opacity(editing ? 1 : 0)
                .padding(.horizontal, 10)
            if !editing {
                AddressSummary(url: currentURL)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: beginEditing)
            }
        }
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(editing ? 0.09 : 0.055)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(editing ? Color.accentColor.opacity(0.7) : Color.clear, lineWidth: 1))
        .onChange(of: fieldFocused) { _, focused in if !focused { editing = false } }
    }

    private func beginEditing() {
        address = currentURL?.absoluteString ?? ""
        editing = true
        fieldFocused = true
    }

    /// Bare hosts get a scheme (http for local dev servers); anything else is a search.
    private func navigate() {
        let text = address.trimmingCharacters(in: .whitespaces)
        defer { fieldFocused = false }
        guard !text.isEmpty else { return }
        let local = text.hasPrefix("localhost") || text.hasPrefix("127.0.0.1") || text.hasPrefix(":")
        let looksLikeAddress = !text.contains(" ") && (text.contains(".") || local || text.contains(":"))
        let target: URL?
        if text.contains("://") {
            target = URL(string: text)
        } else if text.hasPrefix(":"), let port = Int(text.dropFirst()) {
            target = URL(string: "http://localhost:\(port)")
        } else if looksLikeAddress {
            target = URL(string: (local ? "http://" : "https://") + text)
        } else {
            var search = URLComponents(string: "https://www.google.com/search")
            search?.queryItems = [URLQueryItem(name: "q", value: text)]
            target = search?.url
        }
        if let target { model.load(target) }
    }

    // MARK: Menu

    private var menu: some View {
        Menu {
            Button("Open in Google Chrome") { openInChrome() }.disabled(currentURL == nil)
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(currentURL?.absoluteString ?? "", forType: .string)
            }
            .disabled(currentURL == nil)
            Divider()
            Button("Import Chrome Logins…") { BrowserLogins.importFromChrome(reload: model) }
            Button("Developer Tools") { model.browser?.toggleDevTools() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
    }

    private func openInChrome() {
        guard let url = currentURL,
              let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else {
            if let url = currentURL { NSWorkspace.shared.open(url) }
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// At rest the field reads like Safari's: a security glyph, the host, and a dimmed path.
private struct AddressSummary: View {
    let url: URL?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            if let url, let host = url.host() {
                (Text(host + (url.port.map { ":\($0)" } ?? "")).foregroundStyle(.primary)
                    + Text(path(of: url)).foregroundStyle(.tertiary))
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text("Search or enter address")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
    }

    private var symbol: String {
        guard let url else { return "magnifyingglass" }
        if url.scheme == "https" { return "lock.fill" }
        if url.host() == "localhost" || url.host() == "127.0.0.1" { return "server.rack" }
        return "globe"
    }

    private func path(of url: URL) -> String {
        let path = url.path()
        return path == "/" || path.isEmpty ? "" : path
    }
}

private struct BarButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(isEnabled ? Color.secondary : Color.secondary.opacity(0.35))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(hovering && isEnabled ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// "@api · click": who is driving the page right now.
private struct AgentActivityPill: View {
    let activity: AgentBrowser.Activity
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Palette.working)
                .frame(width: 6, height: 6)
                .opacity(pulse ? 0.35 : 1)
            Text("@\(activity.agent)").fontWeight(.semibold)
            Text(activity.action).foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Palette.working.opacity(0.14)))
        .overlay(Capsule().strokeBorder(Palette.working.opacity(0.3), lineWidth: 0.5))
        .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true } }
        .help("@\(activity.agent) is using the browser")
    }
}

/// A hairline under the bar that fills while a page loads.
private struct LoadProgress: View {
    let progress: Double?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.primary.opacity(0.07))
                if let progress {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: proxy.size.width * max(0.08, min(progress, 1)))
                        .animation(.easeOut(duration: 0.25), value: progress)
                }
            }
        }
        .frame(height: progress == nil ? 0.5 : 2)
    }
}

// MARK: - Start page

private struct BrowserStartPage: View {
    let label: String
    let error: String?
    let servers: [(label: String, port: Int)]
    let open: (URL) -> Void

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(Palette.working.opacity(0.14)).frame(width: 58, height: 58)
                Image(systemName: error == nil ? "globe" : "exclamationmark.triangle")
                    .font(.system(size: 25, weight: .light))
                    .foregroundStyle(error == nil ? Palette.working : Palette.attention)
            }
            VStack(spacing: 6) {
                Text(error == nil ? "@\(label)" : "Browser unavailable")
                    .font(.system(size: 16, weight: .semibold, design: error == nil ? .monospaced : .default))
                Text(error ?? "Agents drive this browser as @\(label) and you can step in anytime. Every Kuronami browser shares one set of logins.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            if error == nil && !servers.isEmpty {
                VStack(spacing: 8) {
                    Text("RUNNING LOCALLY")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(.tertiary)
                    FlowLayout(spacing: 6) {
                        ForEach(servers, id: \.port) { server in
                            Button { if let url = URL(string: "http://localhost:\(server.port)") { open(url) } } label: {
                                HStack(spacing: 5) {
                                    Text(":" + String(server.port)).font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(Palette.running)
                                    Text(server.label).font(.system(size: 11.5)).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(Color.primary.opacity(0.06)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: 340)
                }
                .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: Theme.terminalBackground))
    }
}

/// Hosts SwiftUI content in its own NSView so it stacks above sibling AppKit views (Chromium's)
/// in a ZStack; plain SwiftUI content draws beneath them.
private struct AppKitLayer<Content: View>: NSViewRepresentable {
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> NSHostingView<Content> {
        let view = NSHostingView(rootView: content())
        view.sizingOptions = []
        return view
    }

    func updateNSView(_ view: NSHostingView<Content>, context: Context) {
        view.rootView = content()
    }
}
