require "ImmichAPI"
require "StackManager"

local LrTasks = import 'LrTasks'
local LrColor = import 'LrColor'

ExportDialogSections = {}

local function _updateCantExportBecause(propertyTable)
	LrTasks.startAsyncTask(function()
		propertyTable.immich:reconfigure(propertyTable.url, propertyTable.apiKey)
		if not propertyTable.immich:checkConnectivity() then
			propertyTable.LR_cantExportBecause = "Immich connection not setup"
			return
		else
			propertyTable.albums = propertyTable.immich:getAlbums()
		end

		propertyTable.LR_cantExportBecause = nil
	end)
end

local function _updateEditedPhotosCount(propertyTable)
    local mode = propertyTable.originalFileMode
    if mode ~= 'edited' and mode ~= 'original_plus_jpeg_if_edited' then
        propertyTable.editedPhotosCount = ""
        return
    end
    
    -- Show immediate feedback for all selections
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

-------------------------------------------------------------------------------

function ExportDialogSections.startDialog(propertyTable)
	-- Initialize edited photos count
	propertyTable.editedPhotosCount = ""

	LrTasks.startAsyncTask(function()
		propertyTable.immich = ImmichAPI:new(propertyTable.url, propertyTable.apiKey)
		propertyTable.albums = propertyTable.immich:getAlbums()
		--_updateCantExportBecause(propertyTable)
	end)
	-- propertyTable:addObserver('url', _updateCantExportBecause)
	-- propertyTable:addObserver('apiKey', _updateCantExportBecause)
	
	-- Add observer for originalFileMode changes
	propertyTable:addObserver('originalFileMode', function(key, value)
		_updateEditedPhotosCount(propertyTable)
	end)
	
	-- Trigger initial count if mode uses edit detection
	if propertyTable.originalFileMode == 'edited' or propertyTable.originalFileMode == 'original_plus_jpeg_if_edited' then
		-- Small delay to ensure UI is ready
		LrTasks.startAsyncTask(function()
			LrTasks.sleep(0.1)
			_updateEditedPhotosCount(propertyTable)
		end)
	end
end

-------------------------------------------------------------------------------

function ExportDialogSections.sectionsForBottomOfDialog(f, propertyTable)
	local bind = LrView.bind
	local share = LrView.share

	local result = {

		{
			title = "Keep Original Files in Immich",
			f:column {
				f:row {
					f:static_text {
						title = "Upload original files alongside edited exports to create stacks in Immich.",
						alignment = 'left',
						font = '<system/small>',
					},
				},
				f:row {
					f:static_text {
						title = "Tip: Uploading originals increases file size but preserves RAW data for future edits.",
						alignment = 'left',
						text_color = LrColor( 0.6, 0.6, 0.6 ),
						font = '<system/small>',
					},
				},
				f:row {
					f:static_text {
						title = "Original file behavior:",
						alignment = 'right',
						width = LrView.share "label_width",
					},
					f:popup_menu {
						alignment = 'left',
						immediate = true,
						width_in_chars = 42,
						items = {
							{ title = "Don't upload original files", value = 'none' },
							{ title = "Upload originals for edited photos only", value = 'edited' },
							{ title = "Upload originals for all photos", value = 'all' },
							{ title = "Always upload original only (no JPG)", value = 'original_only' },
							{ title = "Always upload original, JPG only if edited", value = 'original_plus_jpeg_if_edited' },
						},
						value = bind 'originalFileMode'
					},
				},
				f:row {
					f:static_text {
						title = "",
						alignment = 'right',
						width = LrView.share "label_width",
					},
					f:static_text {
						title = bind 'editedPhotosCount',
						alignment = 'left',
						fill_horizontal = 1,
						font = '<system/small>',
						text_color = LrColor(0.2, 0.6, 0.2),
					},
				},
				f:row {
					f:static_text {
						title = "DNG+JPG export:",
						alignment = 'right',
						width = LrView.share "label_width",
					},
					f:checkbox {
						title = "Stack in Immich (edited JPG as primary)",
						value = bind 'stackDngJpg',
					},
				},
				f:row {
					f:static_text {
						title = "Lightroom stacks:",
						alignment = 'right',
						width = LrView.share "label_width",
					},
					f:checkbox {
						title = "Preserve Lightroom stacks in Immich",
						value = bind 'stackLrStacks',
					},
				},
			},
		},

		{
			title = "Immich Server connection",
			bind_to_object = propertyTable,

			f:row {
				f:static_text {
					title = "URL:",
					alignment = 'right',
					width = share 'labelWidth'
				},
				f:edit_field {
					value = bind 'url',
					truncation = 'middle',
					immediate = false,
					fill_horizontal = 1,
					validate = function(_, url)
						return ImmichAPI.validateUrlForDialog(url, propertyTable.url, propertyTable.apiKey)
					end,
				},
				f:push_button {
					title = "Test connection",
					action = function()
						LrTasks.startAsyncTask(function()
							local success, message, api = ImmichAPI.testConnection(
								propertyTable.url, propertyTable.apiKey, propertyTable.immich)
							if api then
								propertyTable.immich = api
							end
							LrDialogs.message(message)
						end)
					end,
				},
			},

			f:row {
				f:static_text {
					title = "API Key:",
					alignment = "right",
					width = share "labelWidth",
				},
				f:password_field {
					value = bind "apiKey",
					truncation = "middle",
					immediate = false,
					fill_horizontal = 1,
				},
			},
		},
	}

	return result
end

-------------------------------------------------------------------------------

function ExportDialogSections.sectionsForTopOfDialog(_, propertyTable)
	local f = LrView.osFactory()
	local bind = LrView.bind

	local result = {

		{
			title = "Immich Album Options",
			f:column {
				f:row {
					f:column {
						f:row {
							f:static_text {
								title = "Add to album during export:",
								alignment = 'right',
							},
							f:popup_menu {
								alignment = 'left',
								immediate = true,
								items = {
									{ title = 'Choose on export',    value = 'onexport' },
									{ title = 'Existing album',      value = 'existing' },
									{ title = 'Create new album',    value = 'new' },
									{ title = 'Create/use folder name as album',    value = 'folder' },
									{ title = 'Do not use an album', value = 'none' },
								},
								value = bind 'albumMode',
							},
						},
					},

					f:column {
						place = "overlapping",
						f:popup_menu {
							truncation = 'middle',
							width_in_chars = 20,
							fill_horizontal = 1,
							value = bind 'album',
							items = bind 'albums',
							visible = LrBinding.keyEquals("albumMode", "existing"),
							align = "left",
						},
						f:edit_field {
							truncation = 'middle',
							width_in_chars = 20,
							fill_horizontal = 1,
							value = bind 'newAlbumName',
							align = "left",
							visible = LrBinding.keyEquals("albumMode", "new"),
						},
					},
				},
			},
		},
	}

	return result
end
