MetadataTask = {}

local pluginId = 'lrc-immich-plugin'
local keyAssetId = 'immichAssetId'

-- Get plugin reference for metadata operations
-- In Lightroom SDK, we use the pluginId string directly for metadata operations
local function getPlugin()
    return pluginId
end


function MetadataTask.setImmichAssetId(photo, assetId)
    if not photo then
        log:warn("setImmichAssetId: photo is nil")
        return false
    end
    if assetId == nil or (type(assetId) == "string" and assetId == "") then
        log:warn("setImmichAssetId: assetId is nil or empty")
        return false
    end
    
    local catalog = LrApplication.activeCatalog()
    if not catalog then
        log:warn("setImmichAssetId: cannot access catalog")
        return false
    end
    
    local success = false
    local ok, err = pcall(function()
        catalog:withPrivateWriteAccessDo(function()
            photo:setPropertyForPlugin(_PLUGIN, keyAssetId, tostring(assetId))
            success = true
        end)
    end)
    if not ok then
        log:error("setImmichAssetId: failed to write metadata: " .. tostring(err))
        return false
    end
    return success
end

function MetadataTask.getImmichAssetId(photo)
    if not photo then
        return nil
    end
    
    local assetId = photo:getPropertyForPlugin(getPlugin(), keyAssetId)
    if assetId and assetId ~= "" then
        log:trace("getImmichAssetId: Found assetId " .. assetId .. " for photo " .. tostring(photo.localIdentifier))
    end
    return assetId
end
