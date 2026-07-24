require("MetadataTask")

return {

    metadataFieldsForPhotos = {
        {
            id = "immichAssetId",
            title = "Immich Asset ID",
            dataType = "string",
            readOnly = true,
            browsable = true,
            searchable = true,
        },
        {
            -- Immich asset ID of the original/RAW master for this photo (as opposed to
            -- immichAssetId, which holds the rendered/derivative export). Populated when the
            -- plugin uploads an original alongside an export, or when a photo is imported
            -- from Immich (the imported file is that photo's master).
            id = "immichOriginalAssetId",
            title = "Immich Original Asset ID",
            dataType = "string",
            readOnly = true,
            browsable = true,
            searchable = true,
        },
        {
            -- Lightroom time (LrDate.currentTime()) of the last successful sync/upload of this
            -- photo to Immich, stored as a string. Used by the Sync task to decide whether a
            -- photo has been edited since it was last synced (re-upload delta).
            id = "immichSyncTime",
            title = "Immich Last Sync Time",
            dataType = "string",
            readOnly = true,
            browsable = false,
            searchable = false,
        },
    },

    schemaVersion = 12,
    -- noAutoUpdate = true,

    -- updateFromEarlierSchemaVersion = MetadataTask.updateFromEarlierSchemaVersion
}
