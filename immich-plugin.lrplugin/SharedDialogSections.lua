require("ImmichAPI")
require("StackManager")

SharedDialogSections = {}

-- Generate the Shared 'Keep Original Files in Immich' dialog section
function SharedDialogSections.getOriginalFilesSection(f, propertyTable)
    local bind = LrView.bind
    local share = LrView.share

    return {
        title = "Keep Original Files in Immich",
        bind_to_object = propertyTable,
        f:column({
            spacing = f:control_spacing(),
            f:row({
                margin_bottom = 5,
                f:static_text({
                    title = "Upload original files alongside edited exports to create stacks in Immich."
                        .. "\nTip: Uploading originals increases file size but preserves RAW data.",
                    alignment = "left",
                    font = "<system/small>",
                }),
            }),
            f:row({
                f:static_text({
                    title = "Original file behavior:",
                    alignment = "right",
                    width = share("labelWidth"),
                }),
                f:popup_menu({
                    alignment = "left",
                    immediate = true,
                    width_in_chars = 42,
                    items = {
                        { title = "Don't upload original files", value = "none" },
                        { title = "Upload originals for edited photos only", value = "edited" },
                        { title = "Upload originals for all photos", value = "all" },
                        { title = "Always upload original only (no export)", value = "original_only" },
                        {
                            title = "Always upload original + rendered export (if edited)",
                            value = "original_plus_jpeg_if_edited",
                        },
                    },
                    value = bind("originalFileMode"),
                }),
            }),
            f:row({
                f:static_text({ title = "", alignment = "right", width = share("labelWidth") }),
                f:static_text({
                    title = bind("editedPhotosCount"),
                    alignment = "left",
                    fill_horizontal = 1,
                    font = "<system/small>",
                    text_color = LrColor(0.2, 0.6, 0.2),
                }),
            }),
            f:row({
                f:static_text({ title = "", alignment = "right", width = share("labelWidth") }),
                f:static_text({
                    title = bind("originalFormatWarning"),
                    alignment = "left",
                    fill_horizontal = 1,
                    font = "<system/small>",
                    text_color = LrColor(0.8, 0.3, 0.0),
                }),
            }),
            f:row({
                f:static_text({ title = "Stack Options:", alignment = "right", width = share("labelWidth") }),
                f:column({
                    spacing = f:control_spacing(),
                    f:checkbox({
                        title = "Stack Original + Export in Immich",
                        value = bind("stackOriginalExport"),
                    }),
                    f:checkbox({
                        title = "Stack export with existing Immich original (no re-upload)",
                        value = bind("stackWithExistingOriginal"),
                        tooltip = "When a photo already has a known original asset in Immich"
                            .. " (from a previous upload or an import), stack the rendered export with it"
                            .. " instead of uploading the original again. Skipped if the original no longer"
                            .. " exists on the server.",
                    }),
                    f:checkbox({
                        title = "Preserve Lightroom stacks in Immich",
                        value = bind("stackLrStacks"),
                    }),
                }),
            }),
        }),
    }
end

-- Generate the Shared 'Locked Folder' dialog section
function SharedDialogSections.getLockedFolderSection(f, propertyTable)
    local bind = LrView.bind
    local share = LrView.share

    return {
        title = "Locked Folder",
        bind_to_object = propertyTable,
        f:column({
            spacing = f:control_spacing(),
            f:row({
                margin_bottom = 5,
                f:static_text({
                    title = "Photos uploaded to the locked folder are hidden from the timeline"
                        .. " and require a PIN to view in Immich.",
                    alignment = "left",
                    font = "<system/small>",
                }),
            }),
            f:row({
                f:static_text({
                    title = "Locked folder:",
                    alignment = "right",
                    width = share("labelWidth"),
                }),
                f:popup_menu({
                    alignment = "left",
                    immediate = true,
                    width_in_chars = 32,
                    items = {
                        { title = "Don't use locked folder", value = "none" },
                        { title = "Always upload to locked folder", value = "always" },
                        { title = "Ask on each run", value = "ask" },
                    },
                    value = bind("lockedFolderMode"),
                }),
            }),
        }),
    }
end

-- Generate the Shared 'Immich Server connection' dialog section.
-- opts.allowGlobal (Export/Publish presets): adds a checkbox to reuse the global
-- connection configured in Plugin Manager; the per-preset fields are disabled
-- while it is checked. Omit opts for the Plugin Manager section itself, which
-- edits the global connection directly.
function SharedDialogSections.getServerConnectionSection(f, propertyTable, opts)
    local bind = LrView.bind
    local share = LrView.share
    local allowGlobal = opts and opts.allowGlobal
    -- Per-preset fields stay editable unless the preset opts into the global connection.
    local fieldsEnabled = allowGlobal
            and bind({
                key = "useGlobalConnection",
                transform = function(value)
                    return not value
                end,
            })
        or true

    local section = {
        title = "Immich Server connection",
        bind_to_object = propertyTable,
    }

    if allowGlobal then
        table.insert(
            section,
            f:row({
                f:checkbox({
                    title = "Use global server connection (configured in Plugin Manager)",
                    value = bind("useGlobalConnection"),
                }),
            })
        )
    end

    table.insert(
        section,
        f:row({
            f:static_text({
                title = "URL:",
                alignment = "right",
                width = share("labelWidth"),
                enabled = fieldsEnabled,
            }),
            f:edit_field({
                value = bind("url"),
                truncation = "middle",
                immediate = false,
                fill_horizontal = 1,
                enabled = fieldsEnabled,
                validate = function(_, url)
                    return ImmichAPI.validateUrlForDialog(url, propertyTable.url, propertyTable.apiKey)
                end,
            }),
            f:push_button({
                title = "Test connection",
                enabled = fieldsEnabled,
                action = function()
                    LrTasks.startAsyncTask(function()
                        local _, message, api =
                            ImmichAPI.testConnection(propertyTable.url, propertyTable.apiKey, propertyTable.immich)
                        if api then
                            propertyTable.immich = api
                        end
                        LrDialogs.message(message)
                    end)
                end,
            }),
        })
    )

    table.insert(
        section,
        f:row({
            f:static_text({
                title = "API Key:",
                alignment = "right",
                width = share("labelWidth"),
                enabled = fieldsEnabled,
            }),
            f:password_field({
                value = bind("apiKey"),
                truncation = "middle",
                immediate = false,
                fill_horizontal = 1,
                enabled = fieldsEnabled,
            }),
        })
    )

    return section
end

function SharedDialogSections.setupOriginalFileObservers(propertyTable)
    local function _updateWarnings(propertyTable)
        local mode = propertyTable.originalFileMode
        local format = string.upper(propertyTable.LR_format or "")
        if format == "ORIGINAL" and (mode == "original_plus_jpeg_if_edited" or propertyTable.stackOriginalExport) then
            propertyTable.originalFormatWarning = "No reformat selected: switch to any rendered format"
                .. " (e.g. JPEG, TIFF, PNG) to produce a distinct export for stacking."
        else
            propertyTable.originalFormatWarning = ""
        end
    end

    local function _updateEditedPhotosCount(propertyTable)
        local mode = propertyTable.originalFileMode
        if mode ~= "edited" and mode ~= "original_plus_jpeg_if_edited" then
            propertyTable.editedPhotosCount = ""
            return
        end

        local catalog = LrApplication.activeCatalog()
        if catalog then
            local selectedPhotos = catalog:getTargetPhotos()
            if selectedPhotos and #selectedPhotos > 0 then
                propertyTable.editedPhotosCount = "Analyzing " .. #selectedPhotos .. " photos..."
            else
                propertyTable.editedPhotosCount = "Analyzing photos..."
            end
        end

        LrTasks.startAsyncTask(function()
            local analysis = StackManager.analyzeSelectedPhotos()
            propertyTable.editedPhotosCount = analysis.summary
        end)
    end

    propertyTable.editedPhotosCount = ""
    propertyTable.originalFormatWarning = ""

    propertyTable:addObserver("originalFileMode", function()
        _updateWarnings(propertyTable)
        _updateEditedPhotosCount(propertyTable)
    end)
    propertyTable:addObserver("LR_format", function()
        _updateWarnings(propertyTable)
    end)
    propertyTable:addObserver("stackOriginalExport", function()
        _updateWarnings(propertyTable)
    end)

    _updateWarnings(propertyTable)
    if
        propertyTable.originalFileMode == "edited"
        or propertyTable.originalFileMode == "original_plus_jpeg_if_edited"
    then
        LrTasks.startAsyncTask(function()
            LrTasks.sleep(0.1)
            _updateEditedPhotosCount(propertyTable)
        end)
    end
end

return SharedDialogSections
