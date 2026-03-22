require "ImmichAPI"
require "StackManager"
require "UploadHelpers"

--============================================================================--

ExportTask = {}

--------------------------------------------------------------------------------
-- Shows the "album options" modal when albumMode is 'onexport'. Updates exportParams
-- with user choices. Returns true if user confirmed, false if canceled.
local function showAlbumOptionsDialog(immich, exportParams)
    local result = LrFunctionContext.callWithContext('albumChooser', function(context)
        local f = LrView.osFactory()
        exportParams.albumMode = 'none'
        exportParams.albums = immich:getAlbums() or {}

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

        local dialogResult = LrDialogs.presentModalDialog({
            title = "Immich album options",
            contents = dialogContent,
        })

        if dialogResult ~= 'ok' then
            LrDialogs.message('Export canceled.')
            return false
        end
        return true
    end, exportParams)

    return result == true
end

--------------------------------------------------------------------------------
-- Validates export context and creates Immich API instance (uses shared util).
local function validateAndConnect(exportContext)
    return util.validateExportContextAndConnect(exportContext, "Export")
end

--------------------------------------------------------------------------------
local function buildProgressTitle(nPhotos, originalFileMode, url)
    local modeText = ""
    if originalFileMode and originalFileMode ~= 'none' then
        if originalFileMode == 'edited' then modeText = " (with originals for edited)"
        elseif originalFileMode == 'all' then modeText = " (with originals for all)"
        elseif originalFileMode == 'original_only' then modeText = " (original only)"
        elseif originalFileMode == 'original_plus_jpeg_if_edited' then modeText = " (original + JPG if edited)"
        end
    end
    local countStr = (nPhotos > 1) and (nPhotos .. " photos") or "one photo"
    return "Exporting " .. countStr .. modeText .. " to " .. url
end

--------------------------------------------------------------------------------
-- Resolves album for export: onexport dialog, then albumId/useAlbum from mode.
-- Returns: canceled (bool), albumId, useAlbum. When user cancels onexport, canceled is true.
local function resolveAlbumForExport(immich, exportParams)
    if exportParams.albumMode == 'onexport' then
        log:trace('Showing album options dialog.')
        if not showAlbumOptionsDialog(immich, exportParams) then
            return true, nil, false  -- canceled
        end
    end

    local albumId, useAlbum = nil, false
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
    return false, albumId, useAlbum
end

--------------------------------------------------------------------------------
local function getEditedPhotosCacheIfNeeded(exportParams)
    if exportParams.originalFileMode ~= 'edited' and exportParams.originalFileMode ~= 'original_plus_jpeg_if_edited' then
        return nil
    end
    local cache = StackManager.getEditedPhotosCache()
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
    return cache
end

--------------------------------------------------------------------------------
-- Process one photo group (DNG+JPG flow). Mutates state tables; returns nothing.
local function processOnePhotoGroup(immich, lid, items, exportParams, albumId, useAlbum, editedPhotosCache,
    failures, stackWarnings, atLeastSomeSuccess, exportedPrimaryByPhoto)
    if not items or not items[1] then return end
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
        UploadHelpers.sortDngJpgItems(items)
        local assetIds = {}
        local primaryId = nil
        for _, item in ipairs(items) do
            local deviceAssetId = lid .. "_" .. util.getExtension(item.path)
            local id = StackManager.uploadOneAssetOrReplace(immich, item.path, deviceAssetId, filename, dateCreated)
            UploadHelpers.safeDeleteTempFile(item.path)
            if not id then
                table.insert(failures, item.path)
            else
                atLeastSomeSuccess[1] = true
                table.insert(assetIds, id)
                if primaryId == nil then primaryId = id end
            end
        end
        if #assetIds >= 2 and primaryId then
            if not immich:createStack(assetIds) then
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
            if exportParams.originalFileMode and exportParams.originalFileMode ~= "none" then
                local hasEdits = StackManager.hasEdits(photo, editedPhotosCache)
                local shouldStack = (exportParams.originalFileMode == "all")
                    or (exportParams.originalFileMode == "edited" and hasEdits)
                    or (exportParams.originalFileMode == "original_plus_jpeg_if_edited" and hasEdits)
                if shouldStack then
                    local _, stackError = StackManager.processPhotoWithStack(immich, items[1].rendition, primaryId, exportParams)
                    if stackError then table.insert(stackWarnings, filename .. ": " .. stackError) end
                end
            end
        end
    elseif #items == 1 and (exportParams.originalFileMode == "original_only" or exportParams.originalFileMode == "original_plus_jpeg_if_edited") then
        local deviceAssetId = lid
        local originalPath = StackManager.getOriginalFilePath(photo)
        if not originalPath then
            table.insert(failures, filename .. " (original not found)")
        else
            local existingId, existingDeviceId = immich:checkIfAssetExistsEnhanced(photo, deviceAssetId, filename, dateCreated)
            local id
            if existingId == nil then
                id = immich:uploadAsset(originalPath, deviceAssetId)
            else
                id = immich:replaceAsset(existingId, originalPath, existingDeviceId or deviceAssetId)
            end
            if not id then
                table.insert(failures, originalPath)
            else
                atLeastSomeSuccess[1] = true
                local primaryId = id
                if exportParams.originalFileMode == "original_plus_jpeg_if_edited" and StackManager.hasEdits(photo, editedPhotosCache) then
                    if string.upper(exportParams.LR_format or "") == "ORIGINAL" then
                        table.insert(stackWarnings, filename .. ": skipped rendered export — 'Original / no reformat' does not produce an edited version. Change export format to JPEG or TIFF.")
                    else
                        local deviceAssetIdEdited = tostring(deviceAssetId) .. "_edited"
                        local existingJpegId, existingJpegDeviceId = immich:checkIfAssetExists(deviceAssetIdEdited, filename, dateCreated)
                        local jpegId
                        if existingJpegId then
                            jpegId = immich:replaceAsset(existingJpegId, items[1].path, existingJpegDeviceId or deviceAssetIdEdited)
                        else
                            jpegId = immich:uploadAsset(items[1].path, deviceAssetIdEdited)
                        end
                        if jpegId then
                            primaryId = jpegId
                            if not immich:createStack({ jpegId, id }) then
                                table.insert(stackWarnings, filename .. ": Failed to create stack")
                            end
                        end
                    end
                end
                exportedPrimaryByPhoto[photo.localIdentifier] = { assetId = primaryId, photo = photo }
                if useAlbum then immich:addAssetToAlbum(albumId, primaryId)
                elseif exportParams.albumMode == "folder" then
                    local folderAlbumId = immich:createOrGetAlbumFolderBased(photo:getFormattedMetadata("folderName"))
                    if folderAlbumId then immich:addAssetToAlbum(folderAlbumId, primaryId) end
                end
            end
        end
        UploadHelpers.safeDeleteTempFile(items[1].path)
    else
        local firstPrimaryId = nil
        for i, item in ipairs(items) do
            local deviceAssetId = (#items == 1) and lid or (lid .. "_" .. tostring(i))
            local id = StackManager.uploadOneAssetOrReplace(immich, item.path, deviceAssetId, filename, dateCreated)
            UploadHelpers.safeDeleteTempFile(item.path)
            if not id then
                table.insert(failures, item.path)
            else
                atLeastSomeSuccess[1] = true
                if firstPrimaryId == nil then firstPrimaryId = id end
                if useAlbum then immich:addAssetToAlbum(albumId, id)
                elseif exportParams.albumMode == "folder" then
                    local folderAlbumId = immich:createOrGetAlbumFolderBased(photo:getFormattedMetadata("folderName"))
                    if folderAlbumId then immich:addAssetToAlbum(folderAlbumId, id) end
                end
                if #items == 1 and exportParams.originalFileMode and exportParams.originalFileMode ~= "none" and exportParams.originalFileMode ~= "original_plus_jpeg_if_edited" then
                    local hasEdits = StackManager.hasEdits(photo, editedPhotosCache)
                    local shouldStack = (exportParams.originalFileMode == "all") or (exportParams.originalFileMode == "edited" and hasEdits)
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

--------------------------------------------------------------------------------
-- DNG+JPG flow: collect, group by photo, process each group.
local function processStackDngJpgRenditions(immich, exportContext, progressScope, exportParams, albumId, useAlbum, editedPhotosCache)
    local failures, stackWarnings = {}, {}
    local atLeastSomeSuccess = { false }
    local exportedPrimaryByPhoto = {}
    local collected = UploadHelpers.collectRenditions(exportContext, progressScope)
    if not collected then return failures, stackWarnings, atLeastSomeSuccess[1], exportedPrimaryByPhoto end
    local byPhoto = UploadHelpers.groupByPhoto(collected)
    for lid, items in pairs(byPhoto) do
        if progressScope:isCanceled() then break end
        processOnePhotoGroup(immich, lid, items, exportParams, albumId, useAlbum, editedPhotosCache,
            failures, stackWarnings, atLeastSomeSuccess, exportedPrimaryByPhoto)
    end
    return failures, stackWarnings, atLeastSomeSuccess[1], exportedPrimaryByPhoto
end

--------------------------------------------------------------------------------
-- Single-rendition flow: one loop over renditions.
local function processSingleRenditionRenditions(immich, exportContext, progressScope, exportParams, albumId, useAlbum, editedPhotosCache)
    local failures, stackWarnings = {}, {}
    local atLeastSomeSuccess = false
    local exportedPrimaryByPhoto = {}
    for _, rendition in exportContext:renditions { stopIfCanceled = true } do
        local success, pathOrMessage = rendition:waitForRender()
        if progressScope:isCanceled() then break end
        if success then
            local photo = rendition.photo
            local deviceAssetId = util.getPhotoDeviceId(photo)
            local originalFileMode = exportParams.originalFileMode

            if originalFileMode == 'original_only' or originalFileMode == 'original_plus_jpeg_if_edited' then
                local originalPath = StackManager.getOriginalFilePath(photo)
                if not originalPath then
                    table.insert(failures, photo:getFormattedMetadata("fileName") .. " (original not found)")
                else
                    local existingId, existingDeviceId = immich:checkIfAssetExistsEnhanced(photo, deviceAssetId,
                        photo:getFormattedMetadata("fileName"), photo:getFormattedMetadata("dateCreated"))
                    local id = (existingId == nil) and immich:uploadAsset(originalPath, deviceAssetId)
                        or immich:replaceAsset(existingId, originalPath, existingDeviceId or deviceAssetId)
                    if not id then
                        table.insert(failures, photo:getFormattedMetadata("fileName"))
                    else
                        atLeastSomeSuccess = true
                        local primaryId = id
                        if originalFileMode == 'original_plus_jpeg_if_edited' and StackManager.hasEdits(photo, editedPhotosCache) then
                            if string.upper(exportParams.LR_format or "") == "ORIGINAL" then
                                table.insert(stackWarnings, photo:getFormattedMetadata("fileName") .. ": skipped rendered export — 'Original / no reformat' does not produce an edited version. Change export format to JPEG or TIFF.")
                            else
                                local deviceAssetIdEdited = tostring(deviceAssetId) .. "_edited"
                                local fileName, dateCreated = photo:getFormattedMetadata("fileName"), photo:getFormattedMetadata("dateCreated")
                                local existingJpegId, existingJpegDeviceId = immich:checkIfAssetExists(deviceAssetIdEdited, fileName, dateCreated)
                                local jpegId
                                if existingJpegId then
                                    jpegId = immich:replaceAsset(existingJpegId, pathOrMessage, existingJpegDeviceId or deviceAssetIdEdited)
                                else
                                    jpegId = immich:uploadAsset(pathOrMessage, deviceAssetIdEdited)
                                end
                                if jpegId then
                                    primaryId = jpegId
                                    if not immich:createStack({ jpegId, id }) then
                                        table.insert(stackWarnings, photo:getFormattedMetadata("fileName") .. ": failed to create stack")
                                    end
                                else
                                    table.insert(stackWarnings, photo:getFormattedMetadata("fileName") .. ": failed to upload JPG")
                                end
                            end
                        end
                        exportedPrimaryByPhoto[photo.localIdentifier] = { assetId = primaryId, photo = photo }
                        if useAlbum then immich:addAssetToAlbum(albumId, primaryId)
                        elseif exportParams.albumMode == 'folder' then
                            local folderAlbumId = immich:createOrGetAlbumFolderBased(photo:getFormattedMetadata("folderName"))
                            if folderAlbumId then immich:addAssetToAlbum(folderAlbumId, primaryId) end
                        end
                    end
                end
                UploadHelpers.safeDeleteTempFile(pathOrMessage)
            else
                local existingId, existingDeviceId = immich:checkIfAssetExistsEnhanced(photo, deviceAssetId,
                    photo:getFormattedMetadata("fileName"), photo:getFormattedMetadata("dateCreated"))
                local id = (existingId == nil) and immich:uploadAsset(pathOrMessage, deviceAssetId)
                    or immich:replaceAsset(existingId, pathOrMessage, existingDeviceId or deviceAssetId)
                if not id then
                    table.insert(failures, pathOrMessage)
                else
                    atLeastSomeSuccess = true
                    exportedPrimaryByPhoto[photo.localIdentifier] = { assetId = id, photo = photo }
                    if originalFileMode and originalFileMode ~= 'none' then
                        local shouldStack = (originalFileMode == 'all') or (originalFileMode == 'edited' and StackManager.hasEdits(photo, editedPhotosCache))
                        if shouldStack then
                            local _, stackError = StackManager.processPhotoWithStack(immich, rendition, id, exportParams)
                            if stackError then
                                table.insert(stackWarnings, photo:getFormattedMetadata("fileName") .. ": " .. stackError)
                            end
                        end
                    end
                    if useAlbum then immich:addAssetToAlbum(albumId, id)
                    elseif exportParams.albumMode == 'folder' then
                        local folderAlbumId = immich:createOrGetAlbumFolderBased(photo:getFormattedMetadata("folderName"))
                        if folderAlbumId then immich:addAssetToAlbum(folderAlbumId, id) end
                    end
                end
                UploadHelpers.safeDeleteTempFile(pathOrMessage)
            end
        end
    end
    return failures, stackWarnings, atLeastSomeSuccess, exportedPrimaryByPhoto
end

--------------------------------------------------------------------------------
-- Run the appropriate export path and apply LR stacks; return result tables.
local function runExport(immich, exportContext, progressScope, exportParams, albumId, useAlbum, editedPhotosCache)
    local failures, stackWarnings, atLeastSomeSuccess, exportedPrimaryByPhoto
    if exportParams.stackDngJpg then
        failures, stackWarnings, atLeastSomeSuccess, exportedPrimaryByPhoto = processStackDngJpgRenditions(
            immich, exportContext, progressScope, exportParams, albumId, useAlbum, editedPhotosCache)
    else
        failures, stackWarnings, atLeastSomeSuccess, exportedPrimaryByPhoto = processSingleRenditionRenditions(
            immich, exportContext, progressScope, exportParams, albumId, useAlbum, editedPhotosCache)
    end
    if exportParams.stackLrStacks and next(exportedPrimaryByPhoto) then
        UploadHelpers.applyLrStacksInImmich(immich, exportedPrimaryByPhoto, stackWarnings)
    end
    return failures, stackWarnings, atLeastSomeSuccess, exportedPrimaryByPhoto
end

--------------------------------------------------------------------------------
local function finalizeExport(immich, exportParams, albumId, useAlbum, atLeastSomeSuccess, failures, stackWarnings)
    -- Use explicit true check so we behave correctly whether we receive a boolean or (if ever) the DNG+JPG table reference.
    local anySuccess = atLeastSomeSuccess == true or (type(atLeastSomeSuccess) == "table" and atLeastSomeSuccess[1] == true)
    if not anySuccess and exportParams.albumMode == 'new' and albumId then
        log:trace('Deleting newly created album, as no upload succeeded, and album would remain as orphan.')
        immich:deleteAlbum(albumId)
    end
    util.reportUploadFailuresAndWarnings(failures, stackWarnings)
end

--------------------------------------------------------------------------------

function ExportTask.processRenderedPhotos(functionContext, exportContext)
    local exportSession, exportParams, immich = validateAndConnect(exportContext)
    if not exportSession or not exportParams then return nil end

    local nPhotos = exportSession:countRenditions()
    local progressScope = exportContext:configureProgress {
        title = buildProgressTitle(nPhotos, exportParams.originalFileMode, exportParams.url or "")
    }

    local canceled, albumId, useAlbum = resolveAlbumForExport(immich, exportParams)
    if canceled then return end

    local editedPhotosCache = getEditedPhotosCacheIfNeeded(exportParams)

    local failures, stackWarnings, atLeastSomeSuccess, exportedPrimaryByPhoto = runExport(
        immich, exportContext, progressScope, exportParams, albumId, useAlbum, editedPhotosCache)

    finalizeExport(immich, exportParams, albumId, useAlbum, atLeastSomeSuccess, failures, stackWarnings)
end
