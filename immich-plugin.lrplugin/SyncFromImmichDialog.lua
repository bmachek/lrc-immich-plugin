local ImportServiceProvider = require("ImportServiceProvider")
local showConfigurationDialog = ImportServiceProvider.showConfigurationDialog
require("SyncFromImmichTask")

return {
    LrTasks.startAsyncTask(function()
        if Util.nilOrEmpty(prefs.apiKey) or Util.nilOrEmpty(prefs.url) then
            showConfigurationDialog()
        end

        -- If still not configured (user cancelled the config dialog), stop.
        if Util.nilOrEmpty(prefs.apiKey) or Util.nilOrEmpty(prefs.url) then
            return
        end

        -- Default the field toggles on first run; remember choices across sessions.
        if prefs.syncFavorite == nil then
            prefs.syncFavorite = true
        end
        if prefs.syncRating == nil then
            prefs.syncRating = true
        end
        if prefs.syncCaption == nil then
            prefs.syncCaption = true
        end
        if prefs.syncGps == nil then
            prefs.syncGps = true
        end
        if prefs.syncPeople == nil then
            prefs.syncPeople = true
        end
        if prefs.syncOverwrite == nil then
            prefs.syncOverwrite = false
        end

        local f = LrView.osFactory()
        local contents = f:column({
            bind_to_object = prefs,
            spacing = f:control_spacing(),
            margin = 15,
            f:group_box({
                title = "Sync metadata from Immich",
                fill_horizontal = 1,
                f:column({
                    spacing = f:control_spacing(),
                    margin = 5,
                    f:static_text({
                        title = "Pull metadata from Immich onto the selected photos."
                            .. "\nOnly photos previously uploaded to Immich by this plugin can be synced.",
                        alignment = "left",
                        font = "<system/small>",
                    }),
                    f:checkbox({ title = "Favorite → flag", value = LrView.bind("syncFavorite") }),
                    f:checkbox({ title = "Rating → stars", value = LrView.bind("syncRating") }),
                    f:checkbox({ title = "Description → caption", value = LrView.bind("syncCaption") }),
                    f:checkbox({ title = "GPS → location", value = LrView.bind("syncGps") }),
                    f:checkbox({ title = "People → keywords", value = LrView.bind("syncPeople") }),
                    f:separator({ fill_horizontal = 1 }),
                    f:checkbox({
                        title = "Overwrite existing Lightroom values (otherwise only fill empty fields)",
                        value = LrView.bind("syncOverwrite"),
                    }),
                }),
            }),
        })

        local result = LrDialogs.presentModalDialog({
            title = "Sync from Immich",
            contents = contents,
            actionVerb = "Sync",
        })

        if result == "ok" then
            SyncFromImmichTask.run({
                favorite = prefs.syncFavorite,
                rating = prefs.syncRating,
                caption = prefs.syncCaption,
                gps = prefs.syncGps,
                people = prefs.syncPeople,
                overwrite = prefs.syncOverwrite,
            })
        end
    end),
}
