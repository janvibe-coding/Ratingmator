# Ratingmator — Specification

Version 0.8 · 31 Oct 2026 · Replaces v0.7. Based on tests run 30 Sep – 4 Oct and 31 Oct 2026 with Photomator 3.4.15.

## 1. Purpose and scope

A small native Mac app that makes Photomator's star ratings and flags reliable across Macs, drives, folder moves and sidebar changes.

**In scope:** star ratings (0–5) and flags (pick / reject) shown in Photomator's Files browser.

**Out of scope:** develop settings, edits, Lightroom catalogs, keywords, other metadata.

**Principle:** the files are the source of truth. Photomator's list is rebuilt from them.

## 2. The workflow it supports

- Photos live in folders on external drives, not in Apple Photos.
- The **main library** is on the main Mac. A **working library** sits on a portable drive and is used on a laptop. A third Mac has its own library.
- Project folders are copied whole, one subfolder at a time: main → portable, and back when done.
- Folders may be moved or rearranged in the main library afterwards.
- Folders get added to and removed from Photomator's sidebar.
- Culling may happen in another app, e.g. Photo Mechanic or Lightroom, which may write ratings only to the RAW's sidecar.
- The same app runs on every Mac. There is no network link between Macs: the files carry the ratings.

## 3. How Photomator handles ratings (confirmed by testing)

### 3.1 Its list

- One list per Mac:
  `~/Library/Group Containers/4R6749AYRE.com.pixelmator/Library/Files Library/FilesLibrary.plist`
- Binary plist. Top-level keys: `version` (3), `directories`, `looseImages`, `flagsAndRatings`, `directoryOrder`, `displaysFolderContentsRecursively`.
- `flagsAndRatings.ratedAssets`: full path → stars 1–5. Unrated means no entry.
- `flagsAndRatings.flaggedAssets`: full path → `1` (pick) or `-1` (reject). No flag means no entry.
- Paths are plain strings. Folder names with accents use the spelling as stored on disk (NFD on the drives tested), and that works.
- **Photomator shows ratings from this list**, and only from this list.
- **For a RAW+JPEG pair the key is always the JPG**, whatever the "open RAW / open JPG" setting.
- **Rating a photo that shows as unrated overwrites the rating it hid.** Photomator doesn't check the file first; for a pair it overwrites the JPG's.
- **Removing a folder from the sidebar deletes all its entries.** Re-adding the folder doesn't bring them back reliably.
- Photomator **writes the list while running**, not only when it quits.
- `directories` holds the sidebar folders with macOS security bookmarks. Only Photomator creates these.

### 3.2 What it writes into the files

Photomator writes to the file **immediately** on every rating or flag change, besides updating its list.

| File type | Where the rating and flag go | Not touched |
|---|---|---|
| JPG only | inside the JPG | — |
| RAW only (RAF) | `.xmp` sidecar: created if missing, otherwise updated in place | the RAF |
| DNG | `.xmp` sidecar | the DNG itself |
| RAW+JPEG pair | **inside the JPG only** | the RAF, and the RAF's sidecar |

- The fields written:
  - `xmp:Rating`: 0–5. **0 is written explicitly** when a rating is removed.
  - `xmpDM:pick`: 1 pick, −1 reject, 0 none
  - `xmpDM:good`: True for a pick, False for a reject
  - `xmp:MetadataDate`
- **Existing sidecars (from Lightroom) are updated in place.** Document ID, history, camera profile and namespaces are kept. Only empty fields were seen to disappear.
- **New sidecars** get the camera's EXIF copied in (about 5 KB).
- Sidecar extensions on the drives tested are both `.xmp` and `.XMP`. Match case-insensitively.

### 3.3 When it reads the files back

- Only **occasionally**:
  - when a folder is added: complete for a small folder, partial for a large library
  - now and then afterwards
  - It's not predictable: thousands of sidecar ratings on the main Mac were never picked up.
  - On 31 Oct, a newly added folder of 18 photos showed the values of its JPGs and pairs, but not those of RAW-only and DNG sidecars. A small folder's read isn't complete either. The app never relies on these reads: it writes the list.
- For a pair, it reads the **RAF sidecar**, not the JPG. When it does, it can **overwrite existing list entries** with the sidecar's value. Seen 3 Oct: 2 ratings and 67 picks were reverted to stale Lightroom values.

### 3.4 The resulting problem

Photomator writes a pair's rating to the JPG, but may read it back from the RAF sidecar. Its list, the only thing it shows, doesn't travel and disappears when a folder leaves the sidebar. Yet every rating Photomator sets is already in the files. Only the RAF sidecar of a pair is missing it.

## 4. Workflow

Ratingmator holds no ratings itself: the folders do. It has no status screen.

### 4.1 Start

1. **At launch, close Photomator.** If it's running, the app asks to quit it (section 7). Photomator stays closed while Ratingmator runs.
2. **Start window:** two large buttons, each with one line under it, and one small button:
- **Save ratings to photos**: Gives the JPG and RAW of each photo the same rating. (4.2)
- **Load ratings into Photomator**: Does the same, then updates Photomator. (4.3)
- **Restore earlier Photomator ratings** (small; greyed out while there are no backups) (4.4)

### 4.2 Save ratings to photos

1. **Choose.** A window where the user drops one or more folders (subfolders included). A **Scan** button.
2. **Scan.** A count of photos and a Cancel button. Nothing is written.
3. **Summary** (4.5). The action button says what it will do.
4. **Apply.** Back up the sidecars, write the files (section 6.1). A result line in counts, then back to the start window.

### 4.3 Load ratings into Photomator

The list never updates the photos: the photos win.

1. **Scan** the sidebar folders on this Mac whose drive is connected. There's no folder choice. Folders on a drive that isn't connected keep their list entries.
2. **Summary** (4.5), plus one line: "The value of X photos will be updated in Photomator." A rating only in the list is removed: the file wins.
3. A conflict may stay on Ignore, to decide it in Photomator. Nothing is written for that photo, in the files or in the list; whatever the list holds for it stays. A large warning says how many photos this is: "X photos with a conflict will not be updated in Photomator."
4. **Apply.**
   1. Back up the sidecars and write the files (section 6.1).
   2. If a file failed, stop: the list isn't overwritten, and the result says so.
   3. Back up the list, overwrite it (section 6.2) and verify (section 8).
5. **Result:** counts, with two buttons: **Open Photomator** (which also quits Ratingmator) and **Quit**.

### 4.4 Restore an earlier list

1. **Choose** one of the earlier lists in Ratingmator's backup folder (date, time, counts).
2. **Compare** it with the current list and the photos.
3. **Summary:**
   - ratings and flags that will change in the list
   - the sidebar folders that will change
   - photos and folders in the chosen list that no longer exist on this Mac, flagged
   - the count of photos whose files hold another value than the chosen list (Save may have changed a JPG since), and one choice for them: **Ignore** (the default) or **Use these ratings**
   - **Cancel**, and an action button that says what it will do
4. **Apply.**
   1. Back up the current list and put the chosen list back as a whole, sidebar folders included.
   2. With **Use these ratings**: back up the sidecars and write the list's value to those photos' JPG and sidecar.
5. **Result:** counts, with two buttons: **Open Photomator** (which also quits Ratingmator) and **Quit**.

### 4.5 Summaries and conflicts

- At the top, a table: **JPG only**, **RAW only** and **RAW + JPG**, each with its count of photos, of each rating (none, 1–5), of picks and of rejects. A pair counts by its JPG. **Per folder**, closed by default, opens a tree of the same counts: the highest level of folders first, each expanding one level deeper, down to the last.
- The words "sidecar" and "list" aren't used. What counts is the RAW's rating, and updating Photomator.
- Rows in a tree have an alternating shade, so a folder and its box on the far right stay together.
- Below it, the conflicts between a pair's JPG and RAW. Each different kind of conflict gets its own line and choice, saying what differs: RAW has a rating and JPG doesn't, RAW's rating is higher, JPG's is higher; RAW has a pick and JPG doesn't, RAW has a reject and JPG doesn't, JPG pick against RAW reject, JPG reject against RAW pick; and any rating kind together with any flag kind. A kind without photos doesn't show.
- The choices, in this order: **Ignore** (the default), **Decide one by one**, **Pick rating of JPG file**, **Pick rating of RAW file**, **Pick highest rating**, **Pick lowest rating**. An ignored photo is left as it is.
- Under each line, **Per folder**, closed by default, opens the same tree for the folders with that conflict, each with its count and own choice. A folder's choice covers everything under it. When folders differ, the box above them shows **Mixed**, and picking a value there sets them all again.
- **Decide one by one** always opens a separate window with those photos; the main window holds no photo rows. An **Open** button next to the box reopens it. The window has pages and no scrollbar: a page holds as many rows as fit, and the arrow keys or Previous and Next move between pages.
- In that window, each row has a thumbnail (the JPG, or the RAW's embedded preview when there's no JPG), the name, the rating and flag of the JPG and the RAW, and the options **JPG**, **RAW** or **New**: set stars 0–5 and pick / reject / no flag by hand. Preselected: the source with the highest rating.
- Nothing is written until the action button is pressed. Its text says what will happen and updates with the choices, such as "Copy rating of 35 JPGs to their RAW". With nothing to do it reads "Nothing to change" and is greyed out.

### 4.6 Backups

- **List:** before every list write, a dated copy goes to `~/Library/Application Support/Ratingmator/backups/`. All are kept.
- **Sidecars:** before every file write, a zip of every sidecar about to change goes to the same folder. Sidecars are small.
- **JPGs:** not copied, because of size (about 20 MB each). ExifTool writes them safely (a temporary file, then swapped in) and changes only the four fields.

### 4.7 First launch

If Ratingmator has no Full Disk Access, the start window shows where to grant it instead of the three buttons.

## 5. Determining the value

Per photo, separately for stars and flag.

### 5.1 Where to read

| Photo | Read from |
|---|---|
| JPG only (also HEIC, PNG, TIFF: treated like JPG, metadata inside the file; untested) | the file |
| RAW only / DNG | its `.xmp` sidecar |
| Pair (a RAW or DNG with a JPG of the same name: Photomator treats both as a pair) | the JPG **and** the RAW's sidecar |

### 5.2 Conflicts

Photomator writes a pair's rating to the JPG, so:

- **A RAW without a value takes the JPG's.** That's no conflict. Without a value means no field, a rating of 0 or no flag.
- **A RAW with a value that differs from the JPG is a conflict.** It needs a look. A JPG's 0 counts here: a rated RAW against an unrated JPG is a conflict.
- In the one-by-one window, the source chosen for a photo decides both its stars and its flag where they conflict; "new" sets both by hand.
- For flags, highest and lowest rank pick, then reject, then no flag: any flag beats no flag. No rating counts as 0.

## 6. Writing

### 6.1 Files

- The value goes into every file of the photo, but only where a file **differs**:
  - JPG only (and HEIC, PNG, TIFF): inside the file
  - RAW only, or DNG: the `.xmp` sidecar, created if missing
  - pair: inside the JPG and in the RAF's `.xmp` sidecar
- The fields are the four Photomator writes: `xmp:Rating` (0 explicit), `xmpDM:pick`, `xmpDM:good`, `xmp:MetadataDate`. Nothing else is changed, with two exceptions:
  - a new sidecar also holds the RAW's camera EXIF, as Photomator's do, or the four fields alone if that can't be read
  - a file with no XMP toolkit name gets ExifTool's
- A written file keeps its creation date, permissions and Finder tags. Its modification date changes.

### 6.2 List

- Only photos inside a folder that's in Photomator's sidebar on this Mac, since Photomator removes entries for folders that aren't there.
- Keys follow Photomator's rules: a pair uses the JPG path; RAW-only and DNG photos use their own path.
- Stars 1–5 go into `ratedAssets`; 0 removes the entry. Pick/reject go into `flaggedAssets`; none removes the entry.

## 7. Quitting Photomator

- Photomator's bundle ID: `com.pixelmatorteam.pixelmator.touch.x.photo`
- At launch, if Photomator is running, ask to quit it. Ratingmator doesn't continue while Photomator is open.
- Before every Apply, check again; if Photomator was reopened in the meantime, ask to quit it again.
- Quit it normally (like ⌘Q), never force-quit.
- Wait up to 30 seconds. If it's still running, stop and say so.

## 8. Safety rules

1. Refuse to work if the list's `version` isn't 3 or its structure is unexpected.
2. Only ever change `flagsAndRatings`. Never touch `directories`, the bookmarks, or other keys. The one exception is Restore backup, which puts back a whole list that Photomator itself wrote earlier.
3. Back up before every list write, and before every sidecar write.
4. Write the list as a binary plist, through a temporary file that is then swapped in.
5. After writing, read the list back and check three things:
   - it's valid
   - all other keys are unchanged
   - the counts match the summary
   On any failure, restore the backup.
6. The key order changes when the list is written. Photomator opened lists written by Python (3 Oct) and by Swift (31 Oct) fine.
7. Compare file names in Unicode-normalised form, but write list keys in the on-disk spelling.
8. File writes go through ExifTool, and change only `xmp:Rating`, `xmpDM:pick`, `xmpDM:good` and `xmp:MetadataDate`, apart from the exceptions in section 6.1.
9. Nothing is written without a summary and an explicit Apply.
10. The app makes no network connections.

## 9. Not in scope / later

- Develop settings and Lightroom edits (section 1).
- Cleaning up list entries for files that no longer exist: later.
- Notarization through a paid Apple Developer account: only if needed when sharing.

## 10. Technical choices

- Swift + SwiftUI in Xcode. A native macOS app named **Ratingmator**.
- App Sandbox **off**. The app reads and writes another app's Group Container and external drives. It needs Full Disk Access.
- **ExifTool bundled inside the app**, run with macOS's Perl, so users install nothing else. If Perl ever disappears from macOS, fall back to Apple's ImageIO.
- Reading XMP needs only the first ~300 KB of a JPG; sidecars are small. A full scan of about 130,000 files on the studio drive took about 4 minutes. Files are written only where values differ, because rewriting a 20 MB JPG is the slow part.
- Lists are read and written with `PropertyListSerialization` (binary format).
- **Minimum macOS: 13 Ventura**, the same as Photomator 3.4.15 (App Store listing, checked 30 Oct 2026). Use no SwiftUI features newer than that.
- Free Apple ID signing. On other Macs, the first launch needs approval in System Settings → Privacy & Security.
- **Open source.** The app is unnotarized and asks for Full Disk Access, so anyone using it must be able to check the code:
  - the code lives in git from day one, with a commit after each working step
  - before any public sharing, it goes to a public repository (e.g. GitHub), under an open licence (MIT suggested), with ExifTool's own licence included
  - the README states exactly which files the app reads and writes, and that it makes no network connections
  - instructions to build it yourself from source, so nobody has to trust a downloaded binary

## 14. Open questions

- After the app writes correct RAF sidecars, does Photomator stop reverting list entries? Still being tested.
- Where does Photomator write ratings for HEIC, PNG and TIFF? Not tested.
- Does Photomator read anything written inside a RAW/DNG file itself, when there's no sidecar?
