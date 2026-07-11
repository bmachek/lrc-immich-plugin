local ImportServiceProvider = require("ImportServiceProvider")
local getImmichAlbums = ImportServiceProvider.getImmichAlbums
local loadAlbumPhotos = ImportServiceProvider.loadAlbumPhotos
local getAlbumTitleById = ImportServiceProvider.getAlbumTitleById
local showConfigurationDialog = ImportServiceProvider.showConfigurationDialog

return {
    LrTasks.startAsyncTask(function()
        if prefs.apiKey == nil or prefs.url == nil then
            showConfigurationDialog()
        end

        -- Fetch albums from Immich
        local albums = getImmichAlbums()
        if not albums or #albums == 0 then
            LrDialogs.message("Error", "No albums found in Immich.", "critical")
            return
        end

        -- Default to the album chosen last time this dialog ran (matched by name so it
        -- survives across sessions), falling back to the first album in the list.
        prefs.selectedAlbum = albums[1] and albums[1].value or nil
        if prefs.lastImportAlbumName then
            for _, album in ipairs(albums) do
                if album.title == prefs.lastImportAlbumName then
                    prefs.selectedAlbum = album.value
                    break
                end
            end
        end

        -- Create the dialog UI
        local f = LrView.osFactory()
        local contents = f:column({
            bind_to_object = prefs,
            spacing = f:control_spacing(),
            margin = 15,
            f:group_box({
                title = "Select Album for Import",
                fill_horizontal = 1,
                f:column({
                    spacing = f:control_spacing(),
                    margin = 5,
                    f:static_text({
                        title = "Choose an Immich album to import photos into Lightroom."
                            .. " Only new photos will be downloaded.",
                        alignment = "left",
                        font = "<system/small>",
                    }),
                    f:row({
                        margin_top = 10,
                        f:static_text({
                            title = "Immich Album:",
                            alignment = "right",
                            width = LrView.share("label_width"),
                        }),
                        f:popup_menu({
                            items = albums,
                            value = LrView.bind("selectedAlbum"),
                            width = 250,
                        }),
                    }),
                }),
            }),
        })

        -- Show the dialog
        local result = LrDialogs.presentModalDialog({
            title = "Immich Import Album",
            contents = contents,
            actionVerb = "Import",
        })

        -- Handle dialog result
        if result == "ok" and prefs.selectedAlbum then
            local albumTitle = getAlbumTitleById(albums, prefs.selectedAlbum)
            -- Remember this album so it is pre-selected next time the dialog opens.
            prefs.lastImportAlbumName = albumTitle
            loadAlbumPhotos(prefs.selectedAlbum, albumTitle)
        end
    end),
}
