# Security

Memo Export reads your voice recordings and their transcripts, which can be as private as anything on your Mac. So it's built to do that with as little access as possible, and to change nothing.

## Reporting a vulnerability

Please report security problems privately through **Security → Report a vulnerability** on this repository, not in a public issue. You'll get a reply within a few days.

## What Memo Export can access

| | |
|---|---|
| **The Voice Memos library, read-only** | `~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings`, through one read-only sandbox exception. It reads the list of recordings from Voice Memos' database and each transcript from inside its recording. macOS blocks it from writing there. |
| **Full Disk Access** | macOS protects the Voice Memos folder, so reading it needs Full Disk Access, which you turn on yourself. The sandbox still applies on top of it, so this doesn't widen what the app can reach. |
| **The folder you choose** | Read and write, after you pick it in the standard macOS folder picker. It's remembered with a security-scoped bookmark, which only works for this app. |
| **Its own temporary folder** | Where it copies Voice Memos' database to read it. See below. |
| **Two small files in the export folder** | `.memo-export.json`, the record of what's been exported, and `.memo-export.lock`, an empty file that keeps two exports into the same folder from running at once. |
| **Its own settings** | Your export folder and options, stored in the app's sandbox container. |

## What it can't access

- **The internet.** The app runs in the App Sandbox without a network entitlement, so macOS blocks every connection. CI checks every build for this, and that the app never starts another program, which could send something out another way. The one page it ever opens is the Full Disk Access page in System Settings.
- **The rest of your files.** Documents, downloads, desktop, photos and everything else are blocked by the sandbox, even with Full Disk Access on. A sandboxed copy was tested reading the Voice Memos folder and then Documents: the first worked and the second was denied, and writing into the Voice Memos folder was denied too.
- **Other apps.** It has no Apple Events entitlement and no Accessibility permission, so it can't read or control other apps, Voice Memos included.
- **Changing or deleting anything.** Its access to Voice Memos is read-only, and its code never deletes a file; CI checks for that. In the export folder, it never overwrites a file it didn't write, and only rewrites a note it wrote if the memo changed and you haven't touched the note since. (SQLite tidies up its own journal next to the scratch copy in the app's temporary folder. That's the only file that ever goes away.)

Check it yourself on any copy of the app:

```bash
codesign -d --entitlements - "/Applications/Memo Export.app"
```

The only entitlements are `com.apple.security.app-sandbox`, the read-only Voice Memos folder, `com.apple.security.files.user-selected.read-write` for the folder you choose, and `com.apple.security.files.bookmarks.app-scope` to remember it.

## How it handles things

- **Voice Memos' database is never opened in place.** Voice Memos writes new recordings to a journal next to its database before folding them in. Opening that database with SQLite, even read-only, can create or change those journal files. So Memo Export copies the database and its journal into its own temporary folder and opens only the copy. If Voice Memos folds the journal in or starts a new one while they're being copied, it copies them again, so the pair always matches. Reads take turns, so the app and the command line tool never share a half-written copy. The copy is overwritten on the next read, stays in the temporary folder macOS clears out, and never leaves your Mac.
- **Recordings are read a piece at a time.** Only the headers of a recording's boxes are read until the transcript is found, so a long recording's audio is never loaded into memory. A box that claims to be bigger than its file, or a transcript over 16 MB, is rejected.
- **Paths from the database are distrusted.** Only a recording's file name is used, and only a regular file directly inside the Voice Memos folder is opened, so a path in the database can't point anywhere else.
- **The export record is treated as untrusted too.** It lives in a folder you might sync or share, so every path in it must be a plain file name, or a folder and a file name, inside the export folder. A record that points anywhere else is refused, and nothing is exported until it's fixed. Before anything is written, its folder is checked again to be inside the export folder, after following links.
- **Titles and transcripts are treated as untrusted text.** File names have path separators and anything a file name or Obsidian link can't hold removed, and can't start with a dot. In the note, front matter is quoted, Markdown and Obsidian formatting in spoken words, titles and folder names is escaped, and control characters and invisible text-direction marks are removed or escaped. Times and dates far outside any real recording's are treated as damage and clamped, so they can't crash it.
- **Nothing is written inside the Voice Memos library.** The export folder can't be the library or inside it, and every folder a memo is written to is checked too, so grouping by a Voice Memos folder can't lead back into it. The command line tool checks against both the library it reads and your real one, so reading a backup can't write into the original.
- **Records it can't read stop the export.** If the folder's `.memo-export.json` is damaged or from a newer version, it stops rather than starting over and duplicating your memos. If the record goes missing, like when a sync service skips hidden files, notes already in the folder are recognized by the `voice-memo-id` in their front matter and kept as they are, not exported again.
- **The command line tool isn't sandboxed,** since it runs as you in your terminal. It uses the same code as the app, so it reads Voice Memos the same way, through a copy, and writes only into the folder you give it. CI checks that only the export code writes files.
- It has no dependencies. Every line that runs is in this repository.
