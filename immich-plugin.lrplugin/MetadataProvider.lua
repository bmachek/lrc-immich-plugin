require "MetadataTask"

return {

    metadataFieldsForPhotos = {
        {
            id = "immichAssetId",
            title = 'Immich Asset ID',
            dataType = "string",
            readOnly = true,
            browsable = true,
            searchable = true,
        },

    },

    schemaVersion = 10,
    -- noAutoUpdate = true,

    -- updateFromEarlierSchemaVersion = MetadataTask.updateFromEarlierSchemaVersion
}