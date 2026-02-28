require "ImmichAPI"
require "MetadataTask"
require "StackManager"

--============================================================================--

-- File extension to type for DNG+JPG stacking: 'raw', 'jpeg', or 'other'
local RAW_EXT = { dng = true, nef = true, nefw = true, nrw = true, arw = true, cr2 = true, cr3 = true, crw = true, orf = true, raf = true, rw2 = true, pef = true, srw = true, erf = true, dcr = true, raw = true, ['3fr'] = true, x3f = true, mrw = true, rwl = true }
local function getExtension(path)
    if not path or type(path) ~= "string" then return "" end
    return string.lower(string.match(path, "%.([^%.]+)$") or "")
end
local function getFileType(path)
    local ext = getExtension(path)
    if ext == "jpg" or ext == "jpeg" then return "jpeg" end
    if RAW_EXT[ext] then return "raw" end
    return "other"
end

ExportTask = {}

--------------------------------------------------------------------------------

function ExportTask.processRenderedPhotos(functionContext, exportContext)
    if not exportContext or not exportContext.exportSession or not exportContext.propertyTable then
        util.handleError('ExportTask: invalid export context', 'Export context is missing. Please try again.')
        return nil
    end
    local exportSession = exportContext.exportSession
    local exportParams = exportContext.propertyTable

    if util.nilOrEmpty(exportParams.url) or util.nilOrEmpty(exportParams.apiKey) then
        util.handleError('ExportTask: URL or API key not set', 'Configure Immich URL and API key in the export settings.')
        return nil
    end
    local immich = ImmichAPI:new(exportParams.url, exportParams.apiKey)
    if not immich:checkConnectivity() then
        util.handleError('Immich connection not working, probably due to wrong url and/or apiKey. Export stopped.',
            'Immich connection not working. Check URL and API key in export settings.')
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
        elseif exportParams.originalFileMode == 'original_only' then
            modeText = " (original only)"
        elseif exportParams.originalFileMode == 'original_plus_jpeg_if_edited' then
            modeText = " (original + JPG if edited)"
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
        local newName = exportParams.newAlbumName
        if util.nilOrEmpty(newName) then
            log:warn('ExportTask: new album name empty, skipping album')
        else
            log:trace('Creating new album: ' .. newName)
            albumId = immich:createAlbum(newName)
            if not albumId then
                log:error('ExportTask: failed to create album "' .. newName .. '", uploading without album')
                albumId = nil
            end
            useAlbum = (albumId ~= nil)
        end
    elseif exportParams.albumMode == 'none' then
        log:trace('Not using any albums, just uploading assets.')
    elseif exportParams.albumMode == 'folder' then
        log:trace('Create/use folder name as album.')
    else
        log:trace('Unknown albumMode: ' .. exportParams.albumMode .. '. Ignoring.')
    end

    -- For the Original Photos Stack feature : get the edited photos cache.
    local editedPhotosCache
    if exportParams.originalFileMode == 'edited' or exportParams.originalFileMode == 'original_plus_jpeg_if_edited' then
        editedPhotosCache = StackManager.getEditedPhotosCache()
    end

    -- For the Original Photos Stack feature : analyze edited photos if not cached.
    if exportParams.originalFileMode == 'edited' or exportParams.originalFileMode == 'original_plus_jpeg_if_edited' then
        local catalog = LrApplication.activeCatalog()
        if catalog then
            local selectedPhotos = catalog:getTargetPhotos()
            if selectedPhotos and #selectedPhotos > 0 then
                log:info('Pre-processing edit detection for ' .. #selectedPhotos .. ' selected photos')
                local analysis = StackManager.analyzeSelectedPhotos()
                log:info('Pre-analysis complete: ' .. analysis.summary)
            end
        else
            log:warn("Cannot access catalog for pre-analysis")
        end
    end

    -- Iterate through photo renditions.
    local failures = {}
    local stackWarnings = {}
    local atLeastSomeSuccess = false
    -- For "Preserve Lightroom stacks": photo localIdentifier -> { assetId, photo } (primary asset per exported photo)
    local exportedPrimaryByPhoto = {}

    local function uploadOneAndReport(immich, path, deviceAssetId, photo, filename, dateCreated)
        local existingId, existingDeviceId = immich:checkIfAssetExists(deviceAssetId, filename, dateCreated)
        local id
        if existingId == nil then
            id = immich:uploadAsset(path, deviceAssetId)
        else
            id = immich:replaceAsset(existingId, path, existingDeviceId)
        end
        return id
    end

    if exportParams.stackDngJpg then
        -- Phase 1: collect all renditions (same photo can have DNG + JPG)
        local collected = {}
        for _, rendition in exportContext:renditions { stopIfCanceled = true } do
            local success, pathOrMessage = rendition:waitForRender()
            if progressScope:isCanceled() then break end
            if success then
                table.insert(collected, {
                    path = pathOrMessage,
                    photo = rendition.photo,
                    rendition = rendition,
                    ext = getExtension(pathOrMessage),
                    fileType = getFileType(pathOrMessage),
                })
            end
        end
        -- Phase 2: group by photo
        local byPhoto = {}
        for _, item in ipairs(collected) do
            local lid = item.photo.localIdentifier
            if not byPhoto[lid] then byPhoto[lid] = {} end
            table.insert(byPhoto[lid], item)
        end
        -- Phase 3: process each group
        for lid, items in pairs(byPhoto) do
            if progressScope:isCanceled() then break end
            local photo = items[1].photo
            local filename = photo:getFormattedMetadata("fileName")
            local dateCreated = photo:getFormattedMetadata("dateCreated")

            local hasRaw, hasJpeg = false, false
            for _, item in ipairs(items) do
                if item.fileType == "raw" then hasRaw = true end
                if item.fileType == "jpeg" then hasJpeg = true end
            end
            local shouldStackDngJpg = hasRaw and hasJpeg

            if shouldStackDngJpg and #items >= 2 then
                -- Sort: jpeg first (primary), then raw, then other
                table.sort(items, function(a, b)
                    local order = { jpeg = 1, raw = 2, other = 3 }
                    return (order[a.fileType] or 3) < (order[b.fileType] or 3)
                end)
                local assetIds = {}
                local primaryId = nil
                for i, item in ipairs(items) do
                    local deviceAssetId = lid .. "_" .. tostring(i)
                    local id = uploadOneAndReport(immich, item.path, deviceAssetId, photo, filename, dateCreated)
                    LrFileUtils.delete(item.path)
                    if not id then
                        table.insert(failures, item.path)
                    else
                        atLeastSomeSuccess = true
                        table.insert(assetIds, id)
                        if primaryId == nil then primaryId = id end
                    end
                end
                if #assetIds >= 2 and primaryId then
                    local stackId = immich:createStack(assetIds)
                    if not stackId then
                        table.insert(stackWarnings, filename .. ": Failed to create DNG+JPG stack")
                    end
                end
                if primaryId then
                    exportedPrimaryByPhoto[photo.localIdentifier] = { assetId = primaryId, photo = photo }
                    if useAlbum then immich:addAssetToAlbum(albumId, primaryId)
                    elseif exportParams.albumMode == "folder" then
                        local folderAlbumId = immich:createOrGetAlbumFolderBased(photo:getFormattedMetadata("folderName"))
                        if folderAlbumId then immich:addAssetToAlbum(folderAlbumId, primaryId) end
                    end
                    -- Original file stacking (from disk) with primary as the "edited" asset
                    if exportParams.originalFileMode and exportParams.originalFileMode ~= "none" then
                        local shouldStack = (exportParams.originalFileMode == "all") or (exportParams.originalFileMode == "edited" and StackManager.hasEdits(photo, editedPhotosCache))
                        if shouldStack then
                            local _, stackError = StackManager.processPhotoWithStack(immich, items[1].rendition, primaryId, exportParams)
                            if stackError then
                                table.insert(stackWarnings, filename .. ": " .. stackError)
                            end
                        end
                    end
                end
            else
                -- Single file or no raw+jpeg pair: upload each with stable id
                local firstPrimaryId = nil
                for i, item in ipairs(items) do
                    local deviceAssetId = (#items == 1) and lid or (lid .. "_" .. tostring(i))
                    local id = uploadOneAndReport(immich, item.path, deviceAssetId, photo, filename, dateCreated)
                    LrFileUtils.delete(item.path)
                    if not id then
                        table.insert(failures, item.path)
                    else
                        atLeastSomeSuccess = true
                        if firstPrimaryId == nil then firstPrimaryId = id end
                        if useAlbum then immich:addAssetToAlbum(albumId, id)
                        elseif exportParams.albumMode == "folder" then
                            local folderAlbumId = immich:createOrGetAlbumFolderBased(photo:getFormattedMetadata("folderName"))
                            if folderAlbumId then immich:addAssetToAlbum(folderAlbumId, id) end
                        end
                        if #items == 1 and exportParams.originalFileMode and exportParams.originalFileMode ~= "none" then
                            local shouldStack = (exportParams.originalFileMode == "all") or (exportParams.originalFileMode == "edited" and StackManager.hasEdits(photo, editedPhotosCache))
                            if shouldStack then
                                local _, stackError = StackManager.processPhotoWithStack(immich, item.rendition, id, exportParams)
                                if stackError then table.insert(stackWarnings, filename .. ": " .. stackError) end
                            end
                        end
                    end
                end
                if firstPrimaryId then
                    exportedPrimaryByPhoto[lid] = { assetId = firstPrimaryId, photo = photo }
                end
            end
        end
    else
        -- Original single-rendition flow
        for _, rendition in exportContext:renditions { stopIfCanceled = true } do
            local success, pathOrMessage = rendition:waitForRender()
            if progressScope:isCanceled() then break end

            if success then
                local photo = rendition.photo
                local deviceAssetId = util.getPhotoDeviceId(photo)
                local id
                local originalFileMode = exportParams.originalFileMode

                -- Modes that use original file as primary (Issue #91: transfer/archiving)
                if originalFileMode == 'original_only' or originalFileMode == 'original_plus_jpeg_if_edited' then
                    local originalPath = StackManager.getOriginalFilePath(photo)
                    if not originalPath then
                        table.insert(failures, photo:getFormattedMetadata("fileName") .. " (original not found)")
                    else
                        local existingId, existingDeviceId = immich:checkIfAssetExistsEnhanced(photo, deviceAssetId,
                            photo:getFormattedMetadata("fileName"), photo:getFormattedMetadata("dateCreated"))
                        if existingId == nil then
                            id = immich:uploadAsset(originalPath, deviceAssetId)
                        else
                            id = immich:replaceAsset(existingId, originalPath, existingDeviceId or deviceAssetId)
                        end

                        if not id then
                            table.insert(failures, photo:getFormattedMetadata("fileName"))
                        else
                            atLeastSomeSuccess = true

                            -- Optionally add JPG and create stack when edited (original_plus_jpeg_if_edited)
                            if originalFileMode == 'original_plus_jpeg_if_edited' and StackManager.hasEdits(photo, editedPhotosCache) then
                                local deviceAssetIdEdited = tostring(deviceAssetId) .. "_edited"
                                local fileName = photo:getFormattedMetadata("fileName")
                                local dateCreated = photo:getFormattedMetadata("dateCreated")
                                local existingJpegId, existingJpegDeviceId = immich:checkIfAssetExists(deviceAssetIdEdited, fileName, dateCreated)
                                local jpegId
                                if existingJpegId then
                                    jpegId = immich:replaceAsset(existingJpegId, pathOrMessage, existingJpegDeviceId or deviceAssetIdEdited)
                                else
                                    jpegId = immich:uploadAsset(pathOrMessage, deviceAssetIdEdited)
                                end
                                if jpegId then
                                    local stackId = immich:createStack({ id, jpegId })
                                    if not stackId then
                                        table.insert(stackWarnings, photo:getFormattedMetadata("fileName") .. ": failed to create stack")
                                    end
                                else
                                    table.insert(stackWarnings, photo:getFormattedMetadata("fileName") .. ": failed to upload JPG")
                                end
                            end

                            exportedPrimaryByPhoto[photo.localIdentifier] = { assetId = id, photo = photo }
                            MetadataTask.setImmichAssetId(photo, id)
                            if useAlbum then
                                log:trace('Adding asset to album')
                                immich:addAssetToAlbum(albumId, id)
                            elseif exportParams.albumMode == 'folder' then
                                local folderName = photo:getFormattedMetadata("folderName")
                                local folderAlbumId = immich:createOrGetAlbumFolderBased(folderName)
                                if folderAlbumId ~= nil then
                                    immich:addAssetToAlbum(folderAlbumId, id)
                                end
                            end
                        end
                    end
                    LrFileUtils.delete(pathOrMessage)
                else
                    -- Default: JPG as primary, optionally stack original (none / edited / all)
                    local existingId, existingDeviceId = immich:checkIfAssetExistsEnhanced(photo, deviceAssetId,
                        photo:getFormattedMetadata("fileName"), photo:getFormattedMetadata("dateCreated"))
                    if existingId == nil then
                        id = immich:uploadAsset(pathOrMessage, deviceAssetId)
                    else
                        id = immich:replaceAsset(existingId, pathOrMessage, existingDeviceId or deviceAssetId)
                    end

                    if not id then
                        table.insert(failures, pathOrMessage)
                    else
                        atLeastSomeSuccess = true
                        exportedPrimaryByPhoto[photo.localIdentifier] = { assetId = id, photo = photo }
                        if originalFileMode and originalFileMode ~= 'none' then
                            local shouldStack = false
                            if originalFileMode == 'all' then
                                shouldStack = true
                            elseif originalFileMode == 'edited' then
                                shouldStack = StackManager.hasEdits(photo, editedPhotosCache)
                                log:trace('Photo ' .. photo.localIdentifier .. ' has edits: ' .. tostring(shouldStack))
                            end
                            if shouldStack then
                                local finalId, stackError = StackManager.processPhotoWithStack(immich, rendition, id, exportParams)
                                if stackError then
                                    table.insert(stackWarnings, photo:getFormattedMetadata("fileName") .. ": " .. stackError)
                                    log:warn("Stack processing warning: " .. stackError)
                                end
                            end
                        end

                        MetadataTask.setImmichAssetId(photo, id)
                        if useAlbum then
                            log:trace('Adding asset to album')
                            immich:addAssetToAlbum(albumId, id)
                        elseif exportParams.albumMode == 'folder' then
                            local folderName = photo:getFormattedMetadata("folderName")
                            local folderAlbumId = immich:createOrGetAlbumFolderBased(folderName)
                            if folderAlbumId ~= nil then
                                immich:addAssetToAlbum(folderAlbumId, id)
                            end
                        end
                    end
                    LrFileUtils.delete(pathOrMessage)
                end
            end
        end
    end

    -- Preserve Lightroom stacks in Immich (LrPhoto getRawMetadata: isInStackInFolder, stackInFolderMembers, stackPositionInFolder)
    if exportParams.stackLrStacks and next(exportedPrimaryByPhoto) then
        local processedStackKeys = {}
        for lid, rec in pairs(exportedPrimaryByPhoto) do
            local photo = rec.photo
            if photo:getRawMetadata("isInStackInFolder") then
                local top = photo:getRawMetadata("topOfStackInFolderContainingPhoto")
                local stackKey = (top and top.localIdentifier) or lid
                if not processedStackKeys[stackKey] then
                    processedStackKeys[stackKey] = true
                    local members = photo:getRawMetadata("stackInFolderMembers")
                    if members and type(members) == "table" then
                        local ordered = {}
                        for _, member in ipairs(members) do
                            local ex = exportedPrimaryByPhoto[member.localIdentifier]
                            if ex then
                                local pos = member:getRawMetadata("stackPositionInFolder")
                                if type(pos) == "string" then pos = tonumber(string.match(pos, "%d+")) end
                                table.insert(ordered, { pos = pos or 999, assetId = ex.assetId })
                            end
                        end
                        table.sort(ordered, function(a, b) return (a.pos or 999) < (b.pos or 999) end)
                        if #ordered >= 2 then
                            local assetIds = {}
                            for _, e in ipairs(ordered) do table.insert(assetIds, e.assetId) end
                            local stackId = immich:createStack(assetIds)
                            if not stackId then
                                table.insert(stackWarnings, "LR stack: failed to create Immich stack")
                            else
                                log:trace("LR stack created in Immich: " .. stackId)
                            end
                        end
                    end
                end
            end
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
