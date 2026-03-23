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

- Added a runtime guard in `processSingleRenditionRenditions` (`original_plus_jpeg_if_edited` path): if `LR_format == "ORIGINAL"`, skip the rendered export upload and emit a stack warning instead.
- Added a live warning in the export dialog (orange text) when this incompatible combination is detected, discouraging the combination before export starts.
- Detection uses `exportParams.LR_format` directly — no hardcoded format lists.

---

### 4. original+export stacking deviceAssetId was unstable and collision-prone (ExportTask.lua, PublishTask.lua)

**Problem:** Device asset IDs for multi-rendition groups were generated as `lid_1`, `lid_2` based on loop position. If one rendition failed to render, subsequent files shifted positions and collided with previously uploaded asset IDs on retry, causing Immich's dedup check to match the wrong asset. Keying by file extension (`lid_dng`, `lid_jpg`) addressed position-dependency but introduced a new collision when both renditions share the same extension (e.g. JPEG source exported as JPEG) or `util.getExtension` returns `""` — both uploads receive the same `deviceAssetId` and Immich deduplicates the wrong asset.

**Fix:** Established a role-based `deviceAssetId` scheme: `_export` for the rendered export (primary in Immich) and `_orig` for the disk original. Each item receives an `isOriginal` flag (true if the rendered file's extension matches the source file's extension) and an `insertionOrder` counter to support sorting. `sortOriginalExportItems` in UploadHelpers.lua sorts items so the export comes first. The `_export`/`_orig` naming is used in both the `#items == 1` path (the active path — see fix #14) and the `#items >= 2` path (kept as a defensive fallback but currently unreachable since LR delivers exactly one rendition per photo).

**Idempotency:** On re-export, `checkIfAssetExists` finds each asset by exact `deviceAssetId` and calls `replaceAsset` rather than uploading fresh, so repeated exports of the same photo produce exactly one original and one export in one stack.

---

### 5. `checkIfAssetExistsEnhanced` used in wrong path (ExportTask.lua)

**Problem:** The `stackOriginalExport` multi-rendition path used `checkIfAssetExistsEnhanced` for asset lookups. The enhanced version also checks stored Lightroom `immichAssetId` metadata, which points to the primary (export) asset. Using it in this path risked matching the primary when looking up the original, then calling `replaceAsset` on the wrong asset and corrupting the export.

**Fix:** The entire `stackOriginalExport` path (`processOnePhotoGroup`, `processPublishOnePhotoGroup`) uses only basic `checkIfAssetExists` via `StackManager.uploadOneAssetOrReplace`, keyed by stable role-based `deviceAssetId` (`_orig`/`_export`). The enhanced check is retained exclusively in `processSingleRenditionRenditions`, where stored metadata correctly identifies the single primary asset per photo.

---

### 6. Upload timeout too low and not consistently applied (ImmichAPI.lua)

**Problem:** `HTTP_TIMEOUT_UPLOAD` was 15 seconds — far too short for large RAW files or slow connections. Uploads that exceeded 15 s silently failed with no retry. `HTTP_TIMEOUT_DEFAULT` (5 s) was also applied to API calls like stacking and album operations that may legitimately take longer on slow servers. Additionally, the main upload path (`uploadAsset` → `doMultiPartPostRequest` → `LrHttp.postMultipart`) had no timeout argument at all, so the constant had no effect on multipart POST uploads even after being increased.

**Fix:** Increased `HTTP_TIMEOUT_UPLOAD` to 300 s (5 min) and `HTTP_TIMEOUT_DEFAULT` to 30 s. Added an explicit timeout to `doPostRequest` (previously relied on an undocumented LrHttp default). Wired `HTTP_TIMEOUT_UPLOAD` into `LrHttp.postMultipart` in `doMultiPartPostRequest` so the timeout now applies to all upload paths.

---

### 7. High memory usage when uploading assets (ImmichAPI.lua)

**Problem:** The original `replaceAsset` path called `doMultiPartPutRequest`, which called `generateMultiPartBody` to build the multipart body by reading the entire file into memory (`fh:read("*all")`). For a 50 MB RAW file this created ~50 MB of peak heap pressure just for the request body, plus additional copies during string concatenation.

**Fix:** `replaceAsset` now delegates to `uploadAsset`, which passes the file via a `filePath` entry in the `LrHttp.postMultipart` content table. Lightroom streams the file directly from disk — no in-memory copy of the file content is made at all. The old `generateMultiPartBody`, `doMultiPartPutRequest`, `createHeadersForMultipartPut`, and `generateBoundary` functions were removed as dead code (see fix #19).

---

### 8. `hasEdits` ran redundant catalog queries when cache was present (StackManager.lua)

**Problem:** When an `editedPhotosCache` was provided but the photo was not in it (meaning no edits), the function fell through to a fallback that ran two full `catalog:findPhotos` queries anyway — the same queries that were used to build the cache. For large catalogs this meant two extra full-catalog scans per unedited photo. The function header comment also incorrectly implied the fallback always ran.

**Fix:** When a cache is present it is now used exclusively. A cache miss immediately returns `false` without any fallback queries. Function comment updated to accurately describe this behaviour.

---

### 9. Inline processing replaces batch-collect in original+export flow (ExportTask.lua, PublishTask.lua)

**Problem:** `processStackOriginalExportRenditions` (and its publish counterpart) called `UploadHelpers.collectRenditions`, which waited for every rendition across the entire export batch to finish rendering before the first upload began. On large exports this caused all temp files to accumulate on disk simultaneously, risking temp-disk exhaustion and delaying any upload feedback.

**Fix:** Replaced `collectRenditions` + `groupByPhoto` with inline per-rendition processing (see also fix #17, which completed this by removing an intermediate accumulator). Each rendition is uploaded and stacked immediately as it arrives, interleaving renders and uploads. `UploadHelpers.collectRenditions` and `groupByPhoto` had no remaining callers after this change and were removed.

---

### 10. Missing warning when rendered export upload fails (ExportTask.lua)

**Problem:** In `processOnePhotoGroup`, when the `original_plus_jpeg_if_edited` mode uploaded the original successfully but the rendered export upload returned nil, the failure was silent — no entry was added to `stackWarnings`. The equivalent path in `processSingleRenditionRenditions` did emit a warning.

**Fix:** Added an `else` branch to append `"failed to upload rendered export"` to `stackWarnings` when `exportId` is nil, matching the behaviour of the single-rendition path.

---

### 11. `#items == 1` single-rendition fallback: wrong file, wrong ID, dead code (ExportTask.lua, PublishTask.lua)

**Problem:** When only one of the two expected renditions arrived for a photo (e.g., the export render failed), `processOnePhotoGroup` and `processPublishOnePhotoGroup` fell into a `#items == 1` path with three bugs:

1. **Wrong file uploaded as export.** When `items[1].isOriginal == true` (original copy arrived, export failed to render), the code still uploaded `items[1].path` as the "rendered export" — producing an identical duplicate rather than skipping.

2. **Inconsistent `deviceAssetId` naming.** The path used `lid` (no suffix) for the original and `lid_edited` for the export, while the `#items >= 2` branch used `_orig`/`_export`. On re-export when both renditions arrive, dedup fails to match the previous `lid`/`lid_edited` assets by exact `deviceAssetId`, causing redundant uploads.

3. **Dead `else` block.** Both functions contained an `else` block with a loop over all items including positions `i > 1`. The accumulator flushes at exactly 2 items (handled by `#items >= 2`), so `#items > 2` is unreachable. The `i > 1` loop body was dead code. Additionally, `processPublishOnePhotoGroup` recorded `exportedPrimaryByPhoto[lid]` (inconsistent with `photo.localIdentifier` used in `#items >= 2`) and added each individual item to the album instead of only the primary.

**Fix:** Both functions now have a unified `elseif #items == 1` branch that:

- Reads `item.isOriginal` to determine the role of the single rendition.
- Assigns `lid_orig` if the original copy arrived, `lid_export` if the rendered export arrived — consistent with `#items >= 2`.
- If the export arrived (`isOrig == false`): in **export mode**, fetches the disk original via `getOriginalFilePath`, uploads it with `lid_orig`, and creates a stack. In **publish mode**, the disk original is intentionally NOT uploaded — an asset uploaded outside `rendition:recordPublishedPhotoId` cannot be tracked by Lightroom and would become an orphan when the photo is later removed from the publish collection (`deletePhotosFromPublishedCollection` only cleans up assets registered via `recordPublishedPhotoId`). A stack warning is emitted instead.
- If the original arrived (`isOrig == true`): uploads with `lid_orig`; emits a warning if `original_plus_jpeg_if_edited` mode was active and the photo has edits (with the `LR_format == "ORIGINAL"` guard; export path only).
- Records only the primary in `exportedPrimaryByPhoto` and in the album.

The dead `else` block is removed from both functions.

---

### 12. `processPhotoWithStack` called redundantly in `#items >= 2` path (ExportTask.lua)

**Problem:** After uploading both renditions and creating a stack in the `stackOriginalExport` `#items >= 2` branch, the code additionally called `StackManager.processPhotoWithStack`. That function re-fetches the disk original, uploads it under a second `deviceAssetId` (using the `_original` suffix scheme from `generateOriginalDeviceAssetId`), and creates a second Immich stack — resulting in a duplicate original asset and a spurious extra stack.

**Fix:** Removed the `processPhotoWithStack` call from the `#items >= 2` branch. The stack is already created by `immich:createStack(assetIds)` using the renditions that were just uploaded. A comment is left explaining why the call is intentionally absent.

---

### 13. Accumulator keyed on `localIdentifier` instead of stable device ID (ExportTask.lua, PublishTask.lua)

**Problem:** The accumulator in `processStackOriginalExportRenditions` (and its publish counterpart) grouped renditions by `rendition.photo.localIdentifier`, and used that value as the `deviceAssetId` prefix (`lid .. "_export"`/`"_orig"`). The `localIdentifier` is an internal Lightroom database integer that can change if the catalog is recreated or the photo is re-imported, causing the next export to not find previously uploaded assets and creating duplicate uploads.

**Fix:** The accumulator now keys by `util.getPhotoDeviceId(rendition.photo) or rendition.photo.localIdentifier`. `getPhotoDeviceId` returns a stable UUID (same as the single-rendition path uses) when available, falling back to `localIdentifier` only if the UUID is absent. The `exportedPrimaryByPhoto` map still uses `photo.localIdentifier` as its key (required by `applyLrStacksInImmich` which looks up members by `localIdentifier`).

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

**After:** `sortOriginalExportItems` uses an `isOriginal` flag set on each item at accumulation time (`isOriginal = itemExt == srcExt`, where `srcExt` is the source file's extension). Items with `isOriginal == false` (the rendered export) sort first; ties fall back to `insertionOrder` (higher = rendered export = sorts first, so the export is always primary regardless of format).

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

### 14. `#items == 1` fallback: same-extension pairs (JPG→JPG, TIF→TIF) not stacked (ExportTask.lua, PublishTask.lua)

**Problem:** When `stackOriginalExport = true` and the source file and export share the same extension (e.g. JPG photos exported as JPEG), the `#items == 1` fallback in `processOnePhotoGroup` / `processPublishOnePhotoGroup` misidentified the single rendition as the original copy and skipped stacking entirely.

Root cause: `LR_exportOriginalFile` is never set in `ExportServiceProvider.lua`, so Lightroom always delivers exactly **one** rendition per photo — the rendered export. The `isOriginal` flag (set as `itemExt == srcExt`) is `true` for same-extension pairs, which caused the code to upload as `_orig` and skip the disk-original fetch and stack creation.

Symptoms observed: exporting 29 536 JPG photos with `stackOriginalExport = true` produced ~43 134 assets in Immich (a mix of unstacked singles and unstacked pairs from a prior partial export) instead of 58 872 stacked pairs. No error or warning was emitted because the warning guard required `originalFileMode == "original_plus_jpeg_if_edited"`, which is not the active value in the `stackOriginalExport` code path.

The bug affected any same-extension pairing (JPG→JPG, TIF→TIF, PNG→PNG, etc.). Different-extension pairings of the same format (`.jpg` vs `.jpeg`, `.tif` vs `.tiff`) were already handled correctly because the normalized extensions differ, giving `isOriginal = false` and taking the stacking path.

**Fix:** Both `processOnePhotoGroup` (ExportTask.lua) and `processPublishOnePhotoGroup` (PublishTask.lua) `#items == 1` branches now always treat the single arriving rendition as the rendered export — `isOrig` determination and branching removed. The `_export` suffix is always used; the disk original is always fetched and uploaded as `_orig`; the stack is always created. In publish mode the disk original is intentionally not uploaded (orphan prevention), and a stack warning is always emitted.

---

### 15. HTTP request failures showed a blocking modal dialog per failure (ImmichAPI.lua)

**Problem:** `handleRequestFailure` called `ErrorHandler.handleError(...)` for every failed HTTP response, which presented a blocking `LrDialogs.presentModalDialog` popup. During a batch export with many photos, each failed stack creation (e.g. HTTP 400 from `/stacks`) triggered a new modal dialog the moment the previous one was dismissed — forcing the user to click through hundreds of identical popups. The return value of the dialog (OK vs Cancel) was also discarded, so Cancel had no effect and the next dialog appeared immediately.

**Fix:** Replaced the `ErrorHandler.handleError` call in `handleRequestFailure` with plain `log:error` calls that record the same information (method, path, status, headers, response body) without showing any dialog. Callers already check the nil return value and add entries to `failures` / `stackWarnings`, which are reported once in the post-export summary via `reportUploadFailuresAndWarnings`.

---

### 16. StackManager.lua always enabled logging regardless of user preference (StackManager.lua)

**Problem:** `StackManager.lua` created its own `local log = LrLogger('ImmichPlugin')` and called `log:enable("logfile")` unconditionally at module load time. This bypassed the global logging preference managed by `Init.lua` — the plugin wrote to `ImmichPlugin.log` on every run regardless of whether the user had enabled logging in the Plugin Manager. Every other file in the plugin uses the global `log` instance from `Init.lua`.

**Fix:** Removed the local `log` declaration and the unconditional `log:enable("logfile")` call. `StackManager.lua` now uses the global `log` variable set by `Init.lua`, matching the pattern used by all other files.

---

### 17. Insufficient INFO-level logging for upload, stack, and flow operations (multiple files)

**Problem:** The plugin had only 3 INFO-level log statements across the entire codebase. Key operations — upload success, stack creation, and export progress — produced no INFO output. Diagnosing issues (such as the JPG→JPG stacking bug) required enabling TRACE and sifting through hundreds of low-level entries, or adding temporary code.

Specific gaps:

- `uploadAsset` and `replaceAsset`: no log on success; could not confirm which `deviceAssetId` mapped to which Immich asset ID.
- `createStack`: logged at TRACE on success; not visible without full TRACE output.
- `processOnePhotoGroup` / `processPublishOnePhotoGroup`: no log per upload or per stack attempt.
- `processSingleRenditionRenditions` (`original_plus_jpeg_if_edited` path): no log for the original or export upload steps.
- No export-start/done markers with config summary; no periodic progress logging.

**Fix:** Added INFO-level logging to the following:

- **ImmichAPI.lua `uploadAsset`**: logs `uploadAsset: <deviceAssetId> -> <assetId>` on success.
- **ImmichAPI.lua `replaceAsset`**: logs `replaceAsset: <oldId> -> <newId>` on success; changed existing TRACE to INFO.
- **ImmichAPI.lua `createStack`**: changed TRACE success log to INFO (`Stack created: <id> (N assets)`).
- **ExportTask.lua / PublishTask.lua `processOnePhotoGroup` / `processPublishOnePhotoGroup`**: logs INFO per upload announcing role and `deviceAssetId → assetId` mapping.
- **ExportTask.lua `processSingleRenditionRenditions`**: logs INFO when uploading the original and the edited export in the `original_plus_jpeg_if_edited` path.
- **ExportTask.lua / PublishTask.lua `processRenderedPhotos`**: logs `=== Export START ===` / `=== Export DONE ===` with photo count, URL, and key settings; logs `Export progress: N/M (X%)` periodically.

With logging enabled, a typical export now produces clearly readable INFO entries showing each upload's `deviceAssetId → assetId` mapping, stack creation results, and progress milestones.

---

### 18. Progress bar advanced prematurely, appeared to go backwards, and disappeared before all uploads completed (ExportTask.lua, PublishTask.lua)

**Problem — premature completion (accumulator):** `processStackOriginalExportRenditions` and `processPublishStackOriginalExportRenditions` used an accumulator that flushed (uploaded) only when *two* renditions for the same photo had arrived (`#accumulator[lid] == 2`). Because `LR_exportOriginalFile` is never set, Lightroom always delivers exactly **one** rendition per photo, so the flush condition was never met during the main loop. All N renditions were rendered (filling the progress bar to 100%) before any upload began; then all uploads happened in a post-loop "flush incomplete groups" pass with the bar already full.

**Problem — bar disappears mid-upload and forward→0→return motion:** `exportContext:configureProgress` creates a progress scope that Lightroom's render pipeline owns and manages. LR renders photos on a background thread; once all N photos are rendered (which happens much faster than uploading), LR closes the `configureProgress` scope automatically — even while the Lua thread is still executing upload HTTP calls. After that, any `setPortionComplete` call on the closed scope is a no-op, so the bar vanishes while uploads continue silently for minutes. The same render-thread ownership caused the forward→0→return jitter: `setPortionComplete(0, nPhotos)` would reset the bar that LR had already partially advanced during pre-initialization API calls, then LR's render thread would re-advance it concurrently with our upload updates.

**Fix:**

1. Removed the accumulator from both functions. Each rendition is now processed (uploaded and stacked) immediately as it arrives, interleaving renders and uploads exactly as `processSingleRenditionRenditions` does.
2. Replaced `exportContext:configureProgress { title = ... }` with `LrProgressScope { title = ..., functionContext = functionContext }` in both `ExportTask.processRenderedPhotos` and `PublishTask.processRenderedPhotos`. `LrProgressScope` with `functionContext` is owned entirely by the plugin — its lifetime is tied to the function context, so it stays visible until `processRenderedPhotos` returns regardless of when LR finishes rendering. LR's render thread does not advance or close it, eliminating both the early-close and the jitter. `setPortionComplete(done, nPhotos)` after each upload is the sole source of progress updates, so the bar advances monotonically and reaches 100% only when the last upload completes.

---

### 19. Dead code: `generateBoundary`, `generateMultiPartBody`, `createHeadersForMultipartPut`, `doMultiPartPutRequest` (ImmichAPI.lua)

**Problem:** These four functions were left over from an earlier implementation where `replaceAsset` issued a raw multipart PUT request by reading the entire file into memory (`fh:read("*all")`), building the request body as a Lua string, and calling `LrHttp.post` with `method = 'PUT'`. That path was replaced: `replaceAsset` now delegates to `uploadAsset`, which passes the file via `filePath` in the `postMultipart` content table so LR streams it from disk. The old functions had no remaining callers.

**Fix:** Removed all four functions. No behavioral change.

---

## Known limitations

### Upload timeout is configurable by editing ImmichAPI.lua

`HTTP_TIMEOUT_UPLOAD` is now 300 s (5 min). If uploads still time out on very large files or slow connections, increase this value in `ImmichAPI.lua`. A future improvement would be to expose this as a plugin setting.

### Stack warnings in the post-export dialog

If any individual upload or stack creation fails, it is reported as a warning after export completes rather than aborting the entire run. Check the post-export dialog and the log file (`ImmichPlugin.log`) for `"failed to upload"` or `"failed to create stack"` entries. Re-exporting is self-healing: duplicate detection finds previously uploaded assets, missing companions are uploaded fresh, and stacks are created once both IDs are available.

---

## Files changed

| File | Changes |
| ---- | ------- |
| `ExportTask.lua` | Stack order fix, album primary fix, LR_format guard (×2), role-based deviceAssetId (`_orig`/`_export`) via sort+index, stable accumulator key (`getPhotoDeviceId`), `#items == 1` branch unified and corrected (always treat as export; fetch disk original; stack), removed redundant `processPhotoWithStack`, per-rendition immediate processing (no accumulator; fixes progress bar), `LrProgressScope { functionContext }` replaces `configureProgress` (bar stays alive until all uploads done; no forward→0→return jitter), missing export-upload warning, format-agnostic renames |
| `PublishTask.lua` | Role-based deviceAssetId (`_orig`/`_export`) via sort+index, stable accumulator key (`getPhotoDeviceId`), `#items == 1` branch unified and corrected (always treat as export; orphan-safe warning), removed unused `exportParams` from `processPublishStackOriginalExportRenditions`, per-rendition immediate processing (no accumulator; fixes progress bar), `LrProgressScope { functionContext }` replaces `configureProgress` (bar stays alive until all uploads done; no forward→0→return jitter), format-agnostic renames |
| `ExportDialogSections.lua` | Warning UI, updated dropdown labels, section label rename, `stackOriginalExport` bind |
| `PublishDialogSections.lua` | Section label and checkbox text updated, `stackOriginalExport` bind |
| `ExportServiceProvider.lua` | `stackOriginalExport` preference key |
| `PublishServiceProvider.lua` | `stackOriginalExport` preference key |
| `ImmichAPI.lua` | Timeout increases, `HTTP_TIMEOUT_UPLOAD` wired into `postMultipart`, explicit POST timeout, `handleRequestFailure` changed to log-only (no modal dialog), INFO logging for `uploadAsset`/`replaceAsset`/`createStack` success, `replaceAsset` delegates to `uploadAsset` (LR streams file from disk via `filePath` in `postMultipart` — no in-memory file copy), removed dead `generateBoundary`/`generateMultiPartBody`/`createHeadersForMultipartPut`/`doMultiPartPutRequest` |
| `StackManager.lua` | `hasEdits` cache short-circuit and comment fix, removed `getFileType` / `RAW_EXT` |
| `UploadHelpers.lua` | `sortOriginalExportItems` with extension-based `isOriginal` flag and inverted `insertionOrder` tiebreaker (higher = rendered export = primary), removed `fileType` field, removed dead `collectRenditions`/`groupByPhoto`, updated comment |
