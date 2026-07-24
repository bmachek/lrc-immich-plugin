require("ImmichAPI")
require("SharedDialogSections")

PluginInfoDialogSections = {}

function PluginInfoDialogSections.startDialog(propertyTable)
    if prefs.logging == nil then
        prefs.logging = false
    end
    propertyTable.logging = prefs.logging

    -- Global Immich connection, shared by Import, Sync, Search, Share links and
    -- any Export/Publish preset that opts into the global connection.
    propertyTable.url = prefs.url or ""
    propertyTable.apiKey = prefs.apiKey or ""
    LrTasks.startAsyncTask(function()
        propertyTable.immich = ImmichAPI:new(propertyTable.url, propertyTable.apiKey)
    end)
end

function PluginInfoDialogSections.sectionsForBottomOfDialog(f, propertyTable)
    local bind = LrView.bind

    return {

        SharedDialogSections.getServerConnectionSection(f, propertyTable, {
            intro = "These credentials are the global Immich connection used by the Library/File menu"
                .. " actions — Import from Immich, Sync with Immich, Find in Lightroom (search),"
                .. " Create share link and Pull metadata.\n"
                .. "Export and Publish presets have their own connection, but each can be set to reuse"
                .. ' this global one via the "Use global server connection" checkbox in its settings.\n'
                .. "Create an API key in Immich under Account Settings → API Keys.",
        }),
        {
            bind_to_object = propertyTable,

            title = "Immich Plugin Logging",
            f:row({
                f:static_text({
                    title = Util.getLogfilePath(),
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
                        LrShell.revealInShell(Util.getLogfilePath())
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
    prefs.url = propertyTable.url
    prefs.apiKey = propertyTable.apiKey
    prefs.logging = propertyTable.logging
    if propertyTable.logging then
        log:enable("logfile")
    else
        log:disable()
    end
end
