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
	-- Only run if the mode is set to 'edited'
	if propertyTable.originalFileMode ~= 'edited' then
		propertyTable.editedPhotosCount = ""
		return
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
	
	-- Trigger initial count if mode is already set to 'edited'
	if propertyTable.originalFileMode == 'edited' then
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
						width_in_chars = 35,
						items = {
							{ title = "Don't upload original files", value = 'none' },
							{ title = "Upload originals for edited photos only", value = 'edited' },
							{ title = "Upload originals for all photos", value = 'all' },
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
					validate = function (v, url)
						local sanitizedURL = propertyTable.immich:sanityCheckAndFixURL(url)
						if sanitizedURL == url then
							return true, url, ''
						elseif not (sanitizedURL == nil) then
							LrDialogs.message('Entered URL was autocorrected to ' .. sanitizedURL)
							return true, sanitizedURL, ''
						end
						return false, url, 'Entered URL not valid.\nShould look like https://demo.immich.app'
					end,
				},
				f:push_button {
                    title = 'Test connection',
                    action = function(button)
                        LrTasks.startAsyncTask(function()
                            propertyTable.immich:reconfigure(propertyTable.url, propertyTable.apiKey)
                            if propertyTable.immich:checkConnectivity() then
                                LrDialogs.message('Connection test successful')
                            else
                                LrDialogs.message('Connection test NOT successful')
                            end
                        end)
                    end,
                },
			},

			f:row {
				f:static_text {
					title = "API Key:",
					alignment = 'right',
					width = share 'labelWidth',
					visible = bind 'hasNoError',
				},
				f:password_field {
					value = bind 'apiKey',
					truncation = 'middle',
					immediate = true,
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
