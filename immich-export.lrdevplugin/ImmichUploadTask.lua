-- Lightroom API
local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'
local LrErrors = import 'LrErrors'
local LrDialogs = import 'LrDialogs'
require "ImmichAPI"

--============================================================================--

ImmichUploadTask = {}
local log = import 'LrLogger'( 'ImmichUploadTask' )
log:enable ( 'logfile' )

--------------------------------------------------------------------------------

function ImmichUploadTask.processRenderedPhotos(functionContext, exportContext)

    -- Make a local reference to the export parameters.
    local exportSession = exportContext.exportSession
    local exportParams = exportContext.propertyTable

    -- Set progress title.
    local nPhotos = exportSession:countRenditions()
    local progressScope = exportContext:configureProgress {
        title = nPhotos > 1
               and LOC( "$$$/ImmichUpload/Upload/Progress=Uploading ^1 photos to Immich server", nPhotos )
               or LOC "$$$/ImmichUpload/Upload/Progress/One=Uploading one photo to Immich server",
    }

    -- Album handling
    local albumId
    local useAlbum = false
    if exportParams.albumMode == 'existing' then
        log:trace('Using existing album: ' .. exportParams.album)
        albumId = exportParams.album
        useAlbum = true
    elseif exportParams.albumMode == 'new' then
        log:trace('Creating new album: ' .. exportParams.newAlbumName)
        albumId = ImmichAPI.createAlbum(exportParams.url, exportParams.apiKey, exportParams.newAlbumName)
        useAlbum = true
    elseif exportParams.albumMode == 'none' then
        log:trace('Not using any albums, just uploading assets.')
    else
        log:trace('Unknown albumMode: ' .. exportParams.albumMode .. '. Ignoring.')
    end

    -- Iterate through photo renditions.
    local failures = {}
    local atLeastSomeSuccess = false

    for _, rendition in exportContext:renditions{ stopIfCanceled = true } do
    
        -- Wait for next photo to render.
        local success, pathOrMessage = rendition:waitForRender()
        
        -- Check for cancellation again after photo has been rendered.
        if progressScope:isCanceled() then break end
        
        if success then
            local id = ImmichAPI.uploadAsset(exportParams.url, exportParams.apiKey, pathOrMessage)
            
            if not id then
                -- If we can't upload that file, log it.
                table.insert(failures, pathOrMessage)
            else 
                atLeastSomeSuccess = true
                if useAlbum then
                    log:trace('Adding asset to album')
                    ImmichAPI.addAssetToAlbum(exportParams.url, exportParams.apiKey, albumId, id)
                end
            end
                    
            -- When done with photo, delete temp file.
            LrFileUtils.delete(pathOrMessage)
                    
        end
        
    end

    -- If no upload succeeded, delete album if newly created.
    if atLeastSomeSuccess == false and exportParams.albumMode == 'new' and albumId then
        log:trace('Deleting newly created album, as no upload succeeded, and album would remain as orphan.')
        ImmichAPI.deleteAlbum(exportParams.url, exportParams.apiKey, albumId)
    end

    -- Report failures.
    if #failures > 0 then
        local message
        if #failures == 1 then
            message = LOC "$$$/ImmichUpload/Upload/Errors/OneFileFailed=1 file failed to upload correctly."
        else
            message = LOC ("$$$/ImmichUpload/Upload/Errors/SomeFileFailed=^1 files failed to upload correctly.", #failures)
        end
        LrDialogs.message(message, table.concat(failures, "\n"))
    end
    
end
