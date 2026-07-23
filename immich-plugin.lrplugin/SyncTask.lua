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
        local photos = catalog:findPhotosWithProperty(_PLUGIN, field)
        for _, photo in ipairs(photos or {}) do
            local id = photo:getPropertyForPlugin(_PLUGIN, field)
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

-- opts: { direction, uploadContent, stackOriginals, pushMetadata, deleteInImmich, rejectInLr, forceLrHttp }
function SyncTask.run(opts)
    opts = opts or {}
    local doDownload = opts.direction ~= "upload"
    local doUpload = opts.direction ~= "download"

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

        local progress = LrProgressScope({ title = "Syncing with Immich...", caption = "Starting..." })
        local failures = {}
        local stats = { downloaded = 0, uploaded = 0, deleted = 0, rejected = 0, skipped = 0 }

        --------------------------------------------------------------------------
        -- Phase A: download delta
        --------------------------------------------------------------------------
        if doDownload and not progress:isCanceled() then
            progress:setCaption("Fetching Immich asset list...")
            local assets = immich:getAllAssets()
            if not assets then
                progress:done()
                ErrorHandler.handleError("Failed to list Immich assets. Check logs.", "SyncTask: getAllAssets nil")
                return
            end

            local existing = collectExistingAssetIds(catalog)
            local toDownload = {}
            for _, asset in ipairs(assets) do
                if not existing[asset.id] then
                    table.insert(toDownload, asset)
                end
            end

            if #toDownload > 0 then
                local importDir = prefs.importPath
                if not LrFileUtils.exists(importDir) then
                    LrFileUtils.createDirectory(importDir)
                end
                local folder = LrPathUtils.child(importDir, SYNC_SUBFOLDER)
                if not LrFileUtils.exists(folder) then
                    LrFileUtils.createDirectory(folder)
                end

                local pathToId = {}
                for i, asset in ipairs(toDownload) do
                    if progress:isCanceled() then
                        break
                    end
                    local dest = LrPathUtils.child(folder, asset.originalFileName or (asset.id .. ".bin"))
                    if immich:downloadAssetToFile(asset.id, dest, opts.forceLrHttp) then
                        pathToId[dest] = asset.id
                        stats.downloaded = stats.downloaded + 1
                    else
                        table.insert(failures, (asset.originalFileName or asset.id) .. " (download failed)")
                    end
                    progress:setPortionComplete(i, #toDownload)
                    progress:setCaption(string.format("Downloading %d of %d", i, #toDownload))
                end

                if next(pathToId) ~= nil then
                    -- Hand off to Lightroom's Import UI; imported photos are stamped
                    -- (immichOriginalAssetId) by AssetStampTask once they land in the catalog.
                    catalog:triggerImportUI(folder)
                    AssetStampTask.pollAfterImport(pathToId)
                end
            end
        end

        --------------------------------------------------------------------------
        -- Phase B / C need the catalog photo list.
        --------------------------------------------------------------------------
        local photos
        if doUpload or opts.deleteInImmich or opts.rejectInLr then
            photos = catalog:getAllPhotos()
        end

        --------------------------------------------------------------------------
        -- Phase B: upload delta
        --------------------------------------------------------------------------
        if doUpload and photos and not progress:isCanceled() then
            local total = #photos
            for i, photo in ipairs(photos) do
                if progress:isCanceled() then
                    break
                end

                local stored = MetadataTask.getAnyImmichAssetId(photo)
                local syncTime = MetadataTask.getImmichSyncTime(photo) or 0
                local lastEdit = photo:getRawMetadata("lastEditTime") or 0
                local isNew = Util.nilOrEmpty(stored)
                local isEdited = (not isNew) and (lastEdit > syncTime)

                if isNew or isEdited then
                    local originalId, exportId = uploadPhoto(immich, photo, opts, failures)
                    if originalId or exportId then
                        MetadataTask.setImmichSyncTime(photo, LrDate.currentTime())
                        stats.uploaded = stats.uploaded + 1
                    end
                else
                    stats.skipped = stats.skipped + 1
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
            local prev = loadManifest()
            for assetId, uuid in pairs(prev) do
                if not catalog:findPhotoByUuid(uuid) then
                    if immich:deleteAsset(assetId) then
                        stats.deleted = stats.deleted + 1
                    end
                end
            end
            -- Rebuild the manifest from the current catalog state (includes freshly uploaded IDs).
            local current = {}
            for _, photo in ipairs(photos or {}) do
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
        if opts.rejectInLr and photos and not progress:isCanceled() then
            local toReject = {}
            for _, photo in ipairs(photos) do
                local id = MetadataTask.getAnyImmichAssetId(photo)
                if not Util.nilOrEmpty(id) then
                    local info = immich:getAssetInfo(id)
                    if not info or info.isTrashed then
                        table.insert(toReject, photo)
                    end
                end
            end
            if #toReject > 0 then
                catalog:withWriteAccessDo("Immich sync: reject deleted", function()
                    for _, photo in ipairs(toReject) do
                        photo:setRawMetadata("pickStatus", -1)
                    end
                end, { timeout = 30 })
                for _, photo in ipairs(toReject) do
                    MetadataTask.setImmichAssetId(photo, nil)
                    MetadataTask.setImmichOriginalAssetId(photo, nil)
                    stats.rejected = stats.rejected + 1
                end
            end
        end

        progress:done()

        --------------------------------------------------------------------------
        -- Summary
        --------------------------------------------------------------------------
        local lines = {
            stats.downloaded .. " downloaded",
            stats.uploaded .. " uploaded",
        }
        if opts.deleteInImmich then
            table.insert(lines, stats.deleted .. " deleted in Immich")
        end
        if opts.rejectInLr then
            table.insert(lines, stats.rejected .. " rejected in Lightroom")
        end
        table.insert(lines, stats.skipped .. " unchanged")
        LrDialogs.message("Immich sync complete", table.concat(lines, "\n"), "info")

        Util.reportUploadFailuresAndWarnings(failures, nil)
    end)
end

return SyncTask
