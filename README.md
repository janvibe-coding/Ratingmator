# Ratingmator

Keeps Photomator's star ratings and flags reliable across Macs, drives, folder moves and sidebar changes.

Photomator shows ratings from a hidden list that doesn't travel with your photos, and loses entries when a folder moves or leaves the sidebar. Its copies in the files are often fine, but it reads them back only now and then. For RAW+JPEG pairs it writes the rating to the JPG and may read it back from the RAW's sidecar.

Ratingmator fixes missing ratings in Photomator from the metadata stored in the jpg's or sidecars. For raw+jpg pictures, it can copy the rating and flag Photomator stores in the jpg, to the raw's side car, so that the rating is readable in Bridge or Lightroom. The other way works as well, ratings in the raw's side car (written in bridge or lightroom) can get copied to the jpgs.

- **Save ratings to photos** gives the JPG and RAW of each photo the same rating.
- **Load ratings into Photomator** does the same, then updates Photomator from the photos in its sidebar folders.
- **Restore earlier Photomator ratings** puts back an earlier version.

Star ratings and flags only. No develop settings or edits.

## Install

1. Download the `.dmg` from [Releases](../../releases) and drag Ratingmator into Applications.
2. Open it. The app isn't notarized, so macOS blocks it the first time. Go to System Settings → Privacy & Security and click **Open Anyway**.
3. Give it access under System Settings → Privacy & Security → **Full Disk Access**, then reopen it.

macOS 13 Ventura is the minimum, though it has only been tested on newer versions. Written for Photomator 3.4.15.

## What it reads and writes

Reads:

- Photomator's list: `~/Library/Group Containers/4R6749AYRE.com.pixelmator/Library/Files Library/FilesLibrary.plist`
- JPG, HEIC, PNG, TIFF and RAW files, and `.xmp` sidecars, in the folders you choose or in Photomator's sidebar

Writes, only after you press the button on the summary:

- The fields `xmp:Rating`, `xmpDM:pick`, `xmpDM:good` and `xmp:MetadataDate`, inside JPG, HEIC, PNG and TIFF files and in `.xmp` sidecars. New sidecars also get the camera's data from the RAW. RAW files themselves are never changed.
- `flagsAndRatings` in Photomator's list. Restore replaces the whole list with an earlier copy.
- Backups in `~/Library/Application Support/Ratingmator/backups/`: every list before it changes, and a zip of every sidecar before it changes. All are kept.

JPGs aren't backed up, because of their size. Each is written to a new file, read back and checked, and only then swapped in. Keep your own backup of your photos.

It makes no network connections. It needs Full Disk Access to reach Photomator's list, and the app asks you to quit Photomator before it writes.

## Build it yourself

Everything is here, so you don't have to trust a downloaded app. You need Xcode.

1. Open `Ratingmator.xcodeproj`.
2. Under Signing & Capabilities, choose your own team.
3. Choose Product → Scheme → Edit Scheme, set Run to **Release**, and run it.

A Debug build doesn't touch your real list. It reads `~/Ratingmator-debug/FilesLibrary.plist` instead, so you can try things on a copy.

The tests run with Product → Test. `SPEC.md` holds the design and what was found out about how Photomator behaves.

## Licence

MIT, see `LICENSE`. Includes [ExifTool](https://exiftool.org) by Phil Harvey, under its own licence.

Not affiliated with Photomator or Pixelmator.
