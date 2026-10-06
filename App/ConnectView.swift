import AppKit
import SwiftUI
import WebKit

/// Drives IBKR's OAuth self-service portal: generates the keys, hands the public files to the page's
/// upload buttons, and captures the access token when the portal shows it.
@MainActor
final class ConnectModel: ObservableObject {
    static let portalURL = URL(string: "https://ndcdyn.interactivebrokers.com/sso/Login?action=OAUTH&RL=1")!

    @Published var keys: KeyGen.Generated?
    @Published var consumerKey = KeyGen.suggestedConsumerKey()
    @Published var nextUpload = 0  // index into keys.publicFiles the next file chooser receives
    @Published var uploaded: [String] = []
    @Published var accessToken = ""
    @Published var accessTokenSecret = ""
    @Published var status = "Generate the keys, then log in to the portal on the right."
    @Published var finished = false
    private(set) var filesDir: URL?

    @Published var generating = false

    func generateKeys() {
        generating = true
        status = "Generating keys… the Diffie-Hellman parameters take about a minute."
        Task {
            defer { generating = false }
            do {
                let k = try await KeyGen.generate()
                try store(k)
            } catch {
                status = "Key generation failed: \(error.localizedDescription)"
            }
        }
    }

    private func store(_ k: KeyGen.Generated) throws {
        do {
            keys = k
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("folio-oauth-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for f in k.publicFiles {
                try f.contents.write(to: dir.appendingPathComponent(f.name), atomically: true, encoding: .utf8)
            }
            filesDir = dir
            // private keys go into the Keychain right away (as a pending set, so working credentials stay
            // untouched until a token is captured): closing this window must not lose them
            try Credentials(consumerKey: consumerKey, signatureKeyPEM: k.signaturePrivatePEM,
                            encryptionKeyPEM: k.encryptionPrivatePEM, dhParamsPEM: k.dhParamsPEM).savePending()
            status = "Keys generated and stored in the Keychain. Log in to the portal, enter the consumer key, and click its upload buttons: Folio supplies the files."
        } catch {
            status = "Key generation failed: \(error.localizedDescription)"
        }
    }

    /// Called when the page opens a file chooser: provide the next public file.
    func fileForUpload() -> URL? {
        guard let keys, let dir = filesDir, nextUpload < keys.publicFiles.count else { return nil }
        let f = keys.publicFiles[nextUpload]
        uploaded.append(f.name)
        nextUpload += 1
        status = "Uploaded \(f.name)." + (nextUpload < keys.publicFiles.count ? " Next: \(keys.publicFiles[nextUpload].name)." : " All three files uploaded; generate the access token.")
        return dir.appendingPathComponent(f.name)
    }

    func savePublicFiles() {
        guard let keys else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save here"
        panel.message = "Choose a folder for the three public files to upload to IBKR."
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        do {
            for f in keys.publicFiles { try f.contents.write(to: dir.appendingPathComponent(f.name), atomically: true, encoding: .utf8) }
            status = "Public files saved to \(dir.lastPathComponent)."
        } catch { status = error.localizedDescription }
    }

    /// Token (20 hex chars) and secret (long base64) spotted in the page.
    func detected(tokens: [String], secrets: [String]) {
        if accessToken.isEmpty, let t = tokens.first { accessToken = t }
        if accessTokenSecret.isEmpty, let s = secrets.max(by: { $0.count < $1.count }) { accessTokenSecret = s }
        if !accessToken.isEmpty, !accessTokenSecret.isEmpty, !finished {
            status = "Access token captured. Saving…"
            save()
        }
    }

    /// Resume a registration started earlier: the pending keys are still in the Keychain.
    func resumePending() {
        guard keys == nil, let pending = Credentials.loadPending() else { return }
        keys = KeyGen.Generated(signaturePrivatePEM: pending.signatureKeyPEM, signaturePublicPEM: KeyGen.publicPEM(forPrivate: pending.signatureKeyPEM),
                                encryptionPrivatePEM: pending.encryptionKeyPEM, encryptionPublicPEM: KeyGen.publicPEM(forPrivate: pending.encryptionKeyPEM),
                                dhParamsPEM: pending.dhParamsPEM)
        consumerKey = pending.consumerKey
        if let keys {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("folio-oauth-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for f in keys.publicFiles { try? f.contents.write(to: dir.appendingPathComponent(f.name), atomically: true, encoding: .utf8) }
            filesDir = dir
        }
        status = "Resuming the registration started earlier with consumer key \(consumerKey)."
    }

    /// Replaces the live credentials only now, when the token is in hand.
    func save() {
        guard let keys else { status = "Generate the keys first."; return }
        let creds = Credentials(consumerKey: consumerKey,
                                accessToken: accessToken.trimmingCharacters(in: .whitespacesAndNewlines),
                                accessTokenSecret: accessTokenSecret.trimmingCharacters(in: .whitespacesAndNewlines),
                                signatureKeyPEM: keys.signaturePrivatePEM, encryptionKeyPEM: keys.encryptionPrivatePEM, dhParamsPEM: keys.dhParamsPEM)
        guard creds.isComplete else { status = "Token and secret are needed before saving."; return }
        do {
            try creds.save()
            Credentials.deletePending()
            finished = true
            NotificationCenter.default.post(name: .credentialsChanged, object: nil)
            PortfolioStore.shared.credentialsChanged()
            status = "Saved. IBKR activates new keys at its next overnight reset; until then a connection test may fail."
            Task { await PortfolioStore.shared.refresh() }
        } catch {
            status = error.localizedDescription
        }
    }
}

extension Notification.Name {
    static let credentialsChanged = Notification.Name("folio.credentialsChanged")
}

struct ConnectView: View {
    @ObservedObject var model: ConnectModel

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Connect to IBKR").font(.title2.weight(.semibold))
                step(1, "Generate keys", done: model.keys != nil) {
                    HStack {
                        Button("Generate keys") { model.generateKeys() }.disabled(model.keys != nil || model.generating)
                        if model.generating { ProgressView().controlSize(.small) }
                    }
                    if model.keys != nil {
                        Button("Save public files…") { model.savePublicFiles() }
                            .help("Only needed if you upload them from Safari instead of this window")
                    }
                }
                step(2, "Consumer key", done: model.uploaded.count == 3) {
                    HStack {
                        TextField("9 uppercase letters", text: $model.consumerKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 130)
                            .onChange(of: model.consumerKey) { model.consumerKey = String($1.uppercased().filter(\.isLetter).prefix(9)) }
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.consumerKey, forType: .string)
                        }
                    }
                    Text("Enter it in the portal. When you click the portal's upload buttons, Folio provides the files in this order:")
                        .font(.caption).foregroundStyle(.secondary)
                    if let keys = model.keys {
                        ForEach(Array(keys.publicFiles.enumerated()), id: \.offset) { i, f in
                            HStack(spacing: 6) {
                                Image(systemName: i < model.nextUpload ? "checkmark.circle.fill" : (i == model.nextUpload ? "arrow.right.circle" : "circle"))
                                    .foregroundStyle(i < model.nextUpload ? .green : .secondary)
                                Text(f.name).font(.system(.caption, design: .monospaced))
                            }
                        }
                        if model.nextUpload > 0 {
                            Button("Start uploads over") { model.nextUpload = 0; model.uploaded = [] }.controlSize(.small)
                        }
                    }
                }
                step(3, "Access token", done: model.finished) {
                    Text("Click the portal's Generate Token. Folio fills these in when the token appears; paste them if it does not.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Access token", text: $model.accessToken).textFieldStyle(.roundedBorder)
                    SecureField("Access token secret", text: $model.accessTokenSecret).textFieldStyle(.roundedBorder)
                    Button("Save") { model.save() }
                        .disabled(model.accessToken.isEmpty || model.accessTokenSecret.isEmpty)
                }
                Spacer()
                Text(model.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(minWidth: 300, idealWidth: 320, maxWidth: 360)

            PortalWebView(model: model)
                .frame(minWidth: 600)
        }
        .frame(minWidth: 960, minHeight: 640)
    }

    private func step<Content: View>(_ n: Int, _ title: String, done: Bool, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle").foregroundStyle(done ? .green : .secondary)
                Text(title).font(.headline)
            }
            content()
        }
    }
}

/// The portal in a WKWebView. The app answers the page's file choosers and polls the page text for the token.
struct PortalWebView: NSViewRepresentable {
    let model: ConnectModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()  // no cookies kept after the window closes
        let web = WKWebView(frame: .zero, configuration: config)
        web.uiDelegate = context.coordinator
        web.navigationDelegate = context.coordinator
        // IBKR's SSO is happier with a mainstream browser identity
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        model.resumePending()
        web.load(URLRequest(url: ConnectModel.portalURL))
        context.coordinator.startPolling(web)
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) { coordinator.stopPolling() }

    @MainActor
    final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate {
        let model: ConnectModel
        private var timer: Timer?

        init(model: ConnectModel) { self.model = model }

        // The page opened a file chooser: hand over the next public file instead of showing a dialog.
        func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping ([URL]?) -> Void) {
            if let url = model.fileForUpload() {
                completionHandler([url])
            } else {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = parameters.allowsMultipleSelection
                completionHandler(panel.runModal() == .OK ? panel.urls : nil)
            }
        }

        // Links that open a new window: load them here instead.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
            return nil
        }

        func startPolling(_ web: WKWebView) {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self, weak web] _ in
                guard let self, let web else { return }
                Task { @MainActor in await self.scan(web) }
            }
        }

        func stopPolling() {
            timer?.invalidate()
            timer = nil
        }

        /// Looks for the token shapes in the page text and form fields, and offers the consumer key to a matching input.
        private func scan(_ web: WKWebView) async {
            guard !model.finished else { return }
            let js = """
            (function () {
              const fields = Array.from(document.querySelectorAll('input, textarea'));
              const text = (document.body ? document.body.innerText : '') + '\\n' + fields.map(f => f.value || '').join('\\n');
              const tokens = text.match(/\\b[0-9a-f]{20}\\b/g) || [];
              const secrets = text.match(/[A-Za-z0-9+\\/]{200,}={0,2}/g) || [];
              const ck = \(jsString(model.consumerKey));
              for (const f of fields) {
                const hint = ((f.placeholder || '') + ' ' + (f.name || '') + ' ' + (f.id || '') + ' ' + (f.getAttribute('aria-label') || '') + ' ' +
                              (f.labels ? Array.from(f.labels).map(l => l.innerText).join(' ') : '')).toLowerCase();
                if (f.type === 'text' && hint.includes('consumer') && !f.value) {
                  const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
                  setter.call(f, ck);
                  f.dispatchEvent(new Event('input', { bubbles: true }));
                  f.dispatchEvent(new Event('change', { bubbles: true }));
                }
              }
              return JSON.stringify({ tokens, secrets });
            })()
            """
            guard let result = try? await web.evaluateJavaScript(js) as? String,
                  let data = result.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] else { return }
            model.detected(tokens: json["tokens"] ?? [], secrets: json["secrets"] ?? [])
        }

        private func jsString(_ s: String) -> String {
            let data = try! JSONSerialization.data(withJSONObject: [s])
            return String(decoding: data, as: UTF8.self).dropFirst().dropLast().description
        }
    }
}
