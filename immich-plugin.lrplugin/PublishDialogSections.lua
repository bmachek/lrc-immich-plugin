PublishDialogSections = {}


local function updatePublishStatus(propertyTable)
	propertyTable.immich:reconfigure(propertyTable.url, propertyTable.apiKey)
end


function PublishDialogSections.startDialog(propertyTable)
	propertyTable:addObserver('url', updatePublishStatus)
	propertyTable:addObserver('apiKey', updatePublishStatus)
	propertyTable.immich = ImmichAPI:new(propertyTable.url, propertyTable.apiKey)

	updatePublishStatus(propertyTable)
end

function PublishDialogSections.sectionsForTopOfDialog(_, propertyTable)
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
					value = bind 'url',
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
					visible = bind 'hasNoError',
				},
				f:password_field {
					value = bind 'apiKey',
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
