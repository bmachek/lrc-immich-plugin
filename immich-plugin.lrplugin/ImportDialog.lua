local ImportServiceProvider = require "ImportServiceProvider"
local getImmichAlbums = ImportServiceProvider.getImmichAlbums
local loadAlbumPhotos = ImportServiceProvider.loadAlbumPhotos

return {
    LrTasks.startAsyncTask(function()
        local albums = getImmichAlbums()
        prefs.selectedAlbum = albums[1] and albums[1].value or nil
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

        local result = LrDialogs.presentModalDialog {
            title = "Immich Import Album",
            contents = contents,
            actionVerb = "Import",
        }

        if result == "ok" then
            loadAlbumPhotos(prefs.selectedAlbum)
        end
    end)
}