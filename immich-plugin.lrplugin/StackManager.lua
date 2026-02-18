--[[
StackManager.lua - Handles photo stacking functionality for Immich plugin

This module provides functionality to:
1. Detect if a photo has been edited in Lightroom
2. Upload original files alongside edited exports
3. Create stacks in Immich with edited photo as primary
4. Analyze selected photos for edit detection and counting

--]]

local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'
local LrLogger = import 'LrLogger'
local LrApplication = import 'LrApplication'

require "ImmichAPI"

-- Initialize logging
local log = LrLogger('ImmichPlugin')
log:enable("logfile")

StackManager = {}

--------------------------------------------------------------------------------
-- Check if a photo has been edited in Lightroom
-- Primarily uses cache lookup, with fallback to individual checks
function StackManager.hasEdits(photo, editedPhotosCache)
    -- If we have a cache, use it for fast lookup first
    if editedPhotosCache then
        local hasEdits = (editedPhotosCache[photo.localIdentifier] ~= nil)
        if hasEdits then
            log:trace("Photo " .. photo.localIdentifier .. " has edits (cache): " .. tostring(hasEdits))
            return true
        end
    end
    
    -- Fallback: check directly using hasAdjustments criterion
    local catalog = LrApplication.activeCatalog()
    if not catalog then
        log:warn("Cannot access catalog for edit detection")
        return false
    end
    
    -- Search for photos with adjustments and check if this photo is in the results
    local editedPhotos = catalog:findPhotos({
        searchDesc = {
            criteria = "hasAdjustments",
            operation = "isTrue",
            value = true,
        }
    })
    
    -- Check if the current photo is in the edited photos results
    local hasEdits = false
    for _, p in ipairs(editedPhotos) do
        if p.localIdentifier == photo.localIdentifier then
            hasEdits = true
            break
        end
    end
    
    -- Only check for cropping if hasAdjustments didn't detect anything
    -- (cropped-only photos are not detected by hasAdjustments)
    if not hasEdits then
        local croppedPhotos = catalog:findPhotos({
            searchDesc = {
                criteria = "cropped",
                operation = "isTrue",
                value = true,
            }
        })
        
        -- Check if the current photo is in the cropped photos results
        for _, p in ipairs(croppedPhotos) do
            if p.localIdentifier == photo.localIdentifier then
                hasEdits = true
                log:trace("Photo " .. photo.localIdentifier .. " has crop edits (SDK cropped)")
                break
            end
        end
    end
    
    return hasEdits
end

--------------------------------------------------------------------------------
-- Get all edited photo IDs for efficient batch checking
-- Call this once to create a cache for multiple photo checks
-- Uses both hasAdjustments and cropped criteria for comprehensive detection
function StackManager.getEditedPhotosCache()
    local catalog = LrApplication.activeCatalog()
    if not catalog then
        log:warn("Cannot access catalog for edit detection")
        return {}
    end
    
    -- Get all photos with adjustments
    local editedPhotos = catalog:findPhotos({
        searchDesc = {
            criteria = "hasAdjustments",
            operation = "isTrue",
            value = true,
        }
    })
    
    -- Get all photos with cropping
    local croppedPhotos = catalog:findPhotos({
        searchDesc = {
            criteria = "cropped",
            operation = "isTrue",
            value = true,
        }
    })
    
    -- Create a lookup table for fast checking
    local editedPhotoIds = {}
    local uniqueCount = 0
    
    -- Add photos with adjustments
    for _, p in ipairs(editedPhotos) do
        if p.localIdentifier then
            editedPhotoIds[p.localIdentifier] = true
            uniqueCount = uniqueCount + 1
        end
    end
    
    -- Add photos with cropping (avoid duplicates)
    for _, p in ipairs(croppedPhotos) do
        if p.localIdentifier and not editedPhotoIds[p.localIdentifier] then
            editedPhotoIds[p.localIdentifier] = true
            uniqueCount = uniqueCount + 1
        end
    end
    
    log:info("Created edited photos cache with " .. #editedPhotos .. " hasAdjustments + " .. #croppedPhotos .. " cropped = " .. uniqueCount .. " unique photos")
    return editedPhotoIds
end

--------------------------------------------------------------------------------
-- Analyze selected photos and return comprehensive edit statistics
-- Returns a table with: { total, edited, original, summary }
function StackManager.analyzeSelectedPhotos()
    local catalog = LrApplication.activeCatalog()
    if not catalog then
        log:warn("Cannot access catalog for photo analysis")
        return { total = 0, edited = 0, original = 0, summary = "" }
    end
    
    local selectedPhotos = catalog:getTargetPhotos()
    if not selectedPhotos or #selectedPhotos == 0 then
        return { total = 0, edited = 0, original = 0, summary = "" }
    end
    
    local totalCount = #selectedPhotos
    
    -- Get all photos with adjustments in the entire catalog
    local allEditedPhotos = catalog:findPhotos({
        searchDesc = {
            criteria = "hasAdjustments",
            operation = "isTrue",
            value = true,
        }
    })
    
    -- Get all photos with cropping in the entire catalog
    local allCroppedPhotos = catalog:findPhotos({
        searchDesc = {
            criteria = "cropped",
            operation = "isTrue",
            value = true,
        }
    })
    
    -- Create lookup tables for fast checking
    local editedPhotoIds = {}
    local croppedPhotoIds = {}
    
    -- Build lookup for edited photos
    for _, p in ipairs(allEditedPhotos) do
        if p.localIdentifier then
            editedPhotoIds[p.localIdentifier] = true
        end
    end
    
    -- Build lookup for cropped photos
    for _, p in ipairs(allCroppedPhotos) do
        if p.localIdentifier then
            croppedPhotoIds[p.localIdentifier] = true
        end
    end
    
    -- Count edited photos in selection using fast lookups
    local editedCount = 0
    for _, photo in ipairs(selectedPhotos) do
        if photo and photo.localIdentifier then
            -- Check if photo has adjustments OR cropping
            if editedPhotoIds[photo.localIdentifier] or croppedPhotoIds[photo.localIdentifier] then
                editedCount = editedCount + 1
            end
        end
    end
    
    local originalCount = totalCount - editedCount
    
    -- Generate summary text
    local summary
    if editedCount > 0 then
        if originalCount > 0 then
            summary = string.format("%d photos selected: %d edited, %d original", totalCount, editedCount, originalCount)
        else
            summary = string.format("%d photos selected: all edited", totalCount)
        end
    else
        summary = string.format("%d photos selected: no edits detected", totalCount)
    end
    
    return {
        total = totalCount,
        edited = editedCount,
        original = originalCount,
        summary = summary
    }
end

--------------------------------------------------------------------------------
-- Get the original file path for a photo
function StackManager.getOriginalFilePath(photo)
    if not photo then
        log:warn("getOriginalFilePath: photo is nil")
        return nil
    end
    local originalPath = photo:getRawMetadata("path")
    
    if not originalPath or type(originalPath) ~= "string" or originalPath == "" then
        log:warn("getOriginalFilePath: no path metadata for photo " .. tostring(photo.localIdentifier))
        return nil
    end
    if not LrFileUtils.exists(originalPath) then
        log:warn("getOriginalFilePath: file does not exist or is inaccessible: " .. tostring(originalPath))
        return nil
    end
    return originalPath
end

--------------------------------------------------------------------------------
-- Generate device asset ID for original file
-- Appends "_original" to the base photo ID to ensure uniqueness
function StackManager.generateOriginalDeviceAssetId(baseId, originalPath)
    return tostring(baseId) .. "_original"
end

--------------------------------------------------------------------------------
-- Upload original file and create stack with edited photo as primary
function StackManager.processPhotoWithStack(immich, rendition, editedAssetId, exportParams)
    if not immich then
        log:warn("processPhotoWithStack: immich API instance is nil")
        return editedAssetId, "API not available"
    end
    if not rendition or not rendition.photo then
        log:warn("processPhotoWithStack: rendition or photo is nil")
        return editedAssetId, "Invalid rendition"
    end
    local photo = rendition.photo
    
    -- Get original file path
    local originalPath = StackManager.getOriginalFilePath(photo)
    if not originalPath then
        log:warn("processPhotoWithStack: cannot access original file for " .. tostring(photo.localIdentifier))
        return editedAssetId, "Cannot access original file"
    end
    
    -- Generate device asset ID for original using UUID
    local baseDeviceId = util.getPhotoDeviceId(photo)
    if not baseDeviceId then
        log:warn("processPhotoWithStack: no device ID for photo " .. tostring(photo.localIdentifier))
        return editedAssetId, "Cannot generate asset ID for original"
    end
    local originalDeviceAssetId = StackManager.generateOriginalDeviceAssetId(
        baseDeviceId, originalPath)
    
    log:trace("Uploading original file: " .. originalPath)
    
    -- Check if original asset already exists (use enhanced check but without metadata lookup for originals)
    local existingOriginalId, existingOriginalDeviceId = immich:checkIfAssetExists(originalDeviceAssetId,
        LrPathUtils.leafName(originalPath), photo:getFormattedMetadata("dateCreated"))
    
    local originalAssetId
    if existingOriginalId then
        originalAssetId = existingOriginalId
        log:trace("Original asset already exists: " .. originalAssetId)
    else
        -- Upload original file
        originalAssetId = immich:uploadAsset(originalPath, originalDeviceAssetId)
    end
    
    if not originalAssetId then
        return editedAssetId, "Failed to upload original file"
    end
    
    -- Create stack with edited as primary, original as secondary
    local stackId = immich:createStack({editedAssetId, originalAssetId})
    
    if stackId then
        log:trace("Stack created successfully: " .. stackId)
        return editedAssetId, nil -- Success
    else
        return editedAssetId, "Failed to create stack"
    end
end

return StackManager