require "ImmichAPI"
require "MetadataTask"
require "StackManager"

--============================================================================--

ExportTask = {}

--------------------------------------------------------------------------------

function ExportTask.processRenderedPhotos(functionContext, exportContext)
    -- Make a local reference to the export parameters.
    local exportSession = exportContext.exportSession
    local exportParams = exportContext.propertyTable

    local immich = ImmichAPI:new(exportParams.url, exportParams.apiKey)
    if not immich:checkConnectivity() then
        util.handleError('Immich connection not working, probably due to wrong url and/or apiKey. Export stopped.', 
            'Immich connection not working, probably due to wrong url and/or apiKey. Export stopped.')
        return nil
    end

    -- Set progress title.
    local nPhotos = exportSession:countRenditions()
    
    local progressTitle
    if exportParams.originalFileMode and exportParams.originalFileMode ~= 'none' then
        local modeText = ""
        if exportParams.originalFileMode == 'edited' then
            modeText = " (with originals for edited)"
        elseif exportParams.originalFileMode == 'all' then
            modeText = " (with originals for all)"
        end
        
        if nPhotos > 1 then
            progressTitle = "Exporting " .. nPhotos .. " photos" .. modeText .. " to " .. exportParams.url
        else
            progressTitle = "Exporting one photo" .. modeText .. " to " .. exportParams.url
        end
    else
        if nPhotos > 1 then
            progressTitle = "Exporting " .. nPhotos .. " photos to " .. exportParams.url
        else
            progressTitle = "Exporting one photo to " .. exportParams.url
        end
    end
    
    local progressScope = exportContext:configureProgress {
        title = progressTitle
    }

    -- local immich = ImmichAPI:new(prefs.url, prefs.apiKey)

    -- Album handling
    local albumId
    local useAlbum = false
    if exportParams.albumMode == 'onexport' then
        log:trace('Showing album options dialog.')
        local result = LrFunctionContext.callWithContext('albumChooser', function(context)
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
                            { title = 'Do not use an album', value = 'none' },
                            { title = 'Existing album',      value = 'existing' },
                            { title = 'Create new album',    value = 'new' },
                            { title = 'Create/use folder name as album',    value = 'folder' },
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
                            visible = LrBinding.keyEquals("albumMode", "existing"),
                        },
                        f:static_text {
                            title = 'Album name: ',
                            alignment = "right",
                            width = LrView.share "label_width",
                            visible = LrBinding.keyEquals("albumMode", "new"),
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
                            visible = LrBinding.keyEquals("albumMode", "existing"),
                            align = "left",
                            immediate = true,
                        },
                        f:edit_field {
                            truncation = 'middle',
                            width_in_chars = 20,
                            fill_horizontal = 1,
                            value = LrView.bind('newAlbumName'),
                            visible = LrBinding.keyEquals("albumMode", "new"),
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

            if not (result == 'ok') then
                LrDialogs.message('Export canceled.')
                return false
            end
        end, exportParams)

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
    elseif exportParams.albumMode == 'folder' then
        log:trace('Create/use folder name as album.')
    else
        log:trace('Unknown albumMode: ' .. exportParams.albumMode .. '. Ignoring.')
    end

    -- Iterate through photo renditions.
    local failures = {}
    local stackWarnings = {}
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
                -- If we can't upload that file, log it.
                table.insert(failures, pathOrMessage)
            else
                atLeastSomeSuccess = true
                
                -- Handle original file stacking if enabled
                if exportParams.originalFileMode and exportParams.originalFileMode ~= 'none' then
                    local shouldStack = false
                    
                    if exportParams.originalFileMode == 'all' then
                        shouldStack = true
                    elseif exportParams.originalFileMode == 'edited' then
                        shouldStack = StackManager.hasEdits(rendition.photo)
                    end
                    
                    if shouldStack then
                        local finalId, stackError = StackManager.processPhotoWithStack(immich, rendition, id, exportParams)
                        if stackError then
                            table.insert(stackWarnings, rendition.photo:getFormattedMetadata("fileName") .. ": " .. stackError)
                            log:warn("Stack processing warning: " .. stackError)
                        end
                    end
                end
                
                -- MetadataTask.setImmichAssetId(rendition.photo, id)
                if useAlbum then
                    log:trace('Adding asset to album')
                    immich:addAssetToAlbum(albumId, id)
                elseif exportParams.albumMode == 'folder' then
                    local folderName = rendition.photo:getFormattedMetadata("folderName")
                    local folderAlbumId = immich:createOrGetAlbumFolderBased(folderName)
                    if folderAlbumId ~= nil then
                        immich:addAssetToAlbum(folderAlbumId, id)
                    end
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

    -- Report failures and warnings.
    if #failures > 0 then
        local message
        if #failures == 1 then
            message = "1 file failed to upload correctly."
        else
            message = tostring(#failures) .. " files failed to upload correctly."
        end
        LrDialogs.message(message, table.concat(failures, "\n"))
    end
    
    -- Report stack warnings separately
    if #stackWarnings > 0 then
        local message
        if #stackWarnings == 1 then
            message = "1 photo had stacking issues (uploaded without stack):"
        else
            message = tostring(#stackWarnings) .. " photos had stacking issues (uploaded without stacks):"
        end
        LrDialogs.message(message, table.concat(stackWarnings, "\n"))
    end
end
