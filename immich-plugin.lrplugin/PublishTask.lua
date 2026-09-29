require("ImmichAPI")
require("StackManager")
require("UploadHelpers")
require("MetadataTask")

PublishTask = {}

--------------------------------------------------------------------------------
-- Asset identity in Publish
--
-- Lightroom records the remote (Immich) asset ID that was published for a photo per
-- published collection. Immich asset identity is scoped per publish service:
--   * two publish services (e.g. one for full-res originals, one for watermarked web
--     exports) must keep separate Immich assets for the same photo,
--   * two collections of the SAME service must keep pointing at one asset, which is
--     then added to both albums. Since a replace produces a new asset ID, the records
--     of the sibling collections are re-pointed at it in the same run.
-- The plugin metadata field (immichAssetId) holds a single ID per photo and cannot
-- express this: publishing a photo through a second service found the first service's
-- ID and replaced (destroyed) that asset. Publish therefore resolves the replace
-- target from Lightroom's own bookkeeping only. The metadata field is still written,
-- for the metadata panel and for the Export workflow.

--------------------------------------------------------------------------------
-- Read rendition.publishedPhotoId defensively: it is only defined for renditions that
-- belong to a publish service, and reading an undefined rendition property raises.
local function renditionPublishedPhotoId(rendition)
    if not rendition then
        return nil
    end
    local ok, id = LrTasks.pcall(function()
        return rendition.publishedPhotoId
    end)
    if ok and id ~= nil and tostring(id) ~= "" then
        return tostring(id)
    end
    return nil
end

--------------------------------------------------------------------------------
-- Collect all published collections of a publish service; collections may be nested
-- in collection sets, so recurse.
local function collectPublishedCollections(node, acc)
    for _, collection in ipairs(node:getChildCollections()) do
        table.insert(acc, collection)
    end
    for _, collectionSet in ipairs(node:getChildCollectionSets()) do
        collectPublishedCollections(collectionSet, acc)
    end
end

--------------------------------------------------------------------------------
-- All publish services of this plug-in. Lightroom reports a service's plug-in ID with
-- a two character suffix, hence the substring comparison used elsewhere in this file.
local function immichPublishServices()
    local catalog = LrApplication.activeCatalog()
    if not catalog then
        return {}
    end

    local services = {}
    -- Never let an unexpected catalog error take the caller down: without this list the
    -- caller still works, it just cannot see the services other than its own.
    local ok, err = LrTasks.pcall(function()
        services = catalog:getPublishServices(_PLUGIN.id) or {}
        if #services > 0 then
            return
        end
        -- Catalogs that do not match on the bare plug-in ID: filter the full list instead.
        services = {}
        for _, service in ipairs(catalog:getPublishServices() or {}) do
            if string.sub(service:getPluginId(), 1, -3) == _PLUGIN.id then
                table.insert(services, service)
            end
        end
    end)
    if not ok then
        log:warn("immichPublishServices: failed to read publish services: " .. tostring(err))
        return {}
    end
    return services
end

--------------------------------------------------------------------------------
-- Index of the Immich asset IDs Lightroom has recorded for this plug-in, split by
-- publish service:
--
--   index.own[photo.localIdentifier] -> asset IDs published by THIS service for the
--     photo, one per collection that holds it, in discovery order. Several distinct
--     IDs mean the collections drifted apart (a replace in one collection trashes the
--     asset the others still record), so callers try each of them.
--   index.records[photo.localIdentifier] -> the published-photo records of THIS service
--     that carry an asset ID, with the local ID of their collection, so a replace can
--     re-point the sibling collections at the new asset (see syncSiblingPublishedIds).
--   index.foreign[assetId] -> true for assets recorded by ANOTHER publish service of
--     this plug-in. Those must never be replaced by this service, see
--     resolvePublishedAssetId.
--   index.collectionId -> local ID of the collection being published.
local function buildPublishedIdIndex(publishedCollection)
    local index = { own = {}, records = {}, foreign = {}, collectionId = nil }
    if not publishedCollection then
        return index
    end
    index.collectionId = publishedCollection.localIdentifier

    local ok, err = LrTasks.pcall(function()
        local ownService = publishedCollection:getService()
        if not ownService then
            return
        end
        local services = immichPublishServices()
        local ownServiceListed = false
        for _, service in ipairs(services) do
            if service.localIdentifier == ownService.localIdentifier then
                ownServiceListed = true
                break
            end
        end
        if not ownServiceListed then
            table.insert(services, ownService)
        end
        for _, service in ipairs(services) do
            local isOwnService = service.localIdentifier == ownService.localIdentifier
            local collections = {}
            collectPublishedCollections(service, collections)
            for _, collection in ipairs(collections) do
                for _, publishedPhoto in ipairs(collection:getPublishedPhotos()) do
                    local remoteId = publishedPhoto:getRemoteId()
                    if remoteId and tostring(remoteId) ~= "" then
                        remoteId = tostring(remoteId)
                        if isOwnService then
                            local photo = publishedPhoto:getPhoto()
                            if photo then
                                local photoId = photo.localIdentifier
                                local ids = index.own[photoId]
                                if ids == nil then
                                    ids = {}
                                    index.own[photoId] = ids
                                end
                                if not Util.table_contains(ids, remoteId) then
                                    table.insert(ids, remoteId)
                                end
                                local records = index.records[photoId]
                                if records == nil then
                                    records = {}
                                    index.records[photoId] = records
                                end
                                table.insert(records, {
                                    publishedPhoto = publishedPhoto,
                                    collectionId = collection.localIdentifier,
                                })
                            end
                        else
                            index.foreign[remoteId] = true
                        end
                    end
                end
            end
        end
    end)
    if not ok then
        log:warn("buildPublishedIdIndex: failed to read published photos: " .. tostring(err))
        return { own = {}, records = {}, foreign = {}, collectionId = index.collectionId }
    end
    return index
end

--------------------------------------------------------------------------------
-- Resolve the Immich asset this publish service uploaded for the photo before, and
-- verify it still exists (and is not trashed) on the server. The ID recorded for the
-- collection being published is tried first, then the IDs its sibling collections
-- recorded for the same photo: after a replace in a sibling, the own record points at
-- the trashed predecessor while the sibling's record points at the live successor.
-- Returns nil when the photo is new to this service or every recorded asset is gone,
-- so callers upload a fresh one.
local function resolvePublishedAssetId(immich, rendition, photo, publishedIdIndex)
    local candidates = {}
    local function addCandidate(id)
        if not Util.nilOrEmpty(id) and not Util.table_contains(candidates, id) then
            table.insert(candidates, id)
        end
    end
    addCandidate(renditionPublishedPhotoId(rendition))
    if publishedIdIndex and photo then
        for _, id in ipairs(publishedIdIndex.own[photo.localIdentifier] or {}) do
            addCandidate(id)
        end
    end

    for _, candidate in ipairs(candidates) do
        -- Repair of catalogs written before asset identity was scoped per publish service:
        -- back then a second service resolved the first service's asset and replaced it, and
        -- recorded the replacement for itself. Both services ended up pointing at one asset
        -- and kept overwriting each other, and marking photos to re-publish does not clear
        -- those records. An asset another service of this plug-in has recorded is not ours to
        -- replace; a fresh upload makes this service's records its own again.
        if publishedIdIndex and publishedIdIndex.foreign[candidate] then
            log:info(
                "resolvePublishedAssetId: asset "
                    .. candidate
                    .. " is recorded by another publish service, not reusing it"
            )
        else
            local assetInfo = immich:getAssetInfo(candidate)
            if assetInfo and not assetInfo.isTrashed then
                log:trace("resolvePublishedAssetId: reusing asset " .. candidate .. " published by this service")
                return candidate
            end
            log:trace("resolvePublishedAssetId: asset " .. candidate .. " no longer exists in Immich")
        end
    end

    if #candidates > 0 then
        log:trace("resolvePublishedAssetId: none of " .. #candidates .. " recorded asset(s) is usable, uploading fresh")
    end
    return nil
end

--------------------------------------------------------------------------------
-- Lightroom keeps one published-photo record per collection, and a publish run only
-- updates the record of the collection being published. After this service uploads or
-- replaces the asset for a photo, re-point the records of its other collections at the
-- same asset; otherwise they keep referring to the trashed predecessor and upload a
-- second copy the next time they publish.
local function syncSiblingPublishedIds(immich, publishedIdIndex, photo, assetId)
    if not publishedIdIndex or not photo or Util.nilOrEmpty(assetId) then
        return
    end
    local stale = {}
    for _, record in ipairs(publishedIdIndex.records[photo.localIdentifier] or {}) do
        if record.collectionId ~= publishedIdIndex.collectionId then
            local okRead, remoteId = LrTasks.pcall(function()
                return record.publishedPhoto:getRemoteId()
            end)
            if okRead and tostring(remoteId or "") ~= assetId then
                table.insert(stale, record.publishedPhoto)
            end
        end
    end
    if #stale == 0 then
        return
    end

    local catalog = LrApplication.activeCatalog()
    if not catalog then
        log:warn("syncSiblingPublishedIds: cannot access catalog")
        return
    end
    local assetUrl = immich:getAssetUrl(assetId)
    local updated = 0
    local ok, err = LrTasks.pcall(function()
        -- Timeout so the call waits for the catalog lock held by the running publish
        -- instead of failing immediately.
        catalog:withPrivateWriteAccessDo(function()
            for _, publishedPhoto in ipairs(stale) do
                publishedPhoto:setRemoteId(assetId)
                if assetUrl then
                    publishedPhoto:setRemoteUrl(assetUrl)
                end
                updated = updated + 1
            end
        end, { timeout = 5 })
    end)
    if not ok then
        log:warn("syncSiblingPublishedIds: failed to update sibling collections: " .. tostring(err))
        return
    end
    log:info("syncSiblingPublishedIds: " .. updated .. " sibling collection record(s) now point at " .. assetId)
end

--------------------------------------------------------------------------------
-- Upload the tracked primary asset of a publish rendition, replacing the asset this
-- service published before when that asset is still available.
local function uploadPublishPrimary(immich, rendition, photo, path, visibility, publishedIdIndex)
    local existingId = resolvePublishedAssetId(immich, rendition, photo, publishedIdIndex)
    local id, errReason
    if existingId == nil then
        id, errReason = immich:uploadAsset(path, visibility)
    else
        id, errReason = immich:replaceAsset(existingId, path, visibility)
    end
    -- Keep the index and the sibling collections current so a photo published into
    -- several collections of this service resolves to the same asset in every one of them.
    if id and publishedIdIndex and photo then
        id = tostring(id)
        publishedIdIndex.own[photo.localIdentifier] = { id }
        syncSiblingPublishedIds(immich, publishedIdIndex, photo, id)
    end
    return id, errReason
end

--------------------------------------------------------------------------------
-- Resolves the locked folder visibility string from lockedFolderMode setting.
-- Returns "private" to upload to locked folder, nil for normal upload.
local function resolveLockedFolder(exportParams)
    local mode = exportParams.lockedFolderMode
    if not mode or mode == "none" then
        return nil
    elseif mode == "always" then
        return "locked"
    elseif mode == "ask" then
        local result = LrDialogs.confirm(
            "Upload to Locked Folder?",
            "Photos will be hidden from the timeline and require a PIN to view in Immich.",
            "Yes",
            "No"
        )
        return (result == "ok") and "locked" or nil
    end
    return nil
end

--------------------------------------------------------------------------------
-- Resolve or create album for publish; record remote id/url on exportSession.
-- Returns: albumCreationStrategy, albumId, albumAssetIds.
local function resolvePublishAlbum(immich, exportContext)
    local publishedCollection = exportContext.publishedCollection
    local collectionSettings = publishedCollection:getCollectionInfoSummary().collectionSettings
    local albumCreationStrategy = collectionSettings.albumCreationStrategy or "collection"
    local albumId = publishedCollection and publishedCollection:getRemoteId()
    local albumName = publishedCollection and publishedCollection:getName()
    local albumAssetIds = nil
    local exportSession = exportContext.exportSession

    log:trace("Album creation strategy used: " .. albumCreationStrategy)

    if albumCreationStrategy == "collection" or albumCreationStrategy == "existing" then
        if albumId and immich:checkIfAlbumExists(albumId) then
            albumAssetIds = immich:getAlbumAssetIds(albumId)
            exportSession:recordRemoteCollectionId(albumId)
            exportSession:recordRemoteCollectionUrl(immich:getAlbumUrl(albumId))
        else
            albumId = immich:createAlbum(albumName)
            albumAssetIds = {}
            exportSession:recordRemoteCollectionId(albumId)
            exportSession:recordRemoteCollectionUrl(immich:getAlbumUrl(albumId))
        end
    end
    return albumCreationStrategy, albumId, albumAssetIds
end

--------------------------------------------------------------------------------
-- Add asset to album (publish logic: folder vs collection/existing).
local function addAssetToPublishAlbum(immich, albumCreationStrategy, albumId, albumAssetIds, assetId, folderName)
    if albumCreationStrategy == "folder" then
        local folderAlbumId = immich:createOrGetAlbumFolderBased(folderName)
        if folderAlbumId then
            immich:addAssetToAlbum(folderAlbumId, assetId)
        end
    elseif albumId and (not albumAssetIds or not Util.table_contains(albumAssetIds, assetId)) then
        immich:addAssetToAlbum(albumId, assetId)
    end
end

--------------------------------------------------------------------------------
-- True if the current publish settings request uploading original files at all.
local function publishWantsOriginals(exportParams)
    local mode = exportParams.originalFileMode
    return exportParams.stackOriginalExport == true
        or mode == "edited"
        or mode == "all"
        or mode == "original_only"
        or mode == "original_plus_jpeg_if_edited"
end

--------------------------------------------------------------------------------
-- Per-photo decision: should the disk original be uploaded (as an untracked stack
-- secondary) for this photo, given the publish settings?
local function shouldUploadPublishOriginal(exportParams, photo, editedPhotosCache)
    if exportParams.stackOriginalExport == true then
        return true
    end
    local mode = exportParams.originalFileMode
    if mode == "all" or mode == "original_only" or mode == "original_plus_jpeg_if_edited" then
        return true
    end
    if mode == "edited" then
        return StackManager.hasEdits(photo, editedPhotosCache)
    end
    return false
end

--------------------------------------------------------------------------------
-- When publish settings request originals, ask the user whether to upload them,
-- warning that originals are untracked orphans in Immich. Remembers the choice
-- via a "don't show again" preference. Returns true to upload originals.
local function confirmOrphanOriginals(exportParams)
    if not publishWantsOriginals(exportParams) then
        return false
    end
    local action = LrDialogs.promptForActionWithDoNotShow({
        actionPrefKey = "immichPublishUploadOrphanOriginals",
        message = "Upload original files in Publish?",
        info = "Original files uploaded during Publish are stacked with the exported photo but are NOT tracked by"
            .. " Lightroom.\n\nThey will not be updated when you re-publish, and will NOT be removed from Immich when"
            .. " you remove photos from this collection or delete the collection — they remain as orphans you must"
            .. " clean up manually in Immich.",
        verbBtns = {
            { verb = "skip", label = "Skip originals" },
            { verb = "upload", label = "Upload originals" },
        },
    })
    return action == "upload"
end

--------------------------------------------------------------------------------
-- Process one photo group in original+export publish flow.
-- Mutates failures, stackWarnings, atLeastSomeSuccess, exportedPrimaryByPhoto.
local function processPublishOnePhotoGroup(
    immich,
    items,
    albumCreationStrategy,
    albumId,
    albumAssetIds,
    failures,
    stackWarnings,
    atLeastSomeSuccess,
    exportedPrimaryByPhoto,
    visibility,
    exportParams,
    editedPhotosCache,
    allowOrphanOriginals,
    publishedIdIndex
)
    if not items or not items[1] then
        return
    end
    local photo = items[1].photo
    local filename = photo:getFormattedMetadata("fileName")
    if #items >= 2 then
        UploadHelpers.sortOriginalExportItems(items)
        local assetIds = {}
        local primaryId = nil
        for i, item in ipairs(items) do
            -- After sort: items[1]=export (primary), items[2..]=original/extra renditions.
            local id, errReason
            if i == 1 then
                -- Primary export: replace the asset this publish service uploaded before.
                id, errReason =
                    uploadPublishPrimary(immich, item.rendition, photo, item.path, visibility, publishedIdIndex)
            else
                -- Stack secondaries have no stored ID and no safe way to resolve a prior
                -- upload now that deviceAssetId is gone; upload fresh.
                id, errReason = immich:uploadAsset(item.path, visibility)
            end
            UploadHelpers.safeDeleteTempFile(item.path)
            if not id then
                table.insert(failures, filename .. " (" .. (errReason or "Upload failed") .. ")")
            else
                atLeastSomeSuccess[1] = true
                table.insert(assetIds, id)
                if primaryId == nil then
                    primaryId = id
                end
                item.rendition:recordPublishedPhotoId(id)
                item.rendition:recordPublishedPhotoUrl(immich:getAssetUrl(id))
                log:info("original+export [" .. filename .. "]: -> " .. id)
            end
        end
        if #assetIds >= 2 and primaryId then
            if not immich:createStack(assetIds) then
                table.insert(stackWarnings, filename .. ": Failed to create original+export stack")
            end
        end
        if primaryId then
            MetadataTask.setImmichAssetId(photo, primaryId)
            exportedPrimaryByPhoto[photo.localIdentifier] = { assetId = primaryId, photo = photo }
            addAssetToPublishAlbum(
                immich,
                albumCreationStrategy,
                albumId,
                albumAssetIds,
                primaryId,
                photo:getFormattedMetadata("folderName")
            )
        end
    elseif #items == 1 then
        -- One rendition arrived. Since LR_exportOriginalFile is never set, Lightroom always
        -- delivers the rendered export (never an original-copy rendition), so item.role = "export".
        -- Always treat the single rendition as the tracked export primary.
        --
        -- The disk original can optionally be uploaded as a stack secondary (allowOrphanOriginals,
        -- confirmed by the user). Such assets are uploaded outside recordPublishedPhotoId, so
        -- Lightroom cannot track them: they are NOT updated on re-publish and NOT removed when the
        -- photo leaves the collection (deletePhotosFromPublishedCollection only cleans up assets
        -- registered via recordPublishedPhotoId). They become orphans the user must clean up in
        -- Immich. When the user declines (or the settings don't request originals), only the export
        -- is uploaded and we warn instead.
        local item = items[1]
        log:info("original+export [" .. filename .. "]: single rendition, uploading as export")
        local id, errReason =
            uploadPublishPrimary(immich, item.rendition, photo, item.path, visibility, publishedIdIndex)
        UploadHelpers.safeDeleteTempFile(item.path)
        if not id then
            table.insert(failures, filename .. " (" .. (errReason or "Upload failed") .. ")")
        else
            atLeastSomeSuccess[1] = true
            local primaryId = id
            MetadataTask.setImmichAssetId(photo, primaryId)
            item.rendition:recordPublishedPhotoId(id)
            item.rendition:recordPublishedPhotoUrl(immich:getAssetUrl(id))

            local wantsOriginal = exportParams and shouldUploadPublishOriginal(exportParams, photo, editedPhotosCache)
            if wantsOriginal and allowOrphanOriginals then
                if string.upper(exportParams.LR_format or "") == "ORIGINAL" then
                    -- 'Original / no reformat' makes the export a byte-for-byte copy of the source,
                    -- so uploading the disk original would create two identical assets. Skip.
                    table.insert(
                        stackWarnings,
                        filename
                            .. ": skipped original+export stack — 'Original / no reformat' produces an identical copy."
                            .. " Switch to any rendered format (e.g. JPEG, TIFF, PNG)."
                    )
                else
                    local originalPath = StackManager.getOriginalFilePath(photo)
                    if originalPath then
                        -- Untracked orphan secondary: upload fresh (no stored ID to dedup against).
                        local origId = immich:uploadAsset(originalPath, visibility)
                        if origId then
                            -- Warn once per publish run to keep the post-publish dialog concise.
                            if not stackWarnings._orphanOriginalsWarned then
                                table.insert(
                                    stackWarnings,
                                    "Original files were uploaded as untracked assets: Lightroom will not update or"
                                        .. " remove them from Immich, so clean up orphaned originals manually"
                                        .. " (applies to all photos in this run)"
                                )
                                stackWarnings._orphanOriginalsWarned = true
                            end
                            if not immich:createStack({ id, origId }) then
                                table.insert(stackWarnings, filename .. ": failed to create original+export stack")
                            end
                        else
                            table.insert(stackWarnings, filename .. ": failed to upload original file")
                        end
                    else
                        table.insert(stackWarnings, filename .. ": original file not accessible; uploaded export only")
                    end
                end
            elseif wantsOriginal then
                -- User declined the orphan upload: keep export-only behavior and warn once.
                if not stackWarnings._originalNotUploadedWarned then
                    table.insert(
                        stackWarnings,
                        "Originals not uploaded in publish mode to avoid untracked orphans in Immich"
                            .. " (applies to all photos in this run)"
                    )
                    stackWarnings._originalNotUploadedWarned = true
                end
            end
            exportedPrimaryByPhoto[photo.localIdentifier] = { assetId = primaryId, photo = photo }
            addAssetToPublishAlbum(
                immich,
                albumCreationStrategy,
                albumId,
                albumAssetIds,
                primaryId,
                photo:getFormattedMetadata("folderName")
            )
        end
    end
end

--------------------------------------------------------------------------------
-- Original+export flow: process each rendition immediately as it arrives, keeping
-- renders and uploads interleaved so the Lightroom progress bar advances
-- proportionally to real work done. LR_exportOriginalFile is never set, so LR
-- always delivers exactly one rendition per photo; the disk original is fetched
-- inside processPublishOnePhotoGroup (or skipped for orphan safety in publish mode).
local function processPublishStackOriginalExportRenditions(
    immich,
    exportContext,
    progressScope,
    nPhotos,
    albumCreationStrategy,
    albumId,
    albumAssetIds,
    visibility,
    exportParams,
    editedPhotosCache,
    allowOrphanOriginals,
    publishedIdIndex
)
    local failures, stackWarnings = {}, {}
    local atLeastSomeSuccess = { false }
    local exportedPrimaryByPhoto = {}
    local done = 0
    for _, rendition in exportContext:renditions({ stopIfCanceled = true }) do
        if progressScope:isCanceled() then
            break
        end
        local success, pathOrMessage = rendition:waitForRender()
        if progressScope:isCanceled() then
            break
        end
        if success then
            -- role = "export": LR_exportOriginalFile is never set, so LR always delivers the
            -- rendered export (never an original-copy rendition), regardless of file extension.
            local item = {
                path = pathOrMessage,
                photo = rendition.photo,
                rendition = rendition,
                role = "export",
            }
            processPublishOnePhotoGroup(
                immich,
                { item },
                albumCreationStrategy,
                albumId,
                albumAssetIds,
                failures,
                stackWarnings,
                atLeastSomeSuccess,
                exportedPrimaryByPhoto,
                visibility,
                exportParams,
                editedPhotosCache,
                allowOrphanOriginals,
                publishedIdIndex
            )
        end
        -- Advance progress for every rendition, including failed renders, so the bar reaches 100%.
        done = done + 1
        progressScope:setPortionComplete(done, nPhotos)
        if done == 1 or done % 10 == 0 or done == nPhotos then
            log:info("Publish progress: " .. done .. "/" .. nPhotos .. " (" .. math.floor(done * 100 / nPhotos) .. "%)")
        end
    end
    return failures, stackWarnings, atLeastSomeSuccess[1], exportedPrimaryByPhoto
end

--------------------------------------------------------------------------------
local function processPublishSingleRenditionRenditions(
    immich,
    exportContext,
    progressScope,
    nPhotos,
    exportParams,
    albumCreationStrategy,
    albumId,
    albumAssetIds,
    visibility,
    publishedIdIndex
)
    local failures, stackWarnings = {}, {}
    local atLeastSomeSuccess = false
    local exportedPrimaryByPhoto = {}
    local done = 0
    for _, rendition in exportContext:renditions({ stopIfCanceled = true }) do
        local success, pathOrMessage = rendition:waitForRender()
        if progressScope:isCanceled() then
            break
        end
        if success then
            local photo = rendition.photo
            -- Primary asset: replace the asset this publish service uploaded before.
            local id, errReason =
                uploadPublishPrimary(immich, rendition, photo, pathOrMessage, visibility, publishedIdIndex)

            if not id then
                table.insert(
                    failures,
                    photo:getFormattedMetadata("fileName") .. " (" .. (errReason or "Upload failed") .. ")"
                )
            else
                atLeastSomeSuccess = true
                MetadataTask.setImmichAssetId(photo, id)
                rendition:recordPublishedPhotoId(id)
                rendition:recordPublishedPhotoUrl(immich:getAssetUrl(id))
                exportedPrimaryByPhoto[photo.localIdentifier] = { assetId = id, photo = photo }
                if albumCreationStrategy == "folder" then
                    local folderName = rendition.photo:getFormattedMetadata("folderName")
                    local folderBasedAlbumId = immich:createOrGetAlbumFolderBased(folderName)
                    if folderBasedAlbumId then
                        immich:addAssetToAlbum(folderBasedAlbumId, id)
                    end
                else
                    if albumId and (not albumAssetIds or not Util.table_contains(albumAssetIds, id)) then
                        immich:addAssetToAlbum(albumId, id)
                    end
                end
            end
            UploadHelpers.safeDeleteTempFile(pathOrMessage)
        end
        -- Advance progress for every rendition, including failed renders, so the bar reaches 100%.
        done = done + 1
        progressScope:setPortionComplete(done, nPhotos)
        if done == 1 or done % 10 == 0 or done == nPhotos then
            log:info("Publish progress: " .. done .. "/" .. nPhotos .. " (" .. math.floor(done * 100 / nPhotos) .. "%)")
        end
    end
    return failures, stackWarnings, atLeastSomeSuccess, exportedPrimaryByPhoto
end

--------------------------------------------------------------------------------
local function runPublishExport(
    immich,
    exportContext,
    progressScope,
    nPhotos,
    exportParams,
    albumCreationStrategy,
    albumId,
    albumAssetIds,
    visibility,
    editedPhotosCache,
    allowOrphanOriginals,
    publishedIdIndex
)
    local failures, stackWarnings, atLeastSomeSuccess, exportedPrimaryByPhoto
    local useStacking = exportParams.stackOriginalExport
    local mode = exportParams.originalFileMode
    if mode == "edited" or mode == "all" or mode == "original_plus_jpeg_if_edited" or mode == "original_only" then
        useStacking = true
    end

    if useStacking then
        failures, stackWarnings, atLeastSomeSuccess, exportedPrimaryByPhoto =
            processPublishStackOriginalExportRenditions(
                immich,
                exportContext,
                progressScope,
                nPhotos,
                albumCreationStrategy,
                albumId,
                albumAssetIds,
                visibility,
                exportParams,
                editedPhotosCache,
                allowOrphanOriginals,
                publishedIdIndex
            )
    else
        failures, stackWarnings, atLeastSomeSuccess, exportedPrimaryByPhoto = processPublishSingleRenditionRenditions(
            immich,
            exportContext,
            progressScope,
            nPhotos,
            exportParams,
            albumCreationStrategy,
            albumId,
            albumAssetIds,
            visibility,
            publishedIdIndex
        )
    end
    if exportParams.stackLrStacks and next(exportedPrimaryByPhoto) then
        UploadHelpers.applyLrStacksInImmich(immich, exportedPrimaryByPhoto, stackWarnings)
    end
    UploadHelpers.applyVideoMetadataForAll(immich, exportedPrimaryByPhoto)
    return failures, stackWarnings, atLeastSomeSuccess, exportedPrimaryByPhoto
end

--------------------------------------------------------------------------------

function PublishTask.processRenderedPhotos(functionContext, exportContext)
    local exportSession, exportParams, immich = Util.validateExportContextAndConnect(exportContext, "Publish")
    if not exportSession then
        return nil
    end

    local albumCreationStrategy, albumId, albumAssetIds = resolvePublishAlbum(immich, exportContext)

    local nPhotos = exportSession:countRenditions()
    log:info(
        "=== Publish START: "
            .. nPhotos
            .. " photos | url="
            .. tostring(exportParams.url)
            .. " | stackOriginalExport="
            .. tostring(exportParams.stackOriginalExport)
            .. " | stackLrStacks="
            .. tostring(exportParams.stackLrStacks)
            .. " | albumCreationStrategy="
            .. tostring(albumCreationStrategy)
            .. " | lockedFolderMode="
            .. tostring(exportParams.lockedFolderMode)
            .. " ==="
    )

    local progressTitle = (prefs and prefs.url and prefs.url ~= "") and prefs.url or "Immich"
    -- Use LrProgressScope tied to functionContext rather than exportContext:configureProgress.
    -- configureProgress creates a scope managed by LR's render pipeline, which closes the bar
    -- when rendering completes — potentially long before all uploads are done. LrProgressScope
    -- with functionContext stays alive until processRenderedPhotos returns, and is not advanced
    -- by LR's render thread, eliminating both early-close and forward→0→return race conditions.
    local progressScope = LrProgressScope({
        title = Util.buildSimpleUploadProgressTitle(nPhotos, "Publishing", progressTitle),
        functionContext = functionContext,
    })

    local visibility = resolveLockedFolder(exportParams)

    -- Ask once whether to upload (untracked) originals when settings request them.
    local allowOrphanOriginals = confirmOrphanOriginals(exportParams)
    -- The "edited" mode needs a catalog-wide edit cache to decide per photo.
    local editedPhotosCache = nil
    if allowOrphanOriginals and exportParams.originalFileMode == "edited" then
        editedPhotosCache = StackManager.getEditedPhotosCache()
    end
    log:info("Publish upload originals (orphans): " .. tostring(allowOrphanOriginals))

    -- Asset identity is scoped to this publish service (see notes at the top of this
    -- file), so collect the IDs this service already published for its photos, plus the
    -- ones other services of this plug-in own and this service must not replace.
    local publishedIdIndex = buildPublishedIdIndex(exportContext.publishedCollection)
    local knownPublishedIds, foreignPublishedIds = 0, 0
    for _ in pairs(publishedIdIndex.own) do
        knownPublishedIds = knownPublishedIds + 1
    end
    for _ in pairs(publishedIdIndex.foreign) do
        foreignPublishedIds = foreignPublishedIds + 1
    end
    log:info(
        "Publish: "
            .. knownPublishedIds
            .. " photos already published by this service, "
            .. foreignPublishedIds
            .. " assets owned by other publish services"
    )

    local failures, stackWarnings = runPublishExport(
        immich,
        exportContext,
        progressScope,
        nPhotos,
        exportParams,
        albumCreationStrategy,
        albumId,
        albumAssetIds,
        visibility,
        editedPhotosCache,
        allowOrphanOriginals,
        publishedIdIndex
    )
    progressScope:done()

    log:info(
        "=== Publish DONE: "
            .. nPhotos
            .. " photos | failures="
            .. #failures
            .. " | warnings="
            .. #stackWarnings
            .. " ==="
    )
    Util.reportUploadFailuresAndWarnings(failures, stackWarnings)
end

function PublishTask.addCommentToPublishedPhoto(publishSettings, remotePhotoId, commentText) end

function PublishTask.getCommentsFromPublishedCollection(publishSettings, arrayOfPhotoInfo, commentCallback)
    local immich = ImmichAPI:new(publishSettings.url, publishSettings.apiKey)
    if not immich:checkConnectivity() then
        ErrorHandler.handleError(
            "Immich connection not working. Check URL and API key in plugin settings.",
            "Immich connection not working, probably due to wrong url and/or apiKey. Export stopped."
        )
        return nil
    end

    for i, photoInfo in ipairs(arrayOfPhotoInfo) do
        -- Get all published Collections where the photo is included.
        local publishedCollections = photoInfo.photo:getContainedPublishedCollections()

        local comments = {}
        for j, publishedCollection in ipairs(publishedCollections) do
            -- Check if the published collection is an Immich collection and still exists on the server.
            if string.sub(publishedCollection:getService():getPluginId(), 1, -3) == _PLUGIN.id then
                log:trace("publishedCollection : " .. publishedCollection:getName() .. " is an Immich collection.")
                if immich:checkIfAlbumExists(publishedCollection:getRemoteId()) then
                    log:trace("... and it exists on the server.")
                    -- Get activities for the photo in the published collection.
                    local activities =
                        immich:getActivities(publishedCollection:getRemoteId(), photoInfo.publishedPhoto:getRemoteId())
                    if activities and type(activities) == "table" then
                        for k, activity in ipairs(activities) do
                            if activity and activity.createdAt then
                                local comment = {}

                                local year, month, day, hour, minute =
                                    string.sub(activity.createdAt, 1, 15):match("(%d+)%-(%d+)%-(%d+)%a(%d+)%:(%d+)")

                                if year and month and day and hour and minute then
                                    -- Convert from date string to EPOC to COCOA
                                    comment.dateCreated = os.time({
                                        year = year,
                                        month = month,
                                        day = day,
                                        hour = hour,
                                        min = minute,
                                    }) - 978307200
                                end
                                comment.commentId = activity.id
                                comment.username = (activity.user and activity.user.email) or ""
                                comment.realname = (activity.user and activity.user.name) or ""

                                if activity.type == "comment" then
                                    comment.commentText = activity.comment or ""
                                    table.insert(comments, comment)
                                elseif activity.type == "like" then
                                    comment.commentText = "Like"
                                    table.insert(comments, comment)
                                end
                            end
                        end
                    end
                end
            end
        end

        -- Call Lightroom's callback function to register comments.
        commentCallback({ publishedPhoto = photoInfo, comments = comments })
    end
end

function PublishTask.deletePhotosFromPublishedCollection(
    publishSettings,
    arrayOfPhotoIds,
    deletedCallback,
    localCollectionId
)
    if Util.nilOrEmpty(publishSettings.url) or Util.nilOrEmpty(publishSettings.apiKey) then
        ErrorHandler.handleError(
            "Configure Immich in plugin settings.",
            "deletePhotosFromPublishedCollection: URL or API key not set"
        )
        return nil
    end
    local immich = ImmichAPI:new(publishSettings.url, publishSettings.apiKey)
    if not immich:checkConnectivity() then
        ErrorHandler.handleError(
            "Immich connection not working. Check URL and API key in plugin settings.",
            "Immich connection not working, probably due to wrong url and/or apiKey. Export stopped."
        )
        return nil
    end

    local delete = LrDialogs.promptForActionWithDoNotShow({
        actionPrefKey = "immichDeletePhotosTrashBehavior",
        message = "Delete photos",
        info = "Should removed photos be trashed in Immich?",
        verbBtns = {
            { verb = "no", label = "No" },
            { verb = "only_if_not_in_album", label = "If not included in any album" },
            { verb = "always", label = "Yes (dangerous!)" },
        },
    })
    if delete == nil then
        return nil
    end

    local catalog = LrApplication.activeCatalog()
    if not catalog then
        ErrorHandler.handleError(
            "Lightroom catalog not available.",
            "deletePhotosFromPublishedCollection: cannot access catalog"
        )
        return nil
    end
    local publishedCollection = catalog:getPublishedCollectionByLocalIdentifier(localCollectionId)
    if not publishedCollection then
        ErrorHandler.handleError(
            "Collection not found.",
            "deletePhotosFromPublishedCollection: published collection not found"
        )
        return nil
    end
    local publishedPhotos = publishedCollection:getPublishedPhotos()

    local notExistingAlbums = {}

    for _, publishedPhoto in ipairs(publishedPhotos) do
        if Util.table_contains(arrayOfPhotoIds, publishedPhoto:getRemoteId()) then
            local photoRemoteId = publishedPhoto:getRemoteId()
            log:trace("Photo " .. photoRemoteId .. " is in the list to be deleted.")

            local folderName = publishedPhoto:getPhoto():getFormattedMetadata("folderName")
            log:trace("Photo is in folder: " .. folderName)

            local albumId = nil
            local albumCreationStrategy =
                publishedCollection:getCollectionInfoSummary().collectionSettings.albumCreationStrategy
            if albumCreationStrategy == nil then
                albumCreationStrategy = "collection" -- Default strategy for old collections.
            end

            if albumCreationStrategy == "folder" then
                local albums = immich:getAlbumsByNameFolderBased(folderName)
                log:trace("Album found for folder based strategy: " .. Util.dumpTable(albums))
                if albums ~= nil and #albums == 1 then
                    albumId = albums[1].value
                elseif not Util.table_contains(notExistingAlbums, folderName or "(unknown folder)") then
                    table.insert(notExistingAlbums, folderName or "(unknown folder)")
                end
            else
                albumId = publishedCollection:getRemoteId()
            end

            log:trace("Album id to remove from: " .. albumId)

            local removeFromAlbumSuccess = false
            if albumId ~= nil then
                removeFromAlbumSuccess = immich:removeAssetFromAlbum(albumId, photoRemoteId)
            end

            local deletionSuccess = true
            if delete == "always" then
                deletionSuccess = immich:deleteAsset(photoRemoteId)
            elseif delete == "only_if_not_in_album" then
                if not immich:checkIfAssetIsInAnAlbum(photoRemoteId) then
                    deletionSuccess = immich:deleteAsset(photoRemoteId)
                end
            end
            -- delete == 'no': only remove from album, do not trash
            if not deletionSuccess then
                ErrorHandler.handleError(
                    "Failed to delete asset (check logs)",
                    "Failed to delete asset " .. photoRemoteId .. " from Immich"
                )
            end

            if removeFromAlbumSuccess and deletionSuccess then
                log:trace("Successfully removed photo " .. photoRemoteId .. " from album " .. tostring(albumId))
                deletedCallback(photoRemoteId)
            end
        end
    end

    if #notExistingAlbums > 0 then
        LrDialogs.message(
            "Some albums not found",
            "The following albums were not found on the Immich server,"
                .. " but the photos were removed from the collection: \n"
                .. table.concat(notExistingAlbums, "\n"),
            "info"
        )
    end
end

function PublishTask.deletePublishedCollection(publishSettings, info)
    local immich = ImmichAPI:new(publishSettings.url, publishSettings.apiKey)
    if not immich:checkConnectivity() then
        ErrorHandler.handleError(
            "Immich connection not working. Check URL and API key in plugin settings.",
            "Immich connection not working, probably due to wrong url and/or apiKey. Export stopped."
        )
        return nil
    end

    -- remoteId is nil, if the collection isn't yet published.
    if info.remoteId ~= nil and info.remoteId ~= "" then
        if not immich:checkIfAlbumExists(info.remoteId) then
            log:trace(
                "deletePublishedCollection: album does not exist on server, skip delete: " .. tostring(info.remoteId)
            )
        else
            local ok = immich:deleteAlbum(info.remoteId)
            if not ok then
                ErrorHandler.handleError(
                    "Could not delete album on Immich. Check logs.",
                    "deletePublishedCollection: failed to delete album " .. tostring(info.remoteId)
                )
            end
        end
    end
end

function PublishTask.renamePublishedCollection(publishSettings, info)
    local immich = ImmichAPI:new(publishSettings.url, publishSettings.apiKey)
    if not immich:checkConnectivity() then
        ErrorHandler.handleError(
            "Immich connection not working. Check URL and API key in plugin settings.",
            "Immich connection not working, probably due to wrong url and/or apiKey. Export stopped."
        )
        return nil
    end

    -- remoteId is nil, if the collection isn't yet published.
    if info.remoteId ~= nil and info.remoteId ~= "" and info.name and info.name ~= "" then
        local ok = immich:renameAlbum(info.remoteId, info.name)
        if not ok then
            ErrorHandler.handleError(
                "Could not rename album on Immich. Check logs.",
                "renamePublishedCollection: failed to rename album " .. tostring(info.remoteId)
            )
        end
    end
end

function PublishTask.shouldDeletePhotosFromServiceOnDeleteFromCatalog(publishSettings, nPhotos)
    return nil -- Show builtin Lightroom dialog.
end

function PublishTask.validatePublishedCollectionName(name)
    return true, "" -- TODO
end

function PublishTask.getCollectionBehaviorInfo(publishSettings)
    return {
        defaultCollectionName = "default",
        defaultCollectionCanBeDeleted = true,
        canAddCollection = true,
        -- Allow unlimited depth of collection sets, as requested by user.
        -- maxCollectionSetDepth = 0,
    }
end

function PublishTask.viewForCollectionSettings(f, publishSettings, info)
    if info.publishedCollection ~= nil then
        return f:row({}) -- No settings for existing published collections.
    end

    info.pluginContext.albumCreationStrategy = "collection"
    info.pluginContext.selectedAlbum = 0
    info.pluginContext.immichAlbums = { { title = "Please select", value = 0 } }

    LrTasks.startAsyncTask(function()
        local immich = ImmichAPI:new(publishSettings.url, publishSettings.apiKey)
        local albums = immich:getAlbumsWODate()
        if albums == nil then
            albums = {}
        end
        table.insert(albums, 1, { title = "Please select", value = 0 })
        info.pluginContext.immichAlbums = albums
    end)

    local share = LrView.share
    local bind = LrView.bind

    local result = f:group_box({
        bind_to_object = info.pluginContext,
        title = "Immich Album Settings",
        fill_horizontal = 1,
        f:column({
            spacing = share("inter_control_spacing"),
            f:radio_button({
                title = "Create new album from collection name",
                checked_value = "collection",
                value = bind("albumCreationStrategy"),
            }),
            f:radio_button({
                title = "Create albums based on folder names",
                checked_value = "folder",
                value = bind("albumCreationStrategy"),
            }),
            f:row({
                f:radio_button({
                    title = "Use existing album",
                    checked_value = "existing",
                    value = bind("albumCreationStrategy"),
                }),
                f:popup_menu({
                    items = bind("immichAlbums"),
                    value = bind("selectedAlbum"), -- Preselect "Please select"
                    width = share("field_width"),
                    enabled = bind("albumCreationStrategy", { "existing" }),
                }),
            }),
        }),
    })

    return result
end

function PublishTask.endDialogForCollectionSettings(publishSettings, info)
    log:trace("endDialogForCollectionSettings called")
    local props = info.pluginContext
    if info.why == "ok" then
        if props.albumCreationStrategy ~= nil then
            if props.albumCreationStrategy == "existing" and props.selectedAlbum ~= 0 then
                log:trace("User selected to bind collection to existing album with id " .. props.selectedAlbum)
                info.collectionSettings.albumCreationStrategy = "existing"
                info.collectionSettings.remoteId = props.selectedAlbum
            elseif props.albumCreationStrategy == "existing" and props.selectedAlbum == 0 then
                ErrorHandler.handleError("No album selected", "No album selected")
            else
                log:trace("Setting album creation strategy to: " .. props.albumCreationStrategy)
                info.collectionSettings.albumCreationStrategy = props.albumCreationStrategy
            end
        elseif info.collectionSettings.albumCreationStrategy == nil then
            log:trace("No album creation strategy set, defaulting to 'collection'")
            info.collectionSettings.albumCreationStrategy = "collection" -- Default strategy for old collections.
        else
            log:trace("Keeping existing album creation strategy: " .. info.collectionSettings.albumCreationStrategy)
        end
    end
end

function PublishTask.updateCollectionSettings(publishSettings, info)
    log:trace("updateCollectionSettings called")
    if not info or not info.collectionSettings then
        return
    end
    local props = info.collectionSettings
    if props.albumCreationStrategy == "existing" and props.remoteId then
        local immich = ImmichAPI:new(publishSettings.url, publishSettings.apiKey)
        if not immich:checkConnectivity() then
            log:warn("updateCollectionSettings: Immich connection not available")
            return
        end
        log:trace("Binding collection to existing album with id " .. tostring(props.remoteId))
        local name = immich:getAlbumNameById(props.remoteId)
        local url = immich:getAlbumUrl(props.remoteId)
        if not name then
            name = "Album " .. tostring(props.remoteId)
        end
        if not url then
            url = ""
        end
        log:trace("Setting collection name to " .. tostring(name) .. ", url to " .. tostring(url))
        local catalog = LrApplication.activeCatalog()
        if catalog and info.publishedCollection then
            catalog:withWriteAccessDo("Update published collection info", function()
                info.publishedCollection:setRemoteId(props.remoteId)
                info.publishedCollection:setRemoteUrl(url)
                info.publishedCollection:setName(name)
            end)
        end
    end
end
