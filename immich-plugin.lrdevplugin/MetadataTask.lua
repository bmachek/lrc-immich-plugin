require "ImmichAPI"

MetadataTask = {}

local pluginId = 'lrc-immich-plugin'
local keyAssetId = 'immichAssetId'


-- function MetadataTask.updateFromEarlierSchemaVersion(catalog, previousSchemaVersion, progressScope)
--     catalog:assertHasPrivateWriteAccess("ImmichPlugin.updateFromEarlierSchemaVersion") 

--     if previousSchemaVersion == nil or previousSchemaVersion < 6 then
--         log:trace("MetadataTask.updateFromEarlierSchemaVersion: Updating to version 5.")
--         local photosToMigrate = catalog:findPhotosWithProperty(pluginId, keyAssetId)
--         log:trace("MetadataTask.updateFromEarlierSchemaVersion: Found " .. tostring(#photosToMigrate) .. " photos to migrate")
--         local immich = ImmichAPI:new(prefs.url, prefs.apiKey)

--         for i, photo in ipairs (photosToMigrate) do
--             log:trace("Migrating photo with local identifier: " .. tostring(photo.localIdentifier))
--             assetId, deviceAssetId = immich:checkIfAssetExists(photo.localIdentifier, photo:getFormattedMetadata( "fileName" ), photo:getFormattedMetadata( "dateCreated" ))
--             if assetId then
--                 log:trace("Asset found, trying to write Immich asset id " .. assetId ..  " to catalog.")
--                 photo:setPropertyForPlugin(_PLUGIN, keyAssetId, assetId)
--             end
--         end
--     end
-- end

-- function MetadataTask.setImmichAssetId(photo, assetId)
--     LrApplication.activeCatalog():withPrivateWriteAccessDo(function ()
--         photo:setPropertyForPlugin(_PLUGIN, keyAssetId, assetId)
--     end)
-- end


-- function MetadataTask.getImmichAssetId(photo)
--     return photo:getPropertyForPlugin(_PLUGIN, keyAssetId)
-- end