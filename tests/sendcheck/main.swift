// Sends a place through PlaceSender (what the share extension does) to a test room.
import Foundation
let place = SharedPlace(lat: 40.1913593, lng: 44.5151026, name: "Cascade Complex", source: "Google Maps")
do { print(try await PlaceSender.send(place, room: CommandLine.arguments[1])) } catch { print("FAIL", error); exit(1) }
