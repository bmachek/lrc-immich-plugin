-- Lightroom API
local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'
local LrFunctionContext = import "LrFunctionContext"
local LrBinding = import "LrBinding"
local LrErrors = import 'LrErrors'
local LrDialogs = import 'LrDialogs'
local LrView = import 'LrView'
local prefs = import 'LrPrefs'.prefsForPlugin() 
require "ImmichAPI"

--============================================================================--

ImmichUploadTask = {}
local log = import 'LrLogger'( 'ImmichPlugin' )
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
               and "Uploading " .. nPhotos .. " photos to Immich server"
               or "Uploading one photo to Immich server"
    }

    -- Album handling
    local albumId
    local useAlbum = false
    if exportParams.albumMode == 'onexport' then
        log:trace('Showing album options dialog.')
        local result = LrFunctionContext.callWithContext( 'albumChooser', function(context) 
            local f = LrView.osFactory()
            -- local properties = LrBinding.makePropertyTable(context)
            -- properties.albumMode = ''
            -- properties.albums = {}
            -- properties.album = ''
            -- properties.newAlbumName = ''
            exportParams.albumMode = 'none'

            exportParams.albums = ImmichAPI.getAlbums(exportParams.url, exportParams.apiKey)

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
                                align = left,
                                immediate = true,
                            },
                            f:edit_field {
                                truncation = 'middle',
                                width_in_chars = 20,
                                fill_horizontal = 1,
                                value = LrView.bind('newAlbumName'),
                                visible = LrBinding.keyEquals( "albumMode", "new" ),
                                align = left,
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
