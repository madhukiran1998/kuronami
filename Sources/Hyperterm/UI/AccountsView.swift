import AppKit
import SwiftUI

/// Claude Code and Codex accounts: who each is signed in as, which one new agents use, and
/// adding or signing in another.
struct AccountsView: View {
    @ObservedObject var accounts: AccountStore
    let signIn: (AgentAccount) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Accounts").font(.system(size: 20, weight: .semibold))
                Text("Each account signs in separately and keeps its own history. Agents stay on the account they started with; move one from its menu when it hits a limit.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            AccountSection(kind: .claude, accounts: accounts, signIn: signIn)
            AccountSection(kind: .codex, accounts: accounts, signIn: signIn)
        }
        .padding(24)
        .frame(width: 560)
        .background(Color(nsColor: Ink.floor))
    }
}

private struct AccountSection: View {
    let kind: SessionKind
    @ObservedObject var accounts: AccountStore
    let signIn: (AgentAccount) -> Void
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(kind.displayName.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            VStack(spacing: 0) {
                ForEach(accounts.accounts(for: kind)) { account in
                    AccountRow(account: account, isPreferred: accounts.preferredID(for: kind) == account.id,
                               makePreferred: { accounts.setPreferred(account) },
                               signIn: { signIn(account) },
                               remove: account.isDefault ? nil : { accounts.remove(account) })
                    Divider().opacity(0.5)
                }
                HStack(spacing: 8) {
                    TextField("Add an account (e.g. work)", text: $newName)
                        .textFieldStyle(.plain)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .background(Color(nsColor: Ink.surface), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: Ink.hairline)))
        }
    }

    private func add() {
        guard let account = accounts.add(kind: kind, name: newName) else { NSSound.beep(); return }
        newName = ""
        signIn(account)
    }
}

private struct AccountRow: View {
    let account: AgentAccount
    let isPreferred: Bool
    let makePreferred: () -> Void
    let signIn: () -> Void
    let remove: (() -> Void)?

    var body: some View {
        // Re-read the sign-in now and then: it changes when a login terminal finishes.
        TimelineView(.periodic(from: .now, by: 3)) { _ in
            let email = AccountStore.signedInEmail(account)
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(account.name).font(.system(size: 13, weight: .semibold))
                        if isPreferred {
                            Text("New agents")
                                .font(.system(size: 10.5, weight: .medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Palette.working.opacity(0.16)))
                                .foregroundStyle(Palette.working)
                        }
                    }
                    Text(email ?? "Not signed in")
                        .font(.system(size: 12))
                        .foregroundStyle(email == nil ? Palette.attention : Color.secondary)
                }
                Spacer()
                if !isPreferred {
                    Button("Use for New Agents", action: makePreferred).controlSize(.small)
                }
                Button(email == nil ? "Sign In" : "Sign In Again", action: signIn).controlSize(.small)
                if let remove {
                    Button(role: .destructive, action: remove) { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Remove from Kuronami (its folder and sign-in stay on disk)")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }
}

/// The Accounts window, and the menu that moves the selected agent to another account.
@MainActor
final class AccountsController: NSObject, NSMenuDelegate {
    static let shared = AccountsController()
    private var window: NSWindow?

    func show() {
        guard let store = TerminalSessionFactory.store else { return }
        if window == nil {
            let host = NSHostingController(rootView: AccountsView(accounts: AccountStore.shared, signIn: { store.signIn($0) }))
            let window = NSWindow(contentViewController: host)
            window.title = "Accounts"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = Ink.floor
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
    }

    /// "Move to Account" lists the selected agent's other accounts.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let store = TerminalSessionFactory.store, let session = store.selected, session.kind.isAgent else {
            menu.addItem(NSMenuItem(title: "Select an agent", action: nil, keyEquivalent: ""))
            return
        }
        let current = session.spec.account ?? AgentAccount.defaultID
        for account in AccountStore.shared.accounts(for: session.kind) {
            let email = AccountStore.signedInEmail(account)
            let item = NSMenuItem(title: account.name + (email.map { " · \($0)" } ?? " · not signed in"),
                                  action: #selector(move(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = account.id
            item.state = account.id == current ? .on : .off
            item.isEnabled = account.id != current && email != nil
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let manage = NSMenuItem(title: "Accounts…", action: #selector(showAccounts(_:)), keyEquivalent: "")
        manage.target = self
        menu.addItem(manage)
    }

    @objc private func move(_ sender: NSMenuItem) {
        guard let store = TerminalSessionFactory.store, let session = store.selected,
              let id = sender.representedObject as? String,
              let account = AccountStore.shared.account(id, kind: session.kind) else { return }
        store.move(session, to: account)
    }

    @objc func showAccounts(_ sender: Any?) { show() }
}
