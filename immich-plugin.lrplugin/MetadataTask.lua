MetadataTask = {}

local keyAssetId = 'immichAssetId'


-- Set or clear stored Immich asset ID for a photo. Pass nil or "" to clear (e.g. when asset was deleted in Immich).
function MetadataTask.setImmichAssetId(photo, assetId)
    if not photo then
        log:warn("setImmichAssetId: photo is nil")
        return false
    end

    local catalog = LrApplication.activeCatalog()
    if not catalog then
        log:warn("setImmichAssetId: cannot access catalog")
        return false
    end

    local valueToSet = (assetId ~= nil and assetId ~= "") and tostring(assetId) or ""
    local success = false
    local ok, err = LrTasks.LrTasks.pcall(function()
        -- Timeout required so the call waits for catalog lock instead of failing immediately
        -- (e.g. when called from async task right after export/publish).
        catalog:withPrivateWriteAccessDo(function()
            photo:setPropertyForPlugin(_PLUGIN, keyAssetId, valueToSet)
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

    local assetId = photo:getPropertyForPlugin(_PLUGIN, keyAssetId)
    if assetId and assetId ~= "" then
        log:trace("getImmichAssetId: Found assetId " .. assetId .. " for photo " .. tostring(photo.localIdentifier))
    end
    return assetId
end
