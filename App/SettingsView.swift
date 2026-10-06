import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var store: PortfolioStore
    @AppStorage("pollMinutes") private var pollMinutes = 5
    @State private var creds = Credentials.load() ?? Credentials()
    @State private var saved = Credentials.load()
    @State private var status: String?
    @State private var statusIsError = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var importEnv = "live"
    @State private var pickingFolder = false
    @State private var pickingKey: KeyField?

    private enum KeyField: String, Identifiable {
        case signature = "Signature key", encryption = "Encryption key", dh = "DH parameters"
        var id: String { rawValue }
    }

    private var appName: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Folio" }
    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return short == "0.0.0" ? "development build" : "\(short) (\(build))"  // 0.0.0 = built from the project, not released
    }

    var body: some View {
        Form {
            Section("Status") {
                if let p = store.portfolio {
                    LabeledContent("Account", value: "\(p.account) · \(Fmt.money(p.nav, p.currency))")
                    LabeledContent("Last update") {
                        HStack(spacing: 4) {
                            Text(p.fetchedDate, style: .time)
                            if let n = store.nextPoll, !store.refreshing {
                                Text("· next \(n, style: .time)").foregroundStyle(.secondary)
                            }
                            if store.refreshing { ProgressView().controlSize(.mini) }
                        }
                    }
                } else if saved == nil {
                    Text("Not connected. Add your IBKR OAuth credentials below.").foregroundStyle(.secondary)
                }
                if let e = store.lastError {
                    Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
                }
                HStack {
                    Button("Refresh now") { Task { await store.refresh() } }.disabled(store.refreshing || saved == nil)
                    Spacer()
                    Button("Quit \(appName)") { NSApplication.shared.terminate(nil) }
                        .help("Stops background polling; the widget keeps its last data")
                }
                Text("Widget: right-click the desktop → Edit Widgets → \(appName). Closing this window keeps \(appName) running in the background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Version") {
                    HStack(spacing: 6) {
                        Text("\(appName) \(version)")
                        Link("Releases", destination: URL(string: "https://github.com/usatenko/folio/releases")!)
                            .font(.caption)
                    }
                }
            }
            Section("IBKR OAuth credentials") {
                HStack {
                    Button("Connect to IBKR…") { AppDelegate.shared.openConnect() }
                    Text("Generates the keys and walks you through IBKR's portal.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                TextField("Consumer key", text: $creds.consumerKey)
                TextField("Access token", text: $creds.accessToken)
                SecureField("Access token secret", text: $creds.accessTokenSecret)
                keyRow(.signature, pem: creds.signatureKeyPEM)
                keyRow(.encryption, pem: creds.encryptionKeyPEM)
                keyRow(.dh, pem: creds.dhParamsPEM)
                HStack {
                    Picker("", selection: $importEnv) {
                        Text("live").tag("live")
                        Text("paper").tag("papr")
                    }
                    .labelsHidden()
                    .frame(width: 90)
                    Button("Import from folder…") { pickingFolder = true }
                    Spacer()
                }
                Text("Import reads ibkr_env_<live|papr> and the key files it names. Everything is kept in your login Keychain; the files are not needed afterwards.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Getting credentials from IBKR") {
                Link(destination: URL(string: "https://ndcdyn.interactivebrokers.com/sso/Login?action=OAUTH&RL=1")!) {
                    Label("Open the IBKR OAuth self-service portal", systemImage: "arrow.up.right.square")
                }
                DisclosureGroup("How to register and generate the keys") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("1. Generate the keys on your Mac (Terminal), then keep the private files safe:")
                    Text(Self.opensslCommands)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    Text("2. In the portal, log in with your live username, choose a consumer key (9 uppercase letters) and upload the three public files: signature.pub.pem, encryption.pub.pem and dhparam.pem.")
                    Text("3. Generate the access token: the portal shows the token and its secret once. Paste them above, choose the two private .pem files and dhparam.pem, then Test and Save.")
                    Text("New consumer keys and tokens can take until IBKR's next overnight reset to start working.")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                HStack {
                    Button("Copy commands") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.opensslCommands, forType: .string)
                    }
                    Spacer()
                }
                }
            }
            Section("App") {
                Picker("Poll IBKR every", selection: $pollMinutes) {
                    Text("1 minute").tag(1)
                    Text("5 minutes").tag(5)
                    Text("15 minutes").tag(15)
                }
                .onChange(of: pollMinutes) { store.startPolling() }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { toggleLogin($1) }

                Text("Read-only access: \(appName) never opens a trading session, so TWS and the mobile app stay connected. Widgets update within about 15 minutes of each poll.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Test connection") { Task { await test() } }
                        .disabled(!creds.isComplete)
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!creds.isComplete || creds == saved)
                    if saved != nil {
                        Button("Forget credentials", role: .destructive) { forget() }
                    }
                    Spacer()
                }
                if let status {
                    Text(status).foregroundStyle(statusIsError ? .red : .green).font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 640)  // fixed height; the grouped form scrolls
        .onReceive(NotificationCenter.default.publisher(for: .credentialsChanged)) { _ in
            creds = Credentials.load() ?? Credentials()
            saved = Credentials.load()
        }
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { importFolder($0) }
        .fileImporter(isPresented: Binding(get: { pickingKey != nil }, set: { if !$0 { pickingKey = nil } }),
                      allowedContentTypes: [.item]) { importKey($0) }
    }

    static let opensslCommands = """
    mkdir -p ~/.ibkr && cd ~/.ibkr
    openssl genrsa -out signature.pem 2048 && openssl rsa -in signature.pem -pubout -out signature.pub.pem
    openssl genrsa -out encryption.pem 2048 && openssl rsa -in encryption.pem -pubout -out encryption.pub.pem
    openssl dhparam -out dhparam.pem 2048
    """

    private func keyRow(_ field: KeyField, pem: String) -> some View {
        LabeledContent(field.rawValue) {
            HStack {
                if pem.isEmpty {
                    Text("missing").foregroundStyle(.secondary)
                } else if let label = try? PEM.decode(pem).label {
                    Label(label, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Label("not a PEM file", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                }
                Spacer()
                Button("Choose…") { pickingKey = field }
            }
        }
    }

    private func importFolder(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            guard url.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
            defer { url.stopAccessingSecurityScopedResource() }
            creds = try Credentials.importFolder(url, env: importEnv)
            show("Imported from \(url.lastPathComponent). Test, then Save.", error: false)
        } catch {
            show(error.localizedDescription, error: true)
        }
    }

    private func importKey(_ result: Result<URL, Error>) {
        guard let field = pickingKey else { return }
        do {
            let url = try result.get()
            guard url.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
            defer { url.stopAccessingSecurityScopedResource() }
            let text = try String(contentsOf: url, encoding: .utf8)
            switch field {
            case .signature: creds.signatureKeyPEM = text
            case .encryption: creds.encryptionKeyPEM = text
            case .dh: creds.dhParamsPEM = text
            }
        } catch {
            show(error.localizedDescription, error: true)
        }
    }

    private func test() async {
        do {
            let client = try IBKRClient(credentials: creds)
            let p = try await PortfolioStore.fetch(client)
            show("Connected: account \(p.account), \(Fmt.money(p.nav, p.currency))", error: false)
        } catch {
            show(error.localizedDescription, error: true)
        }
    }

    private func save() {
        do {
            try creds.save()
            saved = creds
            store.credentialsChanged()
            show("Saved to Keychain.", error: false)
            Task { await store.refresh() }
        } catch {
            show(error.localizedDescription, error: true)
        }
    }

    private func forget() {
        Credentials.delete()
        creds = Credentials()
        saved = nil
        store.credentialsChanged()
        show("Credentials removed from Keychain.", error: false)
    }

    private func toggleLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            show(error.localizedDescription, error: true)
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func show(_ text: String, error: Bool) {
        status = text
        statusIsError = error
    }
}
