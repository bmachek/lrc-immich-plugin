require "ImmichAPI"

PluginInfoDialogSections = {}



function storeValue(propertyTable, key, val)
    if key == 'url' then
        propertyTable.immich.url(val)
    elseif key == 'apiKey' then
        propertyTable.immich.apiKey(val)
    end

    prefs[key] = val
end


function PluginInfoDialogSections.sectionsForTopOfDialog(f, propertyTable)
	
    local bind = LrView.bind
	local share = LrView.share

    return {

        {
            bind_to_object = propertyTable,

            title = "Immich Server Connection",

            f:row {
                f:static_text {
                    title = "URL:",
                    alignment = 'right',
                    width = share 'labelWidth'
                },
                f:edit_field {
                    value = bind 'url',
                    truncation = 'middle',
                    immediate = true,
                    width_in_chars = 40,
                    validate = function (v, url) 
                        sanitizedURL = propertyTable.immich:sanityCheckAndFixURL(url)
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
					action = function (button)
						LrTasks.startAsyncTask(function ()
                            if propertyTable.immich then
                                if propertyTable.immich:checkConnectivity() then
                                    LrDialogs.message('Connection test successful')
                                else
                                    LrDialogs.message('Connection test NOT successful')
                                end
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
                },
            },
        },
    }
end


function PluginInfoDialogSections.startDialog(propertyTable)

    if prefs.url == nil then 
        prefs.url = ''
    end

    if prefs.apiKey == nil then
        prefs.apiKey = ''
    end

    propertyTable.url = prefs.url
    propertyTable.apiKey = prefs.apiKey

    propertyTable:addObserver('url', storeValue)
    propertyTable:addObserver('apiKey', storeValue)

    if propertyTable.url and propertyTable.apiKey then
        LrTasks.startAsyncTask(function ()
            propertyTable.immich = ImmichAPI:new(prefs.url, prefs.apiKey)
        end)
    end
end

-- function PluginInfoDialogSections.endDialog(propertyTable)
--     prefs.apiKey = propertyTable.apiKey
--     prefs.url = propertyTable.url
-- end

