# App Store listing — TeslaNav

Draft text for App Store Connect. Screenshots: `design/appstore/1-4` (6.9", 1320×2868), upload
one at a time in order.

| Field | Value |
|---|---|
| Bundle ID | `com.hakobhakobyan.teslanav` (+ `.broadcast` extension) |
| SKU | `teslanav-ios` |
| Name | *to decide* — "Tesla" is a trademark (guideline 5.2.1). Candidates: **HotspotNav: Car Screen Maps**, **CarScreen Nav** |
| Subtitle | Maps on your car's big screen |
| Category | Navigation (secondary: Utilities) |
| Price | Free |
| Age rating | 4+ (no objectionable content; unrestricted web access: **No** — the car page is local) |
| Support URL | https://hakob17.github.io/teslanav/ |
| Privacy Policy URL | https://hakob17.github.io/teslanav/privacy.html |
| App Privacy | **Data Not Collected** |
| Encryption | `ITSAppUsesNonExemptEncryption = NO` |
| In-app purchase | Consumable `com.hakobhakobyan.teslanav.coffee`, "Buy me a coffee", Tier $2.99, needs its own review screenshot |

## Promotional text

Turn on Personal Hotspot, open one bookmark in your car's browser, and drive with a big,
dark, turn-by-turn map — powered by your iPhone's GPS.

## Description

Put navigation on your car's big screen, straight from your iPhone.

TeslaNav runs a tiny web server on your iPhone. Join your car to the iPhone's Personal Hotspot,
open one address in the car's built-in browser, and you get a full-screen night map with:

• Place and address search, nearby results first
• Turn-by-turn directions with voice prompts
• Automatic rerouting when you leave the route
• Arrival time, distance and time remaining
• Your iPhone's GPS for an accurate, smooth position

MIRROR MODE
Prefer your usual navigation app and its live traffic? Start a screen broadcast in TeslaNav and
tap "Phone screen" in the car — your whole iPhone screen appears on the car display.

NO CLOUD, NO ACCOUNT
Everything runs between your phone and your car. There is no sign-up, no ads and no tracking.
TeslaNav keeps working while you use other apps or lock the phone.

Maps © OpenStreetMap contributors. Routing by OSRM, search by Nominatim.

## Keywords

car screen,car browser,navigation,hotspot,maps,turn by turn,gps,mirror,screen mirroring,route,eta

## Notes for App Review

No account or login. The app serves a navigation web page to a car's built-in web browser over
the iPhone's Personal Hotspot; there is no backend.

To review without a car: on the iPhone turn on Personal Hotspot, join it from a Mac or another
device, open TeslaNav on the iPhone (allow location), and open http://172.20.10.1:8080 in a
browser on the other device. Search a place, pick a result, and use ⋯ → Simulate drive to see
turn-by-turn guidance. Mirror mode: tap Start Broadcast in the app, then "Phone screen" on the
page.

Background location is used so the page in the car keeps receiving the iPhone's position while
the user has another app in front or the phone locked (active navigation).

"Buy me a coffee" is an optional tip (consumable IAP); it unlocks nothing.
