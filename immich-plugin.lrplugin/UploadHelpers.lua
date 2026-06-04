--[[
UploadHelpers.lua - Shared upload logic for Export and Publish

Provides:
- Sorting original+export rendition pairs for correct Immich stack ordering
- Preserving Lightroom stacks in Immich
- Safe temporary file deletion (ensures cleanup on error or cancel)
]]

require("StackManager")

UploadHelpers = {}

--------------------------------------------------------------------------------
-- Delete a temporary file; never throws. Call after each upload so temp files
-- do not remain on early cancel or error.
function UploadHelpers.safeDeleteTempFile(path)
    if not path or type(path) ~= "string" then
        return
    end
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
    if not next(exportedPrimaryByPhoto) then
        return
    end
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
                            if type(pos) == "string" then
                                pos = tonumber(string.match(pos, "%d+"))
                            end
                            table.insert(ordered, { pos = pos or 999, assetId = ex.assetId })
                        end
                    end
                    table.sort(ordered, function(a, b)
                        return (a.pos or 999) < (b.pos or 999)
                    end)
                    if #ordered >= 2 then
                        local assetIds = {}
                        for _, e in ipairs(ordered) do
                            table.insert(assetIds, e.assetId)
                        end
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

--------------------------------------------------------------------------------
-- Collect a photo's keywords as Immich tag names, honoring each keyword's
-- "Include on Export" attribute (the same gate Lightroom uses when embedding
-- keywords into rendered files).
function UploadHelpers.collectExportKeywords(photo)
    local names = {}
    local keywords = photo:getRawMetadata("keywords")
    if type(keywords) ~= "table" then
        return names
    end
    for _, keyword in ipairs(keywords) do
        local attrs = keyword:getAttributes()
        if attrs == nil or attrs.includeOnExport ~= false then
            local name = keyword:getName()
            if not util.nilOrEmpty(name) then
                table.insert(names, name)
            end
        end
    end
    return names
end

--------------------------------------------------------------------------------
-- Parse an ISO datetime's calendar components into an LrDate, ignoring any zone.
-- Used only to diff two such values, so the (consistent) reference zone cancels.
local function naiveTime(isoStr)
    local y, mo, d, h, mi, s = (isoStr or ""):match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
    if not y then
        return nil
    end
    local ok, t = pcall(
        LrDate.timeFromComponents,
        tonumber(y),
        tonumber(mo),
        tonumber(d),
        tonumber(h),
        tonumber(mi),
        tonumber(s),
        "gmt"
    )
    if ok then
        return t
    end
    return nil
end

-- Resolve a photo's capture time as a zoned ISO string for Immich. Immich assumes
-- any value lacking a timezone is UTC and displays it shifted by whatever zone it
-- infers for the asset, so we send Lightroom's local wall-clock together with an
-- explicit offset. Immich then displays exactly the wall-clock Lightroom shows,
-- regardless of the zone it would otherwise infer. The offset is derived from
-- Lightroom itself (local wall-clock minus its UTC rendering), so it matches what
-- Lightroom displays and is DST-aware.
--
-- Source priority: the "original capture" field, then "digitized". The adjusted
-- "dateTime" field is excluded -- for videos Lightroom routinely fills it with a
-- bogus value (wrong day, unrelated time). Each field has an ISO8601 string and a
-- numeric variant; for some videos (e.g. .mts) the string is nil while the numeric
-- one still holds the value Lightroom shows under "Original Date/Time", so we fall
-- back to the numeric field. Returns nil when nothing usable is present, so the
-- caller leaves Immich's own extraction untouched. Capture-time edits land in the
-- original field, so this still honors "Edit Capture Time".
function UploadHelpers.captureTimeForImmich(photo)
    local cocoa = photo:getRawMetadata("dateTimeOriginal") or photo:getRawMetadata("dateTimeDigitized")

    -- Prefer the ISO8601 string (Lightroom's local wall-clock, faithful to the
    -- capture-location zone). Fall back to rendering the numeric field locally.
    local localIso = photo:getRawMetadata("dateTimeOriginalISO8601") or photo:getRawMetadata("dateTimeDigitizedISO8601")
    if util.nilOrEmpty(localIso) then
        if type(cocoa) ~= "number" then
            return nil
        end
        localIso = LrDate.timeToUserFormat(cocoa, "%Y-%m-%dT%H:%M:%S")
        if util.nilOrEmpty(localIso) then
            return nil
        end
    end

    -- Lightroom already supplied a zone: trust it.
    if localIso:match("[Zz]$") or localIso:match("[%+%-]%d%d:?%d%d$") then
        return localIso
    end

    -- No offset: derive it (DST-aware) from the same instant -- the local
    -- wall-clock minus its UTC rendering -- and append it.
    if type(cocoa) == "number" then
        local utcIso = LrDate.timeToW3CDate(cocoa)
        local localNaive, utcNaive = naiveTime(localIso), naiveTime(utcIso)
        if localNaive and utcNaive then
            local offsetSec = localNaive - utcNaive
            local sign = offsetSec >= 0 and "+" or "-"
            local mins = math.floor((math.abs(offsetSec) + 30) / 60)
            local offset = string.format("%s%02d:%02d", sign, math.floor(mins / 60), mins % 60)
            return localIso .. offset
        end
    end
    log:warn("captureTimeForImmich: could not derive offset; sending local '" .. localIso .. "' as-is")
    return localIso
end

--------------------------------------------------------------------------------
-- Push Lightroom metadata that Immich cannot read from the uploaded file to the
-- primary asset. Only applied to videos: Lightroom rewrites edited capture date
-- and keywords into rendered photos (which Immich extracts on ingest) but passes
-- video containers through untouched, so those edits never reach Immich
-- otherwise. Best-effort; failures are logged, not fatal.
function UploadHelpers.applyVideoMetadata(immich, photo, assetId)
    if not photo or util.nilOrEmpty(assetId) then
        return
    end
    if photo:getRawMetadata("fileFormat") ~= "VIDEO" then
        return
    end

    -- Immich probes and thumbnails a freshly uploaded video asynchronously.
    -- Changing its date here before that finishes races the ingest pipeline and
    -- leaves the thumbnail in an error state, so wait for it to be ready first.
    immich:waitForAssetReady(assetId, 30)

    -- Edited capture time, as a zoned ISO string so Immich stores the correct
    -- instant (it assumes UTC for any value lacking a timezone).
    local isoDate = UploadHelpers.captureTimeForImmich(photo)
    if not util.nilOrEmpty(isoDate) then
        immich:setAssetDate(assetId, isoDate)
    end

    -- Keywords -> tags. Additive only: assign the photo's current export keywords
    -- as tags and never remove any. Tags added directly in Immich are preserved.
    local tagNames = UploadHelpers.collectExportKeywords(photo)
    if #tagNames > 0 then
        local tags = immich:upsertTags(tagNames)
        if tags then
            local tagIds = {}
            for _, tag in ipairs(tags) do
                if tag.id then
                    table.insert(tagIds, tag.id)
                end
            end
            if #tagIds > 0 then
                immich:assignTagsToAsset(tagIds, assetId)
            end
        end
    end

    -- The date change above can invalidate the video's thumbnail (Immich
    -- regenerates it, and a freshly uploaded or just-replaced asset can be left
    -- showing an error). The pre-upload wait can't prevent this because the
    -- breakage is caused by our own edit, and an existing asset already has a
    -- stale thumbnail that defeats the wait. Queue a regeneration so it recovers.
    immich:regenerateThumbnail(assetId)
end

--------------------------------------------------------------------------------
-- Apply applyVideoMetadata to every successfully-uploaded primary asset. Runs
-- after all uploads so it lands after replaceAsset's metadata copy. One bad
-- photo never aborts the batch.
function UploadHelpers.applyVideoMetadataForAll(immich, exportedPrimaryByPhoto)
    for _, rec in pairs(exportedPrimaryByPhoto) do
        local ok, err = LrTasks.pcall(function()
            UploadHelpers.applyVideoMetadata(immich, rec.photo, rec.assetId)
        end)
        if not ok then
            log:warn("applyVideoMetadata failed: " .. tostring(err))
        end
    end
end
