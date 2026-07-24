local ImportServiceProvider = require("ImportServiceProvider")
local getImmichAlbums = ImportServiceProvider.getImmichAlbums
local loadAlbumPhotos = ImportServiceProvider.loadAlbumPhotos
local loadSearchPhotos = ImportServiceProvider.loadSearchPhotos
local getAlbumTitleById = ImportServiceProvider.getAlbumTitleById

--[[
    Unified "Import from Immich" dialog. Lets the user pick the import source:
      - Album: download the photos of a chosen Immich album.
      - Search: run Immich's smart (CLIP) search and download the matches.
    The two entry points used to be separate menu items; they are merged here with a
    mode chooser that toggles which controls are shown.
]]

return {
    LrTasks.startAsyncTask(function()
        if not Util.ensureConnected() then
            return
        end

        -- Fetch albums up front so the album popup is ready. Search still works without any.
        local albums = getImmichAlbums() or {}
        local hasAlbums = #albums > 0

        LrFunctionContext.callWithContext("immichUnifiedImport", function(context)
            local f = LrView.osFactory()
            local props = LrBinding.makePropertyTable(context)

            -- Import mode: "album" or "search". Remembered across sessions. Fall back to
            -- search when there are no albums to choose from.
            local defaultMode = prefs.lastImportMode == "search" and "search" or "album"
            if not hasAlbums then
                defaultMode = "search"
            end
            props.importMode = defaultMode

            -- Album default: the album chosen last time (matched by name so it survives
            -- across sessions), falling back to the first album.
            props.selectedAlbum = albums[1] and albums[1].value or nil
            if prefs.lastImportAlbumName then
                for _, album in ipairs(albums) do
                    if album.title == prefs.lastImportAlbumName then
                        props.selectedAlbum = album.value
                        break
                    end
                end
            end

            props.searchQuery = prefs.lastSearchQuery or ""

            -- Import destination settings (previously in the separate import config dialog).
            props.importPath = prefs.importPath or ""
            props.importBatchSize = prefs.importBatchSize or 2
            props.stampAfterImport = prefs.stampAfterImport ~= false

            local isAlbum = function(v)
                return v == "album"
            end
            local isSearch = function(v)
                return v == "search"
            end

            local contents = f:column({
                bind_to_object = props,
                spacing = f:control_spacing(),
                margin = 15,
                fill_horizontal = 1,
                f:row({
                    f:static_text({
                        title = "Import by:",
                        alignment = "right",
                        width = LrView.share("import_label"),
                    }),
                    f:popup_menu({
                        value = LrView.bind("importMode"),
                        items = {
                            { title = "Album", value = "album" },
                            { title = "Search (smart / CLIP)", value = "search" },
                        },
                        width = 220,
                        enabled = hasAlbums,
                    }),
                }),
                f:separator({ fill_horizontal = 1 }),

                -- Album mode
                f:column({
                    visible = LrView.bind({ key = "importMode", transform = isAlbum }),
                    spacing = f:control_spacing(),
                    fill_horizontal = 1,
                    f:static_text({
                        title = "Choose an Immich album to import into Lightroom."
                            .. " Only new photos are downloaded.",
                        alignment = "left",
                        font = "<system/small>",
                    }),
                    f:row({
                        margin_top = 5,
                        f:static_text({
                            title = "Album:",
                            alignment = "right",
                            width = LrView.share("import_label"),
                        }),
                        f:popup_menu({
                            items = albums,
                            value = LrView.bind("selectedAlbum"),
                            width = 250,
                            enabled = hasAlbums,
                        }),
                    }),
                }),

                -- Search mode
                f:column({
                    visible = LrView.bind({ key = "importMode", transform = isSearch }),
                    spacing = f:control_spacing(),
                    fill_horizontal = 1,
                    f:static_text({
                        title = 'Describe the photos you want to import (e.g. "sunset over water").'
                            .. "\nImmich's smart search finds matching photos and imports them into Lightroom.",
                        alignment = "left",
                        font = "<system/small>",
                    }),
                    f:row({
                        margin_top = 5,
                        f:static_text({
                            title = "Search:",
                            alignment = "right",
                            width = LrView.share("import_label"),
                        }),
                        f:edit_field({
                            value = LrView.bind("searchQuery"),
                            width_in_chars = 30,
                            immediate = true,
                        }),
                    }),
                }),

                -- Import destination settings (shared by both modes).
                f:separator({ fill_horizontal = 1 }),
                f:row({
                    f:static_text({
                        title = "Import to:",
                        alignment = "right",
                        width = LrView.share("import_label"),
                    }),
                    f:edit_field({
                        value = LrView.bind("importPath"),
                        truncation = "middle",
                        immediate = true,
                        fill_horizontal = 1,
                        width_in_chars = 28,
                        validate = function(_, path)
                            if not Util.nilOrEmpty(path) and not LrFileUtils.exists(path) then
                                return false, path, "Selected path does not exist"
                            end
                            return true, path, ""
                        end,
                    }),
                    f:push_button({
                        title = "Browse...",
                        action = function()
                            local directory = LrDialogs.runOpenPanel({
                                title = "Choose Import Directory",
                                prompt = "Select",
                                canChooseFiles = false,
                                canChooseDirectories = true,
                                canCreateDirectories = true,
                                allowsMultipleSelection = false,
                            })
                            if directory and directory[1] then
                                props.importPath = directory[1]
                            end
                        end,
                    }),
                }),
                f:row({
                    f:static_text({
                        title = "Batch size:",
                        alignment = "right",
                        width = LrView.share("import_label"),
                    }),
                    f:edit_field({
                        value = LrView.bind("importBatchSize"),
                        width_in_chars = 5,
                        immediate = true,
                        validate = function(_, value)
                            local n = tonumber(value)
                            if not n or n < 1 then
                                return false, value, "Batch size must be a positive integer (>= 1)."
                            end
                            return true, tostring(math.floor(n + 0.5)), ""
                        end,
                    }),
                }),
                f:row({
                    f:static_text({ title = "", width = LrView.share("import_label") }),
                    f:checkbox({
                        title = "Stamp Immich asset IDs onto imported photos automatically",
                        value = LrView.bind("stampAfterImport"),
                    }),
                }),
            })

            local result = LrDialogs.presentModalDialog({
                title = "Import from Immich",
                contents = contents,
                actionVerb = "Import",
            })

            if result ~= "ok" then
                return
            end

            -- Persist import destination settings.
            if Util.nilOrEmpty(props.importPath) then
                LrDialogs.message(
                    "No import folder set.",
                    "Choose a folder to import photos into before importing.",
                    "warning"
                )
                return
            end
            prefs.importPath = props.importPath
            prefs.importBatchSize = tonumber(props.importBatchSize) or 2
            prefs.stampAfterImport = props.stampAfterImport == true

            prefs.lastImportMode = props.importMode

            if props.importMode == "search" then
                local query = props.searchQuery
                if Util.nilOrEmpty(query) then
                    LrDialogs.message("Please enter a search query.", nil, "warning")
                    return
                end
                prefs.lastSearchQuery = query
                loadSearchPhotos(query)
            else
                if not hasAlbums or Util.nilOrEmpty(props.selectedAlbum) then
                    LrDialogs.message("No album selected", "No Immich albums were found to import from.", "info")
                    return
                end
                local albumTitle = getAlbumTitleById(albums, props.selectedAlbum)
                prefs.lastImportAlbumName = albumTitle
                loadAlbumPhotos(props.selectedAlbum, albumTitle)
            end
        end)
    end),
}
