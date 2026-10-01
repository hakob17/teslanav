// Checks PlaceLink against real and documented share formats:
//   swiftc Shared/Shared.swift Shared/PlaceLink.swift tests/placelink/main.swift -o build/placelink && build/placelink
import Foundation

struct Case { let text: String?; let url: String?; let lat: Double; let lng: Double; let name: String? }
let cases: [Case] = [
    // Shared from Yandex Maps on an iPhone (a dropped pin).
    Case(text: "Sayat-Nova Street\nNor Geghi village, Kotayk Region\nhttps://yandex.com/maps?text=40.355798,44.594740&si=3w2tgd8rgv1va93uud6qm6kka8",
         url: nil, lat: 40.355798, lng: 44.594740, name: "Sayat-Nova Street"),
    Case(text: nil, url: "https://yandex.ru/maps/10262/yerevan/?ll=44.515537%2C40.191087&mode=poi&poi%5Bpoint%5D=44.515102%2C40.191360&z=17",
         lat: 40.191360, lng: 44.515102, name: nil),
    Case(text: nil, url: "https://yandex.ru/maps/?rtext=40.177200%2C44.503490~40.191360%2C44.515102&rtt=auto", lat: 40.191360, lng: 44.515102, name: nil),
    Case(text: nil, url: "https://yandex.ru/maps/?whatshere%5Bpoint%5D=44.5151%2C40.1914&whatshere%5Bzoom%5D=17", lat: 40.1914, lng: 44.5151, name: nil),
    Case(text: nil, url: "https://yandex.ru/maps/?pt=44.5151,40.1914&z=17&l=map", lat: 40.1914, lng: 44.5151, name: nil),
    Case(text: nil, url: "https://www.google.com/maps/place/Cascade+Complex/@40.1912,44.5130,17z/data=!3m1!4b1!4m6!3m5!1s0x0:0x0!8m2!3d40.1913593!4d44.5151026",
         lat: 40.1913593, lng: 44.5151026, name: "Cascade Complex"),
    Case(text: nil, url: "https://maps.google.com/?q=40.1913,44.5151", lat: 40.1913, lng: 44.5151, name: nil),
    Case(text: nil, url: "https://www.google.com/maps/dir/?api=1&destination=40.19,44.51", lat: 40.19, lng: 44.51, name: nil),
    Case(text: nil, url: "https://maps.apple.com/place?coordinate=40.19,44.51&name=Cascade", lat: 40.19, lng: 44.51, name: "Cascade"),
    Case(text: nil, url: "geo:40.19,44.51?q=40.19,44.51(Cascade)", lat: 40.19, lng: 44.51, name: "Cascade"),
    Case(text: "Meet here: 40.1913, 44.5151", url: nil, lat: 40.1913, lng: 44.5151, name: nil),
    // Safari's share title is a tagline, not a place: the street is looked up instead.
    Case(text: "Yandex Maps: search for places, transport, and routes", url: "https://yandex.com/maps?text=40.355798,44.594740",
         lat: 40.355798, lng: 44.594740, name: nil),
]

var failures = 0
for c in cases {
    let place = await PlaceLink.place(fromText: c.text, url: c.url.flatMap(URL.init(string:)))
    let ok = place.map { abs($0.lat - c.lat) < 1e-6 && abs($0.lng - c.lng) < 1e-6 && (c.name == nil || $0.name == c.name) } ?? false
    if !ok { failures += 1 }
    print(ok ? "ok  " : "FAIL", (c.url ?? c.text ?? "").prefix(70), "→", place.map { "\($0.lat),\($0.lng) “\($0.name)” \($0.source)" } ?? "nil")
}

// Real short links (network): Yandex and the Google one shared from an iPhone.
for link in ["https://yandex.ru/maps/-/CCUkr2Hj3A", "https://maps.app.goo.gl/zCdYfhHjDpdVKGB77?g_st=ic"] {
    let place = await PlaceLink.place(fromText: nil, url: URL(string: link))
    if place == nil { failures += 1 }
    print(place != nil ? "ok  " : "FAIL", link, "→", place.map { "\($0.lat),\($0.lng) “\($0.name)” \($0.source)" } ?? "nil")
}
print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
