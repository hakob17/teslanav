import Foundation

/// A place shared from a maps app, to send to the car page.
struct SharedPlace: Equatable {
    var lat: Double
    var lng: Double
    var name: String
    /// "Yandex Maps", "Google Maps", "Apple Maps" or "" when unknown.
    var source: String
    /// Found by looking up an address rather than read from the link: only roughly right.
    var approximate = false
}

/// Reads a destination out of what a maps app shares: a link (full or short), the text around
/// it, or bare coordinates. Yandex puts longitude first (ll, pt, poi[point], whatshere[point]),
/// except in routes (rtext=lat,lng~lat,lng, where the destination is the last point) and
/// coordinate searches (text=lat,lng).
enum PlaceLink {
    static func place(fromText text: String?, url: URL?) async -> SharedPlace? {
        var urls: [URL] = url.map { [$0] } ?? []
        if let text, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(text.startIndex..., in: text)
            for match in detector.matches(in: text, range: range) {
                if let u = match.url, !urls.contains(u) { urls.append(u) }
            }
        }
        let label = name(fromText: text)
        // A place found without a usable name gets the street and town it's on.
        func named(_ place: SharedPlace) async -> SharedPlace {
            var p = place
            if p.name.isEmpty || isGeneric(p.name) { p.name = await Geocoder.reverse(p.lat, p.lng) ?? "" }
            return p
        }

        for candidate in urls {
            let resolved = await resolve(candidate)
            if var place = parse(resolved) ?? parse(candidate) {
                if place.name.isEmpty { place.name = label ?? "" }
                return await named(place)
            }
            // Google place links carry a name and address but no coordinates.
            if let address = googleAddress(resolved) ?? googleAddress(candidate),
               let place = await Geocoder.locate(address) {
                return place
            }
        }
        if let text, let (lat, lng) = coordinates(in: text) {
            return await named(SharedPlace(lat: lat, lng: lng, name: label ?? "", source: ""))
        }
        return nil
    }

    // MARK: Parsing

    static func parse(_ url: URL) -> SharedPlace? {
        if url.scheme == "geo" {
            let body = url.absoluteString.dropFirst(4).split(separator: "?").first.map(String.init) ?? ""
            guard let (lat, lng) = latLng(body) else { return nil }
            return SharedPlace(lat: lat, lng: lng, name: query(url, "q").flatMap(nameInParens) ?? "", source: "")
        }
        guard let host = url.host?.lowercased() else { return nil }

        if host.contains("yandex.") || host.contains("ya.ru") {
            let source = "Yandex Maps"
            if let route = query(url, "rtext"), let last = route.split(separator: "~").last,
               let (lat, lng) = latLng(String(last)) {
                return SharedPlace(lat: lat, lng: lng, name: "", source: source)
            }
            // A coordinate search (what Yandex shares for a dropped pin) is latitude first.
            if let value = query(url, "text"), let (lat, lng) = latLng(value) {
                return SharedPlace(lat: lat, lng: lng, name: "", source: source)
            }
            for key in ["pt", "poi[point]", "whatshere[point]", "ll"] {
                if let value = query(url, key), let (lng, lat) = latLng(value.split(separator: "~").first.map(String.init) ?? value) {
                    return SharedPlace(lat: lat, lng: lng, name: yandexName(url), source: source)
                }
            }
            return nil
        }

        if host.contains("google.") || host.hasPrefix("maps.app.goo.gl") || host.hasPrefix("goo.gl") {
            let source = "Google Maps"
            let s = url.absoluteString.removingPercentEncoding ?? url.absoluteString
            // The place itself (!3d lat !4d lng) is better than the map centre (@lat,lng).
            if let m = s.firstMatch(of: #/!3d(-?\d+\.\d+)!4d(-?\d+\.\d+)/#), let lat = Double(m.1), let lng = Double(m.2) {
                return SharedPlace(lat: lat, lng: lng, name: googleName(url), source: source)
            }
            for key in ["destination", "daddr", "q", "query", "ll", "center"] {
                if let value = query(url, key), let (lat, lng) = latLng(value) {
                    return SharedPlace(lat: lat, lng: lng, name: googleName(url), source: source)
                }
            }
            if let m = s.firstMatch(of: #/@(-?\d+\.\d+),(-?\d+\.\d+)/#), let lat = Double(m.1), let lng = Double(m.2) {
                return SharedPlace(lat: lat, lng: lng, name: googleName(url), source: source)
            }
            return nil
        }

        if host.contains("maps.apple") {
            let source = "Apple Maps"
            for key in ["coordinate", "ll", "daddr", "sll", "q"] {
                if let value = query(url, key), let (lat, lng) = latLng(value) {
                    let name = query(url, "name") ?? query(url, "q").flatMap { latLng($0) == nil ? $0 : nil } ?? ""
                    return SharedPlace(lat: lat, lng: lng, name: name, source: source)
                }
            }
            return nil
        }
        return nil
    }

    /// Two numbers that look like latitude, longitude ("40.19,44.51" or "40.19, 44.51").
    static func latLng(_ s: String) -> (Double, Double)? {
        let parts = s.replacingOccurrences(of: " ", with: "").split(separator: ",")
        guard parts.count >= 2, let a = Double(parts[0]), let b = Double(parts[1]),
              abs(a) <= 180, abs(b) <= 180 else { return nil }
        return (a, b)
    }

    /// Coordinates typed or pasted as text, e.g. "40.1913, 44.5151".
    static func coordinates(in text: String) -> (Double, Double)? {
        guard let m = text.firstMatch(of: #/(-?\d{1,2}\.\d{3,})\s*,\s*(-?\d{1,3}\.\d{3,})/#),
              let lat = Double(m.1), let lng = Double(m.2), abs(lat) <= 90, abs(lng) <= 180 else { return nil }
        return (lat, lng)
    }

    private static func query(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    private static func nameInParens(_ q: String) -> String? {
        guard let open = q.firstIndex(of: "("), let close = q.lastIndex(of: ")"), open < close else { return nil }
        return String(q[q.index(after: open)..<close])
    }

    /// maps.google.com/?q=Market,+1+Garegin+Nzhdeh,+Nor+Geghi+2404&ftid=… → the q text.
    static func googleAddress(_ url: URL) -> String? {
        guard let host = url.host?.lowercased(), host.contains("google."),
              let raw = query(url, "q") ?? query(url, "query") else { return nil }
        let q = raw.replacingOccurrences(of: "+", with: " ").trimmingCharacters(in: .whitespaces)
        guard latLng(q) == nil, !q.isEmpty else { return nil }
        return q
    }

    /// /maps/place/Cascade+Complex/@… → "Cascade Complex".
    private static func googleName(_ url: URL) -> String {
        let parts = url.pathComponents
        guard let i = parts.firstIndex(of: "place"), i + 1 < parts.count else { return "" }
        return parts[i + 1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? ""
    }

    /// /maps/org/cascade/1117880744/ → "Cascade" (a slug, so only a fallback for the shared text).
    private static func yandexName(_ url: URL) -> String {
        let parts = url.pathComponents
        guard let i = parts.firstIndex(of: "org"), i + 1 < parts.count else { return "" }
        return parts[i + 1].replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Page titles and app taglines ("Yandex Maps: search for places, transport, and routes")
    /// aren't place names.
    static func isGeneric(_ name: String) -> Bool {
        let n = name.lowercased()
        return ["yandex maps", "яндекс карты", "яндекс.карты", "google maps", "apple maps", "yandex.maps"].contains { n.contains($0) }
    }

    /// Maps apps put the place's name on the first line of the shared text, before the link.
    static func name(fromText text: String?) -> String? {
        guard let text else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.isEmpty || l.contains("://") || coordinates(in: l) != nil { continue }
            return String(l.prefix(120))
        }
        return nil
    }

    // MARK: Short links

    /// Follows a short link (yandex.ru/maps/-/…, maps.app.goo.gl/…) to the full URL, which
    /// carries the coordinates. Only the redirect is needed, not the page.
    static func resolve(_ url: URL) async -> URL {
        guard let host = url.host?.lowercased() else { return url }
        let short = (host.contains("yandex.") && url.path.contains("/maps/-/"))
            || host.hasPrefix("maps.app.goo.gl") || host.hasPrefix("goo.gl")
        guard short else { return url }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
                         forHTTPHeaderField: "User-Agent")
        let catcher = RedirectCatcher()
        let session = URLSession(configuration: .ephemeral, delegate: catcher, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        _ = try? await session.data(for: request)
        return catcher.last ?? url
    }

    /// Stops at the first redirect that leaves the short-link host, keeping its URL.
    private final class RedirectCatcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        var last: URL?
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            last = request.url
            if let u = request.url, PlaceLink.parse(u) != nil { return nil }
            return request
        }
    }
}

/// Finds an address with OpenStreetMap's public geocoders (Nominatim, Photon). Street names repeat
/// across towns, so a street-level match only counts near the town the address names; otherwise
/// the town itself is used, marked approximate.
enum Geocoder {
    static func locate(_ address: String) async -> SharedPlace? {
        let parts = address.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = parts.first else { return nil }
        // "Nor Geghi 2404" → "Nor Geghi": the last part is the town, often with a postcode.
        let town = (parts.last ?? first).replacingOccurrences(of: #"\s*\d{4,6}$"#, with: "", options: .regularExpression)
        let townHit = await search(town)

        var attempts: [String] = []
        for drop in 0..<max(parts.count - 1, 1) { attempts.append(parts[drop...].joined(separator: ", ")) }
        for query in attempts {
            guard let hit = await search(query) else { continue }
            if let t = townHit, distance(hit, t) > 5000 { continue }
            if townHit == nil && parts.count > 1 { continue }
            return SharedPlace(lat: hit.0, lng: hit.1, name: first, source: "Google Maps")
        }
        guard let t = townHit else { return nil }
        return SharedPlace(lat: t.0, lng: t.1, name: "\(first) (\(town))", source: "Google Maps", approximate: true)
    }

    /// "Sayat-Nova Street, Nor Geghi" for a point, in English where OpenStreetMap has it.
    static func reverse(_ lat: Double, _ lng: Double) async -> String? {
        var c = URLComponents(string: "https://nominatim.openstreetmap.org/reverse")!
        c.queryItems = [URLQueryItem(name: "format", value: "jsonv2"), URLQueryItem(name: "zoom", value: "17"),
                        URLQueryItem(name: "lat", value: String(lat)), URLQueryItem(name: "lon", value: String(lng)),
                        URLQueryItem(name: "accept-language", value: "en")]
        var request = URLRequest(url: c.url!, timeoutInterval: 10)
        request.setValue("HotspotNav/1.0 (https://github.com/hakob17/teslanav)", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let address = row["address"] as? [String: String] ?? [:]
        let place = (row["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let road = address["road"]
        let town = address["city"] ?? address["town"] ?? address["village"] ?? address["suburb"]
        let parts = [place ?? road, town].compactMap { $0 }
        return parts.isEmpty ? nil : Array(NSOrderedSet(array: parts)).compactMap { $0 as? String }.joined(separator: ", ")
    }

    private static func search(_ q: String) async -> (Double, Double)? {
        var c = URLComponents(string: "https://nominatim.openstreetmap.org/search")!
        c.queryItems = [URLQueryItem(name: "format", value: "jsonv2"), URLQueryItem(name: "limit", value: "1"), URLQueryItem(name: "q", value: q)]
        var request = URLRequest(url: c.url!, timeoutInterval: 10)
        request.setValue("HotspotNav/1.0 (https://github.com/hakob17/teslanav)", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let row = rows.first, let lat = Double(row["lat"] as? String ?? ""), let lng = Double(row["lon"] as? String ?? "") else { return nil }
        return (lat, lng)
    }

    private static func distance(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
        let r = 6_371_000.0, dLat = (b.0 - a.0) * .pi / 180, dLng = (b.1 - a.1) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(a.0 * .pi / 180) * cos(b.0 * .pi / 180) * sin(dLng / 2) * sin(dLng / 2)
        return 2 * r * asin(min(1, h.squareRoot()))
    }
}

/// Sends a place to the car page through the relay.
enum PlaceSender {
    enum Outcome { case delivered, queued }

    static func send(_ place: SharedPlace, room: String) async throws -> Outcome {
        guard var components = URLComponents(string: Shared.relayURL.replacingOccurrences(of: "wss://", with: "https://")
            .replacingOccurrences(of: "/ws", with: "/send")) else { throw URLError(.badURL) }
        components.queryItems = [URLQueryItem(name: "room", value: room)]
        var request = URLRequest(url: components.url!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "type": "dest", "lat": place.lat, "lng": place.lng, "name": place.name, "source": place.source,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let delivered = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["delivered"] as? Int ?? 0
        return delivered > 0 ? .delivered : .queued
    }
}
