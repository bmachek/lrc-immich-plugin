require "ImmichAPI"
require "StackManager"
require "UploadHelpers"

PublishTask = {}

--------------------------------------------------------------------------------
-- Resolve or create album for publish; record remote id/url on exportSession.
-- Returns: albumCreationStrategy, albumId, albumAssetIds.
local function resolvePublishAlbum(immich, exportContext)
    local publishedCollection = exportContext.publishedCollection
    local collectionSettings = publishedCollection:getCollectionInfoSummary().collectionSettings
    local albumCreationStrategy = collectionSettings.albumCreationStrategy or 'collection'
    local albumId = publishedCollection and publishedCollection:getRemoteId()
    local albumName = publishedCollection and publishedCollection:getName()
    local albumAssetIds = nil
    local exportSession = exportContext.exportSession

    log:trace("Album creation strategy used: " .. albumCreationStrategy)

    if albumCreationStrategy == 'collection' or albumCreationStrategy == 'existing' then
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
    if albumCreationStrategy == 'folder' then
        local folderAlbumId = immich:createOrGetAlbumFolderBased(folderName)
        if folderAlbumId then immich:addAssetToAlbum(folderAlbumId, assetId) end
    elseif albumId and (not albumAssetIds or not util.table_contains(albumAssetIds, assetId)) then
        immich:addAssetToAlbum(albumId, assetId)
    end
end

--------------------------------------------------------------------------------
-- Process one photo group in original+export publish flow. Mutates failures, stackWarnings, atLeastSomeSuccess, exportedPrimaryByPhoto.
local function processPublishOnePhotoGroup(immich, lid, items, albumCreationStrategy, albumId, albumAssetIds,
    failures, stackWarnings, atLeastSomeSuccess, exportedPrimaryByPhoto)
    if not items or not items[1] then return end
    local photo = items[1].photo
    local filename = photo:getFormattedMetadata("fileName")
    local dateCreated = photo:getFormattedMetadata("dateCreated")
    if #items >= 2 then
        UploadHelpers.sortOriginalExportItems(items)
        local assetIds = {}
        local primaryId = nil
        for i, item in ipairs(items) do
            -- After sort: items[1]=export (primary), items[2]=original.
            -- Index-based suffix guarantees distinct IDs regardless of format pairing.
            local deviceAssetId = lid .. (i == 1 and "_export" or "_orig")
            local id = StackManager.uploadOneAssetOrReplace(immich, item.path, deviceAssetId, filename, dateCreated)
            UploadHelpers.safeDeleteTempFile(item.path)
            if not id then
                table.insert(failures, item.path)
            else
                atLeastSomeSuccess[1] = true
                table.insert(assetIds, id)
                if primaryId == nil then primaryId = id end
                item.rendition:recordPublishedPhotoId(id)
                item.rendition:recordPublishedPhotoUrl(immich:getAssetUrl(id))
            end
        end
        if #assetIds >= 2 and primaryId then
            if not immich:createStack(assetIds) then
                table.insert(stackWarnings, filename .. ": Failed to create original+export stack")
            end
        end
        if primaryId then
            exportedPrimaryByPhoto[photo.localIdentifier] = { assetId = primaryId, photo = photo }
            addAssetToPublishAlbum(immich, albumCreationStrategy, albumId, albumAssetIds, primaryId,
                photo:getFormattedMetadata("folderName"))
        end
    elseif #items == 1 then
        -- One rendition arrived (the other failed to render or was not expected for this photo/mode).
        -- Use isOriginal to determine the role: original copy (_orig) vs rendered export (_export).
        local item = items[1]
        local isOrig = item.isOriginal == true
        local deviceAssetId = lid .. (isOrig and "_orig" or "_export")
        local id = StackManager.uploadOneAssetOrReplace(immich, item.path, deviceAssetId, filename, dateCreated)
        UploadHelpers.safeDeleteTempFile(item.path)
        if not id then
            table.insert(failures, item.path)
        else
            atLeastSomeSuccess[1] = true
            local primaryId = id
            item.rendition:recordPublishedPhotoId(id)
            item.rendition:recordPublishedPhotoUrl(immich:getAssetUrl(id))
            if not isOrig then
                -- Export rendition arrived; upload disk original and create stack.
                local originalPath = StackManager.getOriginalFilePath(photo)
                if originalPath then
                    local origId = StackManager.uploadOneAssetOrReplace(immich, originalPath, lid .. "_orig", filename, dateCreated)
                    if origId then
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
            exportedPrimaryByPhoto[photo.localIdentifier] = { assetId = primaryId, photo = photo }
            addAssetToPublishAlbum(immich, albumCreationStrategy, albumId, albumAssetIds, primaryId,
                photo:getFormattedMetadata("folderName"))
        end
    end
end

--------------------------------------------------------------------------------
-- Original+export flow: accumulate renditions per photo, flush each group as soon as
-- both renditions are ready. This avoids buffering all renders before any upload starts.
local function processPublishStackOriginalExportRenditions(immich, exportContext, progressScope, exportParams,
    albumCreationStrategy, albumId, albumAssetIds)
    local failures, stackWarnings = {}, {}
    local atLeastSomeSuccess = { false }
    local exportedPrimaryByPhoto = {}
    local accumulator = {}
    for _, rendition in exportContext:renditions { stopIfCanceled = true } do
        if progressScope:isCanceled() then break end
        local success, pathOrMessage = rendition:waitForRender()
        if progressScope:isCanceled() then break end
        if success then
            local lid = rendition.photo.localIdentifier
            if not accumulator[lid] then accumulator[lid] = {} end
            local srcPath = StackManager.getOriginalFilePath(rendition.photo)
            local srcExt = srcPath and util.getExtension(srcPath) or ""
            local itemExt = util.getExtension(pathOrMessage)
            table.insert(accumulator[lid], {
                path = pathOrMessage,
                photo = rendition.photo,
                rendition = rendition,
                ext = itemExt,
                isOriginal = srcExt ~= "" and itemExt == srcExt,
                insertionOrder = #accumulator[lid],  -- 0-based; used as stable sort tiebreaker
            })
            -- Both renditions for this photo are ready: upload and stack immediately.
            if #accumulator[lid] == 2 then
                processPublishOnePhotoGroup(immich, lid, accumulator[lid], albumCreationStrategy, albumId, albumAssetIds,
                    failures, stackWarnings, atLeastSomeSuccess, exportedPrimaryByPhoto)
                accumulator[lid] = nil
            end
        end
    end
    -- Flush any incomplete groups (one rendition failed to render or publish was canceled).
    for lid, items in pairs(accumulator) do
        if not progressScope:isCanceled() then
            processPublishOnePhotoGroup(immich, lid, items, albumCreationStrategy, albumId, albumAssetIds,
                failures, stackWarnings, atLeastSomeSuccess, exportedPrimaryByPhoto)
        end
    end
    return failures, stackWarnings, atLeastSomeSuccess[1], exportedPrimaryByPhoto
end

--------------------------------------------------------------------------------
local function processPublishSingleRenditionRenditions(immich, exportContext, progressScope, exportParams,
    albumCreationStrategy, albumId, albumAssetIds)
    local failures, stackWarnings = {}, {}
    local atLeastSomeSuccess = false
    local exportedPrimaryByPhoto = {}
    for _, rendition in exportContext:renditions { stopIfCanceled = true } do
        local success, pathOrMessage = rendition:waitForRender()
        if progressScope:isCanceled() then break end
        if success then
            local photo = rendition.photo
            local deviceAssetId = util.getPhotoDeviceId(photo)
            local existingId, existingDeviceId = immich:checkIfAssetExistsEnhanced(photo, deviceAssetId,
                photo:getFormattedMetadata("fileName"), photo:getFormattedMetadata("dateCreated"))
            local id
            if existingId == nil then
                id = immich:uploadAsset(pathOrMessage, deviceAssetId)
            else
                id = immich:replaceAsset(existingId, pathOrMessage, existingDeviceId or deviceAssetId)
            end

            if not id then
                table.insert(failures, pathOrMessage)
            else
                atLeastSomeSuccess = true
                rendition:recordPublishedPhotoId(id)
                rendition:recordPublishedPhotoUrl(immich:getAssetUrl(id))
                exportedPrimaryByPhoto[photo.localIdentifier] = { assetId = id, photo = photo }
                if albumCreationStrategy == 'folder' then
                    local folderName = rendition.photo:getFormattedMetadata("folderName")
                    local folderBasedAlbumId = immich:createOrGetAlbumFolderBased(folderName)
                    if folderBasedAlbumId then immich:addAssetToAlbum(folderBasedAlbumId, id) end
                else
                    if albumId and (not albumAssetIds or not util.table_contains(albumAssetIds, id)) then
                        immich:addAssetToAlbum(albumId, id)
                    end
                end
            end
            UploadHelpers.safeDeleteTempFile(pathOrMessage)
        end
    end
    return failures, stackWarnings, atLeastSomeSuccess, exportedPrimaryByPhoto
end

--------------------------------------------------------------------------------
local function runPublishExport(immich, exportContext, progressScope, exportParams,
    albumCreationStrategy, albumId, albumAssetIds)
    local failures, stackWarnings, atLeastSomeSuccess, exportedPrimaryByPhoto
    if exportParams.stackOriginalExport then
        failures, stackWarnings, atLeastSomeSuccess, exportedPrimaryByPhoto = processPublishStackOriginalExportRenditions(
            immich, exportContext, progressScope, exportParams, albumCreationStrategy, albumId, albumAssetIds)
    else
        failures, stackWarnings, atLeastSomeSuccess, exportedPrimaryByPhoto = processPublishSingleRenditionRenditions(
            immich, exportContext, progressScope, exportParams, albumCreationStrategy, albumId, albumAssetIds)
    end
    if exportParams.stackLrStacks and next(exportedPrimaryByPhoto) then
        UploadHelpers.applyLrStacksInImmich(immich, exportedPrimaryByPhoto, stackWarnings)
    end
    return failures, stackWarnings, atLeastSomeSuccess, exportedPrimaryByPhoto
end

--------------------------------------------------------------------------------

function PublishTask.processRenderedPhotos(functionContext, exportContext)
    local exportSession, exportParams, immich = util.validateExportContextAndConnect(exportContext, "Publish")
    if not exportSession then return nil end

    local albumCreationStrategy, albumId, albumAssetIds = resolvePublishAlbum(immich, exportContext)

    local nPhotos = exportSession:countRenditions()
    local progressTitle = (prefs and prefs.url and prefs.url ~= "") and prefs.url or "Immich"
    local progressScope = exportContext:configureProgress {
        title = util.buildSimpleUploadProgressTitle(nPhotos, "Publishing", progressTitle)
    }

    local failures, stackWarnings, atLeastSomeSuccess, exportedPrimaryByPhoto = runPublishExport(
        immich, exportContext, progressScope, exportParams, albumCreationStrategy, albumId, albumAssetIds)

    util.reportUploadFailuresAndWarnings(failures, stackWarnings)
end

function PublishTask.addCommentToPublishedPhoto(publishSettings, remotePhotoId, commentText)
end

function PublishTask.getCommentsFromPublishedCollection(publishSettings, arrayOfPhotoInfo, commentCallback)
    local immich = ImmichAPI:new(publishSettings.url, publishSettings.apiKey)
    if not immich:checkConnectivity() then
        ErrorHandler.handleError('Immich connection not working. Check URL and API key in plugin settings.',
            'Immich connection not working, probably due to wrong url and/or apiKey. Export stopped.')
        return nil
    end

    for i, photoInfo in ipairs(arrayOfPhotoInfo) do
        -- Get all published Collections where the photo is included.
        local publishedCollections = photoInfo.photo:getContainedPublishedCollections()

        local comments = {}
        for j, publishedCollection in ipairs(publishedCollections) do
            -- Check if the published collection is an Immich collection and still exists on the server.
            if string.sub(publishedCollection:getService():getPluginId(), 1, -3) == _PLUGIN.id then
                log:trace('publishedCollection : ' .. publishedCollection:getName() .. " is an Immich collection.")
                if immich:checkIfAlbumExists(publishedCollection:getRemoteId()) then
                    log:trace("... and it exists on the server.")
                    -- Get activities for the photo in the published collection.
                    local activities = immich:getActivities(publishedCollection:getRemoteId(),
                        photoInfo.publishedPhoto:getRemoteId())
                    if activities and type(activities) == "table" then
                        for k, activity in ipairs(activities) do
                            if activity and activity.createdAt then
                                local comment = {}

                                local year, month, day, hour, minute = string.sub(activity.createdAt, 1, 15):match(
                                "(%d+)%-(%d+)%-(%d+)%a(%d+)%:(%d+)")

                                if year and month and day and hour and minute then
                                    -- Convert from date string to EPOC to COCOA
                                    comment.dateCreated = os.time { year = year, month = month, day = day, hour = hour, min = minute } - 978307200
                                end
                                comment.commentId = activity.id
                                comment.username = (activity.user and activity.user.email) or ""
                                comment.realname = (activity.user and activity.user.name) or ""

                                if activity.type == 'comment' then
                                    comment.commentText = activity.comment or ''
                                    table.insert(comments, comment)
                                elseif activity.type == 'like' then
                                    comment.commentText = 'Like'
                                    table.insert(comments, comment)
                                end
                            end
                         end
                    end
                end
            end
        end

        -- Call Lightroom's callback function to register comments.
        commentCallback { publishedPhoto = photoInfo, comments = comments }
    end
end

function PublishTask.deletePhotosFromPublishedCollection(publishSettings, arrayOfPhotoIds, deletedCallback, localCollectionId)
    if util.nilOrEmpty(publishSettings.url) or util.nilOrEmpty(publishSettings.apiKey) then
        ErrorHandler.handleError('Configure Immich in plugin settings.', 'deletePhotosFromPublishedCollection: URL or API key not set')
        return nil
    end
    local immich = ImmichAPI:new(publishSettings.url, publishSettings.apiKey)
    if not immich:checkConnectivity() then
        ErrorHandler.handleError('Immich connection not working. Check URL and API key in plugin settings.',
            'Immich connection not working, probably due to wrong url and/or apiKey. Export stopped.')
        return nil
    end

    local delete = LrDialogs.promptForActionWithDoNotShow({
        actionPrefKey = 'immichDeletePhotosTrashBehavior',
        message = 'Delete photos',
        info = 'Should removed photos be trashed in Immich?',
        verbBtns = {
            { verb = 'no', label = 'No' },
            { verb = 'only_if_not_in_album', label = 'If not included in any album' },
            { verb = 'always', label = 'Yes (dangerous!)' },
        },
    })
    if delete == nil then
        return nil
    end

    local catalog = LrApplication.activeCatalog()
    if not catalog then
        ErrorHandler.handleError('Lightroom catalog not available.', 'deletePhotosFromPublishedCollection: cannot access catalog')
        return nil
    end
    local publishedCollection = catalog:getPublishedCollectionByLocalIdentifier(localCollectionId)
    if not publishedCollection then
        ErrorHandler.handleError('Collection not found.', 'deletePhotosFromPublishedCollection: published collection not found')
        return nil
    end
    local publishedPhotos = publishedCollection:getPublishedPhotos()

    local notExistingAlbums = {}

    for _, publishedPhoto in ipairs(publishedPhotos) do
        if util.table_contains(arrayOfPhotoIds, publishedPhoto:getRemoteId()) then
            local photoRemoteId = publishedPhoto:getRemoteId()
            log:trace("Photo " .. photoRemoteId .. " is in the list to be deleted.")

            local folderName = publishedPhoto:getPhoto():getFormattedMetadata("folderName")
            log:trace("Photo is in folder: " .. folderName)

            local albumId = nil
            local albumCreationStrategy = publishedCollection:getCollectionInfoSummary().collectionSettings.albumCreationStrategy
            if albumCreationStrategy == nil then
                albumCreationStrategy = 'collection' -- Default strategy for old collections.
            end

            if albumCreationStrategy == 'folder' then
                local albums = immich:getAlbumsByNameFolderBased(folderName)
                log:trace("Album found for folder based strategy: " .. util.dumpTable(albums))
                if albums ~= nil and #albums == 1 then
                    albumId = albums[1].value
                elseif not util.table_contains(notExistingAlbums, folderName or "(unknown folder)") then
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
            if delete == 'always' then
                deletionSuccess = immich:deleteAsset(photoRemoteId)
            elseif delete == 'only_if_not_in_album' then
                if not immich:checkIfAssetIsInAnAlbum(photoRemoteId) then
                    deletionSuccess = immich:deleteAsset(photoRemoteId)
                end
            end
            -- delete == 'no': only remove from album, do not trash
            if not deletionSuccess then
                ErrorHandler.handleError('Failed to delete asset (check logs)', 'Failed to delete asset ' .. photoRemoteId .. ' from Immich')
            end

            if removeFromAlbumSuccess and deletionSuccess then
                log:trace("Successfully removed photo " .. photoRemoteId .. " from album " .. tostring(albumId))
                deletedCallback(photoRemoteId)
            end
        end
    end



    if #notExistingAlbums > 0 then
        LrDialogs.message('Some albums not found', 'The following albums were not found on the Immich server, but the photos were removed from the collection: \n' ..
            table.concat(notExistingAlbums, "\n"), 'info')
    end
end

function PublishTask.deletePublishedCollection(publishSettings, info)
    local immich = ImmichAPI:new(publishSettings.url, publishSettings.apiKey)
    if not immich:checkConnectivity() then
        ErrorHandler.handleError('Immich connection not working. Check URL and API key in plugin settings.',
            'Immich connection not working, probably due to wrong url and/or apiKey. Export stopped.')
        return nil
    end

    -- remoteId is nil, if the collection isn't yet published.
    if info.remoteId ~= nil and info.remoteId ~= '' then
        if not immich:checkIfAlbumExists(info.remoteId) then
            log:trace('deletePublishedCollection: album does not exist on server, skip delete: ' .. tostring(info.remoteId))
        else
            local ok = immich:deleteAlbum(info.remoteId)
            if not ok then
                ErrorHandler.handleError('Could not delete album on Immich. Check logs.',
                    'deletePublishedCollection: failed to delete album ' .. tostring(info.remoteId))
            end
        end
    end
end

function PublishTask.renamePublishedCollection(publishSettings, info)
    local immich = ImmichAPI:new(publishSettings.url, publishSettings.apiKey)
    if not immich:checkConnectivity() then
        ErrorHandler.handleError('Immich connection not working. Check URL and API key in plugin settings.',
            'Immich connection not working, probably due to wrong url and/or apiKey. Export stopped.')
        return nil
    end

    -- remoteId is nil, if the collection isn't yet published.
    if info.remoteId ~= nil and info.remoteId ~= '' and info.name and info.name ~= '' then
        local ok = immich:renameAlbum(info.remoteId, info.name)
        if not ok then
            ErrorHandler.handleError('Could not rename album on Immich. Check logs.',
                'renamePublishedCollection: failed to rename album ' .. tostring(info.remoteId))
        end
    end
end

function PublishTask.shouldDeletePhotosFromServiceOnDeleteFromCatalog(publishSettings, nPhotos)
    return nil -- Show builtin Lightroom dialog.
end

function PublishTask.validatePublishedCollectionName(name)
    return true, '' -- TODO
end

function PublishTask.getCollectionBehaviorInfo(publishSettings)
    return {
        defaultCollectionName = 'default',
        defaultCollectionCanBeDeleted = true,
        canAddCollection = true,
        -- Allow unlimited depth of collection sets, as requested by user.
        -- maxCollectionSetDepth = 0,
    }
end


function PublishTask.viewForCollectionSettings(f, publishSettings, info)
    if info.publishedCollection ~= nil then
        return f:row {} -- No settings for existing published collections.
    end

    info.pluginContext.albumCreationStrategy = 'collection'
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

    local result = f:group_box {
        bind_to_object = info.pluginContext,
        title = "Immich Album Settings",
        fill_horizontal = 1,
        f:column {
            spacing = share 'inter_control_spacing',
            f:radio_button {
                title = "Create new album from collection name",
                checked_value = 'collection',
                value = bind 'albumCreationStrategy',
            },
            f:radio_button {
                title = "Create albums based on folder names",
                checked_value = 'folder',
                value = bind 'albumCreationStrategy',
            },
            f:row {
                f:radio_button {
                    title = "Use existing album",
                    checked_value = 'existing',
                    value = bind 'albumCreationStrategy',
                },
                f:popup_menu {
                    items = bind 'immichAlbums',
                    value = bind 'selectedAlbum', -- Preselect "Please select"
                    width = share "field_width",
                    enabled = bind('albumCreationStrategy', { 'existing' }),
                },
            },
        }
    }

    return result
end

function PublishTask.endDialogForCollectionSettings(publishSettings, info)
    log:trace("endDialogForCollectionSettings called")
    local props = info.pluginContext
    if info.why == "ok" then
        if props.albumCreationStrategy ~= nil then
            if props.albumCreationStrategy == 'existing' and props.selectedAlbum ~= 0 then
                log:trace("User selected to bind collection to existing album with id " .. props.selectedAlbum)
                info.collectionSettings.albumCreationStrategy = 'existing'
                info.collectionSettings.remoteId = props.selectedAlbum
            elseif props.albumCreationStrategy == 'existing' and props.selectedAlbum == 0 then
                ErrorHandler.handleError("No album selected", "No album selected")
            else
                log:trace("Setting album creation strategy to: " .. props.albumCreationStrategy)
                info.collectionSettings.albumCreationStrategy = props.albumCreationStrategy
            end
        elseif info.collectionSettings.albumCreationStrategy == nil then
            log:trace("No album creation strategy set, defaulting to 'collection'")
            info.collectionSettings.albumCreationStrategy = 'collection' -- Default strategy for old collections.
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
    if props.albumCreationStrategy == 'existing' and props.remoteId then
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