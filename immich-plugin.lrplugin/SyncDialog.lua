require("SyncTask")

return {
    LrTasks.startAsyncTask(function()
        if not Util.ensureConnected() then
            return
        end

        -- Defaults, remembered across sessions.
        if prefs.syncDirection == nil then
            prefs.syncDirection = "both"
        end
        if prefs.syncUploadContent == nil then
            prefs.syncUploadContent = "original"
        end
        if prefs.syncStackOriginals == nil then
            prefs.syncStackOriginals = true
        end
        if prefs.syncPushMetadata == nil then
            prefs.syncPushMetadata = true
        end
        if prefs.syncDeleteInImmich == nil then
            prefs.syncDeleteInImmich = false
        end
        if prefs.syncRejectInLr == nil then
            prefs.syncRejectInLr = false
        end
        if prefs.syncForceLrHttp == nil then
            prefs.syncForceLrHttp = false
        end

        local f = LrView.osFactory()
        local share = LrView.share
        local bind = LrView.bind

        local contents = f:column({
            bind_to_object = prefs,
            spacing = f:control_spacing(),
            margin = 15,
            fill_horizontal = 1,
            f:static_text({
                title = "Delta-sync the whole Lightroom catalog with the whole Immich library."
                    .. "\nOnly new/changed items are transferred. The first run over a large library"
                    .. "\ncan take a long time and move a lot of data.",
                alignment = "left",
                font = "<system/small>",
            }),
            f:separator({ fill_horizontal = 1 }),

            f:row({
                f:static_text({ title = "Direction:", alignment = "right", width = share("sync_label") }),
                f:popup_menu({
                    value = bind("syncDirection"),
                    items = {
                        { title = "Both (download + upload)", value = "both" },
                        { title = "Download only (Immich → Lightroom)", value = "download" },
                        { title = "Upload only (Lightroom → Immich)", value = "upload" },
                    },
                    width = 260,
                }),
            }),
            f:row({
                f:static_text({ title = "Upload:", alignment = "right", width = share("sync_label") }),
                f:popup_menu({
                    value = bind("syncUploadContent"),
                    items = {
                        { title = "Original files", value = "original" },
                        { title = "Rendered export (JPEG)", value = "export" },
                        { title = "Both (original + export)", value = "both" },
                    },
                    width = 260,
                }),
            }),
            f:row({
                f:static_text({ title = "", width = share("sync_label") }),
                f:checkbox({ title = "Stack original + export in Immich", value = bind("syncStackOriginals") }),
            }),
            f:row({
                f:static_text({ title = "", width = share("sync_label") }),
                f:checkbox({
                    title = "Push Lightroom metadata to Immich for uploaded originals",
                    value = bind("syncPushMetadata"),
                }),
            }),

            f:separator({ fill_horizontal = 1 }),
            f:row({
                f:static_text({ title = "Deletions:", alignment = "right", width = share("sync_label") }),
                f:column({
                    spacing = f:control_spacing(),
                    f:checkbox({
                        title = "Delete in Immich when a photo is removed from Lightroom",
                        value = bind("syncDeleteInImmich"),
                    }),
                    f:checkbox({
                        title = "Reject in Lightroom when its asset is deleted in Immich",
                        value = bind("syncRejectInLr"),
                    }),
                    f:static_text({
                        title = "Lightroom cannot delete catalog photos via a plugin, so the second option"
                            .. "\nsets the Reject flag instead of removing the photo.",
                        font = "<system/small>",
                    }),
                }),
            }),

            f:separator({ fill_horizontal = 1 }),
            f:row({
                f:static_text({ title = "Download:", alignment = "right", width = share("sync_label") }),
                f:checkbox({
                    title = "Force LrHttp transport (disable curl streaming)",
                    value = bind("syncForceLrHttp"),
                }),
            }),
        })

        local result = LrDialogs.presentModalDialog({
            title = "Sync with Immich",
            contents = contents,
            actionVerb = "Sync",
        })

        if result == "ok" then
            SyncTask.run({
                direction = prefs.syncDirection,
                uploadContent = prefs.syncUploadContent,
                stackOriginals = prefs.syncStackOriginals,
                pushMetadata = prefs.syncPushMetadata,
                deleteInImmich = prefs.syncDeleteInImmich,
                rejectInLr = prefs.syncRejectInLr,
                forceLrHttp = prefs.syncForceLrHttp,
            })
        end
    end),
}
