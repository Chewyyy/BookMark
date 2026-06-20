# Pre-Option-2 Snapshot

Snapshot taken before introducing word-count-based stats.

## Files backed up

These are byte-identical copies of the working tree at the moment before
the Option 2 implementation began:

- `Models.swift`
- `EPUBImporter.swift`
- `EPUBPackage.swift`
- `ReaderView.swift`
- `Store.swift`
- `StatsView.swift`
- `SessionCSV.swift`
- `BackupMigration.swift`

## Files added by Option 2 (delete to revert)

- `App/EPUBWordCounter.swift` (new file)

## To revert everything

```bash
# From repo root
cp .bookmark-backups/option2-pre-words/*.swift App/
rm -f App/EPUBWordCounter.swift
```

Then in Xcode: remove the reference to `EPUBWordCounter.swift` from the
BookMark target (if it was added) and clean build folder.
