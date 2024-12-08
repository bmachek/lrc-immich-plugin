PublishDialogSections = {}

local function _updateCantExportBecause(propertyTable)
	LrTasks.startAsyncTask(function()
		propertyTable.immich:reconfigure(propertyTable.url, propertyTable.apiKey)
		if not propertyTable.immich:checkConnectivity() then
			propertyTable.LR_cantExportBecause = "Immich connection not setup"
			return
		end
		propertyTable.LR_cantExportBecause = nil
	end)
end


function PublishDialogSections.startDialog(propertyTable)
	LrTasks.startAsyncTask(function()
		propertyTable.immich = ImmichAPI:new(propertyTable.url, propertyTable.apiKey)
		--_updateCantExportBecause(propertyTable)
	end)
	-- propertyTable:addObserver('url', _updateCantExportBecause)
	-- propertyTable:addObserver('apiKey', _updateCantExportBecause)
end

function PublishDialogSections.sectionsForTopOfDialog(f, propertyTable)
	local bind = LrView.bind
	local share = LrView.share

	local result = {

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
