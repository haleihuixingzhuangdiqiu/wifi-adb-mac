import SwiftUI
import ADBCore

struct AddDeviceSheet: View {
    @ObservedObject var store: AppStore
    let draft: AddDeviceDraft
    @Environment(\.dismiss) private var dismiss
    @State private var pairing = false
    @State private var paired = false
    @State private var host = ""
    @State private var port = ""
    @State private var pairingPort = ""
    @State private var code = ""
    @State private var name = ""
    @State private var error: String?
    @State private var submitted = false
    @FocusState private var focus: Field?
    private enum Field { case host, port, pairingPort, code, name }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right").font(.system(size: 27)).foregroundStyle(.blue)
                    .frame(width: 52, height: 52).background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 6) {
                    Text("添加设备").font(.system(size: 22, weight: .bold))
                    Text("连接后验证硬件身份，并保存到「我的设备」。").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Picker("连接方式", selection: $pairing) {
                Text("已配对直接连接").tag(false)
                Text("首次配对").tag(true)
            }.pickerStyle(.segmented).disabled(store.busy || paired)
            VStack(alignment: .leading, spacing: 17) {
                HStack(alignment: .top, spacing: 14) {
                    input("主机名或 IP", hint: "192.168.1.100") {
                        TextField("192.168.1.100", text: $host).focused($focus, equals: .host)
                    }.frame(maxWidth: .infinity)
                    input("连接端口", hint: "无线调试主页") {
                        TextField("例如 37123", text: $port).focused($focus, equals: .port)
                    }.frame(width: 150)
                }
                if pairing && !paired {
                    VStack(alignment: .leading, spacing: 13) {
                        Label("配对信息", systemImage: "lock.shield").font(.system(size: 13, weight: .semibold))
                        Text("手机：无线调试 → 使用配对码配对设备。该窗口显示的是配对端口；上方连接端口来自无线调试主页。")
                            .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
                        HStack(alignment: .top, spacing: 14) {
                            input("配对端口", hint: "配对弹窗中的端口") {
                                TextField("例如 40217", text: $pairingPort).focused($focus, equals: .pairingPort)
                            }
                            input("六位配对码", hint: "仅发送给本机 adb，不保存") {
                                SecureField("六位数字", text: $code).focused($focus, equals: .code)
                                    .onChange(of: code) { _, value in code = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6)) }
                            }
                        }
                    }.padding(16).background(.blue.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                }
                if paired {
                    Label("配对已成功。可修改连接端口后继续，无需再次输入配对码。", systemImage: "checkmark.shield")
                        .font(.system(size: 12)).foregroundStyle(Palette.green)
                }
                input("设备名称（可选）", hint: "留空时使用设备型号，可稍后重命名") {
                    TextField("例如：我的 Pixel", text: $name).focused($focus, equals: .name)
                        .onChange(of: name) { _, value in name = String(value.prefix(120)) }
                }
            }
            .disabled(store.busy)
            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill").font(.system(size: 12)).foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            } else {
                Label("配对端口不能用作连接端口。需要 Android 11 或更新版本的无线调试支持。", systemImage: "info.circle")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                if store.busy { ProgressView().controlSize(.small); Text(store.activity).font(.system(size: 12)).foregroundStyle(.secondary) }
                Spacer()
                Button("取消") { code = ""; dismiss() }.keyboardShortcut(.cancelAction).disabled(store.busy)
                Button(pairing && !paired ? "配对并连接" : "连接并保存") { submit() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(store.busy || submitted || !store.adbAvailable)
            }
        }
        .textFieldStyle(.roundedBorder).controlSize(.large).padding(28).frame(width: 560)
        .interactiveDismissDisabled(store.busy)
        .onAppear { host = draft.host; port = draft.port; focus = host.isEmpty ? .host : .name }
        .onDisappear { code = "" }
        .onChange(of: pairing) { _, _ in code = ""; error = nil }
    }

    private func input<Content: View>(_ label: String, hint: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.system(size: 12, weight: .medium))
            content().font(.system(size: 13)).accessibilityLabel(label)
            Text(hint).font(.system(size: 10)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func submit() {
        guard !submitted, !store.busy else { return }
        do {
            _ = try Endpoint(host: host, portText: port)
            if pairing && !paired {
                _ = try Endpoint(host: host, portText: pairingPort)
                guard code.count == 6 else { throw ADBError.invalidCode }
            }
        } catch {
            self.error = (error as? ADBError ?? .invalidEndpoint).localizedDescription
            return
        }
        let secret = code
        code = "" // Clear the field immediately, before the in-flight command is created.
        error = nil; submitted = true
        Task {
            let result = await store.add(host: host, port: port, name: name, pairPort: pairing && !paired ? pairingPort : nil, code: secret) { paired = true }
            submitted = false; code = ""
            if let result { error = result; focus = paired ? .port : (pairing ? .code : .port) }
            else { dismiss() }
        }
    }
}

struct RenameSheet: View {
    let device: SavedDevice
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("重命名设备").font(.system(size: 20, weight: .semibold))
            TextField("设备名称", text: $name).textFieldStyle(.roundedBorder).focused($focused).onSubmit { commit() }
                .onChange(of: name) { _, value in name = String(value.prefix(120)) }
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Button("保存") { commit() }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(26).frame(width: 380).onAppear { name = device.name; focused = true }
    }
    private func commit() { guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }; save(name); dismiss() }
}

struct HelpSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 23) {
            Label("连接与重连", systemImage: "wifi").font(.system(size: 23, weight: .semibold))
            help("1", title: "第一次：配对并保存", body: "在手机开发者选项中开启无线调试，打开「使用配对码配对设备」。输入配对端口和六位码，再用无线调试主页上的连接端口连接。")
            help("2", title: "下一次：一键重连", body: "点击保存设备上的「一键重连」。应用会重新发现连接服务，并核对硬件序列号；端口变化后也可重新找到同一台设备。")
            help("3", title: "连接不上时", body: "确认 Mac 和手机网络互通、无线调试仍开启。VPN、访客网络与路由器隔离可能阻止发现；可手动输入当前地址。未授权时在手机确认；身份无法验证时通过「添加设备」重新绑定。")
            Divider()
            Text("「已发现」不等于已连接。忘记设备只移除本地记录；断开无线连接会影响共享 adb 的其他工具。USB 和模拟器仅显示状态，不提供 Wi-Fi 断开操作。")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
            HStack { Spacer(); Button("知道了") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(30).frame(width: 540)
    }
    private func help(_ number: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number).font(.system(size: 12, weight: .semibold)).foregroundStyle(.blue)
                .frame(width: 25, height: 25).background(.blue.opacity(0.09), in: Circle())
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(body).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
            }
        }
    }
}
