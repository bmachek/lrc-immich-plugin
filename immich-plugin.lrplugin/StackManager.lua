--[[
StackManager.lua - Handles photo stacking functionality for Immich plugin

This module provides functionality to:
1. Detect if a photo has been edited in Lightroom
2. Upload original files alongside edited exports
3. Create stacks in Immich with edited photo as primary

Author: Immich Plugin Contributors
--]]

local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'
local LrLogger = import 'LrLogger'

require "ImmichAPI"

-- Initialize logging
local log = LrLogger('ImmichPlugin')
log:enable("logfile")

StackManager = {}

--------------------------------------------------------------------------------
-- Check if a photo has been edited in Lightroom
-- Analyzes core develop settings that indicate user adjustments
function StackManager.hasEdits(photo, editedPhotosCache)
    -- Check develop settings for core editing parameters
    local developSettings = photo:getDevelopSettings()
    if not developSettings then
        return false
    end
    
    -- Check core editing parameters that indicate user adjustments
    local coreParams = {
        "Exposure2012", "Contrast2012", "Highlights2012", "Shadows2012", 
        "Whites2012", "Blacks2012", "Texture", "Clarity2012", 
        "Vibrance", "Saturation"
    }
    
    for _, param in ipairs(coreParams) do
        local value = developSettings[param]
        if value and math.abs(value) > 0.001 then
            return true
        end
    end
    
    -- Check for cropping
    if developSettings.HasCrop then
        return true
    end
    
    -- Check for local adjustments (masks/brushes)
    if developSettings.MaskGroupBasedCorrections and #developSettings.MaskGroupBasedCorrections > 0 then
        return true
    end
    
    return false
end

--------------------------------------------------------------------------------
-- Get the original file path for a photo
function StackManager.getOriginalFilePath(photo)
    local originalPath = photo:getRawMetadata("path")
    
    if originalPath and LrFileUtils.exists(originalPath) then
        return originalPath
    end
    
    log:warn("Original file not found or inaccessible: " .. tostring(originalPath))
    return nil
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
    local photo = rendition.photo
    
    -- Get original file path
    local originalPath = StackManager.getOriginalFilePath(photo)
    if not originalPath then
        log:warn("Cannot access original file for: " .. photo.localIdentifier)
        return editedAssetId, "Cannot access original file"
    end
    
    -- Generate device asset ID for original
    local originalDeviceAssetId = StackManager.generateOriginalDeviceAssetId(
        photo.localIdentifier, originalPath)
    
    log:trace("Uploading original file: " .. originalPath)
    
    -- Check if original asset already exists
    local existingOriginalId = immich:checkIfAssetExists(originalDeviceAssetId,
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