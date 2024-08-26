require "ImmichAPI"

ExportDialogSections = {}

local function updateExportStatus(propertyTable)
	
	local message = nil

	if message then
		propertyTable.message = message
		propertyTable.hasError = true
		propertyTable.hasNoError = false
		propertyTable.LR_cantExportBecause = message
	else
		propertyTable.message = nil
		propertyTable.hasError = false
		propertyTable.hasNoError = true
		propertyTable.LR_cantExportBecause = nil
	end
	
end

-------------------------------------------------------------------------------

function ExportDialogSections.startDialog(propertyTable)

	propertyTable:addObserver('url', updateExportStatus)
	propertyTable:addObserver('apiKey', updateExportStatus)
	propertyTable:addObserver('album', updateExportStatus)
	propertyTable:addObserver('newAlbumName', updateExportStatus)
	propertyTable:addObserver('albums', updateExportStatus)
	propertyTable:addObserver('albumMode', updateExportStatus)

	LrTasks.startAsyncTask(function ()
		propertyTable.immich = ImmichAPI:new(prefs.url, prefs.apiKey)
		propertyTable.albums = propertyTable.immich:getAlbums()
	end)


	updateExportStatus(propertyTable)
	
end

-------------------------------------------------------------------------------

function ExportDialogSections.sectionsForBottomOfDialog(_, propertyTable)

	local f = LrView.osFactory()
	local bind = LrView.bind
	local share = LrView.share

	local result = {
	
		{
			title = "Immich Server URL",
						
			f:row {
				f:static_text {
					title = "URL:",
					alignment = 'right',
					width = share 'labelWidth'
				},
				f:edit_field {
					value = prefs.url,
					truncation = 'middle',
					immediate = false,
					width_in_chars = 40,
					-- fill_horizontal = 1,
					-- validate = function (v, url) 
					-- 	sanitizedURL = propertyTable.immich:sanityCheckAndFixURL()
					-- 	if sanitizedURL == url then
					-- 		return true, url, ''
					-- 	elseif not (sanitizedURL == nil) then
					-- 		LrDialogs.message('Entered URL was autocorrected to ' .. sanitizedURL)
					-- 		return true, sanitizedURL, ''
					-- 	end
					-- 	return false, url, 'Entered URL not valid.\nShould look like https://demo.immich:app'
					-- end,
					enabled = false, -- Configuration moved to PluginInfo
				},
			},
			
			f:row {
				f:static_text {
					title = "API Key:",
					alignment = 'right',
					width = share 'labelWidth',
				},
				f:password_field {
					value = prefs.apiKey,
					truncation = 'middle',
					immediate = true,
					width_in_chars = 40,
					-- fill_horizontal = 1,
					enabled = false, -- Configuration moved to PluginInfo
				},
			},
		},
	}
	
	return result
	
end

-------------------------------------------------------------------------------


function ExportDialogSections.sectionsForTopOfDialog( _, propertyTable )

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
									{ title = 'Choose on export', value = 'onexport'},
									{ title = 'Existing album', value = 'existing'},
									{ title = 'Create new album', value = 'new'},
									{ title = 'Do not use an album', value = 'none'},
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
							visible = LrBinding.keyEquals( "albumMode", "existing" ),
							align = left,
						},
						f:edit_field {
							truncation = 'middle',
							width_in_chars = 20,
							fill_horizontal = 1,
							value = bind 'newAlbumName',
							visible = LrBinding.keyEquals( "albumMode", "new" ),
							align = left,
						},
					}, 
				},
			},
		},
	}
	
	return result
	
end

