# App Store listing — TeslaNav

## Status (2026-09-28)

| Item | State |
|---|---|
| App record | ✅ **HotspotNav: Car Screen Maps**, Apple ID 6816818389, SKU `teslanav-ios` |
| Build | ⏳ 1.0 (4) uploaded — attach it in place of build 1 |
| App Information | ✅ subtitle, Navigation / Utilities, content rights (OSM data, licensed) |
| Age rating | ✅ 4+ (every question None/No) |
| Pricing & availability | ✅ Free, 175 countries |
| App Privacy | ✅ published: Data Not Collected; privacy URL set |
| In-app purchase | ✅ consumable `…teslanav.coffee`, $2.99, display name, review screenshot + notes |
| Version page | ⏳ replace with the 5 new screenshots (`design/appstore-6.5/`); earlier: 4 screenshots, promo text, description, keywords, support URL, copyright, review notes, sign-in not required, manual release |
| Review contact | ⏳ needs name, **phone**, email |
| Submit for Review | ⏳ left for you (attach the coffee IAP to the submission) |

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

Open one page in your car's browser for a heading-up 3D map with turn-by-turn and voice, or
mirror your iPhone to use your favourite navigation app with live traffic. Free, no account.

## Description

Put navigation on your car's big screen.

MAP ON THE CAR SCREEN
Open hakob17.github.io/teslanav/car in the car's built-in browser and bookmark it. You get a
full-screen night map that runs in the car and uses its own GPS:

• Heading-up 3D view that turns with the road, or north-up
• Turn-by-turn directions with voice prompts and street names read in English
• Search that understands English, Russian and Armenian spellings, nearby results first
• Automatic rerouting, arrival time, distance and time remaining
• EV charging stations on the map

MIRROR YOUR IPHONE
Prefer Yandex Navigator, Google Maps or Waze and their live traffic? Tap Start Broadcast in
the app, tap "Phone screen" in the car and enter your pairing code once. Your whole iPhone
screen appears on the car display, full screen, in portrait or landscape.

FREE, NO ACCOUNT
No sign-up and no ads. Mirroring streams your screen through TeslaNav's relay only while the
car is watching (about 0.5 GB of mobile data per hour); nothing is recorded or stored.

Maps © OpenStreetMap contributors, OpenFreeMap. Routing by OSRM, search by Photon.

## Keywords

car screen,car browser,navigation,screen mirroring,mirror,maps,turn by turn,heading up,ev charger,armenia

## Notes for App Review

No account or login. The app has two parts:

1. Map mode is a web page, https://hakob17.github.io/teslanav/car/, opened in a car's
   built-in browser (or any browser). It uses that browser's location. Search a place, pick a
   result, and use ⋯ → Simulate drive to see turn-by-turn guidance without driving.

2. Mirror mode is this app. Tap Start Broadcast → Start Broadcast. On any computer open the
   page above, tap "Phone screen" and enter the 8-character code shown in the app. The iPhone
   screen appears in the browser within a few seconds. The broadcast extension encodes the
   screen as H.264 and streams it through our relay (a Cloudflare Worker) only while a
   browser is watching; nothing is stored.

"Buy me a coffee" is an optional tip (consumable in-app purchase); it unlocks nothing.
