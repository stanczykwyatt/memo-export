# Contributing

Thanks for helping out! Bug reports, ideas and pull requests are all welcome.

## Reporting a memo it read wrong

If a memo is missing, has the wrong title or folder, or its transcript comes out wrong, open a [bug report](https://github.com/stanczykwyatt/memo-export/issues/new?template=bug.yml) with your macOS version and what you expected. Please don't attach a recording or paste a transcript: describe it instead, like "a 40-minute memo in French with long pauses".

If Voice Memos changes how it stores recordings in a new macOS version, the output of this command helps the most. It lists only the database's table and column names, nothing you recorded:

```bash
sqlite3 -readonly "file:$HOME/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/CloudRecordings.db?immutable=1" ".schema ZCLOUDRECORDING"
```

## Getting started

You need macOS 14 or later and Swift 6 (Xcode 16 or the Command Line Tools).

```bash
swift test                # run the tests
scripts/build-app.sh      # build "Memo Export.app" and memo-export into ./build
open "build/Memo Export.app"
```

Reading the library, the recordings and their transcripts, writing the notes and subtitles, the export record, search, the command line tool and all the wording live in `Sources/MemoCore`, with tests in `Tests/MemoCoreTests`. Those tests build made-up libraries in throwaway folders: a database shaped like Voice Memos' own and recordings with transcripts inside. Changes to how paragraphs are split belong in `Transcript.swift`, with a test that describes the speech.

The menu bar app, the menu and the window are in `Sources/MemoExport`, tested in `Tests/MemoExportTests` with a made-up library and windows that are never shown. No test reads your Voice Memos, writes outside a throwaway folder or puts anything on screen.

To redraw the art: `swift scripts/make-icon.swift`, `swift scripts/make-art.swift`, and `SCREENSHOT_DIR=docs swift test --filter Window` for the screenshots.

## Ground rules

- **No network access, ever.** Pull requests that add a network entitlement, cloud transcription or third-party analytics won't be merged.
- **Read-only.** Memo Export never changes, moves or deletes anything in Voice Memos, and never deletes anything anywhere.
- **Your files win.** Never overwrite a file the exporter didn't write, or a note you've changed.
- **Least access.** No new entitlements or folders without a very good reason.
- **No new dependencies** without a very good reason. The app has none today, which keeps it easy to audit.
- **Made-up memos only** in screenshots, art, tests and bug reports.
- Run `swift test` before opening a pull request, and add tests for changes to `MemoCore`.
- Keep commits small, with a short message saying what changed and why.

## Security issues

Please don't open public issues for vulnerabilities. See [SECURITY.md](SECURITY.md).
