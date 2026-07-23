require("ImmichAPI")
require("StackManager")
require("UploadHelpers")
require("MetadataTask")

PublishTask = {}

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
    allowOrphanOriginals
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
                -- Primary export: dedup/replace via the stored rendered-export ID.
                id, errReason = StackManager.uploadOneAssetOrReplace(immich, photo, item.path, visibility, false)
            else
                -- Stack secondary = the original master: dedup/replace via the stored
                -- original ID so re-publish updates it instead of creating a duplicate.
                id, errReason = StackManager.uploadOneAssetOrReplace(immich, photo, item.path, visibility, true)
            end
            UploadHelpers.safeDeleteTempFile(item.path)
            if not id then
                table.insert(failures, filename .. " (" .. (errReason or "Upload failed") .. ")")
            else
                atLeastSomeSuccess[1] = true
                table.insert(assetIds, id)
                if primaryId == nil then
                    primaryId = id
                else
                    -- Secondary original: persist its ID.
                    MetadataTask.setImmichOriginalAssetId(photo, id)
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
        local id, errReason = StackManager.uploadOneAssetOrReplace(immich, photo, item.path, visibility)
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
                        -- Orphan secondary re: Lightroom's publish lifecycle (not tracked via
                        -- recordPublishedPhotoId), but its Immich ID is persisted separately
                        -- (immichOriginalAssetId) and deduped against the original field, so a
                        -- re-publish replaces the same original instead of piling up duplicates.
                        local origId =
                            StackManager.uploadOneAssetOrReplace(immich, photo, originalPath, visibility, true)
                        if origId then
                            MetadataTask.setImmichOriginalAssetId(photo, origId)
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
    allowOrphanOriginals
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
                allowOrphanOriginals
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
    visibility
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
            -- Primary asset: resolve a prior upload via the stored Immich asset ID.
            local existingId = immich:checkIfAssetExistsEnhanced(photo)
            local id, errReason
            if existingId == nil then
                id, errReason = immich:uploadAsset(pathOrMessage, visibility)
            else
                id, errReason = immich:replaceAsset(existingId, pathOrMessage, visibility)
            end

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
                -- Optionally stack the export with an already-present original in Immich (from a
                -- prior publish/export or an import), without re-uploading it. Verified live, so a
                -- since-deleted original is skipped.
                if exportParams.stackWithExistingOriginal then
                    local r = StackManager.stackExportWithExistingOriginal(immich, photo, id)
                    if r == false then
                        table.insert(
                            stackWarnings,
                            photo:getFormattedMetadata("fileName") .. ": failed to stack with existing Immich original"
                        )
                    end
                end
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
    allowOrphanOriginals
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
                allowOrphanOriginals
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
            visibility
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
            .. " | stackWithExistingOriginal="
            .. tostring(exportParams.stackWithExistingOriginal)
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
        allowOrphanOriginals
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

-- Sharing UI shown when editing the settings of an already-published Immich album collection.
-- Lets the user generate an album share link and share the album with individual Immich users.
function PublishTask.viewForSharingSettings(f, publishSettings, info)
    local ctx = info.pluginContext or {}
    local settings = info.publishedCollection:getCollectionInfoSummary().collectionSettings or {}
    local strategy = settings.albumCreationStrategy or "collection"
    local albumId = info.publishedCollection:getRemoteId()

    if strategy == "folder" then
        return f:group_box({
            title = "Immich album sharing",
            fill_horizontal = 1,
            f:static_text({
                title = "This collection creates one album per folder, so it has no single album to share.",
                fill_horizontal = 1,
            }),
        })
    end

    if Util.nilOrEmpty(albumId) then
        return f:group_box({
            title = "Immich album sharing",
            fill_horizontal = 1,
            f:static_text({
                title = "Publish this collection to Immich first, then reopen these settings"
                    .. " to create a share link or share with users.",
                fill_horizontal = 1,
            }),
        })
    end

    ctx.shareUrl = ""
    ctx.shareRole = "viewer"
    ctx.selectedShareUser = 0
    ctx.immichShareUsers = { { title = "Loading users...", value = 0 } }

    -- Populate the user picker asynchronously (same pattern as the album picker below).
    LrTasks.startAsyncTask(function()
        local immich = ImmichAPI:new(publishSettings.url, publishSettings.apiKey)
        local users = immich:getAllUsers()
        local items = { { title = "Please select", value = 0 } }
        if users then
            for _, u in ipairs(users) do
                local label = u.name or u.email or u.id
                if u.name and u.email then
                    label = u.name .. " (" .. u.email .. ")"
                end
                table.insert(items, { title = label, value = u.id })
            end
        end
        ctx.immichShareUsers = items
    end)

    local bind = LrView.bind
    local share = LrView.share

    return f:group_box({
        bind_to_object = ctx,
        title = "Immich album sharing",
        fill_horizontal = 1,
        f:column({
            spacing = share("inter_control_spacing"),
            fill_horizontal = 1,
            f:row({
                f:push_button({
                    title = "Generate share link",
                    action = function()
                        LrTasks.startAsyncTask(function()
                            local immich = ImmichAPI:new(publishSettings.url, publishSettings.apiKey)
                            local url = immich:createAlbumSharedLink(albumId, {})
                            if Util.nilOrEmpty(url) then
                                ErrorHandler.handleError(
                                    "Could not create share link. Check logs.",
                                    "viewForSharingSettings: createAlbumSharedLink returned nil"
                                )
                            else
                                ctx.shareUrl = url
                            end
                        end)
                    end,
                }),
                f:edit_field({
                    value = bind("shareUrl"),
                    fill_horizontal = 1,
                    width_in_chars = 24,
                    tooltip = "Select to copy the share link",
                }),
                f:push_button({
                    title = "Open",
                    action = function()
                        if not Util.nilOrEmpty(ctx.shareUrl) then
                            LrHttp.openUrlInBrowser(ctx.shareUrl)
                        end
                    end,
                }),
            }),
            f:separator({ fill_horizontal = 1 }),
            f:row({
                f:static_text({ title = "Share with user:" }),
                f:popup_menu({
                    items = bind("immichShareUsers"),
                    value = bind("selectedShareUser"),
                    width = share("field_width"),
                }),
                f:popup_menu({
                    items = {
                        { title = "Viewer", value = "viewer" },
                        { title = "Editor", value = "editor" },
                    },
                    value = bind("shareRole"),
                }),
                f:push_button({
                    title = "Share",
                    action = function()
                        LrTasks.startAsyncTask(function()
                            if Util.nilOrEmpty(ctx.selectedShareUser) or ctx.selectedShareUser == 0 then
                                LrDialogs.message("Select a user to share with.", nil, "warning")
                                return
                            end
                            local immich = ImmichAPI:new(publishSettings.url, publishSettings.apiKey)
                            if immich:addUserToAlbum(albumId, ctx.selectedShareUser, ctx.shareRole) then
                                LrDialogs.message(
                                    "Album shared",
                                    "Shared with the selected user as " .. tostring(ctx.shareRole) .. ".",
                                    "info"
                                )
                            else
                                ErrorHandler.handleError(
                                    "Could not share album with user. Check logs.",
                                    "viewForSharingSettings: addUserToAlbum failed"
                                )
                            end
                        end)
                    end,
                }),
            }),
        }),
    })
end

function PublishTask.viewForCollectionSettings(f, publishSettings, info)
    if info.publishedCollection ~= nil then
        return PublishTask.viewForSharingSettings(f, publishSettings, info)
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
