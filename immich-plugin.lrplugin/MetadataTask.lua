MetadataTask = {}

local keyAssetId = "immichAssetId"
local keyOriginalAssetId = "immichOriginalAssetId"
local keySyncTime = "immichSyncTime"

-- Set or clear a stored Immich asset ID field on a photo. Pass nil or "" to clear
-- (e.g. when the asset was deleted in Immich).
local function setField(photo, fieldKey, assetId)
    if not photo then
        log:warn("setField: photo is nil (" .. fieldKey .. ")")
        return false
    end

    local catalog = LrApplication.activeCatalog()
    if not catalog then
        log:warn("setField: cannot access catalog (" .. fieldKey .. ")")
        return false
    end

    local valueToSet = (assetId ~= nil and assetId ~= "") and tostring(assetId) or ""
    local success = false
    local ok, err = LrTasks.pcall(function()
        -- Timeout required so the call waits for catalog lock instead of failing immediately
        -- (e.g. when called from async task right after export/publish).
        catalog:withPrivateWriteAccessDo(function()
            photo:setPropertyForPlugin(_PLUGIN, fieldKey, valueToSet)
            success = true
        end, { timeout = 5 })
    end)
    if not ok then
        log:error("setField: failed to write " .. fieldKey .. ": " .. tostring(err))
        return false
    end
    return success
end

local function getField(photo, fieldKey)
    if not photo then
        return nil
    end
    local value = photo:getPropertyForPlugin(_PLUGIN, fieldKey)
    if value and value ~= "" then
        return value
    end
    return nil
end

-- Rendered/derivative export asset ID.
function MetadataTask.setImmichAssetId(photo, assetId)
    return setField(photo, keyAssetId, assetId)
end

function MetadataTask.getImmichAssetId(photo)
    local assetId = getField(photo, keyAssetId)
    if assetId then
        log:trace("getImmichAssetId: Found assetId " .. assetId .. " for photo " .. tostring(photo.localIdentifier))
    end
    return assetId
end

-- Original/RAW master asset ID.
function MetadataTask.setImmichOriginalAssetId(photo, assetId)
    return setField(photo, keyOriginalAssetId, assetId)
end

function MetadataTask.getImmichOriginalAssetId(photo)
    local assetId = getField(photo, keyOriginalAssetId)
    if assetId then
        log:trace(
            "getImmichOriginalAssetId: Found originalAssetId "
                .. assetId
                .. " for photo "
                .. tostring(photo.localIdentifier)
        )
    end
    return assetId
end

-- Best available Immich asset ID for consumers that just need "the asset this photo maps
-- to" (sync, search, share): prefer the rendered export, fall back to the original master.
-- Photos imported from Immich only have the original ID set.
function MetadataTask.getAnyImmichAssetId(photo)
    return MetadataTask.getImmichAssetId(photo) or MetadataTask.getImmichOriginalAssetId(photo)
end

-- Last successful sync time (LrDate.currentTime() as a string). Used by the Sync task's
-- re-upload delta: a photo is "edited since last sync" when lastEditTime > this value.
function MetadataTask.setImmichSyncTime(photo, time)
    return setField(photo, keySyncTime, time and tostring(time) or nil)
end

function MetadataTask.getImmichSyncTime(photo)
    return tonumber(getField(photo, keySyncTime))
end
