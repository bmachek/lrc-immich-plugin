require "ImmichAPI"

MetadataTask = {}

local pluginId = 'lrc-immich-plugin'
local keyAssetId = 'immichAssetId'

function MetadataTask.updateFromEarlierSchemaVersion(catalog, previousSchemaVersion, progressScope)
    catalog:assertHasPrivateWriteAccess("ImmichPlugin.updateFromEarlierSchemaVersion") 

    if previousSchemaVersion == nil then
        -- nil means not yet existent in this case.
        local photosToMigrate = catalog:findPhotosWithProperty(myPlugpluginIdinId, keyAssetId)

        -- Need URL and API Key !?!?!?!?!?
        -- local immich = ImmichAPI:new(url, apiKey)

        for i, photo in ipairs (photosToMigrate) do
            -- assetId, deviceAssetId = immich:checkIfAssetExists(photo.localIdentifier, photo:getFormattedMetadata( "fileName" ), photo:getFormattedMetadata( "dateCreated" ))
        end
    end
end

function MetadataTask.setImmichAssetId(photo, assetId)
    LrApplication.activeCatalog():withPrivateWriteAccessDo(function ()
        photo:setPropertyForPlugin(_PLUGIN, keyAssetId, assetId)
    end)
end