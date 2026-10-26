import SwiftUI
import ADBCore

enum Palette {
    static let navy = Color(red: 0.055, green: 0.085, blue: 0.14)
    static let green = adaptive(light: NSColor(srgbRed: 0.08, green: 0.45, blue: 0.28, alpha: 1),
                                dark: NSColor(srgbRed: 0.35, green: 0.83, blue: 0.60, alpha: 1))
    static let warning = adaptive(light: NSColor(srgbRed: 0.56, green: 0.32, blue: 0.02, alpha: 1),
                                  dark: NSColor(srgbRed: 0.96, green: 0.70, blue: 0.32, alpha: 1))
    static let blue = adaptive(light: NSColor(srgbRed: 0.0, green: 0.35, blue: 0.73, alpha: 1),
                               dark: NSColor(srgbRed: 0.42, green: 0.69, blue: 1.0, alpha: 1))
    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

struct RootView: View {
    @ObservedObject var store: AppStore
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                if let error = store.storageError { banner(error, persistent: true) }
                if let notice = store.notice { banner(notice) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        header
                        if !store.adbAvailable && store.page != .settings { adbSetup }
                        switch store.page {
                        case .devices: devicesPage
                        case .discovery: discoveryPage
                        case .settings: settingsPage
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: 1100, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(.blue)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { Task { await store.refresh() } } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    .labelStyle(.titleAndIcon)
                    .disabled(store.busy).help("刷新设备与局域网发现（⌘R）")
                Button { store.addDraft = AddDeviceDraft() } label: { Label("添加设备", systemImage: "plus") }
                    .disabled(store.busy || !store.canSave).help("手动连接或首次配对（⌘N）")
            }
        }
        .sheet(item: $store.addDraft) { draft in AddDeviceSheet(store: store, draft: draft) }
        .sheet(item: $store.renameDevice) { device in RenameSheet(device: device) { store.rename(device, to: $0) } }
        .sheet(isPresented: $store.showHelp) { HelpSheet() }
        .alert("移除这台设备的记录？", isPresented: Binding(get: { store.forgetDevice != nil }, set: { if !$0 { store.forgetDevice = nil } }), presenting: store.forgetDevice) { device in
            Button("取消", role: .cancel) { store.forgetDevice = nil }
            Button("移除记录", role: .destructive) { store.forget(device) }
        } message: { _ in Text("仅移除 Mac 上保存的设备名称与地址，不会撤销手机配对或断开连接。") }
        .onAppear {
            let action = openWindow
            delegate.reopenWindow = { action(id: "main") }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "wifi").font(.system(size: 23, weight: .semibold)).foregroundStyle(Color.mint)
                    .frame(width: 44, height: 44).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 3) {
                    Text("WiFi ADB").font(.system(size: 18, weight: .semibold))
                    Text("无线连接工作台").font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
                }
            }
            .padding(.horizontal, 20).padding(.top, 30).padding(.bottom, 38)
            Text("工作空间").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 24).padding(.bottom, 12)
            ForEach(Page.allCases) { page in
                Button { store.page = page } label: {
                    HStack(spacing: 11) {
                        Image(systemName: page.symbol).font(.system(size: 16)).frame(width: 23)
                        Text(page.rawValue).font(.system(size: 13, weight: store.page == page ? .semibold : .regular))
                        Spacer()
                        if page == .devices && !store.devices.isEmpty {
                            Text("\(store.devices.count)").font(.system(size: 11, weight: .medium)).padding(.horizontal, 7).padding(.vertical, 2)
                                .background(.white.opacity(0.1), in: Capsule())
                        }
                    }
                    .padding(.horizontal, 13).padding(.vertical, 12)
                    .background(store.page == page ? Color.white.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 9))
                    .foregroundStyle(store.page == page ? .white : .white.opacity(0.7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.horizontal, 12).padding(.bottom, 5)
                .accessibilityAddTraits(store.page == page ? .isSelected : [])
            }
            Spacer(minLength: 24)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 7) {
                    Circle().fill(store.adbAvailable ? Color.mint : Color.orange).frame(width: 6, height: 6)
                    Text(store.adbAvailable ? "本机 adb 已就绪" : "需要配置 adb").font(.system(size: 11))
                }.foregroundStyle(.white.opacity(0.8))
                Button { store.showHelp = true } label: { Label("连接帮助", systemImage: "questionmark.circle").font(.system(size: 12)) }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6))
            }
            .padding(24)
        }
        .frame(width: 204).frame(maxHeight: .infinity)
        .background(Palette.navy).foregroundStyle(.white)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(store.page.rawValue).font(.system(size: 27, weight: .bold))
                Spacer()
                if store.page == .devices {
                    Label("本地管理", systemImage: "lock.shield").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Text(store.page.subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }

    private var devicesPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 12) {
                summary("已保存", value: store.devices.count, symbol: "bookmark", color: .blue)
                summary("无线在线", value: store.connectedCount, symbol: "checkmark.circle", color: Palette.green)
                summary("发现的服务", value: store.connectServices.count, symbol: "dot.radiowaves.left.and.right", color: .blue)
            }
            if !store.snapshot.transports.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeading("当前连接", trailing: "\(store.snapshot.transports.count) 条连接 · 同一设备可同时使用 USB 和无线")
                    transportsCard
                }
            }
            if store.devices.isEmpty && store.snapshot.transports.isEmpty {
                emptyState(symbol: "iphone.gen3.radiowaves.left.and.right", title: "让下一次连接，更简单", detail: "添加并保存你的 Android 设备。\n之后点击「一键重连」，自动查找地址并验证身份。") {
                    Button("添加第一台设备") { store.addDraft = AddDeviceDraft() }.buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(store.busy || !store.canSave)
                }
            } else if !store.devices.isEmpty {
                sectionHeading("常用设备", trailing: "仅在点击时发起连接")
                VStack(spacing: 12) { ForEach(store.devices) { savedCard($0) } }
            }
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "info.circle").foregroundStyle(.blue)
                Text("保持手机与 Mac 网络互通，并开启无线调试。配对端口与连接端口不同，端口变化后可优先尝试一键重连。")
                    .foregroundStyle(.secondary)
            }.font(.system(size: 12)).lineSpacing(3)
        }
    }

    private func summary(_ label: String, value: Int, symbol: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(color)
                .frame(width: 37, height: 37).background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text("\(value)").font(.system(size: 22, weight: .semibold, design: .rounded))
                Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16).frame(maxWidth: .infinity).cardSurface()
    }

    private func savedCard(_ device: SavedDevice) -> some View {
        let state = store.status(device)
        let active = store.activeDeviceID == device.id
        return VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: "iphone.gen3").font(.system(size: 25)).foregroundStyle(.blue)
                    .frame(width: 48, height: 52).background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 7) {
                    Text(device.name).font(.system(size: 16, weight: .semibold)).lineLimit(2)
                    HStack(spacing: 6) {
                        Circle().fill(stateColor(state)).frame(width: 6, height: 6)
                        Text(active ? "正在验证并重连…" : stateText(state)).font(.system(size: 12)).foregroundStyle(stateColor(state))
                    }
                }
                Spacer(minLength: 8)
                Menu {
                    Button("重命名", systemImage: "pencil") { store.renameDevice = device }
                    Button("移除记录…", systemImage: "bookmark.slash") { store.forgetDevice = device }
                } label: { Image(systemName: "ellipsis").frame(width: 20, height: 24).accessibilityLabel("\(device.name) 的更多操作") }
                    .menuStyle(.borderlessButton).fixedSize().disabled(store.busy || !store.canSave)
            }
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("上次地址  \(device.lastEndpoint.description)").font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    Text("上次成功  \(device.lastConnected.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if case .connected(let transport) = state {
                    if transport.isWireless {
                        Button("断开") { Task { await store.disconnect(transport) } }.disabled(store.busy)
                            .accessibilityLabel("断开 \(device.name)")
                            .help("直接断开此连接；其他共享 adb 的工具也会断开这台设备。")
                    }
                } else {
                    Button { Task { await store.reconnect(device) } } label: {
                        HStack(spacing: 6) {
                            if active { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                            Text(active ? "正在重连" : "一键重连")
                        }
                    }.buttonStyle(.borderedProminent).controlSize(.large).disabled(store.busy || !store.canSave)
                }
            }
        }.padding(20).cardSurface()
    }

    private var discoveryPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !store.snapshot.discoveryAvailable { inlineNote("局域网发现暂不可用，仍可通过「添加设备」输入当前地址。", symbol: "antenna.radiowaves.left.and.right.slash") }
            if store.connectServices.isEmpty {
                emptyState(symbol: "dot.radiowaves.left.and.right", title: "尚未发现无线设备", detail: "在手机上打开「开发者选项 → 无线调试」，然后点击右上角「刷新」。\n确认网络互通，也可以手动输入连接地址。") {
                    Button("手动添加设备") { store.addDraft = AddDeviceDraft() }.buttonStyle(.bordered).disabled(store.busy)
                }
            } else {
                sectionHeading("局域网连接服务", trailing: "发现不代表已连接")
                ForEach(store.connectServices) { service in
                    let online = store.snapshot.transports.first { $0.state == .device && service.matches(transport: $0) }
                    let saved = online.flatMap { store.verified[$0.id] }.map { serial in store.devices.contains { $0.hardwareSerial == serial } } ?? false
                    HStack(spacing: 14) {
                        Image(systemName: "wifi").font(.system(size: 20)).foregroundStyle(.blue).frame(width: 36)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(service.endpoint.description).font(.system(size: 13, weight: .medium, design: .monospaced)).textSelection(.enabled)
                            Text(service.name).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Text(online == nil ? "可连接" : (saved ? "已连接 · 已保存" : "ADB 已在线"))
                                .font(.system(size: 11)).foregroundStyle(online == nil ? Color.secondary : Palette.green)
                        }
                        Spacer(minLength: 8)
                        if saved {
                            Button("查看设备") { store.page = .devices }
                        } else if let online {
                            Button("保存设备") { Task { await store.save(online) } }.disabled(store.busy || !store.canSave)
                        } else {
                            Button("连接") { Task { await store.connectDiscovered(service) } }
                                .buttonStyle(.borderedProminent).disabled(store.busy || !store.canSave)
                        }
                    }.padding(18).cardSurface()
                }
            }
            if !store.snapshot.transports.isEmpty { sectionHeading("adb 当前设备", trailing: "USB / 模拟器 / 无线"); transportsCard }
        }
    }

    private var transportsCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(store.snapshot.transports.enumerated()), id: \.element.id) { index, transport in
                if index > 0 { Divider().padding(.horizontal, 18) }
                HStack(spacing: 12) {
                    Image(systemName: transport.isEmulator ? "desktopcomputer" : (transport.isWireless ? "wifi" : "cable.connector"))
                        .foregroundStyle(.secondary).frame(width: 24)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(transport.displayName).font(.system(size: 13, weight: .medium))
                        Text(transport.id).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Text("\(transport.isEmulator ? "模拟器" : (transport.isWireless ? "无线" : "USB")) · \(transportState(transport))")
                            .font(.system(size: 11)).foregroundStyle(transport.state == .device ? Palette.green : Palette.warning)
                    }
                    Spacer(minLength: 8)
                    if transport.isWireless && transport.state == .device {
                        let saved = store.verified[transport.id].map { serial in store.devices.contains(where: { $0.hardwareSerial == serial }) } ?? false
                        if !saved {
                            Button("验证并保存") { Task { await store.save(transport) } }.disabled(store.busy || !store.canSave)
                        }
                        Button("断开") { Task { await store.disconnect(transport) } }.disabled(store.busy)
                            .accessibilityLabel("断开当前连接 \(transport.displayName)")
                    }
                }.padding(18)
            }
        }.cardSurface()
    }

    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 18) {
                Label("ADB 工具", systemImage: "terminal").font(.system(size: 16, weight: .semibold))
                Text("使用已安装的 Android SDK Platform-Tools，无需下载额外组件。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    Text("可执行文件").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Text(store.adbURL?.path ?? "尚未找到 adb").font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12).background(Color(nsColor: .quaternaryLabelColor).opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                }
                HStack {
                    Label(store.adbVersion.map { "ADB \($0)" } ?? (store.adbAvailable ? "路径已找到，等待验证" : "需要选择 adb"),
                          systemImage: store.adbVersion == nil ? "info.circle" : "checkmark.circle.fill")
                        .font(.system(size: 12)).foregroundStyle(store.adbVersion == nil ? Color.secondary : Palette.green)
                    Spacer()
                    Button("选择 adb…") { store.selectADB() }.disabled(store.busy || store.pathOverride)
                }
                if store.pathOverride { Text("当前路径由 WIFIADB_ADB_PATH 指定。修改环境变量后重新启动可切换。").font(.system(size: 11)).foregroundStyle(.secondary) }
            }.padding(22).cardSurface()
            VStack(alignment: .leading, spacing: 16) {
                Label("本地与隐私", systemImage: "lock.shield").font(.system(size: 16, weight: .semibold))
                Text("设备名称、硬件身份、最近地址和成功时间仅保存在本机。配对码只通过标准输入发送给 adb，不会保存。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                Text(store.storage.directory.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                Divider()
                Text("启动时读取一次状态；之后点击「刷新」或按 ⌘R 更新。连接、保存和断开操作后更新结果，空闲时不定时扫描或唤醒。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
            }.padding(22).cardSurface()
            Button { store.showHelp = true } label: { Label("查看连接与重连帮助", systemImage: "questionmark.circle") }.buttonStyle(.link)
        }
    }

    private var adbSetup: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "terminal").font(.system(size: 22)).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 7) {
                Text("先选择本机 adb").font(.system(size: 14, weight: .semibold))
                Text("自动查找常用 Android SDK 与 Homebrew 路径。找不到时，可在设置中指定 adb。").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("前往设置") { store.page = .settings }
        }.padding(18).background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
    private var footer: some View {
        HStack(spacing: 8) {
            if store.busy { ProgressView().controlSize(.mini); Text(store.activity) }
            else { Image(systemName: "leaf").font(.system(size: 10)); Text("手动刷新 · 空闲时不扫描") }
            Spacer()
            if let date = store.lastRefresh { Text("上次读取 \(date.formatted(date: .omitted, time: .standard))") }
        }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 28).padding(.vertical, 11)
            .background(.bar)
    }
    private func banner(_ message: String, persistent: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            Text(message).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            if !persistent { Button { store.notice = nil } label: { Image(systemName: "xmark").accessibilityLabel("关闭提示") }.buttonStyle(.plain) }
        }.padding(14).background(.orange.opacity(0.09))
    }
    private func inlineNote(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
    }
    private func sectionHeading(_ title: String, trailing: String) -> some View {
        HStack { Text(title).font(.system(size: 14, weight: .semibold)); Spacer(); Text(trailing).font(.system(size: 11)).foregroundStyle(.secondary) }
    }
    private func emptyState<Actions: View>(symbol: String, title: String, detail: String, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 15) {
            Image(systemName: symbol).font(.system(size: 37, weight: .light)).foregroundStyle(.blue)
                .frame(width: 92, height: 92).background(.blue.opacity(0.06), in: Circle())
            Text(title).font(.system(size: 19, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
            actions().padding(.top, 5)
        }.padding(36).frame(maxWidth: .infinity).cardSurface()
    }
    private func stateColor(_ status: SavedConnectionStatus) -> Color {
        switch status { case .connected: return Palette.green; case .discovered: return Palette.blue; case .offline, .unauthorized: return Palette.warning; case .unavailable: return .secondary }
    }
    private func stateText(_ status: SavedConnectionStatus) -> String {
        switch status {
        case .connected: return "已连接 · 身份已关联"
        case .discovered: return "已发现 · 尚未连接"
        case .offline: return "设备离线"
        case .unauthorized: return "等待设备授权"
        case .unavailable: return "未连接 · 可尝试重连"
        }
    }
    private func transportState(_ transport: ADBTransport) -> String {
        switch transport.state { case .device: return "已连接"; case .offline: return "离线"; case .unauthorized: return "未授权"; case .unknown: return "其他状态" }
    }
}

private struct CardSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.primary.opacity(0.065), lineWidth: 1))
    }
}
extension View { func cardSurface() -> some View { modifier(CardSurface()) } }
