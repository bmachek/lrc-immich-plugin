local ImportServiceProvider = require "ImportServiceProvider"
local getImmichAlbums = ImportServiceProvider.getImmichAlbums
local loadAlbumPhotos = ImportServiceProvider.loadAlbumPhotos
local getAlbumTitleById = ImportServiceProvider.getAlbumTitleById

return {
    LrTasks.startAsyncTask(function()
        -- Fetch albums from Immich
        local albums = getImmichAlbums()
        if not albums or #albums == 0 then
            LrDialogs.message("Error", "No albums found in Immich.", "critical")
            return
        end

        -- Set default selected album
        prefs.selectedAlbum = albums[1] and albums[1].value or nil
        
        -- Create the dialog UI
        local f = LrView.osFactory()
        local contents = f:column {
            bind_to_object = prefs,
            spacing = f:control_spacing(),
            f:row {
                f:static_text {
                    title = "Immich Album:",
                    alignment = 'right',
                    width = LrView.share 'label_width',
                },
                f:popup_menu {
                    items = albums,
                    value = LrView.bind('selectedAlbum'),
                    width = 250,
                },
            },
        }

        -- Show the dialog
        local result = LrDialogs.presentModalDialog {
            title = "Immich Import Album",
            contents = contents,
            actionVerb = "Import",
        }

    -- Handle dialog result
    if result == "ok" and prefs.selectedAlbum then
            local albumTitle = getAlbumTitleById(albums, prefs.selectedAlbum)
            loadAlbumPhotos(prefs.selectedAlbum, albumTitle)
        end
    end)
}