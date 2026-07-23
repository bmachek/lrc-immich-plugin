require("ImmichAPI")
require("MetadataTask")
require("AssetStampTask")
require("StackManager")
require("UploadHelpers")

local LrExportSession = import("LrExportSession")

--[[
    SyncTask – full two-way delta sync between the whole Lightroom catalog and the whole
    Immich library.

      Phase A (download): Immich assets not present in the catalog are streamed to disk
        (curl when available, LrHttp fallback) and handed to Lightroom's Import UI; the
        imported photos are stamped with their immichOriginalAssetId (AssetStampTask).

      Phase B (upload): catalog photos with no stored Immich ID (new) or edited since their
        last sync (immichSyncTime vs lastEditTime) are uploaded per config — original, export
        (rendered via LrExportSession), or both (optionally stacked). For originals, Lightroom
        metadata is pushed to Immich (nothing is baked into a RAW).

      Phase C (deletions, opt-in): LR→Immich deletes Immich assets whose source photo was
        removed from the catalog (tracked via a persistent manifest). Immich→LR flags photos
        whose Immich asset was deleted as rejected (the SDK cannot delete catalog photos).

    Delta keeps repeat runs cheap; the first full-library run is inherently heavy.
]]

SyncTask = {}

local SYNC_SUBFOLDER = "Immich Sync"

-- Persistent manifest { assetId -> photoUuid } used for LR→Immich deletion detection.
local function loadManifest()
    local m = prefs.syncManifest
    return (type(m) == "table") and m or {}
end

local function saveManifest(m)
    prefs.syncManifest = (m and next(m) ~= nil) and m or nil
end

-- Enumerate the Immich asset IDs already known to the catalog (both ID fields), so the
-- download delta can skip them. Mirrors ImportServiceProvider.getExistingAssetIds.
local function collectExistingAssetIds(catalog)
    local existing = {}
    for _, field in ipairs({ "immichAssetId", "immichOriginalAssetId" }) do
        local photos = catalog:findPhotosWithProperty(_PLUGIN.id, field)
        for _, photo in ipairs(photos or {}) do
            local id = photo:getPropertyForPlugin(_PLUGIN.id, field)
            if not Util.nilOrEmpty(id) then
                existing[id] = true
            end
        end
    end
    return existing
end

-- Render a single photo to a temporary JPEG via an export session. Returns the rendered
-- path or nil. Best-effort: any failure is logged and returns nil so the caller can warn.
local function renderExport(photo)
    local renderedPath
    local ok, err = LrTasks.pcall(function()
        local session = LrExportSession({
            photosToExport = { photo },
            exportSettings = {
                LR_format = "JPEG",
                LR_jpeg_quality = 0.9,
                LR_export_colorSpace = "sRGB",
                LR_export_destinationType = "tempFolder",
                LR_collisionHandling = "rename",
                LR_size_doConstrain = false,
                LR_outputSharpeningOn = false,
                LR_metadata_keywordOptions = "lightroomHierarchical",
                LR_embeddedMetadataOption = "all",
                LR_includeVideoFiles = false,
                LR_reimportExportedPhoto = false,
            },
        })
        for _, rendition in session:renditions() do
            local success, pathOrMessage = rendition:waitForRender()
            if success then
                renderedPath = pathOrMessage
            end
        end
    end)
    if not ok then
        log:warn("renderExport: failed for photo " .. tostring(photo.localIdentifier) .. ": " .. tostring(err))
        return nil
    end
    return renderedPath
end

-- Push Lightroom metadata onto an Immich asset (used for uploaded originals). Best-effort.
local function pushMetadataForPhoto(immich, photo, assetId)
    local fields = {}
    local rating = photo:getRawMetadata("rating")
    if type(rating) == "number" and rating >= 1 then
        fields.rating = rating
    end
    local caption = photo:getFormattedMetadata("caption")
    if not Util.nilOrEmpty(caption) then
        fields.description = caption
    end
    if photo:getRawMetadata("pickStatus") == 1 then
        fields.isFavorite = true
    end
    local gps = photo:getRawMetadata("gps")
    if type(gps) == "table" and type(gps.latitude) == "number" and type(gps.longitude) == "number" then
        fields.latitude = gps.latitude
        fields.longitude = gps.longitude
    end
    local iso = UploadHelpers.captureTimeForImmich(photo)
    if not Util.nilOrEmpty(iso) then
        fields.dateTimeOriginal = iso
    end
    immich:updateAsset(assetId, fields)

    -- Keywords -> tags (additive), honoring "Include on Export".
    local tagNames = UploadHelpers.collectExportKeywords(photo)
    if #tagNames > 0 then
        local tags = immich:upsertTags(tagNames)
        if tags then
            local tagIds = {}
            for _, tag in ipairs(tags) do
                if tag.id then
                    table.insert(tagIds, tag.id)
                end
            end
            if #tagIds > 0 then
                immich:assignTagsToAsset(tagIds, assetId)
            end
        end
    end
end

-- Upload one photo per the configured content. Returns { originalId, exportId } (either may
-- be nil). Appends messages to failures. Does not set immichSyncTime (caller does on success).
local function uploadPhoto(immich, photo, opts, failures)
    local filename = photo:getFormattedMetadata("fileName")
    local content = opts.uploadContent or "original"
    local originalId, exportId

    if content == "original" or content == "both" then
        local originalPath = StackManager.getOriginalFilePath(photo)
        if not originalPath then
            table.insert(failures, filename .. " (original file not accessible)")
        else
            local id = StackManager.uploadOneAssetOrReplace(immich, photo, originalPath, nil, true)
            if id then
                MetadataTask.setImmichOriginalAssetId(photo, id)
                originalId = id
                if opts.pushMetadata then
                    LrTasks.pcall(function()
                        pushMetadataForPhoto(immich, photo, id)
                    end)
                end
            else
                table.insert(failures, filename .. " (original upload failed)")
            end
        end
    end

    if content == "export" or content == "both" then
        local exportPath = renderExport(photo)
        if not exportPath then
            table.insert(failures, filename .. " (export render failed)")
        else
            local id = StackManager.uploadOneAssetOrReplace(immich, photo, exportPath, nil, false)
            UploadHelpers.safeDeleteTempFile(exportPath)
            if id then
                MetadataTask.setImmichAssetId(photo, id)
                exportId = id
            else
                table.insert(failures, filename .. " (export upload failed)")
            end
        end
    end

    if opts.stackOriginals and originalId and exportId then
        immich:createStack({ exportId, originalId })
    end

    return originalId, exportId
end

-- Phase A analysis: which Immich assets are missing from the catalog and would be downloaded.
-- Returns the asset list, or nil + an error message on failure.
local function analyzeDownload(immich, catalog)
    local assets = immich:getAllAssets()
    if not assets then
        return nil, "Failed to list Immich assets. Check logs."
    end
    local existing = collectExistingAssetIds(catalog)
    local toDownload = {}
    for _, asset in ipairs(assets) do
        if not existing[asset.id] then
            table.insert(toDownload, asset)
        end
    end
    return toDownload
end

-- Phase B analysis: which catalog photos are new or edited since their last sync. Returns the
-- upload item list ({ photo, filename, reason }) and the count of unchanged (skipped) photos.
local function analyzeUpload(photos)
    local toUpload = {}
    local skipped = 0
    for _, photo in ipairs(photos) do
        local stored = MetadataTask.getAnyImmichAssetId(photo)
        local syncTime = MetadataTask.getImmichSyncTime(photo) or 0
        local lastEdit = photo:getRawMetadata("lastEditTime") or 0
        local isNew = Util.nilOrEmpty(stored)
        local isEdited = (not isNew) and (lastEdit > syncTime)
        if isNew or isEdited then
            table.insert(toUpload, {
                photo = photo,
                filename = photo:getFormattedMetadata("fileName"),
                reason = isNew and "new" or "edited",
            })
        else
            skipped = skipped + 1
        end
    end
    return toUpload, skipped
end

-- Phase C analysis (LR -> Immich): assets from the manifest whose source photo is gone.
local function analyzeDelete(catalog)
    local items = {}
    for assetId, uuid in pairs(loadManifest()) do
        if not catalog:findPhotoByUuid(uuid) then
            table.insert(items, { assetId = assetId, uuid = uuid })
        end
    end
    return items
end

-- Phase C analysis (Immich -> LR): catalog photos whose Immich asset was deleted/trashed. This
-- queries Immich once per stamped photo, so it can be slow on large catalogs.
local function analyzeReject(immich, photos, progress)
    local toReject = {}
    local total = #photos
    for i, photo in ipairs(photos) do
        if progress:isCanceled() then
            break
        end
        local id = MetadataTask.getAnyImmichAssetId(photo)
        if not Util.nilOrEmpty(id) then
            local info = immich:getAssetInfo(id)
            if not info or info.isTrashed then
                table.insert(toReject, photo)
            end
        end
        progress:setPortionComplete(i, total)
    end
    return toReject
end

-- Build the full delta plan without transferring anything. Returns the plan table, or
-- nil + an error message if a fatal problem occurred (e.g. Immich asset listing failed).
function SyncTask.analyze(opts, catalog, immich, progress)
    local doDownload = opts.direction ~= "upload"
    local doUpload = opts.direction ~= "download"
    local plan = { download = {}, upload = {}, delete = {}, reject = {}, skipped = 0, photos = nil }

    if doDownload and not progress:isCanceled() then
        progress:setCaption("Fetching Immich asset list...")
        local toDownload, err = analyzeDownload(immich, catalog)
        if not toDownload then
            return nil, err
        end
        plan.download = toDownload
    end

    -- Phases B and C all iterate the catalog photo list.
    if doUpload or opts.deleteInImmich or opts.rejectInLr then
        plan.photos = catalog:getAllPhotos()
    end

    if doUpload and plan.photos and not progress:isCanceled() then
        progress:setCaption("Checking Lightroom for new/edited photos...")
        plan.upload, plan.skipped = analyzeUpload(plan.photos)
    end

    if opts.deleteInImmich and not progress:isCanceled() then
        plan.delete = analyzeDelete(catalog)
    end

    if opts.rejectInLr and plan.photos and not progress:isCanceled() then
        progress:setCaption("Checking Immich for deleted assets...")
        plan.reject = analyzeReject(immich, plan.photos, progress)
    end

    return plan
end

-- Which asset kinds an upload config produces: originals (RAW) and/or exports (edits). A photo
-- uploaded as "both" counts toward both totals.
local function uploadContentFlags(opts)
    local content = opts.uploadContent or "original"
    local raws = content == "original" or content == "both"
    local edits = content == "export" or content == "both"
    return raws, edits
end

-- Render a plain-text report from a list of { heading, lines } sections plus optional footer
-- lines. Used for the detailed "Save summary to file" export in both the preview and completion
-- dialogs.
local function formatReport(title, sections, footer)
    local out = { title, os.date("Generated %Y-%m-%d %H:%M:%S"), "" }
    for _, s in ipairs(sections) do
        table.insert(out, string.format("%s (%d)", s.heading, #s.lines))
        if #s.lines == 0 then
            table.insert(out, "  (none)")
        else
            for _, line in ipairs(s.lines) do
                table.insert(out, "  " .. line)
            end
        end
        table.insert(out, "")
    end
    for _, line in ipairs(footer or {}) do
        table.insert(out, line)
    end
    return table.concat(out, "\n")
end

-- Prompt for a location and write the given text there. Runs synchronously from a button action.
local function saveSummaryToFile(defaultName, text)
    local path = LrDialogs.runSavePanel({
        title = "Save Immich sync summary",
        requiredFileType = "txt",
        initialFile = defaultName,
        canCreateDirectories = true,
    })
    if not path then
        return
    end
    local file = io.open(path, "w")
    if not file then
        LrDialogs.message("Could not save summary", "Unable to write to " .. path, "critical")
        return
    end
    file:write(text)
    file:close()
    LrDialogs.showBezel("Sync summary saved")
end

-- Full detailed report of the planned changes (filenames, asset IDs, paths) for the preview
-- "Save summary to file" button.
local function buildPreviewText(opts, plan)
    local doDownload = opts.direction ~= "upload"
    local doUpload = opts.direction ~= "download"
    local sections = {}

    if doDownload then
        local lines = {}
        for _, asset in ipairs(plan.download) do
            table.insert(lines, string.format("%s  [id %s]", asset.originalFileName or "?", asset.id))
        end
        table.insert(sections, { heading = "Download to Lightroom", lines = lines })
    end

    if doUpload then
        local lines = {}
        for _, item in ipairs(plan.upload) do
            table.insert(
                lines,
                string.format("%s  (%s)  %s", item.filename, item.reason, item.photo:getRawMetadata("path") or "?")
            )
        end
        table.insert(
            sections,
            { heading = "Upload to Immich (content: " .. (opts.uploadContent or "original") .. ")", lines = lines }
        )
    end

    if opts.deleteInImmich then
        local lines = {}
        for _, item in ipairs(plan.delete) do
            table.insert(lines, string.format("id %s  (was uuid %s)", item.assetId, item.uuid))
        end
        table.insert(sections, { heading = "Delete in Immich", lines = lines })
    end

    if opts.rejectInLr then
        local lines = {}
        for _, photo in ipairs(plan.reject) do
            table.insert(
                lines,
                string.format(
                    "%s  [id %s]  %s",
                    photo:getFormattedMetadata("fileName"),
                    MetadataTask.getAnyImmichAssetId(photo) or "?",
                    photo:getRawMetadata("path") or "?"
                )
            )
        end
        table.insert(sections, { heading = "Reject in Lightroom", lines = lines })
    end

    return formatReport(
        "Immich sync – planned changes (nothing transferred yet)",
        sections,
        { string.format("Unchanged (skipped): %d", plan.skipped) }
    )
end

-- Present the optional wizard step: a concise summary of what the plan would do, so the user can
-- confirm before anything is transferred. A "Save summary to file" button exports the full
-- per-item detail. Returns true if the user chose to proceed.
function SyncTask.presentPreview(opts, plan)
    local f = LrView.osFactory()
    local doDownload = opts.direction ~= "upload"
    local doUpload = opts.direction ~= "download"
    local rawOn, editOn = uploadContentFlags(opts)

    local rows = {}
    local function countRow(label, count)
        table.insert(rows, f:static_text({ title = string.format("%s  %d", label, count), font = "<system/bold>" }))
    end
    local function subRow(label, count)
        table.insert(rows, f:static_text({ title = string.format("      %s  %d", label, count) }))
    end

    if doDownload then
        countRow("Download to Lightroom:", #plan.download)
    end
    if doUpload then
        countRow("Upload to Immich:", #plan.upload)
        if rawOn then
            subRow("originals (RAW):", #plan.upload)
        end
        if editOn then
            subRow("edits (exports):", #plan.upload)
        end
    end
    if opts.deleteInImmich then
        countRow("Delete in Immich:", #plan.delete)
    end
    if opts.rejectInLr then
        countRow("Reject in Lightroom:", #plan.reject)
    end
    table.insert(rows, f:static_text({ title = string.format("Unchanged (skipped):  %d", plan.skipped) }))

    local detailText = buildPreviewText(opts, plan)

    local contents = f:column({
        spacing = f:control_spacing(),
        margin = 10,
        f:static_text({ title = "Review the changes. Nothing has been transferred yet.", font = "<system/bold>" }),
        f:separator({ fill_horizontal = 1 }),
        f:column(rows),
        f:separator({ fill_horizontal = 1 }),
        f:push_button({
            title = "Save summary to file…",
            action = function()
                saveSummaryToFile("immich-sync-plan.txt", detailText)
            end,
        }),
    })

    local result = LrDialogs.presentModalDialog({
        title = "Immich sync – preview",
        contents = contents,
        actionVerb = "Run sync",
        cancelVerb = "Cancel",
    })
    return result == "ok"
end

-- Carry out a plan produced by SyncTask.analyze. Returns the stats table and a detailed report
-- table (per-item filenames/IDs/paths for the "Save summary to file" export), and appends any
-- per-item problems to failures.
function SyncTask.execute(opts, plan, catalog, immich, progress, failures)
    local stats = {
        downloaded = 0,
        uploaded = 0,
        uploadedOriginals = 0,
        uploadedExports = 0,
        deleted = 0,
        rejected = 0,
        skipped = plan.skipped,
    }
    local report = { downloaded = {}, uploaded = {}, deleted = {}, rejected = {} }

    --------------------------------------------------------------------------
    -- Phase A: download delta
    --------------------------------------------------------------------------
    if #plan.download > 0 and not progress:isCanceled() then
        local importDir = prefs.importPath
        if not LrFileUtils.exists(importDir) then
            LrFileUtils.createDirectory(importDir)
        end
        local folder = LrPathUtils.child(importDir, SYNC_SUBFOLDER)
        if not LrFileUtils.exists(folder) then
            LrFileUtils.createDirectory(folder)
        end

        local total = #plan.download
        local pathToId = {}
        for i, asset in ipairs(plan.download) do
            if progress:isCanceled() then
                break
            end
            local dest = LrPathUtils.child(folder, asset.originalFileName or (asset.id .. ".bin"))
            if immich:downloadAssetToFile(asset.id, dest, opts.forceLrHttp) then
                pathToId[dest] = asset.id
                stats.downloaded = stats.downloaded + 1
                table.insert(report.downloaded, {
                    filename = asset.originalFileName or asset.id,
                    assetId = asset.id,
                    path = dest,
                })
            else
                table.insert(failures, (asset.originalFileName or asset.id) .. " (download failed)")
            end
            progress:setPortionComplete(i, total)
            progress:setCaption(string.format("Downloading %d of %d", i, total))
        end

        if next(pathToId) ~= nil then
            -- Hand off to Lightroom's Import UI; imported photos are stamped
            -- (immichOriginalAssetId) by AssetStampTask once they land in the catalog.
            catalog:triggerImportUI(folder)
            AssetStampTask.pollAfterImport(pathToId)
        end
    end

    --------------------------------------------------------------------------
    -- Phase B: upload delta
    --------------------------------------------------------------------------
    if #plan.upload > 0 and not progress:isCanceled() then
        local total = #plan.upload
        for i, item in ipairs(plan.upload) do
            if progress:isCanceled() then
                break
            end
            local originalId, exportId = uploadPhoto(immich, item.photo, opts, failures)
            if originalId or exportId then
                MetadataTask.setImmichSyncTime(item.photo, LrDate.currentTime())
                stats.uploaded = stats.uploaded + 1
                if originalId then
                    stats.uploadedOriginals = stats.uploadedOriginals + 1
                end
                if exportId then
                    stats.uploadedExports = stats.uploadedExports + 1
                end
                table.insert(report.uploaded, {
                    filename = item.filename,
                    path = item.photo:getRawMetadata("path"),
                    originalId = originalId,
                    exportId = exportId,
                })
            end
            progress:setPortionComplete(i, total)
            progress:setCaption(string.format("Uploading (%d of %d)", i, total))
        end
    end

    --------------------------------------------------------------------------
    -- Phase C: deletions (opt-in)
    --------------------------------------------------------------------------
    -- LR -> Immich: delete assets whose source photo was removed from the catalog.
    if opts.deleteInImmich and not progress:isCanceled() then
        for _, item in ipairs(plan.delete) do
            if immich:deleteAsset(item.assetId) then
                stats.deleted = stats.deleted + 1
                table.insert(report.deleted, item.assetId)
            end
        end
        -- Rebuild the manifest from the current catalog state (includes freshly uploaded IDs).
        local current = {}
        for _, photo in ipairs(plan.photos or {}) do
            local uuid = photo:getRawMetadata("uuid")
            if uuid then
                for _, getter in ipairs({ MetadataTask.getImmichAssetId, MetadataTask.getImmichOriginalAssetId }) do
                    local id = getter(photo)
                    if not Util.nilOrEmpty(id) then
                        current[id] = uuid
                    end
                end
            end
        end
        saveManifest(current)
    end

    -- Immich -> LR: flag photos whose Immich asset was deleted as rejected (SDK cannot
    -- delete catalog photos), and clear their stored IDs.
    if opts.rejectInLr and #plan.reject > 0 and not progress:isCanceled() then
        catalog:withWriteAccessDo("Immich sync: reject deleted", function()
            for _, photo in ipairs(plan.reject) do
                photo:setRawMetadata("pickStatus", -1)
            end
        end, { timeout = 30 })
        for _, photo in ipairs(plan.reject) do
            table.insert(report.rejected, {
                filename = photo:getFormattedMetadata("fileName"),
                assetId = MetadataTask.getAnyImmichAssetId(photo),
            })
            MetadataTask.setImmichAssetId(photo, nil)
            MetadataTask.setImmichOriginalAssetId(photo, nil)
            stats.rejected = stats.rejected + 1
        end
    end

    return stats, report
end

-- Full detailed report of what actually happened (filenames, real asset IDs, paths, and any
-- problems) for the completion dialog's "Save summary to file" button.
local function buildCompletionText(opts, stats, report, failures)
    local sections = {}

    local downloadLines = {}
    for _, item in ipairs(report.downloaded) do
        table.insert(downloadLines, string.format("%s  [id %s]  -> %s", item.filename, item.assetId, item.path))
    end
    table.insert(sections, { heading = "Downloaded to Lightroom", lines = downloadLines })

    local uploadLines = {}
    for _, item in ipairs(report.uploaded) do
        table.insert(
            uploadLines,
            string.format(
                "%s  original=%s  export=%s  %s",
                item.filename,
                item.originalId or "-",
                item.exportId or "-",
                item.path or "?"
            )
        )
    end
    table.insert(sections, { heading = "Uploaded to Immich", lines = uploadLines })

    if opts.deleteInImmich then
        local deleteLines = {}
        for _, assetId in ipairs(report.deleted) do
            table.insert(deleteLines, "id " .. assetId)
        end
        table.insert(sections, { heading = "Deleted in Immich", lines = deleteLines })
    end

    if opts.rejectInLr then
        local rejectLines = {}
        for _, item in ipairs(report.rejected) do
            table.insert(rejectLines, string.format("%s  [id %s]", item.filename, item.assetId or "?"))
        end
        table.insert(sections, { heading = "Rejected in Lightroom", lines = rejectLines })
    end

    if failures and #failures > 0 then
        table.insert(sections, { heading = "Problems", lines = failures })
    end

    return formatReport(
        "Immich sync – results",
        sections,
        { string.format("Unchanged (skipped): %d", stats.skipped) }
    )
end

-- Present the completion summary: a concise count breakdown (uploads split into originals/edits)
-- with a "Save summary to file" button that exports the full per-item detail.
function SyncTask.presentCompletion(opts, stats, report, failures)
    local f = LrView.osFactory()
    local doDownload = opts.direction ~= "upload"
    local doUpload = opts.direction ~= "download"

    local rows = {}
    local function countRow(label, count)
        table.insert(rows, f:static_text({ title = string.format("%s  %d", label, count), font = "<system/bold>" }))
    end
    local function subRow(label, count)
        table.insert(rows, f:static_text({ title = string.format("      %s  %d", label, count) }))
    end

    if doDownload then
        countRow("Downloaded to Lightroom:", stats.downloaded)
    end
    if doUpload then
        countRow("Uploaded to Immich:", stats.uploaded)
        subRow("originals (RAW):", stats.uploadedOriginals)
        subRow("edits (exports):", stats.uploadedExports)
    end
    if opts.deleteInImmich then
        countRow("Deleted in Immich:", stats.deleted)
    end
    if opts.rejectInLr then
        countRow("Rejected in Lightroom:", stats.rejected)
    end
    table.insert(rows, f:static_text({ title = string.format("Unchanged (skipped):  %d", stats.skipped) }))

    if failures and #failures > 0 then
        table.insert(rows, f:separator({ fill_horizontal = 1 }))
        table.insert(rows, f:static_text({
            title = string.format("%d item(s) had problems – see saved summary for details.", #failures),
            text_color = LrColor(0.7, 0.2, 0.2),
        }))
    end

    local detailText = buildCompletionText(opts, stats, report, failures)

    local contents = f:column({
        spacing = f:control_spacing(),
        margin = 10,
        f:static_text({ title = "Immich sync complete.", font = "<system/bold>" }),
        f:separator({ fill_horizontal = 1 }),
        f:column(rows),
        f:separator({ fill_horizontal = 1 }),
        f:push_button({
            title = "Save summary to file…",
            action = function()
                saveSummaryToFile("immich-sync-summary.txt", detailText)
            end,
        }),
    })

    LrDialogs.presentModalDialog({
        title = "Immich sync complete",
        contents = contents,
        actionVerb = "Done",
        cancelVerb = "< exclude >",
    })
end

-- opts: { direction, uploadContent, stackOriginals, pushMetadata, deleteInImmich, rejectInLr,
--         forceLrHttp, preview }
function SyncTask.run(opts)
    opts = opts or {}

    LrTasks.startAsyncTask(function()
        AssetStampTask.reconcile(false)

        local catalog = LrApplication.activeCatalog()
        local immich = ImmichAPI:new(prefs.url, prefs.apiKey)
        if not immich:checkConnectivity() then
            ErrorHandler.handleError(
                "Immich connection not working. Check URL and API key in the import configuration.",
                "SyncTask: connectivity check failed"
            )
            return
        end

        local failures = {}

        --------------------------------------------------------------------------
        -- Step 1: analyze (build the delta plan; transfers nothing).
        --------------------------------------------------------------------------
        local analyzeScope = LrProgressScope({ title = "Analyzing Immich sync...", caption = "Starting..." })
        local plan, err = SyncTask.analyze(opts, catalog, immich, analyzeScope)
        local canceled = analyzeScope:isCanceled()
        analyzeScope:done()

        if not plan then
            ErrorHandler.handleError(err or "Sync analysis failed.", "SyncTask: analyze failed")
            return
        end
        if canceled then
            return
        end

        --------------------------------------------------------------------------
        -- Step 2 (optional): preview and confirm.
        --------------------------------------------------------------------------
        if opts.preview and not SyncTask.presentPreview(opts, plan) then
            return
        end

        --------------------------------------------------------------------------
        -- Step 3: execute the plan.
        --------------------------------------------------------------------------
        local progress = LrProgressScope({ title = "Syncing with Immich...", caption = "Starting..." })
        local stats, report = SyncTask.execute(opts, plan, catalog, immich, progress, failures)
        progress:done()

        --------------------------------------------------------------------------
        -- Summary
        --------------------------------------------------------------------------
        SyncTask.presentCompletion(opts, stats, report, failures)

        Util.reportUploadFailuresAndWarnings(failures, nil)
    end)
end

return SyncTask
