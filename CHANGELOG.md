# Changelog

## 0.1.0 (2026-11-04)

First release.

- **Export Voice Memos** to a folder you choose: each recording's audio, plus a Markdown note with its title, date, length, folder and the whole transcript in paragraphs with timestamps.
- **Only new memos on each run,** with a record in the export folder so nothing is duplicated.
- **Notes stay up to date without losing your edits:** a transcript that arrives later, or a renamed memo, updates a note only if you haven't changed it.
- **Automatic export** of new memos, off until you turn it on.
- **Obsidian-friendly notes,** with front matter, a `voice-memo` tag and an audio embed, or standard Markdown links.
- **Optional SRT subtitles** and subfolders matching your Voice Memos folders.
- **A window to search what was said** across every memo, and copy any transcript with its paragraphs, with or without timestamps.
- **The `memo-export` command line tool** to list, print and export memos.
- **Open at login**, on by default and easy to turn off.
- Runs in the App Sandbox with no network access, read-only access to Voice Memos, and write access only to the folder you choose.
