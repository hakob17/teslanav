import UIKit
import SwiftUI
import UniformTypeIdentifiers

/// "Share → HotspotNav" from Yandex Maps, Google Maps, Apple Maps or any text with coordinates:
/// finds the place and sends it to the car page, which starts navigating to it.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .systemBackground
        let host = UIHostingController(rootView: ShareView(model: model) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        })
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        Task { await model.run(items: extensionContext?.inputItems as? [NSExtensionItem] ?? []) }
    }
}

@MainActor
final class ShareModel: ObservableObject {
    enum State: Equatable {
        case finding
        case sending(SharedPlace)
        case delivered(SharedPlace)
        case queued(SharedPlace)
        case notFound(String)
        case failed(String)
    }
    @Published var state = State.finding

    func run(items: [NSExtensionItem]) async {
        var text: String?
        var url: URL?
        for item in items {
            if let t = item.attributedContentText?.string, !t.isEmpty { text = [text, t].compactMap { $0 }.joined(separator: "\n") }
            for provider in item.attachments ?? [] {
                // From Safari: the page's current address, from PageURL.js.
                if provider.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier),
                   let dict = try? await provider.loadItem(forTypeIdentifier: UTType.propertyList.identifier) as? [String: Any],
                   let results = dict[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any],
                   let page = (results["url"] as? String).flatMap(URL.init(string:)) {
                    url = page
                    continue
                }
                if url == nil, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let u = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                    url = u
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let t = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                    text = [text, t].compactMap { $0 }.joined(separator: "\n")
                }
            }
        }
        guard let place = await PlaceLink.place(fromText: text, url: url) else {
            state = .notFound([url?.absoluteString, text].compactMap { $0 }.joined(separator: "\n"))
            return
        }
        state = .sending(place)
        do {
            switch try await PlaceSender.send(place, room: Shared.pairCode) {
            case .delivered: state = .delivered(place)
            case .queued: state = .queued(place)
            }
        } catch {
            state = .failed("Couldn't reach the internet. Try again in a moment.")
        }
    }
}

struct ShareView: View {
    @ObservedObject var model: ShareModel
    let done: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            switch model.state {
            case .finding:
                ProgressView()
                Text("Finding the place…").foregroundStyle(.secondary)
            case .sending(let place):
                ProgressView()
                placeTitle(place)
                Text("Sending to your car…").foregroundStyle(.secondary)
            case .delivered(let place):
                Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(.green)
                placeTitle(place)
                Text("Sent — your car is navigating there.").multilineTextAlignment(.center)
            case .queued(let place):
                Image(systemName: "clock.fill").font(.system(size: 56)).foregroundStyle(.orange)
                placeTitle(place)
                Text("The car page isn't open right now. Open \(Shared.carPageURL) in the car within 10 minutes and the route starts by itself.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                Text("The car page must be paired with code \(Shared.formatted(Shared.pairCode)) (⋯ → Phone code).")
                    .font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
            case .notFound(let received):
                Image(systemName: "mappin.slash").font(.system(size: 56)).foregroundStyle(.secondary)
                Text("No location found").font(.headline)
                Text("Share a place from Yandex Maps, Google Maps or Apple Maps, or text with coordinates.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                if !received.isEmpty {
                    Text(received).font(.caption2.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled).lineLimit(6)
                }
            case .failed(let message):
                Image(systemName: "wifi.exclamationmark").font(.system(size: 56)).foregroundStyle(.orange)
                Text(message).multilineTextAlignment(.center)
            }
            Spacer()
            Button(action: done) { Text("Done").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(24)
        .preferredColorScheme(.dark)
    }

    private func placeTitle(_ place: SharedPlace) -> some View {
        VStack(spacing: 4) {
            Text(place.name.isEmpty ? "Shared place" : place.name).font(.title3.bold()).multilineTextAlignment(.center)
            Text(String(format: "%.5f, %.5f", place.lat, place.lng) + (place.source.isEmpty ? "" : " · \(place.source)"))
                .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            if place.approximate {
                Label("Approximate: found by address", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.yellow)
            }
        }
    }
}
