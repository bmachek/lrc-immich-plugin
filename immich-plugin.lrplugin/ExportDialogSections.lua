require "ImmichAPI"

ExportDialogSections = {}

local function updateExportStatus(propertyTable)
	propertyTable.immich:reconfigure(propertyTable.url, propertyTable.apiKey)
end

-------------------------------------------------------------------------------

function ExportDialogSections.startDialog(propertyTable)
	propertyTable:addObserver('url', updateExportStatus)
	propertyTable:addObserver('apiKey', updateExportStatus)
	propertyTable:addObserver('album', updateExportStatus)
	propertyTable:addObserver('newAlbumName', updateExportStatus)
	propertyTable:addObserver('albums', updateExportStatus)
	propertyTable:addObserver('albumMode', updateExportStatus)

	LrTasks.startAsyncTask(function()
		propertyTable.immich = ImmichAPI:new(propertyTable.url, propertyTable.apiKey)
		if propertyTable.immich:checkConnectivity() then
			propertyTable.albums = immich:getAlbums()
		else
			LrDialogs.error('Immich connection not set up.')
		end
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
                            local testImmich = ImmichAPI:new(propertyTable.url, propertyTable.apiKey)
                            if testImmich:checkConnectivity() then
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
				},
				f:password_field {
					value = prefs.apiKey,
					truncation = 'middle',
					immediate = true,
					width_in_chars = 40,
					-- fill_horizontal = 1,
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
							visible = LrBinding.keyEquals("albumMode", "new"),
							align = "left",
						},
					},
				},
			},
		},
	}

	return result
end
