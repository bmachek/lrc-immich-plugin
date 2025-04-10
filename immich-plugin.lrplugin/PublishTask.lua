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
    local albumId = publishedCollection:getRemoteId()
    local albumName = publishedCollection:getName()
    local albumAssetIds

    if immich:checkIfAlbumExists(albumId) then
        albumAssetIds = ImmichAPI:getAlbumAssetIds(albumId)
    else
        albumAssetIds = {}
        albumId = immich:createAlbum(albumName)
        exportSession:recordRemoteCollectionId(albumId)
        exportSession:recordRemoteCollectionUrl(immich:getAlbumUrl(albumId))
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

                if util.table_contains(albumAssetIds, id) == false then
                    immich:addAssetToAlbum(albumId, id)
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
            local activities = ImmichAPI:getActivities(publishedCollection:getRemoteId(),
                photoInfo.publishedPhoto:getRemoteId())
            if activities ~= nil  then
                for k, activity in ipairs(activities) do
                    local comment = {}

                    local year, month, day, hour, minute = string.sub(activity.createdAt, 1, 15):match(
                    "(%d+)%-(%d+)%-(%d+)%a(%d+)%:(%d+)")

                    -- Convert from date string to EPOC to COCOA
                    comment.dateCreated = os.time { year = year, month = month, day = day, hour = hour, min = minute } -
                    978307200
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

                    -- log:trace(util.dumpTable(comment))
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
