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
        elseif originalFileMode == 'original_plus_jpeg_if_edited' then modeText = " (original + export if edited)"
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
-- Process one photo group (original+export flow). Mutates state tables; returns nothing.
local function processOnePhotoGroup(immich, lid, items, exportParams, albumId, useAlbum, editedPhotosCache,
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
            -- Suffix is stable for the expected two-item pair; extra renditions get an index suffix.
            local suffix = (i == 1) and "_export" or (i == 2) and "_orig" or ("_rend" .. tostring(i))
            local deviceAssetId = lid .. suffix
            local id, errReason = StackManager.uploadOneAssetOrReplace(immich, item.path, deviceAssetId, filename, dateCreated)
            UploadHelpers.safeDeleteTempFile(item.path)
            if not id then
                table.insert(failures, filename .. " (" .. (errReason or "Upload failed") .. ")")
            else
                atLeastSomeSuccess[1] = true
                table.insert(assetIds, id)
                if primaryId == nil then primaryId = id end
                log:info('original+export [' .. filename .. ']: ' .. deviceAssetId .. ' -> ' .. id)
            end
        end
        if #assetIds >= 2 and primaryId then
            if not immich:createStack(assetIds) then
                table.insert(stackWarnings, filename .. ": Failed to create original+export stack")
            end
        end
        if primaryId then
            exportedPrimaryByPhoto[photo.localIdentifier] = { assetId = primaryId, photo = photo }
            if useAlbum then immich:addAssetToAlbum(albumId, primaryId)
            elseif exportParams.albumMode == "folder" then
                local folderAlbumId = immich:createOrGetAlbumFolderBased(photo:getFormattedMetadata("folderName"))
                if folderAlbumId then immich:addAssetToAlbum(folderAlbumId, primaryId) end
            end
            -- Note: processPhotoWithStack is intentionally NOT called here. Both renditions
            -- (original copy + rendered export) have already been uploaded and stacked by
            -- immich:createStack above. Calling processPhotoWithStack would re-upload the disk
            -- original under a different deviceAssetId and create a duplicate stack.
        end
    elseif #items == 1 then
        -- One rendition arrived. Since LR_exportOriginalFile is never set, Lightroom always
        -- delivers the rendered export (never an original-copy rendition), so item.role = "export".
        -- Always treat the single rendition as the export and fetch the disk original.
        local item = items[1]
        local deviceAssetId = lid .. "_export"
        log:info('original+export [' .. filename .. ']: single rendition, uploading as export (' .. deviceAssetId .. ')')
        local id, errReason = StackManager.uploadOneAssetOrReplace(immich, item.path, deviceAssetId, filename, dateCreated)
        UploadHelpers.safeDeleteTempFile(item.path)
        if not id then
            table.insert(failures, filename .. " (" .. (errReason or "Upload failed") .. ")")
        else
            atLeastSomeSuccess[1] = true
            local primaryId = id
            if string.upper(exportParams.LR_format or "") == "ORIGINAL" then
                -- LR_format == "ORIGINAL" means Lightroom copied the source byte-for-byte; the
                -- rendition IS the original. Uploading the disk original as _orig would create two
                -- identical assets. Skip original upload and warn instead.
                table.insert(stackWarnings, filename .. ": skipped original+export stack — 'Original / no reformat' produces an identical copy. Switch to any rendered format (e.g. JPEG, TIFF, PNG).")
            else
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
            if useAlbum then immich:addAssetToAlbum(albumId, primaryId)
            elseif exportParams.albumMode == "folder" then
                local folderAlbumId = immich:createOrGetAlbumFolderBased(photo:getFormattedMetadata("folderName"))
                if folderAlbumId then immich:addAssetToAlbum(folderAlbumId, primaryId) end
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Original+export flow: process each rendition immediately as it arrives, keeping
-- renders and uploads interleaved so the Lightroom progress bar advances
-- proportionally to real work done. LR_exportOriginalFile is never set, so LR
-- always delivers exactly one rendition per photo; the disk original is fetched
-- inside processOnePhotoGroup.
local function processStackOriginalExportRenditions(immich, exportContext, progressScope, nPhotos, exportParams, albumId, useAlbum, editedPhotosCache)
    local failures, stackWarnings = {}, {}
    local atLeastSomeSuccess = { false }
    local exportedPrimaryByPhoto = {}
    local done = 0
    for _, rendition in exportContext:renditions { stopIfCanceled = true } do
        if progressScope:isCanceled() then break end
        local success, pathOrMessage = rendition:waitForRender()
        if progressScope:isCanceled() then break end
        if success then
            -- Use stable device ID (UUID when available) so deviceAssetIds survive catalog re-imports.
            local lid = util.getPhotoDeviceId(rendition.photo) or rendition.photo.localIdentifier
            -- role = "export": LR_exportOriginalFile is never set, so LR always delivers the
            -- rendered export (never an original-copy rendition), regardless of file extension.
            local item = {
                path = pathOrMessage,
                photo = rendition.photo,
                rendition = rendition,
                role = "export",
            }
            processOnePhotoGroup(immich, lid, { item }, exportParams, albumId, useAlbum, editedPhotosCache,
                failures, stackWarnings, atLeastSomeSuccess, exportedPrimaryByPhoto)
        end
        -- Advance progress for every rendition, including failed renders, so the bar reaches 100%.
        done = done + 1
        progressScope:setPortionComplete(done, nPhotos)
        if done == 1 or done % 10 == 0 or done == nPhotos then
            log:info('Export progress: ' .. done .. '/' .. nPhotos
                .. ' (' .. math.floor(done * 100 / nPhotos) .. '%)')
        end
    end
    return failures, stackWarnings, atLeastSomeSuccess[1], exportedPrimaryByPhoto
end

--------------------------------------------------------------------------------
-- Single-rendition flow: one loop over renditions.
local function processSingleRenditionRenditions(immich, exportContext, progressScope, nPhotos, exportParams, albumId, useAlbum, editedPhotosCache)
    local failures, stackWarnings = {}, {}
    local atLeastSomeSuccess = false
    local exportedPrimaryByPhoto = {}
    local done = 0
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
                    log:info('single-rendition [' .. photo:getFormattedMetadata("fileName") .. ']: uploading original (' .. tostring(deviceAssetId) .. ')')
                    local id, errReason = (existingId == nil) and immich:uploadAsset(originalPath, deviceAssetId)
                        or immich:replaceAsset(existingId, originalPath, existingDeviceId or deviceAssetId)
                    if not id then
                        table.insert(failures, photo:getFormattedMetadata("fileName") .. " - " .. (errReason or "Upload failed"))
                    else
                        atLeastSomeSuccess = true
                        local primaryId = id
                        if originalFileMode == 'original_plus_jpeg_if_edited' and StackManager.hasEdits(photo, editedPhotosCache) then
                            if string.upper(exportParams.LR_format or "") == "ORIGINAL" then
                                table.insert(stackWarnings, photo:getFormattedMetadata("fileName") .. ": skipped rendered export — 'Original / no reformat' does not produce an edited version. Switch to any rendered format (e.g. JPEG, TIFF, PNG).")
                            else
                                local deviceAssetIdEdited = tostring(deviceAssetId) .. "_edited"
                                local fileName, dateCreated = photo:getFormattedMetadata("fileName"), photo:getFormattedMetadata("dateCreated")
                                log:info('single-rendition [' .. fileName .. ']: uploading edited export (' .. deviceAssetIdEdited .. ')')
                                local existingExportId, existingExportDeviceId = immich:checkIfAssetExists(deviceAssetIdEdited, fileName, dateCreated)
                                local exportId
                                if existingExportId then
                                    exportId = immich:replaceAsset(existingExportId, pathOrMessage, existingExportDeviceId or deviceAssetIdEdited)
                                else
                                    exportId = immich:uploadAsset(pathOrMessage, deviceAssetIdEdited)
                                end
                                if exportId then
                                    primaryId = exportId
                                    if not immich:createStack({ exportId, id }) then
                                        table.insert(stackWarnings, photo:getFormattedMetadata("fileName") .. ": failed to create stack")
                                    end
                                else
                                    table.insert(stackWarnings, photo:getFormattedMetadata("fileName") .. ": failed to upload rendered export")
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
                local id, errReason = (existingId == nil) and immich:uploadAsset(pathOrMessage, deviceAssetId)
                    or immich:replaceAsset(existingId, pathOrMessage, existingDeviceId or deviceAssetId)
                if not id then
                    table.insert(failures, photo:getFormattedMetadata("fileName") .. " - " .. (errReason or "Upload failed"))
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
        -- Advance progress for every rendition, including failed renders, so the bar reaches 100%.
        done = done + 1
        progressScope:setPortionComplete(done, nPhotos)
        if done == 1 or done % 10 == 0 or done == nPhotos then
            log:info('Export progress: ' .. done .. '/' .. nPhotos
                .. ' (' .. math.floor(done * 100 / nPhotos) .. '%)')
        end
    end
    return failures, stackWarnings, atLeastSomeSuccess, exportedPrimaryByPhoto
end

--------------------------------------------------------------------------------
-- Run the appropriate export path and apply LR stacks; return result tables.
local function runExport(immich, exportContext, progressScope, nPhotos, exportParams, albumId, useAlbum, editedPhotosCache)
    local failures, stackWarnings, atLeastSomeSuccess, exportedPrimaryByPhoto
    if exportParams.stackOriginalExport then
        failures, stackWarnings, atLeastSomeSuccess, exportedPrimaryByPhoto = processStackOriginalExportRenditions(
            immich, exportContext, progressScope, nPhotos, exportParams, albumId, useAlbum, editedPhotosCache)
    else
        failures, stackWarnings, atLeastSomeSuccess, exportedPrimaryByPhoto = processSingleRenditionRenditions(
            immich, exportContext, progressScope, nPhotos, exportParams, albumId, useAlbum, editedPhotosCache)
    end
    if exportParams.stackLrStacks and next(exportedPrimaryByPhoto) then
        UploadHelpers.applyLrStacksInImmich(immich, exportedPrimaryByPhoto, stackWarnings)
    end
    return failures, stackWarnings, atLeastSomeSuccess, exportedPrimaryByPhoto
end

--------------------------------------------------------------------------------
local function finalizeExport(immich, exportParams, albumId, useAlbum, atLeastSomeSuccess, failures, stackWarnings)
    -- Use explicit true check so we behave correctly whether we receive a boolean or a table reference.
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
    log:info('=== Export START: ' .. nPhotos .. ' photos | url=' .. tostring(exportParams.url)
        .. ' | originalFileMode=' .. tostring(exportParams.originalFileMode)
        .. ' | stackOriginalExport=' .. tostring(exportParams.stackOriginalExport)
        .. ' | stackLrStacks=' .. tostring(exportParams.stackLrStacks)
        .. ' | albumMode=' .. tostring(exportParams.albumMode) .. ' ===')

    -- Use LrProgressScope tied to functionContext rather than exportContext:configureProgress.
    -- configureProgress creates a scope managed by LR's render pipeline, which closes the bar
    -- when rendering completes — potentially long before all uploads are done. LrProgressScope
    -- with functionContext stays alive until processRenderedPhotos returns, and is not advanced
    -- by LR's render thread, eliminating both early-close and forward→0→return race conditions.
    local progressScope = LrProgressScope {
        title = buildProgressTitle(nPhotos, exportParams.originalFileMode, exportParams.url or ""),
        functionContext = functionContext,
    }

    local canceled, albumId, useAlbum = resolveAlbumForExport(immich, exportParams)
    if canceled then return end

    local editedPhotosCache = getEditedPhotosCacheIfNeeded(exportParams)

    local failures, stackWarnings, atLeastSomeSuccess, exportedPrimaryByPhoto = runExport(
        immich, exportContext, progressScope, nPhotos, exportParams, albumId, useAlbum, editedPhotosCache)
    progressScope:done()

    log:info('=== Export DONE: ' .. nPhotos .. ' photos | failures=' .. #failures
        .. ' | warnings=' .. #stackWarnings .. ' ===')
    finalizeExport(immich, exportParams, albumId, useAlbum, atLeastSomeSuccess, failures, stackWarnings)
end
