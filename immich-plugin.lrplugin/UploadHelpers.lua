--[[
UploadHelpers.lua - Shared upload logic for Export and Publish

Provides:
- Sorting original+export rendition pairs for correct Immich stack ordering
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
    local ok, err = LrTasks.pcall(function()
        if LrFileUtils.exists(path) then
            LrFileUtils.delete(path)
        end
    end)
    if not ok and log and log.warn then
        log:warn("UploadHelpers: could not delete temp file: " .. tostring(path) .. " - " .. tostring(err))
    end
end

--------------------------------------------------------------------------------
-- Original+export sort order: rendered export first (primary in Immich), original second.
-- Items must carry an explicit role field: "export" or "orig".
-- Using an explicit role avoids ambiguity for same-extension pairs (e.g. JPEG→JPEG)
-- where extension-based detection cannot distinguish the rendered export from the original.
function UploadHelpers.sortOriginalExportItems(items)
    table.sort(items, function(a, b)
        local aIsExport = a.role == "export"
        local bIsExport = b.role == "export"
        return aIsExport and not bIsExport -- exports before originals
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
