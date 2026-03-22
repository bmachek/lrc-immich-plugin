# Pull Request: Fix original+export stacking, UI clarity, reliability bugs, and upload resiliency

## Summary

This PR fixes the `original_plus_jpeg_if_edited` export mode (issue #91), corrects several bugs that caused duplicate uploads and wrong stack ordering, improves UI labeling, addresses memory and timeout issues that caused failures on large exports, and replaces the batch-collect upload path with a per-photo-pair streaming accumulator to eliminate temp-disk exhaustion on large exports. All DNG/JPG-specific naming and file-type hardcoding has been replaced with format-agnostic equivalents so the stacking feature works correctly for any original+export pairing (DNG+JPG, CR2+TIF, TIF+JPG, etc.).

---

## Bug fixes

### 1. Stack primary image was wrong (ExportTask.lua)

**Problem:** `createStack({ id, exportId })` was called with the original file first. Immich uses the first element as the stack's key/cover image, so the unedited original was shown as the primary instead of the edited export.

**Fix:** Swapped to `createStack({ exportId, id })` so the rendered export is the primary in both `processOnePhotoGroup` and `processSingleRenditionRenditions`.

---

### 2. Album received the wrong asset (ExportTask.lua)

**Problem:** After creating a stack, both code paths added the original (`id`) to the album and recorded it as the primary, even when the edited export was available.

**Fix:** Introduced a `primaryId` variable that defaults to `id` and is updated to `exportId` when the export upload succeeds. Album assignment and `exportedPrimaryByPhoto` now use `primaryId`.

---

### 3. "Original / no reformat" produced two identical uploads (ExportTask.lua, ExportDialogSections.lua)

**Problem:** When Lightroom's export format is set to "Original / no reformat", Lightroom copies the source file byte-for-byte without rendering an edited version. The plugin then uploaded both copies as if they were distinct, resulting in two identical files in Immich with no meaningful stack.

**Fix:**
- Added a runtime guard in both `processOnePhotoGroup` and `processSingleRenditionRenditions`: if `LR_format == "ORIGINAL"`, skip the rendered export upload and emit a stack warning instead.
- Added a live warning in the export dialog (orange text) when this incompatible combination is detected.
- Detection uses `exportParams.LR_format` directly — no hardcoded format lists.

---

### 4. original+export stacking deviceAssetId was position-dependent (ExportTask.lua, PublishTask.lua)

**Problem:** Device asset IDs for multi-rendition groups were generated as `lid_1`, `lid_2` based on loop position. If one rendition failed to render, subsequent files shifted positions and collided with previously uploaded asset IDs on retry, causing Immich's dedup check to match the wrong asset.

**Fix:** Keyed by actual file extension (`lid_dng`, `lid_jpg`, `lid_tif`, etc.) using `util.getExtension(item.path)`. The ID is now stable regardless of rendering failures and agnostic to file format.

---

### 5. `checkIfAssetExists` used inconsistently (ExportTask.lua)

**Problem:** The `original_only` / `original_plus_jpeg_if_edited` path in `processOnePhotoGroup` called the basic `checkIfAssetExists`, while `processSingleRenditionRenditions` called `checkIfAssetExistsEnhanced`. The enhanced version also checks stored Lightroom metadata (`immichAssetId`) and legacy `localIdentifier` uploads. This meant a photo previously exported via one path would not be recognised as already uploaded when re-exported via the other, creating duplicate assets.

**Fix:** Changed the `processOnePhotoGroup` original path to use `checkIfAssetExistsEnhanced` consistently.

---

### 6. Upload timeout too low for large files (ImmichAPI.lua)

**Problem:** `HTTP_TIMEOUT_UPLOAD` was 15 seconds. A 50 MB RAW file at 10 Mbps takes ~40 s; a 100 MB video at 5 Mbps takes ~160 s. Uploads that exceeded 15 s silently failed with no retry. `HTTP_TIMEOUT_DEFAULT` (5 s) was also applied to API calls like stacking and album operations that may legitimately take longer on slow servers.

**Fix:** Increased `HTTP_TIMEOUT_UPLOAD` to 300 s (5 min) and `HTTP_TIMEOUT_DEFAULT` to 30 s. Also added an explicit timeout to `doPostRequest`, which previously relied on an undocumented LrHttp default.

---

### 7. High memory usage when replacing assets (ImmichAPI.lua)

**Problem:** `generateMultiPartBody` built the multipart request body using repeated Lua string concatenation (`body = body .. chunk`). Lua strings are immutable, so each `..` allocated a new copy of all previous content. For a 50 MB RAW file this created ~100 MB of peak heap pressure just to build the request body.

**Fix:** Accumulated body parts in a Lua table and called `table.concat(parts)` once at the end, performing a single allocation.

---

### 8. `hasEdits` ran redundant catalog queries when cache was present (StackManager.lua)

**Problem:** When an `editedPhotosCache` was provided but the photo was not in it (meaning no edits), the function fell through to a fallback that ran two full `catalog:findPhotos` queries anyway — the same queries that were used to build the cache. For large catalogs this meant two extra full-catalog scans per unedited photo.

**Fix:** When a cache is present it is now used exclusively. A cache miss immediately returns `false` without any fallback queries. Function comment updated to accurately describe this behaviour.

---

### 9. Inline accumulator replaces batch-collect in original+export flow (ExportTask.lua, PublishTask.lua)

**Problem:** `processStackOriginalExportRenditions` (and its publish counterpart) called `UploadHelpers.collectRenditions`, which waited for every rendition across the entire export batch to finish rendering before the first upload began. On large exports this caused all temp files to accumulate on disk simultaneously, risking temp-disk exhaustion and delaying any upload feedback.

**Fix:** Replaced `collectRenditions` + `groupByPhoto` with an inline accumulator loop in both `processStackOriginalExportRenditions` (ExportTask.lua) and `processPublishStackOriginalExportRenditions` (PublishTask.lua). Each photo group is flushed — uploaded, stacked, temp files deleted — as soon as both of its renditions have arrived. Groups where one rendition failed to render are flushed as a single-item group at the end of the loop. `UploadHelpers.collectRenditions` and `groupByPhoto` are retained for other callers.

Edge cases handled:

- Render failure on one of a pair → single-item flush at end; `processOnePhotoGroup` already handles the 1-item case.
- Cancellation mid-export → already-flushed groups have temp files deleted; in-progress accumulator items remain (same as single-rendition path).
- Interleaved renditions from different photos → accumulator correctly groups by `localIdentifier` regardless of render order.

---

### 10. Missing warning when rendered export upload fails (ExportTask.lua)

**Problem:** In `processOnePhotoGroup`, when the `original_plus_jpeg_if_edited` mode uploaded the original successfully but the rendered export upload returned nil, the failure was silent — no entry was added to `stackWarnings`. The equivalent path in `processSingleRenditionRenditions` did emit a warning.

**Fix:** Added an `else` branch to append `"failed to upload rendered export"` to `stackWarnings` when `exportId` is nil, matching the behaviour of the single-rendition path.

---

## Format-agnostic cleanup

The original+export stacking feature was implemented with DNG+JPG as the only use case in mind. All format-specific naming and file-type logic has been removed so the feature works correctly for any pairing (DNG+JPG, CR2+TIF, original JPG+export JPG, etc.).

### Renamed identifiers

| Before | After | Files |
| ------ | ----- | ----- |
| `stackDngJpg` (preference key + bindings) | `stackOriginalExport` | ExportServiceProvider.lua, PublishServiceProvider.lua, ExportDialogSections.lua, PublishDialogSections.lua, ExportTask.lua, PublishTask.lua |
| `processStackDngJpgRenditions` | `processStackOriginalExportRenditions` | ExportTask.lua |
| `processPublishStackDngJpgRenditions` | `processPublishStackOriginalExportRenditions` | PublishTask.lua |
| `sortDngJpgItems` | `sortOriginalExportItems` | UploadHelpers.lua |
| `jpegId` | `exportId` | ExportTask.lua |
| `existingJpegId` | `existingExportId` | ExportTask.lua |
| `existingJpegDeviceId` | `existingExportDeviceId` | ExportTask.lua |

### Sort logic made format-agnostic (UploadHelpers.lua)

**Before:** `sortDngJpgItems` sorted by file type (`jpeg=1`, `raw=2`, `other=3`). For pairings where the export is not a JPEG (e.g., DNG+TIF), the sort placed the original first, making it the Immich stack primary — the opposite of the intended behaviour.

**After:** `sortOriginalExportItems` identifies the original by comparing `item.path` to `StackManager.getOriginalFilePath(item.photo)`. The export (non-original) always sorts first regardless of format.

### File-type checks removed (ExportTask.lua, PublishTask.lua)

**Before:** `processOnePhotoGroup` / `processPublishOnePhotoGroup` computed `hasRaw` and `hasJpeg` from each item's file type and only stacked when both were present (`shouldStackDngJpg = hasRaw and hasJpeg`). Any pairing that wasn't exactly raw+jpeg would skip stacking silently.

**After:** `#items >= 2` is the only condition for stacking. Any two renditions for the same photo in `stackOriginalExport` mode are treated as an original+export pair.

### Dead code removed (StackManager.lua, UploadHelpers.lua, ExportTask.lua, PublishTask.lua)

- `StackManager.getFileType` and `RAW_EXT` removed — no longer called.
- `fileType` field removed from item tables in all three accumulators — was populated but never read after the file-type checks were removed.

---

## UI improvements

- **ExportDialogSections.lua:** Dropdown labels updated to be format-agnostic; "Original / no reformat" warning added (orange text).
- **PublishDialogSections.lua:** Stack section label `"DNG+JPG:"` → `"Original + Export:"`, checkbox `"Stack in Immich (edited JPG as primary)"` → `"Stack in Immich (export as primary)"`.

> **Note:** The `stackDngJpg` preference key has been renamed to `stackOriginalExport`. Users with existing export presets or publish collections that had the stacking checkbox enabled will need to re-enable it after updating.

---

## Known limitations

### Upload timeout is configurable by editing ImmichAPI.lua

`HTTP_TIMEOUT_UPLOAD` is now 300 s (5 min). If uploads still time out on very large files or slow connections, increase this value in `ImmichAPI.lua`. A future improvement would be to expose this as a plugin setting.

### Stack warnings in the post-export dialog

If any individual upload or stack creation fails, it is reported as a warning after export completes rather than aborting the entire run. Check the post-export dialog and the log file (`ImmichPlugin.log`) for `"failed to upload"` or `"failed to create stack"` entries. Re-exporting is self-healing: duplicate detection finds previously uploaded assets, missing companions are uploaded fresh, and stacks are created once both IDs are available.

---

## Files changed

| File | Changes |
|------|---------|
| `ExportTask.lua` | Stack order fix, album primary fix, LR_format guard (×2), `checkIfAssetExistsEnhanced`, extension-based deviceAssetId, inline accumulator, missing export-upload warning, format-agnostic renames |
| `PublishTask.lua` | Extension-based deviceAssetId, inline accumulator, format-agnostic renames |
| `ExportDialogSections.lua` | Warning UI, updated dropdown labels, section label rename, `stackOriginalExport` bind |
| `PublishDialogSections.lua` | Section label and checkbox text updated, `stackOriginalExport` bind |
| `ExportServiceProvider.lua` | `stackOriginalExport` preference key |
| `PublishServiceProvider.lua` | `stackOriginalExport` preference key |
| `ImmichAPI.lua` | Timeout increases, `table.concat` multipart body, explicit POST timeout |
| `StackManager.lua` | `hasEdits` cache short-circuit and comment fix, removed `getFileType` / `RAW_EXT` |
| `UploadHelpers.lua` | `sortOriginalExportItems` with path-based sort, removed `fileType` field, updated comment |
