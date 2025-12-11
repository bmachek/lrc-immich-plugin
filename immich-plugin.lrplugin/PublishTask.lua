require "ImmichAPI"
-- require "MetadataTask"

PublishTask = {}

function PublishTask.processRenderedPhotos(functionContext, exportContext)
    local exportSession = exportContext.exportSession
    local exportParams = exportContext.propertyTable


    local immich = ImmichAPI:new(exportParams.url, exportParams.apiKey)
    if not immich:checkConnectivity() then
        util.handleError('Immich connection not working, probably due to wrong url and/or apiKey. Export stopped.',
            'Immich connection not working, probably due to wrong url and/or apiKey. Export stopped.')
        return nil
    end

    local publishedCollection = exportContext.publishedCollection
    local albumCreationStrategy = publishedCollection:getCollectionInfoSummary().collectionSettings.albumCreationStrategy
    if albumCreationStrategy == nil then
        albumCreationStrategy = 'collection' -- Default strategy for old collections.
    end
    local albumId = publishedCollection and publishedCollection:getRemoteId()
    local albumName = publishedCollection and publishedCollection:getName()
    local albumAssetIds

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


    -- Set progress title.
    local nPhotos = exportSession:countRenditions()
    local progressScope = exportContext:configureProgress {
        title = nPhotos > 1
            and "Publishing " .. nPhotos .. " photos to " .. prefs.url
            or "Publishing one photo to " .. prefs.url
    }

    -- Iterate through photo renditions.
    local failures = {}
    local atLeastSomeSuccess = false

    for _, rendition in exportContext:renditions { stopIfCanceled = true } do
        -- Wait for next photo to render.
        local success, pathOrMessage = rendition:waitForRender()

        -- Check for cancellation again after photo has been rendered.
        if progressScope:isCanceled() then break end

        if success then
            local existingId, existingDeviceId = immich:checkIfAssetExists(rendition.photo.localIdentifier,
                rendition.photo:getFormattedMetadata("fileName"), rendition.photo:getFormattedMetadata("dateCreated"))
            local id

            if existingId == nil then
                id = immich:uploadAsset(pathOrMessage, rendition.photo.localIdentifier)
            else
                id = immich:replaceAsset(existingId, pathOrMessage, existingDeviceId)
            end

            if not id then
                table.insert(failures, pathOrMessage)
            else
                atLeastSomeSuccess = true
                rendition:recordPublishedPhotoId(id)
                rendition:recordPublishedPhotoUrl(immich:getAssetUrl(id))

                if albumCreationStrategy == 'folder' then
                    local folderName = rendition.photo:getFormattedMetadata("folderName")
                    local folderBasedAlbumId = immich:createOrGetAlbumFolderBased(folderName)
                    if folderBasedAlbumId ~= nil then
                        immich:addAssetToAlbum(folderBasedAlbumId, id)
                    end
                else
                    if util.table_contains(albumAssetIds, id) == false then
                        immich:addAssetToAlbum(albumId, id)
                    end
                end
            end

            -- When done with photo, delete temp file.
            LrFileUtils.delete(pathOrMessage)
        end
    end

    -- Report failures.
    if #failures > 0 then
        local message
        if #failures == 1 then
            message = "1 file failed to upload correctly."
        else
            message = tostring(#failures) .. " files failed to upload correctly."
        end
        LrDialogs.message(message, table.concat(failures, "\n"))
    end
end

function PublishTask.addCommentToPublishedPhoto(publishSettings, remotePhotoId, commentText)
end

function PublishTask.getCommentsFromPublishedCollection(publishSettings, arrayOfPhotoInfo, commentCallback)
    local immich = ImmichAPI:new(publishSettings.url, publishSettings.apiKey)
    if not immich:checkConnectivity() then
        util.handleError('Immich connection not working, probably due to wrong url and/or apiKey. Export stopped.', 
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
                if ImmichAPI:checkIfAlbumExists(publishedCollection:getRemoteId()) then
                    log:trace("... and it exists on the server.")
                    -- Get activities for the photo in the published collection.
                    local activities = ImmichAPI:getActivities(publishedCollection:getRemoteId(),
                        photoInfo.publishedPhoto:getRemoteId())
                    if activities ~= nil  then
                        for k, activity in ipairs(activities) do
                            local comment = {}

                            local year, month, day, hour, minute = string.sub(activity.createdAt, 1, 15):match(
                            "(%d+)%-(%d+)%-(%d+)%a(%d+)%:(%d+)")

                            -- Convert from date string to EPOC to COCOA
                            comment.dateCreated = os.time { year = year, month = month, day = day, hour = hour, min = minute } - 978307200
                            comment.commentId = activity.id
                            comment.username = activity.user.email
                            comment.realname = activity.user.name

                            if activity.type == 'comment' then
                                comment.commentText = activity.comment
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

        -- Call Lightroom's callback function to register comments.
        commentCallback { publishedPhoto = photoInfo, comments = comments }
    end
end

function PublishTask.deletePhotosFromPublishedCollection(publishSettings, arrayOfPhotoIds, deletedCallback, localCollectionId)
   local immich = ImmichAPI:new(publishSettings.url, publishSettings.apiKey)
    if not immich:checkConnectivity() then
        util.handleError('Immich connection not working, probably due to wrong url and/or apiKey. Export stopped.', 
            'Immich connection not working, probably due to wrong url and/or apiKey. Export stopped.')
        return nil
    end

    local delete = LrDialogs.confirm('Delete photos', 'Should removed photos be trashed in Immich?', 'If not included in any album', 'No', 'Yes (dangerous!)')

    local catalog = LrApplication.activeCatalog()
    local publishedCollection = catalog:getPublishedCollectionByLocalIdentifier(localCollectionId)

    for i = 1, #arrayOfPhotoIds do
        if immich:removeAssetFromAlbum(publishedCollection:getRemoteId(), arrayOfPhotoIds[i]) then
            deletedCallback(arrayOfPhotoIds[i])
            local success = true
            
            if delete == 'other' then
                success = immich:deleteAsset(arrayOfPhotoIds[i])
            elseif delete == 'ok' then
                if not immich:checkIfAssetIsInAnAlbum(arrayOfPhotoIds[i]) then
                    success = immich:deleteAsset(arrayOfPhotoIds[i])
                end
            end

            if not success then
                util.handleError('Failed to delete asset ' .. arrayOfPhotoIds[i] .. ' from Immich', 'Failed to delete asset (check logs)')
            end
        end
    end
end

function PublishTask.deletePublishedCollection(publishSettings, info)
    local immich = ImmichAPI:new(publishSettings.url, publishSettings.apiKey)
    if not immich:checkConnectivity() then
        util.handleError('Immich connection not working, probably due to wrong url and/or apiKey. Export stopped.', 
            'Immich connection not working, probably due to wrong url and/or apiKey. Export stopped.')
        return nil
    end

    -- remoteId is nil, if the collection isn't yet published.
    if info.remoteId ~= nil then
        ImmichAPI:deleteAlbum(info.remoteId)
    end
end

function PublishTask.renamePublishedCollection(publishSettings, info)
    local immich = ImmichAPI:new(publishSettings.url, publishSettings.apiKey)
    if not immich:checkConnectivity() then
        util.handleError('Immich connection not working, probably due to wrong url and/or apiKey. Export stopped.', 
            'Immich connection not working, probably due to wrong url and/or apiKey. Export stopped.')
        return nil
    end

    -- remoteId is nil, if the collection isn't yet published.
    if info.remoteId ~= nil then
        ImmichAPI:renameAlbum(info.remoteId, info.name)
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
        if props.albumCreationStrategy == 'existing' and props.selectedAlbum ~= 0 then
            log:trace("User selected to bind collection to existing album with id " .. props.selectedAlbum)
            info.collectionSettings.albumCreationStrategy = 'existing'
            info.collectionSettings.remoteId = props.selectedAlbum
        elseif props.albumCreationStrategy == 'existing' and props.selectedAlbum == 0 then
            util.handleError("No album selected", "No album selected")
        elseif props.albumCreationStrategy == 'folder' then
            log:trace("Setting album creation strategy to: folder")
            info.collectionSettings.albumCreationStrategy = 'folder'
        elseif props.albumCreationStrategy == 'collection' then
            log:trace("Setting album creation strategy to: collection")
            info.collectionSettings.albumCreationStrategy = 'collection'
        else
            log:trace("Unknown album creation strategy, probably old collection. Defaulting to 'collection'")
            info.collectionSettings.albumCreationStrategy = 'collection'
        end
    end
end

function PublishTask.updateCollectionSettings(publishSettings, info)
    log:trace("updateCollectionSettings called")
    local props = info.collectionSettings
    if props.albumCreationStrategy == 'existing' and props.remoteId then
        log:trace("Binding collection to existing album with id " .. props.remoteId)
        local name = ImmichAPI:getAlbumNameById(props.remoteId)
        log:trace("Setting collection name to " .. name)
        local url = ImmichAPI:getAlbumUrl(props.remoteId)
        log:trace("Setting collection url to " .. url)
        LrApplication.activeCatalog():withWriteAccessDo("Update published collection info", function()
            info.publishedCollection:setRemoteId(props.remoteId)
            info.publishedCollection:setRemoteUrl(url)
            info.publishedCollection:setName(name)
        end)
    end
end