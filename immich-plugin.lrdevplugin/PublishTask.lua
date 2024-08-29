require "ImmichAPI"
-- require "MetadataTask"

PublishTask = {}

function PublishTask.processRenderedPhotos(functionContext, exportContext)
    if not ImmichAPI.immichConnected() then
        LrDialogs.showError('Immich connection not set up.')
        return nil
    end

    local exportSession = exportContext.exportSession
    local exportParams = exportContext.propertyTable
    local publishedCollection = exportContext.publishedCollection
    -- local immich = ImmichAPI:new(prefs.url, prefs.apiKey)
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
    
    for _, rendition in exportContext:renditions{ stopIfCanceled = true } do
    
        -- Wait for next photo to render.
        local success, pathOrMessage = rendition:waitForRender()
        
        -- Check for cancellation again after photo has been rendered.
        if progressScope:isCanceled() then break end
        
        if success then
            local existingId, existingDeviceId = immich:checkIfAssetExists(rendition.photo.localIdentifier, rendition.photo:getFormattedMetadata( "fileName" ), rendition.photo:getFormattedMetadata( "dateCreated" ))
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
    if not immich:checkConnectivity() then
        return nil
    end

    local activities = immich:getActivities( xxx ) -- Do know (yet), how to get to the albumId

    for i = 1, #decoded do
        local type = decoded[i].type

        if type == 'comment' then
            local user = decoded[i].user.name
            local assetId = decoded[i].assetId
            local comment = decoded[i].comment
        end
    end
end
	
function PublishTask.deletePhotosFromPublishedCollection(publishSettings, arrayOfPhotoIds, deletedCallback, localCollectionId)
    if not immich:checkConnectivity() then
        LrDialogs.showError('Immich connection not set up.')
        return nil
    end
    local catalog = LrApplication.activeCatalog()
    local publishedCollection = catalog:getPublishedCollectionByLocalIdentifier(localCollectionId)
    local publishedPhotos = publishedCollection.getPublishedPhotos()
    
    for i, photoId in ipairs( arrayOfPhotoIds ) do
        if immich:removeAssetFromAlbum(publishedCollection.getRemoteId(), photoId) then
            deletedCallback(photoId)
        end
    end
end

function PublishTask.deletePublishedCollection(publishSettings, info)
    if not immich:checkConnectivity() then
        LrDialogs.showError('Immich connection not set up.')
        return nil
    end
    ImmichAPI:deleteAlbum(info.remoteId)
end

function PublishTask.renamePublishedCollection(publishSettings, info)
    if not immich:checkConnectivity() then
        LrDialogs.showError('Immich connection not set up.')
        return nil
    end
    ImmichAPI:renameAlbum(info.remoteId, info.name)
end


function PublishTask.shouldDeletePhotosFromServiceOnDeleteFromCatalog(publishSettings, nPhotos)
    return "ignore" -- Photos deleted locally are NOT deleted on Immich
    -- This should open a dialog leaving the choice to the user.
end

function PublishTask.validatePublishedCollectionName(name)
    return true, '' -- TODO
end

function PublishTask.reparentPublishedCollection(publishSettings, info)
end
