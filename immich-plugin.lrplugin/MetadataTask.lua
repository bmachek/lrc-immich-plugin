MetadataTask = {}

local keyAssetId = "immichAssetId"

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
    local ok, err = LrTasks.pcall(function()
        -- Timeout required so the call waits for catalog lock instead of failing immediately
        -- (e.g. when called from async task right after export/publish).
        catalog:withPrivateWriteAccessDo(function()
            photo:setPropertyForPlugin(_PLUGIN, keyAssetId, valueToSet)
            success = true
        end, { timeout = 5 })
    end)
    if not ok then
        log:error("setImmichAssetId: failed to write metadata: " .. tostring(err))
        return false
    end
    return success
end

-- Clear stored Immich asset IDs for a list of photos in one catalog write operation.
-- This only changes Lightroom metadata and does not modify assets on the Immich server.
function MetadataTask.clearImmichAssetIds(photos)
    -- There is nothing to write when Lightroom has no selected photos.
    if not photos or #photos == 0 then
        return 0
    end

    local catalog = LrApplication.activeCatalog()
    if not catalog then
        log:warn("clearImmichAssetIds: Cannot access catalog")
        return false, "Cannot access the Lightroom catalog."
    end

    local cleared = 0
    -- Track callback completion separately because a catalog timeout may not raise an error.
    local writeCompleted = false
    local ok, err = LrTasks.pcall(function()
        -- Use one private write transaction for the whole selection so the catalog is not
        -- locked and unlocked once per photo.
        catalog:withPrivateWriteAccessDo(function()
            for _, photo in ipairs(photos) do
                if photo then
                    -- An empty string is the plugin's representation of a cleared asset ID.
                    photo:setPropertyForPlugin(_PLUGIN, "immichAssetId", "")
                    cleared = cleared + 1
                end
            end
            writeCompleted = true
        end, { timeout = 30 })
    end)

    if not ok or not writeCompleted then
        local message = ok and "Timed out waiting for the Lightroom catalog." or tostring(err)
        log:error("clearImmichAssetIds: Failed to clear metadata: " .. message)
        return false, message
    end

    log:info("clearImmichAssetIds: Cleared IDs for " .. cleared .. " photos")
    return cleared
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
