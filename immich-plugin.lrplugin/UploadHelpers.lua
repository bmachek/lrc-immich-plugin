--[[
UploadHelpers.lua - Shared upload logic for Export and Publish

Provides:
- Collecting and grouping renditions (original+export flow)
- Preserving Lightroom stacks in Immich
- Safe temporary file deletion (ensures cleanup on error or cancel)
]]

require "StackManager"

UploadHelpers = {}

--------------------------------------------------------------------------------
-- Delete a temporary file; never throws. Call after each upload so temp files
-- do not remain on early cancel or error.
function UploadHelpers.safeDeleteTempFile(path)
    if not path or type(path) ~= "string" then return end
    local ok, err = pcall(function()
        if LrFileUtils.exists(path) then
            LrFileUtils.delete(path)
        end
    end)
    if not ok and log and log.warn then
        log:warn("UploadHelpers: could not delete temp file: " .. tostring(path) .. " - " .. tostring(err))
    end
end

--------------------------------------------------------------------------------
-- Collect all renditions from exportContext into an array of
-- { path, photo, rendition, ext }. Stops if progressScope is canceled.
-- Returns collected array, or nil if canceled.
function UploadHelpers.collectRenditions(exportContext, progressScope)
    local collected = {}
    for _, rendition in exportContext:renditions { stopIfCanceled = true } do
        if progressScope and progressScope:isCanceled() then
            return nil
        end
        local success, pathOrMessage = rendition:waitForRender()
        if progressScope and progressScope:isCanceled() then
            return nil
        end
        if success then
            table.insert(collected, {
                path = pathOrMessage,
                photo = rendition.photo,
                rendition = rendition,
                ext = util.getExtension(pathOrMessage),
            })
        end
    end
    return collected
end

--------------------------------------------------------------------------------
-- Group collected items by photo localIdentifier. Returns map lid -> array of items.
function UploadHelpers.groupByPhoto(collected)
    local byPhoto = {}
    for _, item in ipairs(collected) do
        local lid = item.photo.localIdentifier
        if not byPhoto[lid] then byPhoto[lid] = {} end
        table.insert(byPhoto[lid], item)
    end
    return byPhoto
end

--------------------------------------------------------------------------------
-- Original+export sort order: rendered export first (primary in Immich), original second.
-- The original is identified by comparing its path to the source file on disk.
function UploadHelpers.sortOriginalExportItems(items)
    table.sort(items, function(a, b)
        local aIsOriginal = (a.path == StackManager.getOriginalFilePath(a.photo))
        local bIsOriginal = (b.path == StackManager.getOriginalFilePath(b.photo))
        if aIsOriginal ~= bIsOriginal then
            return not aIsOriginal  -- export (non-original) sorts first
        end
        return false  -- preserve order for items of the same kind
    end)
end

--------------------------------------------------------------------------------
-- Create Immich stacks from Lightroom stack metadata (stackInFolderMembers etc.).
-- exportedPrimaryByPhoto: map photo.localIdentifier -> { assetId, photo }.
-- Appends warnings to stackWarnings.
function UploadHelpers.applyLrStacksInImmich(immich, exportedPrimaryByPhoto, stackWarnings)
    if not next(exportedPrimaryByPhoto) then return end
    local processedStackKeys = {}
    for lid, rec in pairs(exportedPrimaryByPhoto) do
        local photo = rec.photo
        if photo:getRawMetadata("isInStackInFolder") then
            local top = photo:getRawMetadata("topOfStackInFolderContainingPhoto")
            local stackKey = (top and top.localIdentifier) or lid
            if not processedStackKeys[stackKey] then
                processedStackKeys[stackKey] = true
                local members = photo:getRawMetadata("stackInFolderMembers")
                if members and type(members) == "table" then
                    local ordered = {}
                    for _, member in ipairs(members) do
                        local ex = exportedPrimaryByPhoto[member.localIdentifier]
                        if ex then
                            local pos = member:getRawMetadata("stackPositionInFolder")
                            if type(pos) == "string" then pos = tonumber(string.match(pos, "%d+")) end
                            table.insert(ordered, { pos = pos or 999, assetId = ex.assetId })
                        end
                    end
                    table.sort(ordered, function(a, b) return (a.pos or 999) < (b.pos or 999) end)
                    if #ordered >= 2 then
                        local assetIds = {}
                        for _, e in ipairs(ordered) do table.insert(assetIds, e.assetId) end
                        local stackId = immich:createStack(assetIds)
                        if not stackId then
                            table.insert(stackWarnings, "LR stack: failed to create Immich stack")
                        else
                            log:trace("LR stack created in Immich: " .. stackId)
                        end
                    end
                end
            end
        end
    end
end
