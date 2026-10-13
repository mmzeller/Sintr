# Sintr

Private meeting notes for iPhone and Mac, in the spirit of Granola — but everything happens on your own device.

- **Type your own notes while Sintr listens.** It writes a live transcript as people talk.
- **On the Mac it hears both sides of a call** — your microphone (“Me”) and whatever the Mac plays, like the other side of Zoom, Teams or FaceTime (“Them”). No bot joins the call.
- **Enhance** turns your rough notes plus the transcript into clean notes: summary, decisions, action items. You pick where that happens.
- **Import and export** Markdown, plain text, Sintr backups and audio files. Notes are plain Markdown when exported, so Nextpad++ (and Parakeet) can open them.

## Privacy: what goes where

| | Where it happens | Uses the internet? |
|---|---|---|
| Recording | Your device | No |
| Transcription | Your device (Apple's speech model) | Only a one-time model download from Apple |
| Enhance with Apple Intelligence | Your Mac (needs iPhone 15 Pro or newer on a phone) | No |
| Enhance with the phone model | Your device | Only a one-time model download from Hugging Face, when you tap Download |
| Send to Claude | Anthropic's Claude API | Yes — only when you tap it and confirm |
| Share / Export | Wherever you send it (AirDrop goes directly between devices) | Depends on where you send it |

Notes live in Sintr's private folder on each device. On iPhone they're kept out of iCloud and computer backups unless you turn that on in Settings. There is no sync: move notes between devices with **Export → Sintr backup** and **Import**.

## What works where

| | iPhone 12 | Your Mac (Apple silicon) |
|---|---|---|
| Record + live transcript | ✓ (keeps going with the screen locked) | ✓ |
| Record the other side of a call | — (iOS doesn't allow it) | ✓ |
| Enhance with Apple Intelligence | — (needs iPhone 15 Pro or newer) | ✓ |
| Enhance with the phone model | ✓ (slower) | ✓ |
| Send to Claude / Share | ✓ | ✓ |

Needs iOS 26 or macOS 26, and Xcode 26 or newer on the Mac.

## First time on your Mac

1. Install **Xcode** from the Mac App Store (it's free, and large — let it finish), then open it once and let it install its extra components.
2. Open **Terminal** and download Sintr:
   ```
   git clone https://github.com/mmzeller/Sintr.git ~/Sintr
   open ~/Sintr/Sintr.xcodeproj
   ```
3. In Xcode: **Xcode → Settings → Accounts → +** → Apple Account, and sign in with your Apple ID. Close Settings.
4. In the left column click the blue **Sintr** icon at the very top, then **Signing & Capabilities**, and under **Team** choose your name (Personal Team).
5. At the top of the window, next to the ▶ button, choose **My Mac** as the destination, then press **▶ (Run)**.
6. Sintr opens. The first time you press **Record**, it asks to download Apple's speech model, then macOS asks for the microphone and for permission to record system audio. Allow both.

To keep Sintr in your Applications folder (so you can open it without Xcode), run this once in Terminal after step 5:
```
bash ~/Sintr/install-mac.sh
```

## Put it on your iPhone

1. Connect the iPhone to the Mac with a cable and unlock it. If it asks "Trust This Computer?", tap **Trust**.
2. On the iPhone: **Settings → Privacy & Security → Developer Mode** → on. It restarts; confirm when it comes back.
3. In Xcode, choose your iPhone as the destination (next to ▶) and press **▶ (Run)**. The first build takes several minutes.
4. If the iPhone says the developer isn't trusted: **Settings → General → VPN & Device Management** → your Apple ID → **Trust**. Then open Sintr.

**Every 7 days:** apps installed with a free Apple ID stop opening after a week. Plug the phone in and press ▶ in Xcode again — your notes stay. (With the paid $99/year Apple Developer Program this becomes once a year.)

## Moving notes between iPhone and Mac

On the iPhone: open the note → share button → **Export…** → **Sintr backup** → **Share** → AirDrop to your Mac. On the Mac: **File → Import…** and pick the file. It works the same way in the other direction. Importing a note that's already there only replaces it if the imported copy is newer.

Tip: record on the iPhone, send the note to the Mac, and Enhance it there with Apple Intelligence.

## Updating

```
bash ~/Sintr/update.sh
```
Then press ▶ in Xcode again (and run `install-mac.sh` again if you use the copy in Applications). Your notes are kept.

## Tips

- **On calls, wear headphones** if you can. Without them your Mac's microphone also hears the other person through the speakers, so some of their words show up twice — once as “Them” and once as “Me”.
- Type only the key points in **My notes**; Enhance fills in the rest from the transcript and keeps your points first.
- The first Enhance with the phone model loads it into memory and takes a little longer.

## If something goes wrong

- **“Them” stays empty on the Mac:** System Settings → Privacy & Security → Screen & System Audio Recording → allow Sintr under “System Audio Recording Only”, then quit and reopen Sintr.
- **The live transcript stopped while the phone was locked:** open the note → Transcript → **Re-transcribe from audio**. (Keep "Keep audio recordings" on in Settings so this is possible.)
- **Xcode shows a red error when building:** copy the message and paste it to Claude.
