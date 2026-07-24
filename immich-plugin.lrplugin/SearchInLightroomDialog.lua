require("SearchInLightroomTask")

return {
    LrTasks.startAsyncTask(function()
        if not Util.ensureConnected() then
            return
        end

        -- Remember the last query across sessions.
        if prefs.lastLrSearchQuery == nil then
            prefs.lastLrSearchQuery = ""
        end

        local f = LrView.osFactory()
        local contents = f:column({
            bind_to_object = prefs,
            spacing = f:control_spacing(),
            margin = 15,
            f:group_box({
                title = "Find in Lightroom via Immich search",
                fill_horizontal = 1,
                f:column({
                    spacing = f:control_spacing(),
                    margin = 5,
                    f:static_text({
                        title = 'Describe the photos you want to find (e.g. "sunset over water").'
                            .. "\nImmich's smart search finds matching assets and this selects the corresponding"
                            .. "\nphotos in your catalog. Only photos previously exported/published to Immich"
                            .. "\nby this plugin can be found.",
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
                            value = LrView.bind("lastLrSearchQuery"),
                            width_in_chars = 30,
                            immediate = true,
                        }),
                    }),
                }),
            }),
        })

        local result = LrDialogs.presentModalDialog({
            title = "Find in Lightroom via Immich search",
            contents = contents,
            actionVerb = "Search",
        })

        if result == "ok" then
            local query = prefs.lastLrSearchQuery
            if Util.nilOrEmpty(query) then
                LrDialogs.message("Please enter a search query.", nil, "warning")
                return
            end
            SearchInLightroomTask.run({ query = query })
        end
    end),
}
