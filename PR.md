# Pull Request: Fix original+export stacking, UI clarity, and reliability bugs

## Summary

This PR fixes the `original_plus_jpeg_if_edited` export mode (issue #91), corrects several bugs that caused duplicate uploads and wrong stack ordering, improves UI labeling, and addresses memory and timeout issues that caused failures on large exports.

---

## Bug fixes

### 1. Stack primary image was wrong (ExportTask.lua)

**Problem:** `createStack({ id, jpegId })` was called with the original file first. Immich uses the first element as the stack's key/cover image, so the unedited original was shown as the primary instead of the edited export.

**Fix:** Swapped to `createStack({ jpegId, id })` so the rendered export is the primary in both `processOnePhotoGroup` and `processSingleRenditionRenditions`.

---

### 2. Album received the wrong asset (ExportTask.lua)

**Problem:** After creating a stack, both code paths added the original (`id`) to the album and recorded it as the primary, even when the edited export (`jpegId`) was available.

**Fix:** Introduced a `primaryId` variable that defaults to `id` and is updated to `jpegId` when the export upload succeeds. Album assignment and `exportedPrimaryByPhoto` now use `primaryId`.

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

**Fix:** When a cache is present it is now used exclusively. A cache miss immediately returns `false` without any fallback queries.

---

## UI improvements (ExportDialogSections.lua)

- **Dropdown labels updated** to be format-agnostic:
  - `"Always upload original only (no JPG)"` → `"Always upload original only (no export)"`
  - `"Always upload original, JPG only if edited"` → `"Always upload original + rendered export (if edited)"`
- **Section label** `"original+export export:"` → `"Original + Export:"` and checkbox `"Stack in Immich (edited JPG as primary)"` → `"Stack in Immich (export as primary)"` — the feature works with any export format, not just JPEG.
- **Warning message** displayed in orange when "Original / no reformat" export format is selected alongside the "upload original + rendered export" mode, prompting the user to switch to JPEG or TIFF.

---

## Known limitations / not in this PR

### collectRenditions batches all renders before upload starts (UploadHelpers.lua)

For the original+export stacking path, `collectRenditions` waits for all renditions across the entire export batch to finish rendering before the first upload begins. On large exports this can fill temp disk before any files are cleaned up. The single-rendition path does not have this issue — it pipes render → upload → delete per photo.

This was not fixed in this PR due to the scope of the required restructuring. Monitor temp disk usage during large original+export exports.

#### Plan for future fix

Replace `collectRenditions` in `processStackDngJpgRenditions` (ExportTask.lua) and `processPublishStackDngJpgRenditions` (PublishTask.lua) with an inline accumulator loop that flushes each photo group as soon as it is complete:

```lua
local accumulator = {}  -- lid -> { items }
for _, rendition in exportContext:renditions { stopIfCanceled = true } do
    if progressScope:isCanceled() then break end
    local success, pathOrMessage = rendition:waitForRender()
    if progressScope:isCanceled() then break end
    if success then
        local lid = rendition.photo.localIdentifier
        if not accumulator[lid] then accumulator[lid] = {} end
        table.insert(accumulator[lid], {
            path = pathOrMessage,
            photo = rendition.photo,
            rendition = rendition,
            ext = util.getExtension(pathOrMessage),
            fileType = StackManager.getFileType(pathOrMessage),
        })
        -- Two renditions = group complete: upload and delete immediately
        if #accumulator[lid] == 2 then
            processOnePhotoGroup(immich, lid, accumulator[lid], ...)
            accumulator[lid] = nil
        end
    end
end
-- Flush any remaining single-rendition groups (e.g. one rendition failed to render)
for lid, items in pairs(accumulator) do
    processOnePhotoGroup(immich, lid, items, ...)
end
```

`processOnePhotoGroup` already handles the 1-item case so the end-of-loop flush requires no changes there. `UploadHelpers.collectRenditions` and `groupByPhoto` are no longer called from these paths but can remain for other uses.

**Edge cases to test:** render failure on one of a pair (group flushes as single-item at end), cancellation mid-export (temp files from flushed groups are already deleted, only in-progress accumulator items remain), and interleaved renditions from different photos (accumulator handles this correctly regardless of order).

### Upload timeout is configurable by editing ImmichAPI.lua

`HTTP_TIMEOUT_UPLOAD` is now 300 s (5 min). If uploads still time out on very large files or slow connections, increase this value in `ImmichAPI.lua`. A future improvement would be to expose this as a plugin setting.

### Stack warnings in the post-export dialog

If any individual upload or stack creation fails, it is reported as a warning after export completes rather than aborting the entire run. Check the post-export dialog and the log file (`ImmichPlugin.log`) for `"failed to upload"` or `"failed to create stack"` entries.

---

## Files changed

| File | Changes |
|------|---------|
| `ExportTask.lua` | Stack order fix, album primary fix, LR_format guard (×2), `checkIfAssetExistsEnhanced`, extension-based deviceAssetId |
| `ExportDialogSections.lua` | Warning UI, updated dropdown labels, section label rename |
| `ImmichAPI.lua` | Timeout increases, `table.concat` multipart body, explicit POST timeout |
| `StackManager.lua` | `hasEdits` cache short-circuit |
| `PublishTask.lua` | Extension-based deviceAssetId for original+export stacking |
