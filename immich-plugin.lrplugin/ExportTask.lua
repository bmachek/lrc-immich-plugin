require "ImmichAPI"
require "MetadataTask"

--============================================================================--

ExportTask = {}

--------------------------------------------------------------------------------

function ExportTask.processRenderedPhotos(functionContext, exportContext)
    if not immich:checkConnectivity() then
        LrDialogs.showError('Immich connection not set up.')
        return nil
    end
    -- Make a local reference to the export parameters.
    local exportSession = exportContext.exportSession
    local exportParams = exportContext.propertyTable

    -- Set progress title.
    local nPhotos = exportSession:countRenditions()
    local progressScope = exportContext:configureProgress {
        title = nPhotos > 1
               and "Exporting " .. nPhotos .. " photos to " .. prefs.url
               or "Exporting one photo to " .. prefs.url
    }

    -- local immich = ImmichAPI:new(prefs.url, prefs.apiKey)

    -- Album handling
    local albumId
    local useAlbum = false
    if exportParams.albumMode == 'onexport' then
        log:trace('Showing album options dialog.')
        local result = LrFunctionContext.callWithContext( 'albumChooser', function(context) 
            local f = LrView.osFactory()
            exportParams.albumMode = 'none'
            exportParams.albums = immich:getAlbums()

            local dialogContent = f:column {
                bind_to_object = exportParams,
                f:row {
                    spacing = f:label_spacing(),
                        f:static_text {
                            title = 'Mode: ',
                            alignment = "right",
                            width = LrView.share "label_width",
                        },
                        f:popup_menu {
                            width_in_chars = 20,
                            alignment = 'left',
                            items = { 
                                { title = 'Do not use an album', value = 'none'},
                                { title = 'Existing album', value = 'existing'},
                                { title = 'Create new album', value = 'new'},
                            },
                            value = LrView.bind('albumMode'),
                            immediate = true,
                        },
                    },
                f:row {
                    spacing = f:label_spacing(),
                        f:column {            
                            place = "overlapping",   
                            f:static_text {
                                title = 'Choose album: ',
                                alignment = "right",
                                width = LrView.share "label_width",
                                visible = LrBinding.keyEquals( "albumMode", "existing"),
                            },
                            f:static_text {
                                title = 'Album name: ',
                                alignment = "right",
                                width = LrView.share "label_width",
                                visible = LrBinding.keyEquals( "albumMode", "new"),
                            },
                        },
                        f:column {
                            place = "overlapping",
                            f:popup_menu {
                                truncation = 'middle',
                                width_in_chars = 20,
                                fill_horizontal = 1,
                                value = LrView.bind('album'),
                                items = LrView.bind('albums'),
                                visible = LrBinding.keyEquals( "albumMode", "existing"),
                                align = "left",
                                immediate = true,
                            },
                            f:edit_field {
                                truncation = 'middle',
                                width_in_chars = 20,
                                fill_horizontal = 1,
                                value = LrView.bind('newAlbumName'),
                                visible = LrBinding.keyEquals( "albumMode", "new" ),
                                align = "left",
                                immediate = true,
                            },
                        },
                    },
                }
                
            local result = LrDialogs.presentModalDialog( 
                {
                    title = "Immich album options",
                    contents = dialogContent,
                }
            )

            if not ( result == 'ok' ) then
                LrDialogs.message('Export canceled.')
                return false 
            end

        end, exportParams )

        if result == false then
            return
        end
    end


    log:trace('Album mode:' .. exportParams.albumMode)
    if exportParams.albumMode == 'existing' then
        log:trace('Using existing album: ' .. exportParams.album)
        albumId = exportParams.album
        useAlbum = true
    elseif exportParams.albumMode == 'new' then
        log:trace('Creating new album: ' .. exportParams.newAlbumName)
        albumId = immich:createAlbum(exportParams.newAlbumName)
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
            local existingId, existingDeviceId = immich:checkIfAssetExists(rendition.photo.localIdentifier, rendition.photo:getFormattedMetadata( "fileName" ), rendition.photo:getFormattedMetadata( "dateCreated" ))
            local id

            if existingId == nil then
                id = immich:uploadAsset(pathOrMessage, rendition.photo.localIdentifier)
            else
                id = immich:replaceAsset(existingId, pathOrMessage, existingDeviceId)
            end

            if not id then
                -- If we can't upload that file, log it.
                table.insert(failures, pathOrMessage)
            else 
                atLeastSomeSuccess = true
                -- MetadataTask.setImmichAssetId(rendition.photo, id)
                if useAlbum then
                    log:trace('Adding asset to album')
                    immich:addAssetToAlbum(albumId, id)
                end
            end
                    
            -- When done with photo, delete temp file.
            LrFileUtils.delete(pathOrMessage)
                    
        end
        
    end

    -- If no upload succeeded, delete album if newly created.
    if atLeastSomeSuccess == false and exportParams.albumMode == 'new' and albumId then
        log:trace('Deleting newly created album, as no upload succeeded, and album would remain as orphan.')
        immich:deleteAlbum(albumId)
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
