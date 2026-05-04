require("ImmichAPI")

PluginInfoDialogSections = {}

function PluginInfoDialogSections.startDialog(propertyTable)
    if prefs.logging == nil then
        prefs.logging = false
    end
    propertyTable.logging = prefs.logging
end

function PluginInfoDialogSections.sectionsForBottomOfDialog(f, propertyTable)
    local bind = LrView.bind

    return {

        {
            bind_to_object = propertyTable,

            title = "Immich Plugin Logging",
            f:row({
                f:static_text({
                    title = util.getLogfilePath(),
                }),
            }),
            f:row({
                spacing = f:control_spacing(),
                f:checkbox({
                    title = "Enable debug logging",
                    value = bind("logging"),
                }),
                f:push_button({
                    title = "Show logfile",
                    action = function(button)
                        LrShell.revealInShell(util.getLogfilePath())
                    end,
                }),
            }),
        },
        {
            bind_to_object = propertyTable,

            title = "Immich Plugin Dialogs",
            f:row({
                spacing = f:control_spacing(),
                f:push_button({
                    title = "Reset delete behavior prompt",
                    action = function()
                        LrDialogs.resetDoNotShowFlag("immichDeletePhotosTrashBehavior")
                        LrDialogs.message("The delete behavior prompt will be shown again on the next publish.")
                    end,
                }),
            }),
        },
    }
end

function PluginInfoDialogSections.endDialog(propertyTable)
    prefs.logging = propertyTable.logging
    if propertyTable.logging then
        log:enable("logfile")
    else
        log:disable()
    end
end
