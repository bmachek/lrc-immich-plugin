require "ImmichAPI"
require "StackManager"

SharedDialogSections = {}

-- Generate the Shared 'Keep Original Files in Immich' dialog section
function SharedDialogSections.getOriginalFilesSection(f, propertyTable)
	local bind = LrView.bind
	local share = LrView.share

	return {
		title = "Keep Original Files in Immich",
		bind_to_object = propertyTable,
		f:column {
			spacing = f:control_spacing(),
			f:row {
				margin_bottom = 5,
				f:static_text {
					title = "Upload original files alongside edited exports to create stacks in Immich.\nTip: Uploading originals increases file size but preserves RAW data.",
					alignment = 'left',
					font = '<system/small>',
				},
			},
			f:row {
				f:static_text {
					title = "Original file behavior:",
					alignment = 'right',
					width = share "labelWidth",
				},
				f:popup_menu {
					alignment = 'left',
					immediate = true,
					width_in_chars = 42,
					items = {
						{ title = "Don't upload original files", value = 'none' },
						{ title = "Upload originals for edited photos only", value = 'edited' },
						{ title = "Upload originals for all photos", value = 'all' },
						{ title = "Always upload original only (no export)", value = 'original_only' },
						{ title = "Always upload original + rendered export (if edited)", value = 'original_plus_jpeg_if_edited' },
					},
					value = bind 'originalFileMode'
				},
			},
			f:row {
				f:static_text { title = "", alignment = 'right', width = share "labelWidth" },
				f:static_text {
					title = bind 'editedPhotosCount',
					alignment = 'left', fill_horizontal = 1,
					font = '<system/small>', text_color = LrColor(0.2, 0.6, 0.2),
				},
			},
			f:row {
				f:static_text { title = "", alignment = 'right', width = share "labelWidth" },
				f:static_text {
					title = bind 'originalFormatWarning',
					alignment = 'left', fill_horizontal = 1,
					font = '<system/small>', text_color = LrColor(0.8, 0.3, 0.0),
				},
			},
			f:row {
				f:static_text { title = "Stack Options:", alignment = 'right', width = share "labelWidth" },
				f:column {
					spacing = f:control_spacing(),
					f:checkbox {
						title = "Stack Original + Export in Immich",
						value = bind 'stackOriginalExport',
					},
					f:checkbox {
						title = "Preserve Lightroom stacks in Immich",
						value = bind 'stackLrStacks',
					},
				},
			},
		},
	}
end

-- Generate the Shared 'Immich Server connection' dialog section
function SharedDialogSections.getServerConnectionSection(f, propertyTable)
	local bind = LrView.bind
	local share = LrView.share

	return {
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
	}
end

function SharedDialogSections.setupOriginalFileObservers(propertyTable)
	local function _updateWarnings(propertyTable)
		local mode = propertyTable.originalFileMode
		local format = string.upper(propertyTable.LR_format or "")
		if format == "ORIGINAL" and (mode == 'original_plus_jpeg_if_edited' or propertyTable.stackOriginalExport) then
			propertyTable.originalFormatWarning = "No reformat selected: switch to any rendered format (e.g. JPEG, TIFF, PNG) to produce a distinct export for stacking."
		else
			propertyTable.originalFormatWarning = ""
		end
	end

	local function _updateEditedPhotosCount(propertyTable)
		local mode = propertyTable.originalFileMode
		if mode ~= 'edited' and mode ~= 'original_plus_jpeg_if_edited' then
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

	propertyTable:addObserver('originalFileMode', function()
		_updateWarnings(propertyTable)
		_updateEditedPhotosCount(propertyTable)
	end)
	propertyTable:addObserver('LR_format', function()
		_updateWarnings(propertyTable)
	end)
	propertyTable:addObserver('stackOriginalExport', function()
		_updateWarnings(propertyTable)
	end)

	_updateWarnings(propertyTable)
	if propertyTable.originalFileMode == 'edited' or propertyTable.originalFileMode == 'original_plus_jpeg_if_edited' then
		LrTasks.startAsyncTask(function()
			LrTasks.sleep(0.1)
			_updateEditedPhotosCount(propertyTable)
		end)
	end
end

return SharedDialogSections
