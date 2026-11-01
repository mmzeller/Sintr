# Sintr

Private meeting notes for iPhone and Mac, in the spirit of Granola — but everything happens on your own device.

- **Type your own notes while Sintr listens.** It writes a live transcript as people talk.
- **Meeting audio (Mac):** hears both sides of a call — your microphone (“Me”) and everything the Mac plays, or just one app (FaceTime, Teams, Zoom, Webex, Slack, a browser…), as “Them”. No bot joins the call.
- **Live input meters:** on the Mac, the microphone and call-audio meters run all the time (not just while recording), so you can check what Sintr hears before you press Record.
- **Echo removal:** without headphones your microphone also hears the call; Sintr drops those duplicate “Me” lines as you record, and again more precisely afterwards.
- **Detect speakers:** after you stop, voices are labeled — Me/Them (or Them 1, Them 2…) on calls, Speaker 1, Speaker 2… in person. Click a name to rename a speaker.
- **Remembers voices:** name a speaker once — yourself as “Me”, a colleague by name — and Sintr puts that name on the voice in later recordings, on this device only. In person, that's how Sintr knows which voice is you, so your action items go to Sectis as yours.
- **Notices calls (Mac):** when Zoom, Teams, FaceTime, Webex, Slack or a call in your browser starts using the microphone, a small panel offers to take notes. When the call ends with goodbyes (or goes quiet for 10 minutes), it offers to stop, with a countdown you can cancel.
- **Enhance** turns your rough notes plus the transcript into clean notes using a template (meeting notes, voice memo, to-do list, interview, lecture, 1:1, or your own). You pick where that happens.
- **Translate** notes or transcripts into other languages, on the device or with Claude.
- **Names and terms:** list the people and jargon in your meetings so Enhance and Translate spell them right.
- **Hides names from Claude:** before anything goes to Claude, people's names become placeholders (Person_1, Person_2…), and the real names are put back in the answer on your device.
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
| Remembered voices | Your device (voice fingerprints in Sintr's folder — numbers, not recordings) | No — never sent, exported or shared |
| Noticing calls (Mac) | Your Mac (which apps are using the microphone — never what they hear) | No |
| Translate with Apple Translate | Your device | Only a one-time language download from Apple |
| Ask with Apple Intelligence or the local model | Your device (search is on-device too) | No |
| Claude (Enhance, Ask or Translate) | Anthropic's Claude API, with people's names replaced by placeholders on your device first (Settings → Claude) | Yes — only when you choose Claude |
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
| Recognize voices you've named | ✓ (your voice as “Me” in person) | ✓ |
| Notice calls and offer to take notes | — (iOS doesn't let apps see each other) | ✓ |
| Hide names from Claude | ✓ | ✓ |
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

**After upgrading to a new macOS (27):** install the matching Xcode (27) from the App Store, open it once so it finishes setting up, then run the update and install as above. Sintr is built and run on macOS 27 with Xcode 27 by the automated checks, so it's ready for it. The copy you already have keeps working after the upgrade; building a new one is what needs the new Xcode.

## Recording calls on the Mac

The first time Sintr opens, **Let Sintr transcribe your meetings** lists everything recording needs — your microphone, the other side of calls, Apple's speech model, and telling voices apart — with an Allow or Download button for each. Open it again any time from ⋯ → **Set up recording…** (or Recording → Set Up Recording… on the Mac).

1. Under the Record button, set **Meeting audio** to **All Mac audio** (catches any call app) or pick one app. **Off** is for in-person meetings and voice notes.
2. The first time, macOS asks to let Sintr **record system audio** — click **Allow**. Without it, macOS quietly gives Sintr silence instead of the call. If you clicked Don't Allow, use the orange **Allow call audio…** button, or turn Sintr on in System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only.
3. The meters under the Record button show what Sintr hears **right now** — your microphone, and the call side (“quiet”, “waiting for Teams”, or “not allowed” if macOS is giving it silence). Play something before a meeting to check it.
4. When you stop, the note is ready straight away. Speaker detection then runs in the background (a spinner shows next to the note); **Skip** stops it and keeps the live transcript. You can delete a note at any time, even while that runs.

**Sintr notices calls.** When a call app — Zoom, Microsoft Teams, FaceTime (and iPhone calls on the Mac), Webex, Slack, Discord, WhatsApp, or Chrome, Safari, Edge, Firefox, Arc or Brave — has been using your microphone for a few seconds, a panel at the top right of the screen asks **Take notes?** Nothing is recorded until you press **Take notes**; it then starts a note called “Zoom call” (or whichever app) and records your microphone and that call (even if Meeting audio is Off, which is for in-person meetings). **Not now** skips this call; **Don't offer for Zoom calls again** stops asking for that app (undo it in Settings → Recording). Sintr only sees *which* apps are using the microphone — the same thing that lights up macOS's orange dot — never what they hear, and it needs no permission for that.

While Sintr records a call — whether it offered or you pressed Record — it also notices when the call app lets go of the microphone. If the last words sound like goodbyes (“thanks everyone”, “talk to you later”, “bye”), the panel says **Sintr stops recording in 15 s** with **Keep recording** and **Stop now**. If the call ends without goodbyes, it keeps going; after 10 minutes with no call and nothing heard, it asks the same way (90-second countdown). Recordings under 2 minutes never stop by themselves. Turn either part off in Settings → Recording.

## Recognizing voices

After speaker detection, voices are labeled Speaker 1, Speaker 2… (or Them 1, Them 2… on a call). **Click (or tap) a speaker's name** to name them. Pick **Me (this is you)** for yourself, a name Sintr already knows, or type one. With **Recognize this voice in future notes** on (it is unless you turn it off), Sintr keeps a *voice fingerprint* — a list of numbers describing how that voice sounds, not a recording of it — and the next time it hears that voice, it puts the name on it. A recognized name has a small waveform next to it: click it to confirm it, change it, or press **Not Dana** if Sintr got it wrong (it then forgets what it learned from that note).

- **Name yourself “Me” once on your iPhone**, and in-person recordings label your voice “Me” from then on — so Enhance writes your action items with you as the owner, and Sintr sends them to Sectis as yours. On the Mac, calls already know you: your microphone is “Me”.
- Each voice keeps up to 8 fingerprints, from different notes, so it's recognized in different rooms and on different microphones. Sintr only uses a name when it's clearly that voice and no one else's; a voice that could be either of two people stays unnamed.
- The other side of a call is never labeled “Me”, and two speakers in one note never get the same remembered name.
- **Settings → Speakers** lists the voices Sintr remembers. Rename one (give it the name of another to join them), forget one, or forget them all. Turning **Recognize voices I've named** off stops both learning and recognizing.
- Fingerprints stay on the device that learned them, in Voices.json in Sintr's folder (the portable folder, in portable mode; out of iPhone backups unless you include notes in backups). They're never sent anywhere, exported, or put in shared folders — so your iPhone and your Mac each learn voices from their own recordings.

## Hiding names from Claude

When you choose Claude for Enhance, Ask or Translate, **Hide people's names from Claude** (Settings → Claude, on by default) swaps names for placeholders on your device before anything is sent — “Person_1 said Person_2's budget is fine” — and swaps them back in Claude's answer as it arrives, so you only ever see real names. It hides:

- the speakers you've named, the voices Sintr remembers, and your own name (the names in Settings → Integrations → Sectis, and your Mac account's name), and
- any other personal names Apple's on-device language model finds in the text, like “ask Jordan about it”.

A misheard spelling of someone you've named (“Dayna Whitfield” for Dana Whitfield) gets the same placeholder, so it comes back spelled right; so does a first name on its own. “Me”, “Them” and “Speaker 2” stay as they are, and so do company, product and place names. Names that are also ordinary words (Will, Faith) are only hidden where they're written as a name. Claude still sees what was said, just not who said it, so it can still write “Person_1 will send the report” — which you see as “Dana will send the report”. Share to another app (which you send yourself) isn't changed.

## Tips

- **On calls, wear headphones** if you can. Without them your Mac's microphone also hears the other person through the speakers. **Remove echo** (Settings → Recording, on by default) drops most of those duplicates, but headphones are cleanest.
- Live meters keep the microphone open, so macOS shows its orange microphone indicator while Sintr is open. Nothing is saved or transcribed until you press Record. Turn them off in Settings → Recording if you prefer.
- Type only the key points in **My notes**; Enhance fills in the rest from the transcript and keeps your points first.
- **Typing on the iPhone:** once the keyboard is up, the title, tabs and Record button step aside so your notes get the screen between the toolbar and the keyboard (if something is recording, a one-line strip with Stop stays). Tap **Done** at the top, or swipe down on the notes, to put the keyboard away and bring them back.
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

Sintr can put a meeting's action items into your [Sectis](https://github.com/mmzeller/sectis) to-do list, so they show up on your Mac and iPhone with the rest of your to-dos: yours as to-dos, and other people's in Sectis's **Waiting For**, so you know to follow up.

1. In Sectis, turn on sync (Settings → Sync), then choose **Add Another Device** and **Copy Code**.
2. In Sintr: **Settings → Integrations → Sectis**, paste the code into **Join code** and press **Save**. **Test connection** checks it.
3. Turn on **Send after Enhance** if you want new notes to send their action items by themselves.

**Each note has its own Send to Sectis switch**: next to the date on the Mac, on the Enhanced tab on iPhone, and in the Enhance window on both. It starts the way **Send after Enhance** is set; turn it off in a note to skip that meeting, or to look the items over before they go.

**Where they go:** the **Inbox**, unless you pick one of your Sectis projects or areas. The menu beside the switch (on the Mac), on the Sectis card at the end of the Enhanced tab, in the Enhance window and in Review & send lists them; **Use for Every Note in “folder”** makes it the choice for that whole folder. If a project has since been finished or deleted in Sectis, the items go to the Inbox instead.

**Review & send** (on the Enhanced tab, or **Share → Send to → Sectis**) lists the action items from that note, yours first and then **Waiting on others**. Untick any you don't want, fix the wording, change who an item is waiting on, add, change or remove a deadline or follow-up date, then **Send**.

What gets sent:

- **Your unchecked action items:** the owner is “Me” (Enhance writes that for your tasks), “you”, “everyone”, or one of the names in **Names you go by** (on a Mac, your account's name if you leave it empty). Items under a heading or label with your name count too, like “**Matthew**” or “Matthew's next steps”.
- **Other people's**, to Waiting For: an item whose owner is someone else (“Send the quote — Dana”, “Dana to send the contract”), or that's listed under their name (“**Dana**”, “Dana's next steps”). It's filed under their name, and a date in it becomes the follow-up date, when it comes back to Sectis's Today. Turn this off in **Settings → Integrations → Sectis → Send other people's items to Waiting For**.
- An item that doesn't name an owner is yours only when nobody else is in the note — a voice memo, or notes you typed alone. Otherwise it isn't sent.
- Each one is tagged **Meeting** (and with the project's or area's tags, as Sectis does). Its notes say which meeting it came from, with an **Open in Sintr** link back to the note. Lines indented under an item become its checklist. A due date (“by Friday”, “Oct 31”, “end of week”) becomes its deadline.
- Automatic sending happens once per note. Use Review & send later to add new items; ones already sent from that note — even if you've reworded them, or completed or deleted them in Sectis — aren't added again.

**After they're sent,** the Sectis card at the end of the Enhanced tab lists them as they are in Sectis now: done, still open (with the deadline), or waiting on someone. On a Mac, click one to open it in Sectis — Sintr learns your Sectis's address the first time you open a Sintr link from Sectis, or you can type it in Settings → Integrations → Sectis.

**Links between the two:**

- **Open in Sintr**, in a to-do's notes in Sectis, opens the meeting's note. (Notes don't sync between your devices, so it opens the note on the device that has it.)
- **Record in Sintr**, in the ••• menu of a Sectis project, area or to-do, starts a new Sintr note with that title whose action items go back to the same project or area. Sintr asks before it starts recording.

Sintr writes straight to the Firebase project Sectis syncs through, encrypting each to-do with the key in your join code, so it works even when Sectis isn't open; they appear the next time it is. Your names and Sectis choices stay on this device: **Share your setup** leaves the Sectis settings out.

## Shared folders

1. Create a folder (⋯ → New folder…), then right-click it → **Share…** and pick a place your team can all reach — a OneDrive, Dropbox, Google Drive or iCloud Drive folder, or a network share.
2. Teammates choose ⋯ → **Open shared folder…** and pick the same place.
3. Everyone sees the same notes; Sintr checks for changes every 15 seconds. If two people change the same note at the same time, the later save is kept as “(conflict copy)” so nothing is lost. Audio recordings stay on the device that made them.

## If something goes wrong

- **Building says “Unable to log in with account …” or “No signing certificate "Mac Development" found”:** Xcode's saved Apple sign-in doesn't work any more. `install-mac.sh` builds without it, so the Mac app still installs. For the iPhone: **Xcode → Settings → Accounts**, remove that account with **−**, add the Apple ID you use now with **+**, and choose its team under Signing & Capabilities.
- **Moving to a different Apple ID:** if the old Sintr is still on your iPhone and opens, export your notes first (⋯ → Export all notes… → Sintr backup → AirDrop to your Mac) — the copy installed with your new Apple ID is a separate app. Import the backup into it, then delete the old one.

- **Start with the Activity Log** (Help → Activity Log… on the Mac, Settings → Troubleshooting on iPhone). It records which microphone and output device Sintr used, audio formats, when sound and words first arrived, timings and errors — never what anyone said. It keeps the previous session too, and on the Mac it shows a summary of the last crash. **Copy** it into a message to Claude.

- **Sintr froze or its window went blank:** the Activity Log notes when Sintr stops responding and what the audio was doing at that moment (it's saved to disk, so it's there after a force quit, under the previous run). Copy it into a message to Claude.
- **“Them” stays empty on the Mac:** System Settings → Privacy & Security → Screen & System Audio Recording → allow Sintr under “System Audio Recording Only”, then quit and reopen Sintr.
- **The live transcript stopped while the phone was locked:** open the note → Transcript → **Re-transcribe from audio**. (Keep "Keep audio recordings" on in Settings so this is possible.)
- **Terminal says `xcodebuild requires Xcode, but active developer directory … is a command line tools instance`:** run `bash ~/Sintr/update.sh` once — newer versions of `install-mac.sh` find Xcode by themselves. (Or switch Terminal to Xcode for good: `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.)
- **Xcode says the Metal toolchain is missing:** Xcode → Settings → Components → Metal Toolchain → Get. It's a one-time download the phone model needs.
- **Portable Sintr says it's using “this Mac's own storage”:** keep Sintr.app and the Sintr Data folder side by side in the same folder, and if macOS asked about access to a removable volume or your Desktop, allow it (System Settings → Privacy & Security → Files & Folders → Sintr).
- **Xcode shows a red error when building:** copy the message and paste it to Claude.
