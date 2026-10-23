# Sintr

Private meeting notes for iPhone and Mac, in the spirit of Granola — but everything happens on your own device.

- **Type your own notes while Sintr listens.** It writes a live transcript as people talk.
- **Meeting audio (Mac):** hears both sides of a call — your microphone (“Me”) and everything the Mac plays, or just one app (FaceTime, Teams, Zoom, Webex, Slack, a browser…), as “Them”. No bot joins the call.
- **Live input meters:** on the Mac, the microphone and call-audio meters run all the time (not just while recording), so you can check what Sintr hears before you press Record.
- **Echo removal:** without headphones your microphone also hears the call; Sintr drops those duplicate “Me” lines as you record, and again more precisely afterwards.
- **Detect speakers:** after you stop, voices are labeled — Me/Them (or Them 1, Them 2…) on calls, Speaker 1, Speaker 2… in person. Click a name to rename a speaker.
- **Enhance** turns your rough notes plus the transcript into clean notes using a template (meeting notes, voice memo, to-do list, interview, lecture, 1:1, or your own). You pick where that happens.
- **Translate** notes or transcripts into other languages, on the device or with Claude.
- **Names and terms:** list the people and jargon in your meetings so Enhance and Translate spell them right.
- **Ask:** chat with one note (“what did I commit to?”, “draft the follow-up email”) or across all of them (“what did we decide about the budget last week?”), with links back to the notes each answer came from.
- **Folders and shared folders:** organize notes in folders. Put a folder in OneDrive, iCloud Drive, Dropbox or a network share and everyone who opens it in Sintr works on the same notes — no Sintr account or server.
- **Integrations:** send a note to Notion, HubSpot, Attio, Affinity, or anywhere through a Zapier / Make / n8n / Power Automate webhook.
- **Sectis:** your own action items go straight to your Sectis Inbox after Enhance — only the ones that are yours, encrypted on your device the same way Sectis encrypts its own.
- **AI apps and scripts (Mac):** an MCP server lets Claude Desktop, Claude Code and other AI apps read your notes when you allow it; a local API and a command line give scripts read-only access.
- **Import and export** Markdown, plain text, Sintr backups and audio files. Notes are plain Markdown when exported, so Nextpad++ (and Parakeet) can open them.

The options Parakeet shows next to its Record button — meeting audio, detect speakers, save audio, language — sit right under Sintr's Record button on the Mac; on iPhone they're in the options menu (the sliders icon) beside it, so the note keeps the screen. Everything else is in **Settings** (the gear in the toolbar, or Sintr → Settings… / ⌘,).

## Privacy: what goes where

| | Where it happens | Uses the internet? |
|---|---|---|
| Recording | Your device | No |
| Transcription | Your device (Apple's speech model) | Only a one-time model download from Apple |
| Enhance with Apple Intelligence | Your Mac (needs iPhone 15 Pro or newer on a phone) | No |
| Enhance with the phone model | Your device | Only a one-time model download from Hugging Face, when you tap Download |
| Detect speakers | Your device (open FluidAudio models) | Only a one-time download (a few dozen MB) from Hugging Face, when you agree |
| Translate with Apple Translate | Your device | Only a one-time language download from Apple |
| Ask with Apple Intelligence or the local model | Your device (search is on-device too) | No |
| Claude (Enhance, Ask or Translate) | Anthropic's Claude API | Yes — only when you choose Claude |
| Send to Notion / HubSpot / Attio / Affinity / webhook | That app | Yes — when you press Send, or after Enhance if you turned that on for Notion or a webhook |
| Send action items to Sectis | Your own Firebase project, encrypted on your device first (Firebase only stores scrambled data) | Yes — when you press Send, or after Enhance if you turned that on |
| Shared folders | The folder you chose | Only through whatever syncs that folder (OneDrive, iCloud…) |
| MCP server, local API, command line (Mac) | Your Mac (local API: 127.0.0.1 only, token required) | No — what an AI app does with an answer is up to that app |
| Share / Export | Wherever you send it (AirDrop goes directly between devices) | Depends on where you send it |

Notes live in Sintr's private folder on each device (or in a shared folder you chose). On iPhone they're kept out of iCloud and computer backups unless you turn that on in Settings. Sintr has no sync service of its own: move notes between devices with **Export → Sintr backup** and **Import**, or keep them in a shared folder.

Nothing is used to train AI. Apple Intelligence and the local model run on your device; Anthropic doesn't use what its API receives for training without your express permission.

## Sintr compared with Granola

Granola's Basic and Business plans list these features. Here's where each one is in Sintr — no account, no subscription.

| Granola | Sintr |
|---|---|
| AI meeting notes | **Enhance** with templates — on your device (Apple Intelligence or a local model) or with Claude |
| Meeting history (limited on Basic) | Unlimited — every note stays until you delete it |
| AI chat within and across meetings | **Ask** tab on each note; **Ask Sintr** (⌘J) across all notes, with links to the notes each answer used. Works offline with Apple Intelligence or the local model |
| Shared folders for collaboration | **Folders**; **Share…** puts a folder in OneDrive, iCloud Drive, Dropbox or a network share for your team. Edits merge; if two people change the same note at once, both versions are kept |
| Customized note templates | Built-in templates you can edit, plus your own (Settings → Templates) |
| Multi-language support | Transcription in Apple's supported languages, **Write enhanced notes in** any language, Translate, and Ask answers in the language you ask in |
| Opt out of model training | Nothing to opt out of: Sintr never trains on your notes |
| Unlimited meeting notes and history | ✓ |
| Advanced AI thinking models | Claude Opus 5.5, Fable 5.1, Sonnet 5.5 or Haiku 5.5 with a **Thinking** level (Settings → Claude); on the Mac, Qwen3 4B / 8B as the most capable models that never leave it |
| Integrations with Attio, Notion, HubSpot, Affinity, Zapier | **Share → Send to…** Notion, HubSpot, Attio, Affinity, or a webhook for Zapier, Make, n8n or Power Automate (Settings → Integrations). Notion and webhooks can receive notes automatically after Enhance — and your own action items can go to Sectis |
| Centralized billing & user management | No billing or accounts to manage. **Settings → Team setup → Share your setup…** gives teammates the same templates, names and terms, defaults and integration targets |
| MCP integration in all your apps | Built-in MCP server on the Mac (Settings → Connections): one click adds it to Claude Desktop; works with Claude Code and other MCP apps. Read-only and off until you turn it on |
| API access | Local read-only API on the Mac (`/v1/notes`, `/v1/notes/{id}`, `/v1/search`, `/v1/folders`, token required) and a command line (`Sintr --cli list / search / get / folders`) |

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
| Ask (one note or all notes) | ✓ (local model or Claude) | ✓ (also Apple Intelligence) |
| Folders, shared folders, integrations | ✓ | ✓ |
| MCP server, local API, command line | — | ✓ |

Needs iOS 26 or macOS 26, and Xcode 26 or newer on the Mac.

## First time on your Mac

1. Install **Xcode** from the Mac App Store (it's free, and large — let it finish), then open it once and let it install its extra components.
2. Open **Terminal**, download Sintr and install it:
   ```
   git clone https://github.com/mmzeller/Sintr.git ~/Sintr
   bash ~/Sintr/install-mac.sh
   ```
3. Sintr opens from your Applications folder and shows **Let Sintr transcribe your meetings** — allow the microphone and call audio, and download the speech model.

No Apple account is needed on the Mac. (If you set up a signing team for the iPhone below, the Mac app is signed with it too, so macOS remembers Sintr's permissions across updates. Without one, macOS may ask for the microphone and call audio again after an update.)

## Put it on your iPhone

The iPhone needs an Apple Account in Xcode — any Apple ID works, including the free one you use for the App Store:

1. Open the project: `open ~/Sintr/Sintr.xcodeproj`. In Xcode: **Xcode → Settings → Accounts**. If an account is listed that you can't sign in to any more, select it and press **−**. Then **+** → Apple Account, and sign in with your Apple ID. Close Settings.
2. In the left column click the blue **Sintr** icon at the very top, then **Signing & Capabilities**, and under **Team** choose your name (Personal Team). (The iPhone app's ID is `io.github.mmzeller.Sintr.iphone`.)
3. Connect the iPhone to the Mac with a cable and unlock it. If it asks "Trust This Computer?", tap **Trust**.
4. On the iPhone: **Settings → Privacy & Security → Developer Mode** → on. It restarts; confirm when it comes back.
5. In Xcode, choose your iPhone as the destination (next to ▶) and press **▶ (Run)**. The first build takes several minutes.
6. If the iPhone says the developer isn't trusted: **Settings → General → VPN & Device Management** → your Apple ID → **Trust**. Then open Sintr.

**Every 7 days:** apps installed with a free Apple ID stop opening after a week. Plug the phone in and press ▶ in Xcode again — your notes stay. (With the paid $99/year Apple Developer Program this becomes once a year.)

## Moving notes between iPhone and Mac

On the iPhone: open the note → share button → **Export…** → **Sintr backup** → **Share** → AirDrop to your Mac. On the Mac: **File → Import…** and pick the file. It works the same way in the other direction. Importing a note that's already there only replaces it if the imported copy is newer.

Tip: record on the iPhone, send the note to the Mac, and Enhance it there with Apple Intelligence.

## Updating

```
bash ~/Sintr/update.sh
```
Then run `bash ~/Sintr/install-mac.sh` (and `make-portable.sh` for the portable copy, or ▶ in Xcode for the iPhone). Your notes are kept.

## Recording calls on the Mac

The first time Sintr opens, **Let Sintr transcribe your meetings** lists everything recording needs — your microphone, the other side of calls, Apple's speech model, and telling voices apart — with an Allow or Download button for each. Open it again any time from ⋯ → **Set up recording…** (or Recording → Set Up Recording… on the Mac).

1. Under the Record button, set **Meeting audio** to **All Mac audio** (catches any call app) or pick one app. **Off** is for in-person meetings and voice notes.
2. The first time, macOS asks to let Sintr **record system audio** — click **Allow**. Without it, macOS quietly gives Sintr silence instead of the call. If you clicked Don't Allow, use the orange **Allow call audio…** button, or turn Sintr on in System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only.
3. The meters under the Record button show what Sintr hears **right now** — your microphone, and the call side (“quiet”, “waiting for Teams”, or “not allowed” if macOS is giving it silence). Play something before a meeting to check it.
4. When you stop, the note is ready straight away. Speaker detection then runs in the background (a spinner shows next to the note); **Skip** stops it and keeps the live transcript. You can delete a note at any time, even while that runs.

## Tips

- **On calls, wear headphones** if you can. Without them your Mac's microphone also hears the other person through the speakers. **Remove echo** (Settings → Recording, on by default) drops most of those duplicates, but headphones are cleanest.
- Live meters keep the microphone open, so macOS shows its orange microphone indicator while Sintr is open. Nothing is saved or transcribed until you press Record. Turn them off in Settings → Recording if you prefer.
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

## Connecting AI apps and scripts (Mac)

In **Settings → Connections**:

- **Let AI apps read my notes (MCP)**, then **Add to Claude Desktop** (quit and reopen Claude Desktop afterwards). For Claude Code, **Copy Claude Code command** and paste it into Terminal. Other MCP apps: **Copy MCP config**. The AI app can search notes, list them, read one, and list folders — nothing else.
- **Local API on this Mac**: turn it on, copy the token, and call it from scripts while Sintr is open:

  ```
  curl -H "Authorization: Bearer <token>" "http://127.0.0.1:52817/v1/notes?since=7d"
  curl -H "Authorization: Bearer <token>" "http://127.0.0.1:52817/v1/search?q=budget"
  curl -H "Authorization: Bearer <token>" "http://127.0.0.1:52817/v1/notes/<id>?transcript=true&format=markdown"
  ```

- **Command line** (works even when Sintr isn't open):

  ```
  /Applications/Sintr.app/Contents/MacOS/Sintr --cli search budget
  /Applications/Sintr.app/Contents/MacOS/Sintr --cli list --since 7d --json
  /Applications/Sintr.app/Contents/MacOS/Sintr --cli get <id> --transcript
  ```

## Sending your action items to Sectis

Sintr can put the action items that are yours into your [Sectis](https://github.com/mmzeller/sectis) Inbox, so they show up on your Mac and iPhone with the rest of your to-dos.

1. In Sectis, turn on sync (Settings → Sync), then choose **Add Another Device** and **Copy Code**.
2. In Sintr: **Settings → Integrations → Sectis**, paste the code into **Join code** and press **Save**. **Test connection** checks it.
3. Turn on **Send after Enhance** if you want new notes to send their action items by themselves.

**Each note has its own Send to Sectis switch**: next to the date on the Mac, on the Enhanced tab on iPhone, and in the Enhance window on both. It starts the way **Send after Enhance** is set; turn it off in a note to skip that meeting, or to look the items over before they go.

**Review & send** (on the Enhanced tab, or **Share → Send to → Sectis**) lists your action items from that note. Untick any you don't want, fix the wording, add, change or remove a deadline, then **Send**. The Enhanced tab also shows how many items are yours and when they were last sent.

What gets sent:

- **Only unchecked action items that are yours:** the owner is “Me” (Enhance writes that for your tasks), “you”, “everyone”, or one of the names in **Names you go by** (on a Mac, your account's name if you leave it empty). Items under a heading or label with your name count too, like “**Matthew**” or “Matthew's next steps”.
- An item that doesn't name an owner is sent only when nobody else is in the note — a voice memo, or notes you typed alone.
- Each one lands in the **Inbox**, tagged **Meeting**, with the meeting's name and date in its notes. A due date in the item (“by Friday”, “Oct 31”, “end of week”) becomes its deadline.
- Automatic sending happens once per note. Use Review & send later to add new items; ones already sent from that note — even if you've reworded them, or completed or deleted them in Sectis — aren't added again.

Sintr writes straight to the Firebase project Sectis syncs through, encrypting each to-do with the key in your join code, so it works even when Sectis isn't open; they appear the next time it is. Your names stay on this device: **Share your setup** leaves the Sectis settings out.

## Shared folders

1. Create a folder (⋯ → New folder…), then right-click it → **Share…** and pick a place your team can all reach — a OneDrive, Dropbox, Google Drive or iCloud Drive folder, or a network share.
2. Teammates choose ⋯ → **Open shared folder…** and pick the same place.
3. Everyone sees the same notes; Sintr checks for changes every 15 seconds. If two people change the same note at the same time, the later save is kept as “(conflict copy)” so nothing is lost. Audio recordings stay on the device that made them.

## If something goes wrong

- **Building says “Unable to log in with account …” or “No signing certificate "Mac Development" found”:** Xcode's saved Apple sign-in doesn't work any more. `install-mac.sh` builds without it, so the Mac app still installs. For the iPhone: **Xcode → Settings → Accounts**, remove that account with **−**, add the Apple ID you use now with **+**, and choose its team under Signing & Capabilities.
- **Moving to a different Apple ID:** if the old Sintr is still on your iPhone and opens, export your notes first (⋯ → Export all notes… → Sintr backup → AirDrop to your Mac) — the copy installed with your new Apple ID is a separate app. Import the backup into it, then delete the old one.

- **Start with the Activity Log** (Help → Activity Log… on the Mac, Settings → Troubleshooting on iPhone). It records which microphone and output device Sintr used, audio formats, when sound and words first arrived, timings and errors — never what anyone said. It keeps the previous session too, and on the Mac it shows a summary of the last crash. **Copy** it into a message to Claude.

- **“Them” stays empty on the Mac:** System Settings → Privacy & Security → Screen & System Audio Recording → allow Sintr under “System Audio Recording Only”, then quit and reopen Sintr.
- **The live transcript stopped while the phone was locked:** open the note → Transcript → **Re-transcribe from audio**. (Keep "Keep audio recordings" on in Settings so this is possible.)
- **Terminal says `xcodebuild requires Xcode, but active developer directory … is a command line tools instance`:** run `bash ~/Sintr/update.sh` once — newer versions of `install-mac.sh` find Xcode by themselves. (Or switch Terminal to Xcode for good: `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.)
- **Xcode says the Metal toolchain is missing:** Xcode → Settings → Components → Metal Toolchain → Get. It's a one-time download the phone model needs.
- **Portable Sintr says it's using “this Mac's own storage”:** keep Sintr.app and the Sintr Data folder side by side in the same folder, and if macOS asked about access to a removable volume or your Desktop, allow it (System Settings → Privacy & Security → Files & Folders → Sintr).
- **Xcode shows a red error when building:** copy the message and paste it to Claude.
