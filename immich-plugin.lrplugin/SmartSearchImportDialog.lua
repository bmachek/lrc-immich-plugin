local ImportServiceProvider = require("ImportServiceProvider")
local loadSearchPhotos = ImportServiceProvider.loadSearchPhotos
local showConfigurationDialog = ImportServiceProvider.showConfigurationDialog

return {
    LrTasks.startAsyncTask(function()
        if Util.nilOrEmpty(prefs.apiKey) or Util.nilOrEmpty(prefs.url) then
            showConfigurationDialog()
        end

        -- If still not configured (user cancelled the config dialog), stop.
        if Util.nilOrEmpty(prefs.apiKey) or Util.nilOrEmpty(prefs.url) then
            return
        end

        -- Remember the last query across sessions (same idea as lastImportAlbumName).
        if prefs.lastSearchQuery == nil then
            prefs.lastSearchQuery = ""
        end

        local f = LrView.osFactory()
        local contents = f:column({
            bind_to_object = prefs,
            spacing = f:control_spacing(),
            margin = 15,
            f:group_box({
                title = "Smart Search Import",
                fill_horizontal = 1,
                f:column({
                    spacing = f:control_spacing(),
                    margin = 5,
                    f:static_text({
                        title = 'Describe the photos you want to import (e.g. "sunset over water").'
                            .. "\nImmich's smart search finds matching photos and imports them into Lightroom.",
                        alignment = "left",
                        font = "<system/small>",
                    }),
                    f:row({
                        margin_top = 10,
                        f:static_text({
                            title = "Search:",
                            alignment = "right",
                            width = LrView.share("label_width"),
                        }),
                        f:edit_field({
                            value = LrView.bind("lastSearchQuery"),
                            width_in_chars = 30,
                            immediate = true,
                        }),
                    }),
                }),
            }),
        })

        local result = LrDialogs.presentModalDialog({
            title = "Immich Smart Search Import",
            contents = contents,
            actionVerb = "Import",
        })

        if result == "ok" then
            local query = prefs.lastSearchQuery
            if Util.nilOrEmpty(query) then
                LrDialogs.message("Please enter a search query.", nil, "warning")
                return
            end
            loadSearchPhotos(query)
        end
    end),
}
