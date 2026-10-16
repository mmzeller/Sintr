# Sintr

Private meeting notes for iPhone and Mac, in the spirit of Granola — but everything happens on your own device.

- **Type your own notes while Sintr listens.** It writes a live transcript as people talk.
- **Meeting audio (Mac):** hears both sides of a call — your microphone (“Me”) and everything the Mac plays, or just one app (FaceTime, Teams, Zoom, Webex, Slack, a browser…), as “Them”. No bot joins the call.
- **Detect speakers:** after you stop, voices are labeled — Me/Them (or Them 1, Them 2…) on calls, Speaker 1, Speaker 2… in person. Click a name to rename a speaker.
- **Enhance** turns your rough notes plus the transcript into clean notes using a template (meeting notes, voice memo, to-do list, interview, lecture, 1:1, or your own). You pick where that happens.
- **Translate** notes or transcripts into other languages, on the device or with Claude.
- **Names and terms:** list the people and jargon in your meetings so Enhance and Translate spell them right.
- **Import and export** Markdown, plain text, Sintr backups and audio files. Notes are plain Markdown when exported, so Nextpad++ (and Parakeet) can open them.

The options Parakeet shows next to its Record button — meeting audio, detect speakers, save audio, language — sit right under Sintr's Record button. Everything else is in **Settings** (the gear in the toolbar, or Sintr → Settings… / ⌘,).

## Privacy: what goes where

| | Where it happens | Uses the internet? |
|---|---|---|
| Recording | Your device | No |
| Transcription | Your device (Apple's speech model) | Only a one-time model download from Apple |
| Enhance with Apple Intelligence | Your Mac (needs iPhone 15 Pro or newer on a phone) | No |
| Enhance with the phone model | Your device | Only a one-time model download from Hugging Face, when you tap Download |
| Detect speakers | Your device (open FluidAudio models) | Only a one-time download (a few dozen MB) from Hugging Face, when you agree |
| Translate with Apple Translate | Your device | Only a one-time language download from Apple |
| Send to Claude (Enhance or Translate) | Anthropic's Claude API | Yes — only when you choose it and confirm |
| Share / Export | Wherever you send it (AirDrop goes directly between devices) | Depends on where you send it |

Notes live in Sintr's private folder on each device. On iPhone they're kept out of iCloud and computer backups unless you turn that on in Settings. There is no sync: move notes between devices with **Export → Sintr backup** and **Import**.

## What works where

| | iPhone 12 | Your Mac (Apple silicon) |
|---|---|---|
| Record + live transcript | ✓ (keeps going with the screen locked) | ✓ |
| Record the other side of a call | — (iOS doesn't allow it) | ✓ |
| Detect speakers | ✓ (Speaker 1, 2… — in person) | ✓ (also Me/Them on calls) |
| Translate | ✓ | ✓ |
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

## Recording calls on the Mac

1. Under the Record button, set **Meeting audio** to **All Mac audio** (catches any call app) or pick one app. **Off** is for in-person meetings and voice notes.
2. The first time, macOS asks to let Sintr **record system audio** — click **Allow**. Without it, macOS quietly gives Sintr silence instead of the call. If you clicked Don't Allow, use the orange **Allow call audio…** button, or turn Sintr on in System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only.
3. While recording, the line under the timer says whether Sintr is hearing the call.

## Tips

- **On calls, wear headphones** if you can. Without them your Mac's microphone also hears the other person through the speakers, so some of their words show up twice — once as “Them” and once as “Me”.
- Type only the key points in **My notes**; Enhance fills in the rest from the transcript and keeps your points first.
- The first Enhance with the phone model loads it into memory and takes a little longer.

## Portable version (thumb drive or any folder)

The portable version is a **Sintr Portable** folder holding `Sintr.app` and a **Sintr Data** folder. Everything Sintr saves — notes, recordings, settings, a downloaded phone model — goes into Sintr Data, next to the app. Put the folder on a thumb drive or anywhere you like, and double-click Sintr.app to run it. Nothing gets installed.

Make it (Xcode needed on this Mac, but no Apple ID or signing team):

```
bash ~/Sintr/update.sh
bash ~/Sintr/make-portable.sh /Volumes/YOURDRIVE
```

Replace `YOURDRIVE` with your thumb drive's name — or type `bash ~/Sintr/make-portable.sh ` (with a space at the end) and drag the drive into the Terminal window. With no drive or folder named, it makes `Sintr Portable` in your home folder. If this Mac already has Sintr notes, it offers to copy them in.

**Updating:** run the same command again with the same drive or folder. The app is replaced; Sintr Data is never touched.

**Good to know:**
- It runs on Macs with Apple silicon (M1 or newer) on macOS 26 or newer.
- The first time on each Mac, macOS asks to let Sintr use the microphone, record system audio and, on a thumb drive, access files on a removable volume — click **Allow**. Sintr also asks once per Mac to download Apple's speech model. A Claude key, if you add one, stays on that Mac and never goes on the drive.
- **Quit Sintr before ejecting the drive**, or the note you're working on may not be saved.
- **Format the drive APFS (Encrypted)** if you can (Disk Utility → select the drive → Erase → Format: APFS (Encrypted) — this wipes the drive). Then a lost drive doesn't expose your notes, and Macs handle it best. A Windows-style exFAT drive also works.
- Settings → Storage shows **Portable** and where the notes are, with a Show in Finder button.
- Back up the Sintr Data folder now and then. If the drive is lost or fails, so are the notes on it.

The iPhone app isn't affected; this is only for the Mac.

## If something goes wrong

- **“Them” stays empty on the Mac:** System Settings → Privacy & Security → Screen & System Audio Recording → allow Sintr under “System Audio Recording Only”, then quit and reopen Sintr.
- **The live transcript stopped while the phone was locked:** open the note → Transcript → **Re-transcribe from audio**. (Keep "Keep audio recordings" on in Settings so this is possible.)
- **Terminal says `xcodebuild requires Xcode, but active developer directory … is a command line tools instance`:** run `bash ~/Sintr/update.sh` once — newer versions of `install-mac.sh` find Xcode by themselves. (Or switch Terminal to Xcode for good: `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.)
- **Xcode says the Metal toolchain is missing:** Xcode → Settings → Components → Metal Toolchain → Get. It's a one-time download the phone model needs.
- **Portable Sintr says it's using “this Mac's own storage”:** keep Sintr.app and the Sintr Data folder side by side in the same folder, and if macOS asked about access to a removable volume or your Desktop, allow it (System Settings → Privacy & Security → Files & Folders → Sintr).
- **Xcode shows a red error when building:** copy the message and paste it to Claude.
