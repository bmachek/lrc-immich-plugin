require("MetadataTask")

return {
    LrTasks.startAsyncTask(function()
        local catalog = LrApplication.activeCatalog()
        -- Capture the current Lightroom selection before displaying any dialogs.
        local photos = catalog and catalog:getTargetPhotos() or {}

        if #photos == 0 then
            LrDialogs.message("Reset Immich IDs", "Select at least one photo before running this command.", "warning")
            return
        end

        -- This command only changes Lightroom metadata. Confirm the scope before writing
        -- so a selection mistake cannot silently reset IDs for the wrong photos.
        local result = LrDialogs.confirm(
            "Reset Immich IDs?",
            "This will clear the stored Immich asset ID for "
                .. #photos
                .. " selected photo(s). It will not modify or delete anything in Immich.",
            "Reset",
            "Cancel"
        )
        if result ~= "ok" then
            return
        end

        -- The helper function resets the stored Immich asset IDs in the current catalog for all selected photos.
        local cleared, err = MetadataTask.clearImmichAssetIds(photos)
        if not cleared then
            LrDialogs.message("Reset Immich IDs failed", tostring(err), "critical")
            return
        end

        LrDialogs.message(
            "Immich IDs reset",
            "Cleared stored Immich asset IDs for " .. cleared .. " selected photo(s)."
        )
    end),
}
