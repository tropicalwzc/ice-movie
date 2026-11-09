import IceCore
import PersistenceKit
import SMBSession
import SwiftUI

struct ConnectionPrefill {
    let host: String
    let share: String
    let path: String
    let user: String
}

struct LibraryConnection {
    let client: SMBClient
    let host: String
    let share: String
    let path: String
    let user: String
    let password: String
}

struct ConnectionView: View {
    var records: HostRecordStore?
    var credentials: KeychainCredentialStore?
    var prefill: ConnectionPrefill?
    var initialMessage: String?
    var onConnected: ((LibraryConnection) -> Void)?

    @State private var host = ""
    @State private var share = ""
    @State private var path = ""
    @State private var user = ""
    @State private var password = ""

    @State private var shares: [SMBShare] = []
    @State private var entries: [SMBEntry] = []
    @State private var recentHosts: [SavedHost] = []
    @State private var message: String?
    @State private var isBusy = false

    private let client = SMBClient()

    var body: some View {
        Form {
            if !recentHosts.isEmpty {
                Section("最近连接") {
                    ForEach(recentHosts) { record in
                        Button {
                            Task { await connectSaved(record) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(record.address)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(record.displaySubtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isBusy)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                forget(record)
                            } label: {
                                Label("忘记", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                forget(record)
                            } label: {
                                Label("忘记此主机", systemImage: "trash")
                            }
                        }
                    }
                }
            }

            Section("主机") {
                TextField("IP、主机名或 nas.local", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("共享名（留空则枚举全部共享）", text: $share)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("目录路径（留空为共享根）", text: $path)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section("凭据") {
                TextField("用户名", text: $user)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("密码", text: $password)
            }

            Section {
                Button {
                    Task { await connect() }
                } label: {
                    HStack {
                        Text(isBusy ? "连接中…" : "连接")
                        if isBusy {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isBusy || host.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let message {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if !shares.isEmpty {
                Section("共享 \(shares.count)") {
                    ForEach(shares) { item in
                        Button {
                            Task { await connect(shareOverride: item.name) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "externaldrive.connected.to.line.below")
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name)
                                        .foregroundStyle(.primary)
                                    if !item.comment.isEmpty {
                                        Text(item.comment)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !entries.isEmpty {
                Section("目录 \(path.isEmpty ? "/" : path) · \(entries.count) 项") {
                    ForEach(entries) { entry in
                        HStack(spacing: 10) {
                            Image(systemName: entry.isDirectory ? "folder" : "doc")
                                .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if !entry.isDirectory {
                                    Text(Self.subtitle(for: entry))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("连接 SMB")
        .navigationBarTitleDisplayMode(.inline)
        .task { await bootstrap() }
    }

    private static func subtitle(for entry: SMBEntry) -> String {
        let size = ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
        guard let modified = entry.modified else { return size }
        let stamp = modified.formatted(.dateTime.year().month().day())
        return "\(size) · \(stamp)"
    }

    private func bootstrap() async {
        let args = ProcessInfo.processInfo.arguments
        if let value = Self.value(for: "-smbHost", in: args) { host = value }
        if let value = Self.value(for: "-smbShare", in: args) { share = value }
        if let value = Self.value(for: "-smbPath", in: args) { path = value }
        if let value = Self.value(for: "-smbUser", in: args) { user = value }
        if let value = Self.value(for: "-smbPassword", in: args) { password = value }

        if let prefill {
            if host.isEmpty { host = prefill.host }
            if share.isEmpty { share = prefill.share }
            if path.isEmpty { path = prefill.path }
            if user.isEmpty { user = prefill.user }
        }
        if let initialMessage {
            message = initialMessage
        }

        reloadRecentHosts()

        if !host.isEmpty, args.contains("-smbAutoConnect") {
            await connect()
        }
    }

    private func connect(
        shareOverride: String? = nil,
        credentialOverride: HostCredential? = nil
    ) async {
        isBusy = true
        message = nil
        shares = []
        entries = []
        defer { isBusy = false }

        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedShare = (shareOverride ?? share).trimmingCharacters(in: .whitespaces)
        let effectiveUser = credentialOverride?.username ?? user
        let effectivePassword = credentialOverride?.password ?? password
        if let credentialOverride {
            user = credentialOverride.username
            password = credentialOverride.password
        }

        do {
            if trimmedShare.isEmpty {
                shares = try await client.listShares(
                    host: trimmedHost,
                    user: effectiveUser,
                    password: effectivePassword
                )
                if shares.isEmpty {
                    message = "该账号没有可见的共享"
                }
            } else {
                try await client.connect(
                    host: trimmedHost,
                    user: effectiveUser,
                    password: effectivePassword,
                    share: trimmedShare
                )
                entries = try await client.listDirectory(path: path)

                // 连接成功后才写持久化：密码进钥匙串，地址原文与最近路径进 SwiftData。
                if let credentials, !trimmedHost.isEmpty {
                    try? credentials.save(
                        HostCredential(username: effectiveUser, password: effectivePassword),
                        for: trimmedHost
                    )
                }
                if let records, !trimmedHost.isEmpty {
                    try? records.remember(
                        address: trimmedHost,
                        username: effectiveUser,
                        share: trimmedShare,
                        path: path
                    )
                    reloadRecentHosts()
                }

                onConnected?(
                    LibraryConnection(
                        client: client,
                        host: trimmedHost,
                        share: trimmedShare,
                        path: path,
                        user: effectiveUser,
                        password: effectivePassword
                    )
                )
            }
        } catch {
            if let smbError = error as? SMBConnectionError {
                switch smbError {
                case .nameNotResolved, .unreachable:
                    message = "\(smbError.localizedDescription)\n若这是首次连接，请在「设置 > 隐私与安全性 > 本地网络」中允许 IceMovie，然后重试。"
                default:
                    message = smbError.localizedDescription
                }
            } else {
                message = error.localizedDescription
            }
            Log.error(.smb, "连接失败 host=\(trimmedHost) \(error.localizedDescription)")
        }
    }

    private func connectSaved(_ record: SavedHost) async {
        guard let credentials else {
            message = "没有可用的凭据存储"
            return
        }
        do {
            guard let credential = try credentials.credential(for: record.address) else {
                host = record.address
                share = record.share
                path = record.recentPath
                user = record.username
                message = "钥匙串中没有这台主机的密码，请重新输入"
                return
            }
            host = record.address
            share = record.share
            path = record.recentPath
            user = record.username
            await connect(shareOverride: record.share, credentialOverride: credential)
        } catch {
            message = error.localizedDescription
        }
    }

    private func forget(_ record: SavedHost) {
        let address = record.address
        try? records?.forget(address: address)
        try? credentials?.deleteCredential(for: address)
        if host.trimmingCharacters(in: .whitespacesAndNewlines) == address {
            password = ""
        }
        recentHosts.removeAll { $0.address == address }
        reloadRecentHosts()
        message = "已忘记 \(address)"
        Log.info(.app, "已忘记主机 host=\(address)")
    }

    private func reloadRecentHosts() {
        recentHosts = records?.all() ?? []
    }

    private static func value(for flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag) else { return nil }
        let next = args.index(after: index)
        guard next < args.endIndex else { return nil }
        return args[next]
    }
}
