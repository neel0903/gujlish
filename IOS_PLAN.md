# Gujlish for iOS — end-to-end build plan

A system keyboard for iPhone that types romanised Gujarati with
prediction, autocorrect and grammar help, inside WhatsApp and every
other app. Built on a friend's Mac in an isolated account, tested on
Neel's iPhone with a free Apple ID, and ready for the App Store the day
a paid developer account exists.

Everything the keyboard needs already exists and is tested in this
repo: the phonetic keys (`phonetics.py`), the ranking, autocorrect and
context engine (`engine.py`, reference; `web/gujlish.js`, verified port),
the grammar rules (`web/grammar.js`), the script converter
(`web/reverse.js`), the lexicon with 80K words, 92K bigrams, 63K
trigrams and 80K script forms, and two test suites that pin the
behaviour. The iOS work is a third port of the same thing, tested the
same way.

**Facts that shape the plan**

| | |
|---|---|
| Free Apple ID | Sideload up to 3 apps on your own devices, 7-day expiry, no App Groups, no iCloud, no TestFlight, no App Store |
| Paid program (99 USD/yr) | App Store, TestFlight, App Groups (shared data between app and keyboard), 1-year signing |
| Keyboard extension memory | Killed silently around 60 MB. The lexicon stays in SQLite on disk, never in RAM |
| Full Access | Not requested. The keyboard is fully offline, so it works without it and review is simpler |
| Weekly re-sign without the Mac | AltStore on Neel's Windows PC re-signs the app over Wi-Fi with the free Apple ID (AltStore itself uses one of the three app slots) |

---

## Step 0 — the friend's Mac, isolated (half a day)

Goal: nothing of ours touches his account, his Xcode settings, his git
identity or his shell. Everything lives in a separate macOS user that
can be deleted afterwards.

**0.1 He creates a macOS user for us** (needs his admin password, once):
System Settings → Users & Groups → Add User → Standard → name `gujlish`.
Log in as that user for everything below. Xcode is installed
system-wide in /Applications, which is fine; its preferences, derived
data, simulators' state, Apple ID sign-in and our source live in
`/Users/gujlish` only. When the project is over he deletes the user and
his machine is exactly as before.

If he will not create a user: work in `~/gujlish` under his account,
set git identity with `git config --local` only, never `--global`, and
never change Xcode's account settings for his Apple ID. Weaker, but
workable.

**0.2 Environment check** (run as the `gujlish` user; note results in
this file under "Step 0 results"):

```bash
sw_vers                          # macOS version; Xcode's App Store page states the minimum it needs
df -h /                          # need ~40 GB free: Xcode ~15 GB + iOS simulator runtime ~8 GB + headroom
xcodebuild -version              # Xcode present? If not: install from the App Store (or ask him — it is system-wide)
xcode-select -p                  # command line tools path; if missing: xcode-select --install
xcrun simctl list runtimes       # an iOS runtime installed? If not: Xcode → Settings → Components
python3 --version                # ships with the command line tools; 3.9+ is enough
git --version
```

**0.3 Per-user tools** (no Homebrew changes to his machine; these
install under our home only):

```bash
# Node, for the JS tests (per-user, via nvm)
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh | bash
source ~/.nvm/nvm.sh && nvm install --lts
# Claude Code, per-user
curl -fsSL https://claude.ai/install.sh | bash
claude auth login                 # Neel's claude.ai account
# GitHub CLI is optional; plain git over HTTPS with a token is enough
```

**0.4 Get the project and prove the ground truth still holds:**

```bash
git clone https://github.com/neel0903/gujlish.git ~/gujlish && cd ~/gujlish
python3 phonetics.py              # 18/18
python3 translit.py               # 65/65
python3 build_db.py lexicon.tsv   # rebuilds gujlish.db from the committed TSVs (no corpus needed)
python3 build_site.py             # writes web/expected.json used by the tests
node web/test_port.js             # all keys, trials, corrections identical
node web/test_grammar.js          # rules + golden sentences
```

Pillow may be missing for icons: `python3 -m pip install --user pillow`.

**0.5 Apple side:**
- Xcode → Settings → Accounts → add Neel's Apple ID. A "Personal Team" appears. Free.
- iPhone: Settings → Privacy & Security → Developer Mode → on (restart).
  Plug in via USB, tap Trust. Xcode → Window → Devices shows it.
- Optional: Xcode → Devices → "Connect via network" so later builds go over Wi-Fi.

**0.6 KeyboardKit licence check.** Open the KeyboardKit repository
(github.com/KeyboardKit/KeyboardKit) and read LICENSE and the FAQ as
they stand that day. Older versions were MIT; newer notes describe the
SDK as closed-source but free to use in any app. We need only the free
tier: QWERTY layout, key callouts, the autocomplete toolbar. If the
licence is unacceptable, Step 3 uses our own SwiftUI keyboard view
instead (more work, no dependency).

**Step 0 exit criteria:** tests pass on the Mac; a blank "Hello" app
built in Xcode installs and runs on the iPhone from the Personal Team.

---

## Step 1 — project skeleton (half a day)

Xcode workspace `ios/Gujlish.xcworkspace` with:

- **`GujlishCore`** — a Swift Package (pure Swift + SQLite, no UIKit).
  Phonetics, Engine, Grammar, Reverse, PersonalDictionary. Unit tests
  live here and run on the Mac in seconds.
- **`Gujlish`** (app target) — SwiftUI container app: onboarding
  ("add the keyboard in Settings"), a tester text field with the same
  keyboard, script preview, settings, and later chat import.
- **`GujlishKeyboard`** (Custom Keyboard Extension target) — the
  keyboard itself. Depends on GujlishCore.
- Both app and extension embed `gujlish.db` as a resource (about 9 MB
  each; without App Groups they cannot share one copy).
- Bundle IDs `com.neel0903.gujlish` and `com.neel0903.gujlish.keyboard`
  (must be prefix-related). `RequestsOpenAccess` = NO in the
  extension's Info.plist.
- `build_ios_assets.py` (to write): runs `build_db.py`, copies
  `gujlish.db`, `web/expected.json`, `web/golden.tsv` into
  `ios/Assets/`. The DB now also carries the English list and the
  script form of every word (see "Prepared on Windows" below).

Git: `ios/` is committed; `ios/**/DerivedData`, `*.xcuserstate` and
`Assets/gujlish.db` are ignored (the DB is rebuilt from the TSVs).

---

## Step 2 — port GujlishCore and pin it to the reference (2–3 days)

Port from the Python, which is the reference, and check against
`expected.json` exactly as the JavaScript is checked.

- **Phonetics.swift** — `strictKey`, `looseKey`, prefix mode. Test:
  every one of the 80K lexicon words plus the probe list keys
  identically to `expected.keys`.
- **Lexicon.swift** — read-only SQLite (`SQLite3` C API, no third-party
  dependency): `byPrefix(key, column, limit)`, `fuzzy`, `bigramWeights`,
  `trigramWeights`, `englishByPrefix`, `native(surface)`. Prepared
  statements cached; the DB opened once per keyboard session and never
  loaded into memory. Indexes already exist for strict_k, loose_k,
  surface; add one on `LENGTH(surface)` in `build_db.py` for the
  correction scan.
- **Engine.swift** — `suggest(typed, prev, prev2)`, `nextWord`,
  `correct` with the same tiers, penalties (30 loose, 60 fuzzy, +40
  exact), context (bigram×4 + trigram×6), `userBoost`, English penalty
  15, correction margin 20. Test: all 40 trials and 21 corrections in
  `expected.json` identical, plus the JS-only checks from
  `web/test_port.js` (mixed mode, personal words, "Avi gaye ghara").
- **PersonalDictionary.swift** — a second, writable SQLite in the
  extension's own container: words, bigrams, trigrams with counts; the
  same `personalFreq` / `personalWeight` formulas; export/import as the
  same JSON the web app uses, so learned data can move between web and
  phone.
- **Grammar.swift** — the rules from `web/grammar.js`, same tokeniser,
  same clause logic. Test: the 23 rule checks and all golden sentences.
- **Reverse.swift** — from `web/reverse.js`. Test: the 13 cases.
- **Performance test** on device: suggest under 5 ms, correct under 10
  ms, cold start under 300 ms. Log with `os_signpost`; check with
  Instruments.

Exit criteria: `swift test` green on the Mac and on a device; the
Python, JS and Swift engines agree on every pinned case.

---

## Step 3 — the keyboard (3–5 days)

- **Layout**: QWERTY via KeyboardKit (or our own view). Shift, numbers
  and symbols layer, space, return, backspace with repeat, the globe
  key (mandatory: every keyboard must offer "next keyboard"), haptics.
- **Suggestion bar**: three chips on narrow phones, five on wide, from
  `Engine.suggest`; after a space, `nextWord`. Tap inserts the word plus
  a space and records it in the personal dictionary.
- **Context**: `textDocumentProxy.documentContextBeforeInput` gives the
  text before the cursor. Current word, prev and prev2 are parsed from
  it exactly like the web app's `split()`. This works inside WhatsApp.
- **Autocorrect on space**: same rules. Undo follows the iOS
  convention: a backspace immediately after an autocorrect restores the
  original, and restoring twice teaches the word.
- **Grammar chip**: when the text before the cursor has an agreement
  issue, the bar shows "che → cho"; tapping it edits in place via
  `deleteBackward` and `insertText`. Ship this after the basics work.
- **Script mode**: a toggle on the bar. When on, taking a chip or
  committing a word inserts the Gujarati script form (`native` column,
  `Reverse` as fallback). This is the feature the web app cannot fully
  give: type Gujlish, and WhatsApp receives ગુજરાતી.
- **Mixed English**: the `english` table in the DB, same penalty.
- **Settings** live on the keyboard itself (a gear key opens a small
  panel: mode, autocorrect, grammar, script mode) because without App
  Groups the container app cannot reach the keyboard's storage.
- **Memory budget**: measure with Instruments while typing 500
  characters in WhatsApp; stay under 40 MB. If KeyboardKit alone is too
  heavy on an old phone, the custom view is the fallback.

Exit criteria: the keyboard works in WhatsApp, Notes, Safari and
Messages; survives rotation and dark mode; never crashes on empty
context; predictions and corrections match the web app for the golden
sentences.

---

## Step 4 — the container app (1–2 days)

- Onboarding screen with the exact path: Settings → General → Keyboard
  → Keyboards → Add New Keyboard → Gujlish. Detects whether the keyboard
  is enabled and shows a tick.
- A test field that opens our keyboard, with the script preview below.
- About and privacy text: everything on device, nothing sent anywhere,
  no Full Access needed.
- **With a paid account only** (App Groups): chat import
  (`UIDocumentPicker` for the WhatsApp export, same parser as the web
  app), shared settings, and the personal dictionary in the group
  container so the app and keyboard share one. Design the storage layer
  now with a `containerURL` abstraction so this is a one-line switch.

---

## Step 5 — testing, in order

1. **Unit** (`swift test`): parity with `expected.json`, grammar rules,
   golden sentences, personal dictionary formulas. Runs on every commit.
2. **Simulator**: the container app's test field with the keyboard;
   XCUITest that types "kem ch" and asserts the bar shows cho first,
   and "tame kem che " shows the chip. Enabling a third-party keyboard
   in the simulator is done once per simulator through its Settings app.
3. **Device protocol** (manual, on Neel's iPhone, each build):
   WhatsApp new message → type the golden sentences → compare with
   `web/golden.tsv`; switch apps mid-sentence; rotate; dark mode; low
   power mode; a 10-minute typing session for memory; the keyboard's
   first appearance time.
4. **Field test**: a week of real use; note every wrong correction and
   every missed one in `web/golden.tsv` with the expected form. That
   file is the product's regression test across web and iOS.

---

## Step 6 — distribution

**6.1 Free Apple ID (now).** Xcode → Run on the iPhone from the Personal
Team. The build expires after 7 days. To re-sign without the Mac:
install AltServer on Neel's Windows PC (requires iTunes and iCloud
from Apple's site, not the Store versions), install AltStore on the
iPhone from it, then sideload the exported `.ipa`; AltStore refreshes
it weekly while the PC is on the same Wi-Fi. Export the `.ipa` once
from Xcode (Product → Archive → Distribute → Debugging / Development).
Three-app limit: AltStore + Gujlish = 2.

**6.2 Paid program (when ready).** Enrol at developer.apple.com (a few
days for approval). Then:
- App ID with App Groups; move personal storage to the group container;
  enable chat import in the app.
- App Store Connect record: name, subtitle, category (Utilities),
  privacy "Data Not Collected", screenshots (6.9" and 6.5" sizes),
  keyboard-specific review notes: works without Full Access, no
  network, the globe key switches keyboards.
- TestFlight: internal testers immediately; a public link for friends.
- Review guidelines to respect for keyboards: must have a next-keyboard
  key, must not require Full Access to function, must not collect
  keystrokes, must be usable without network. Ours already meets all
  four by design.
- Submit. Expect one round of review feedback; typical turnaround is
  a day or two.

---

## Timeline

| Step | Sessions |
|---|---|
| 0 Environment | half a day, the friend present for the user account |
| 1 Skeleton | half a day |
| 2 Core port + tests | 2–3 days |
| 3 Keyboard | 3–5 days |
| 4 Container app | 1–2 days |
| 5 Device testing and fixes | ongoing; 2–3 days concentrated |
| 6.1 Sideload + AltStore | half a day |
| 6.2 App Store | 2 days of prep once enrolled, plus review |

Roughly two to three weeks of working sessions to a keyboard Neel uses
daily; the App Store step is separate and starts whenever the 99 USD is
spent.

---

## Prepared on Windows before the Mac session

- `build_db.py` now writes the `english` table and a `native` column
  into `gujlish.db`, so the keyboard bundles one database with
  everything: words with precomputed keys, bigrams, trigrams, script
  forms, English list.
- `english.tsv` (top 20K English words, log-scaled) is committed, so the
  DB rebuilds on the Mac with no corpus download.
- The tests, `expected.json` generation and golden sentences are what
  the Swift tests will read.

## Progress notes (kept on the Mac)

**Step 1, done 2026-09-21.** `ios/project.yml` is the project definition;
`xcodegen --spec ios/project.yml` writes `ios/Gujlish.xcodeproj` (run it
after adding a Swift file). `python3 build_ios_assets.py` makes
`ios/Assets/gujlish.db`. Signing: free Personal Team, set in project.yml.
Build and install from the command line:

```bash
export DEVELOPER_DIR=/Volumes/GujlishDev/Xcode.app/Contents/Developer
cd ios && xcodebuild -project Gujlish.xcodeproj -scheme Gujlish -configuration Release \
    -destination 'id=<iPhone UDID>' -derivedDataPath /Volumes/GujlishDev/DerivedData \
    -allowProvisioningUpdates build
xcrun devicectl device install app --device <iPhone UDID> \
    /Volumes/GujlishDev/DerivedData/Build/Products/Release-iphoneos/Gujlish.app
```

Always judge speed on a Release build; Debug Swift is several times slower.

**Step 2, done except the device performance test.** `ios/GujlishCore`
(`swift test`): Phonetics, Lexicon, Engine, Grammar, Reverse pinned to
`expected.json` and `golden.tsv`. Deviation from the plan: the personal
dictionary is one JSON file (`PersonalStore`, the web app's export
format, written atomically) instead of a second SQLite database; the
learned data is small and lives in memory anyway.

**Step 3, in progress.** Decisions and what was learned on the phone:

- Own keyboard view, no KeyboardKit (licence, see Step 0 results).
- Everything that can be wrong lives in GujlishCore with unit tests:
  `Composer` (what each key does to the text: autocorrect on space and
  its undo, suggestions, double-space period, script mode, grammar fix),
  `TouchTracker` (which key a set of fingers means: rollover order,
  skid tolerance, cancelled taps, long press), `TypingContext`.
- The engine runs on its own serial queue; a key press only inserts
  text. Measured on an iPhone 17 Pro: key 0.1 ms, engine about 22 ms in
  the background, bar refreshed 22 ms after the key, no touch lost in
  several hundred. iOS itself delivers a touch to a third-party keyboard
  about 20 ms after the finger lands.
- "Fast keys" (default on): letters are typed on touch-down. Off gives
  the system behaviour (on lift, slide to a neighbour to change it).
- `documentContextBeforeInput` can lag after fast typing, so Composer
  mirrors its own edits and recognises a lagging report (0.25 s window).
- The key area is UIKit (`KeyGridView`), sizes measured from iOS 27
  screenshots; the bar and the settings panel are SwiftUI. iOS pads
  about 16 pt above a third-party keyboard, hence the short bar.
- Full Access is not requested, so there are no key haptics; clicks work.
- Open: undo and grammar chip in script mode (waiting for the on-device
  delete probe in the settings panel), dark-mode colours checked against
  the system keyboard, rotation, memory while typing 500 characters.

## Step 0 results

(fill in on the Mac)

- macOS: 27.0, Apple silicon, standard account `user1` (2026-09-21)
- Xcode: 27.0 (27A266a) on a 64 GB APFS pendrive at `/Volumes/GujlishDev/Xcode.app`, not in /Applications; used through `DEVELOPER_DIR=/Volumes/GujlishDev/Xcode.app/Contents/Developer`. Licence and first launch done by the Mac's owner. Swift 6.4, iOS SDK 27.0
- Free disk: internal about 20 GB (too little for Xcode, hence the pendrive); pendrive 51 GB
- iOS runtime: none installed on purpose (no simulator; testing on the iPhone)
- Tests: Python and JS suites pass; `swift test` in `ios/GujlishCore` passes (8 tests)
- KeyboardKit licence on that day: 2026-09-21: README says "KeyboardKit is closed-source" and ships as a binary package; LICENSE is a "Closed Source License" whose terms speak of a valid licence key and a written agreement, and forbid redistribution and reverse engineering. The README still describes a free tier (KeyboardView, layout engine, callouts, basic autocomplete; localized keyboards are Pro), but the free tier's commercial terms are not clear from the repo. Recommendation: build our own SwiftUI keyboard view in Step 3 (no dependency, smaller memory footprint, nothing to clear with a vendor before the App Store)
- Hello-world on iPhone: 
