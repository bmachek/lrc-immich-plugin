-- Helper functions

util = {}

-- Utility function to check if table contains a value
function util.table_contains(tbl, x)
    found = false
    for _, v in pairs(tbl) do
        if v == x then 
            found = true 
        end
    end
    return found
end


-- Utility function to dump tables as JSON scrambling the API key.
function util.dumpTable(t) 
    local s = inspect(t)
    local pattern = '(field = "x%-api%-key",%s+value = ")%w+(")'
    return s:gsub(pattern, '%1xxx%2')
end


-- Utility function to log errors and throw user errors
function util.handleError(logMsg, userErrorMsg)
    log:error(logMsg)
    LrDialogs.showError(userErrorMsg)
end
