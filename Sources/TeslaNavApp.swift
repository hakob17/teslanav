import SwiftUI
import ReplayKit
import CoreLocation
import Combine

@main
struct TeslaNavApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var tips = Tips()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(tips)
                .preferredColorScheme(.dark)
                .task { await tips.load() }
        }
    }
}

// MARK: - Model

@MainActor
final class AppModel: ObservableObject {
    let location = LocationService()
    let frames = FrameStore()
    let server: WebServer

    @Published private(set) var serverReady = false
    @Published private(set) var addresses: [NetworkInfo.Address] = []
    @Published private(set) var mirrorLive = false
    @Published private(set) var lastCarRequest: Date?
    @Published private(set) var streamCount = 0
    @Published private(set) var now = Date()

    private var timer: Timer?
    private var locationChanges: AnyCancellable?

    init() {
        server = WebServer(location: location, frames: frames)
        // Views read GPS state through the model, so re-render when it changes.
        locationChanges = location.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        location.start()
        frames.start()
        server.start()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func refresh() {
        now = Date()
        serverReady = server.isReady
        addresses = NetworkInfo.ipv4Addresses()
        mirrorLive = frames.isLive
        lastCarRequest = server.lastRequest
        streamCount = server.streamCount
    }

    func becameActive() {
        server.ensureRunning()
        location.start()
        refresh()
    }

    /// The address to type into the car. The hotspot bridge is almost always 172.20.10.1,
    /// but only shows up once a device has joined, so fall back to that.
    var carURL: String {
        let ip = addresses.first(where: \.isHotspot)?.ip ?? "172.20.10.1"
        return "http://\(ip):\(WebServer.port)"
    }

    var hotspotConnected: Bool { addresses.contains(where: \.isHotspot) }
}

// MARK: - Hotspot IP lookup

enum NetworkInfo {
    struct Address: Hashable {
        let interface: String
        let ip: String
        /// iOS puts Personal Hotspot clients on a `bridge…` interface.
        var isHotspot: Bool { interface.hasPrefix("bridge") }
    }

    static func ipv4Addresses() -> [Address] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }

        var result: [Address] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("bridge") || name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            result.append(Address(interface: name, ip: String(cString: host)))
        }
        return result.sorted { ($0.isHotspot ? 0 : 1, $0.interface) < ($1.isHotspot ? 0 : 1, $1.interface) }
    }
}

// MARK: - UI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var tips: Tips
    private var location: LocationService { model.location }
    @Environment(\.scenePhase) private var scenePhase
    @State private var copied = false
    private let broadcast = BroadcastTrigger()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("TeslaNav").font(.largeTitle.bold())
                    Text("Navigation on the car screen, served from this iPhone.")
                        .foregroundStyle(.secondary)
                }

                urlCard
                statusCard
                mirrorCard
                howToCard
                supportCard
            }
            .padding(20)
        }
        .background(BroadcastPicker(trigger: broadcast).frame(width: 1, height: 1).opacity(0.01), alignment: .topLeading)
        .onChange(of: scenePhase) { phase in
            if phase == .active { model.becameActive() }
        }
    }

    private var urlCard: some View {
        Card {
            Text("Open in the Tesla browser").font(.headline)
            Text(model.carURL)
                .font(.system(.title2, design: .monospaced).bold())
                .foregroundStyle(Color.accentColor)
                .textSelection(.enabled)
            if !model.hotspotConnected && !carConnected {
                Label("Turn on Personal Hotspot and connect the car to it.", systemImage: "personalhotspot")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
            Button {
                UIPasteboard.general.string = model.carURL
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy address", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.bordered)
        }
    }

    private var statusCard: some View {
        Card {
            Text("Status").font(.headline)
            StatusRow(title: "Server", ok: model.serverReady,
                      detail: model.serverReady ? "Listening on :\(WebServer.port)" : "Starting…")
            StatusRow(title: "iPhone GPS", ok: gpsOK, detail: gpsDetail)
            StatusRow(title: "Car", ok: carConnected, detail: carDetail)
            StatusRow(title: "Screen mirror", ok: model.mirrorLive,
                      detail: model.mirrorLive ? "Broadcasting · \(model.streamCount) viewer(s)" : "Off")
            if location.authorization == .denied || location.authorization == .restricted {
                Button("Allow location in Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var mirrorCard: some View {
        Card {
            Text("Mirror mode").font(.headline)
            Text("Shows this whole screen in the car, so you can drive with Yandex Navigator, Google Maps or Waze and their live traffic. Start it here, then tap “Phone screen” in the car.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                broadcast.fire()
            } label: {
                Label(model.mirrorLive ? "Stop Broadcast" : "Start Broadcast",
                      systemImage: model.mirrorLive ? "stop.circle.fill" : "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.mirrorLive ? .red : .accentColor)
            .controlSize(.large)
        }
    }

    private var howToCard: some View {
        Card {
            Text("How to use").font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                Text("1. Turn on Personal Hotspot and join it from the car's Wi‑Fi.")
                Text("2. Open the address above in the Tesla browser and bookmark it.")
                Text("3. Search a destination on the car screen and drive. You can switch apps or lock the phone — TeslaNav keeps serving.")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private var supportCard: some View {
        Card {
            Text("Support TeslaNav").font(.headline)
            Text("TeslaNav is free, with no ads and no accounts. If it makes your drives better, you can buy me a coffee.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                Task { await tips.buyCoffee() }
            } label: {
                Label(tips.displayPrice.map { "Buy me a coffee · \($0)" } ?? "Buy me a coffee",
                      systemImage: "cup.and.saucer.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 1, green: 0.867, blue: 0))
            .foregroundStyle(.black)
            .controlSize(.large)
            .disabled(tips.product == nil || tips.purchasing)
            if tips.thanked {
                Label("Thank you for the coffee! ☕️", systemImage: "heart.fill")
                    .font(.subheadline)
                    .foregroundStyle(.pink)
            }
            if let failure = tips.failure {
                Text(failure).font(.footnote).foregroundStyle(.orange)
            }
        }
    }

    private var gpsOK: Bool {
        guard let fix = location.lastFix else { return false }
        return model.now.timeIntervalSince(fix.timestamp) < 10
    }

    private var gpsDetail: String {
        switch location.authorization {
        case .denied, .restricted: return "Location access denied"
        case .notDetermined: return "Waiting for permission"
        default: break
        }
        guard let fix = location.lastFix else { return "Searching…" }
        let age = Int(model.now.timeIntervalSince(fix.timestamp))
        return "±\(Int(fix.horizontalAccuracy)) m · \(age) s ago"
    }

    private var carConnected: Bool {
        guard let last = model.lastCarRequest else { return false }
        return model.now.timeIntervalSince(last) < 5
    }

    private var carDetail: String {
        guard let last = model.lastCarRequest else { return "Not connected yet" }
        let age = Int(model.now.timeIntervalSince(last))
        return age < 5 ? "Connected" : "Last seen \(age) s ago"
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
    }
}

private struct StatusRow: View {
    let title: String
    let ok: Bool
    let detail: String
    var body: some View {
        HStack {
            Circle().fill(ok ? Color.green : Color.gray).frame(width: 10, height: 10)
            Text(title)
            Spacer()
            Text(detail).foregroundStyle(.secondary).font(.subheadline)
        }
    }
}

// MARK: - Broadcast picker

/// The system broadcast picker only starts a broadcast from its own button, so keep one
/// invisible in the hierarchy and tap it on the user's behalf from our own button.
final class BroadcastTrigger {
    weak var picker: RPSystemBroadcastPickerView?
    func fire() {
        picker?.subviews.compactMap { $0 as? UIButton }.first?.sendActions(for: .touchUpInside)
    }
}

struct BroadcastPicker: UIViewRepresentable {
    let trigger: BroadcastTrigger

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.preferredExtension = Shared.broadcastExtensionID
        picker.showsMicrophoneButton = false
        trigger.picker = picker
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        trigger.picker = uiView
    }
}
