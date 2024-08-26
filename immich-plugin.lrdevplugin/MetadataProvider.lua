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

    schemaVersion = 1,
    noAutoUpdate = true,

    updateFromEarlierSchemaVersion = MetadataTask.updateFromEarlierSchemaVersion
}