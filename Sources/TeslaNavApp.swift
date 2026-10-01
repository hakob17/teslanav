import SwiftUI
import ReplayKit

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

/// What the app shows: the pairing code, and whether a broadcast is running and watched.
/// The broadcast extension does the actual streaming; it reports back through the App Group.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var pairCode = Shared.pairCode
    @Published private(set) var mirrorLive = false
    @Published private(set) var carsWatching = 0

    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func refresh() {
        let beat = Shared.heartbeatURL.flatMap {
            (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date
        }
        mirrorLive = beat.map { Date().timeIntervalSince($0) < Shared.heartbeatTimeout } ?? false
        carsWatching = mirrorLive ? Shared.carsWatching : 0
    }

    /// A new code disconnects any car paired with the old one (after the next broadcast).
    func newPairCode() {
        pairCode = Shared.newPairCode()
    }
}

// MARK: - UI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var tips: Tips
    @Environment(\.scenePhase) private var scenePhase
    @State private var copied = false
    private let broadcast = BroadcastTrigger()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("HotspotNav").font(.largeTitle.bold())
                    Text("Navigation and your iPhone screen on the car's display.")
                        .foregroundStyle(.secondary)
                }

                carPageCard
                mirrorCard
                howToCard
                supportCard
            }
            .padding(20)
        }
        .background(BroadcastPicker(trigger: broadcast).frame(width: 1, height: 1).opacity(0.01), alignment: .topLeading)
        .onChange(of: scenePhase) { phase in
            if phase == .active { model.refresh() }
        }
    }

    private var carPageCard: some View {
        Card {
            Text("Open in the car's browser").font(.headline)
            Text(Shared.carPageURL)
                .font(.system(.title3, design: .monospaced).bold())
                .foregroundStyle(Color.accentColor)
                .textSelection(.enabled)
            Text("The map, search and turn-by-turn directions run in the car and use its own GPS. Bookmark the page with ☆.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                UIPasteboard.general.string = "https://" + Shared.carPageURL
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy address", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.bordered)
        }
    }

    private var mirrorCard: some View {
        Card {
            Text("Mirror mode").font(.headline)
            Text("Shows this whole screen in the car, so you can drive with Yandex Navigator, Google Maps or Waze and their live traffic. Tap “Phone screen” on the car page and enter this code once:")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Text(Shared.formatted(model.pairCode))
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Button("New code") { model.newPairCode() }
                    .buttonStyle(.bordered)
                    .disabled(model.mirrorLive)
            }
            StatusRow(title: "Broadcast", ok: model.mirrorLive, detail: model.mirrorLive ? "On" : "Off")
            StatusRow(title: "Car watching", ok: model.carsWatching > 0,
                      detail: model.carsWatching > 0 ? "Yes" : (model.mirrorLive ? "Waiting for the car" : "—"))
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
            Text("The screen is sent over the internet through HotspotNav's relay only while the car is watching (about 0.5 GB per hour). Nothing is stored.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var howToCard: some View {
        Card {
            Text("How to use").font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                Text("1. Open the address above in the car's browser and bookmark it. It works on the car's own connection or your iPhone's hotspot.")
                Text("2. Search a destination on the car screen and drive.")
                Text("3. For live traffic, tap Start Broadcast here, open your navigation app, and tap “Phone screen” in the car.")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private var supportCard: some View {
        Card {
            Text("Support HotspotNav").font(.headline)
            Text("HotspotNav is free, with no ads and no accounts. If it makes your drives better, you can buy me a coffee.")
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
            .disabled(tips.purchasing)
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
