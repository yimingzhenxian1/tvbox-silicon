import SwiftUI
import TVCore

/// The Bilibili account: sign in, or sign out. Signing in unlocks 1080P+ and the account's PGC rights.
/// Apple TV and the Mac show a code to scan with the Bilibili phone app (there is no browser on
/// Apple TV); iPhone and iPad, which can't scan their own screen, open Bilibili's sign-in page.
struct BilibiliAccountView: View {
    @State private var account = BilibiliAccount.load()
    @State private var attempt = 0
    #if os(iOS)
    @State private var signingIn = false
    #endif

    var body: some View {
        SettingsPage(title: L10n.text("Bilibili Account"), symbol: "play.tv") {
            if account.signedIn {
                SettingsGroup(footer: L10n.text("Bilibili plays the qualities your account allows. Sign-in details stay on this device.")) {
                    SettingsRow(symbol: "person.crop.circle.fill", tint: .pink, title: account.name.isEmpty ? L10n.text("Signed In") : account.name,
                                subtitle: L10n.text(account.vip ? "Premium member" : "Signed In")) {
                        Button(L10n.text("Sign Out")) { BilibiliAccount.signOut(); account = BilibiliAccount(); attempt += 1 }.settingsButton()
                    }
                }
            } else {
                #if os(iOS)
                SettingsGroup(footer: L10n.text("Sign in on Bilibili's page with a text-message code or your password, or scan a code with the Bilibili app on another phone. Without signing in, videos play at up to 1080P and anime and films at 480P.")) {
                    SettingsRow(symbol: "person.crop.circle.badge.questionmark", tint: .gray, title: L10n.text("Not Signed In"),
                                subtitle: L10n.text("Sign in for your feed, favorites and higher quality.")) {
                        Button(L10n.text("Sign In")) { signingIn = true }.settingsButton(prominent: true)
                            .accessibilityIdentifier("bilibili.signIn")
                    }
                }
                #else
                BilibiliCodeSignIn { account = $0 }
                #endif
            }
        }
        .task(id: attempt) { await refresh() }
        #if os(iOS)
        .sheet(isPresented: $signingIn) {
            WebSignInView(service: .bilibili, signedIn: { account = BilibiliAccount.load() }) {
                ScrollView { BilibiliCodeSignIn { account = $0; signingIn = false }.padding(24) }.screenBackdrop()
            }
        }
        #endif
    }

    /// Shows the current name and membership, and notices a login that expired on the server.
    private func refresh() async {
        guard account.signedIn else { return }
        var current = account
        if await current.refresh() { if current != account { try? current.save(); account = current } }
        else { BilibiliAccount.signOut(); account = BilibiliAccount(); attempt += 1 }
    }
}

/// Signing in to Bilibili by scanning a code with the Bilibili phone app, as the web site does.
struct BilibiliCodeSignIn: View {
    let signedIn: (BilibiliAccount) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var login: BilibiliQRLogin?
    @State private var scanned = false
    @State private var expired = false
    @State private var error: String?
    @State private var attempt = 0

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: spacing) { code; details }
            VStack(alignment: .leading, spacing: spacing) { code; details }
        }
        #if os(tvOS)
        .frame(maxWidth: .infinity)
        #else
        .padding(.vertical, 10)
        #endif
        .task(id: attempt) { await run() }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                #if os(iOS)
                // In the sign-in sheet, under its title.
                Text(L10n.text("Open the %@ app on another phone, scan this code, and confirm the sign-in.", L10n.text("Bilibili")))
                    .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                #else
                Text(L10n.text("Sign In to Bilibili")).font(.title2.weight(.bold))
                Text(L10n.text("Open the Bilibili app on your phone, scan this code, and confirm the sign-in. Without signing in, videos play at up to 1080P and anime and films at 480P."))
                    .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                #endif
            }
            status
            if expired || error != nil {
                Button(L10n.text("Get New Code")) { attempt += 1 }.settingsButton(prominent: true)
            }
            #if os(iOS)
            if let login, !expired { SaveCodeButton(text: login.code, app: L10n.text("Bilibili")).id(login.code) }
            #endif
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    @ViewBuilder private var code: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white)
            if let login, let image = QRCode.image(login.code) {
                Image(image, scale: 1, label: Text(L10n.text("Sign-in code"))).interpolation(.none).resizable().scaledToFit()
                    .padding(codeSize / 12).opacity(expired ? 0.15 : 1)
            } else if error == nil {
                ProgressView().tint(.black)
            }
            if expired {
                Image(systemName: "arrow.clockwise").font(.system(size: codeSize / 6, weight: .semibold)).foregroundStyle(.black.opacity(0.6))
            }
        }
        .frame(width: codeSize, height: codeSize)
        // While waiting there is no button, and Back with nothing focused would leave the app.
        .loadingFocus(takeFocus: true) { dismiss() }
    }

    @ViewBuilder private var status: some View {
        if let error {
            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Brand.amber)
        } else if expired {
            Label(L10n.text("This code has expired."), systemImage: "clock.badge.exclamationmark").foregroundStyle(.secondary)
        } else if login != nil {
            HStack(spacing: 12) {
                ProgressView()
                Text(L10n.text(scanned ? "Scanned. Confirm the sign-in on your phone…" : "Waiting for you to scan…")).foregroundStyle(.secondary)
            }
        }
    }

    private func run() async {
        login = nil; scanned = false; expired = false; error = nil
        do {
            let login = try await BilibiliQRLogin.start()
            self.login = login
            while !Task.isCancelled {
                try await Task.legacySleep(for: .seconds(2))
                switch try await login.poll() {
                case .waiting: continue
                case .scanned: scanned = true
                case .expired: expired = true; return
                case .signedIn(let account): signedIn(account); return
                }
            }
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    private var codeSize: CGFloat {
        #if os(tvOS)
        320
        #else
        220
        #endif
    }
    private var spacing: CGFloat {
        #if os(tvOS)
        72
        #else
        28
        #endif
    }
}

extension BilibiliAccount {
    /// The Settings row's subtitle.
    var summary: String { signedIn ? (name.isEmpty ? L10n.text("Signed In") : name) : L10n.text("Not Signed In") }
}

/// Atop the Bilibili source while signed out: signing in adds the account's lists to the source.
struct BilibiliSignInBanner: View {
    var body: some View {
        HStack(spacing: 16) {
            BilibiliMark(size: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("Sign In to Bilibili")).font(.headline)
                Text(L10n.text("See your following feed, favorites, watch later and history, and play in higher quality."))
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            RouteLink { BilibiliAccountView() } label: { Text(L10n.text("Sign In")) }.controlButton(prominent: true)
        }
        .padding(16)
        .contentPanel()
    }
}
