require("ImmichAPI")
require("MetadataTask")
require("AssetStampTask")

local ImportServiceProvider = require("ImportServiceProvider")
local showConfigurationDialog = ImportServiceProvider.showConfigurationDialog

-- Expiry options in seconds (0 = never).
local EXPIRY_ITEMS = {
    { title = "Never", value = 0 },
    { title = "1 day", value = 86400 },
    { title = "7 days", value = 604800 },
    { title = "30 days", value = 2592000 },
}

return {
    LrTasks.startAsyncTask(function()
        if Util.nilOrEmpty(prefs.apiKey) or Util.nilOrEmpty(prefs.url) then
            showConfigurationDialog()
        end

        -- If still not configured (user cancelled the config dialog), stop.
        if Util.nilOrEmpty(prefs.apiKey) or Util.nilOrEmpty(prefs.url) then
            return
        end

        -- Flush any pending import stamps first, so freshly imported photos become shareable.
        AssetStampTask.reconcile(false)

        local catalog = LrApplication.activeCatalog()
        local photos = catalog:getTargetPhotos()
        if not photos or #photos == 0 then
            LrDialogs.message("No photos selected", "Select one or more photos to share from Immich.", "info")
            return
        end

        -- Resolve stored Immich asset IDs for the selection.
        local assetIds = {}
        local skipped = 0
        for _, photo in ipairs(photos) do
            local id = MetadataTask.getAnyImmichAssetId(photo)
            if Util.nilOrEmpty(id) then
                skipped = skipped + 1
            else
                table.insert(assetIds, id)
            end
        end

        if #assetIds == 0 then
            LrDialogs.message(
                "Nothing to share",
                "None of the selected photos have been uploaded to Immich, so they cannot be shared.",
                "info"
            )
            return
        end

        LrFunctionContext.callWithContext("immichShareLink", function(context)
            local f = LrView.osFactory()
            local props = LrBinding.makePropertyTable(context)
            props.expiry = 0
            props.password = ""
            props.allowDownload = true

            local shareInfo = string.format("Creating a share link for %d asset(s).", #assetIds)
            if skipped > 0 then
                shareInfo = shareInfo .. string.format(" %d selected photo(s) not on Immich were skipped.", skipped)
            end

            local contents = f:column({
                bind_to_object = props,
                spacing = f:control_spacing(),
                margin = 15,
                f:static_text({ title = shareInfo, alignment = "left", font = "<system/small>" }),
                f:row({
                    f:static_text({ title = "Expires:", alignment = "right", width = LrView.share("share_label") }),
                    f:popup_menu({ items = EXPIRY_ITEMS, value = LrView.bind("expiry"), width = 150 }),
                }),
                f:row({
                    f:static_text({ title = "Password:", alignment = "right", width = LrView.share("share_label") }),
                    f:password_field({ value = LrView.bind("password"), width_in_chars = 20, immediate = true }),
                }),
                f:checkbox({ title = "Allow download", value = LrView.bind("allowDownload") }),
            })

            local result = LrDialogs.presentModalDialog({
                title = "Create Immich share link",
                contents = contents,
                actionVerb = "Create",
            })

            if result ~= "ok" then
                return
            end

            local expiresAt = nil
            if props.expiry and props.expiry > 0 then
                expiresAt = Util.toISO8601(LrDate.currentTime() + props.expiry)
            end

            local immich = ImmichAPI:new(prefs.url, prefs.apiKey)
            local url = immich:createSharedLink(assetIds, {
                expiresAt = expiresAt,
                password = props.password,
                allowDownload = props.allowDownload,
            })

            if Util.nilOrEmpty(url) then
                ErrorHandler.handleError(
                    "Could not create share link. Check logs.",
                    "ShareLinkDialog: createSharedLink returned nil"
                )
                return
            end

            -- Result dialog: selectable URL (LrC SDK has no clipboard-write API) + open in browser.
            LrFunctionContext.callWithContext("immichShareResult", function(resultContext)
                local rf = LrView.osFactory()
                local resultProps = LrBinding.makePropertyTable(resultContext)
                resultProps.url = url
                local resultContents = rf:column({
                    bind_to_object = resultProps,
                    spacing = rf:control_spacing(),
                    margin = 15,
                    rf:static_text({ title = "Share link created. Select the URL to copy it:", alignment = "left" }),
                    rf:edit_field({
                        value = LrView.bind("url"),
                        width_in_chars = 45,
                        immediate = false,
                    }),
                })
                local btn = LrDialogs.presentModalDialog({
                    title = "Immich share link",
                    contents = resultContents,
                    actionVerb = "Open in browser",
                    cancelVerb = "Close",
                })
                if btn == "ok" then
                    LrHttp.openUrlInBrowser(url)
                end
            end)
        end)
    end),
}
