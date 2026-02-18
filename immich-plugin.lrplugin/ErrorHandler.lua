ErrorHandler = {}

function ErrorHandler.handleError(errorMessage, detailedInfo)
    local msg = (type(errorMessage) == "string" and errorMessage ~= "") and errorMessage or "An error occurred."
    local detail = (type(detailedInfo) == "string" and detailedInfo ~= "") and detailedInfo or "No additional details provided."
    if log and log.error then
        log:error("Error: " .. msg)
        log:error("Details: " .. detail)
    end
    ErrorHandler.customErrorDialog(msg, detail)
end


function ErrorHandler.customErrorDialog(errorMessage, detailedInfo)
    local msg = (type(errorMessage) == "string" and errorMessage ~= "") and errorMessage or "An error occurred."
    local detail = (type(detailedInfo) == "string" and detailedInfo ~= "") and detailedInfo or "No additional details provided."
    if not LrView or not LrView.osFactory then
        if LrDialogs and LrDialogs.showError then
            LrDialogs.showError(msg .. "\n\n" .. detail)
        end
        return
    end
    local f = LrView.osFactory()
    local bind = LrView.bind
    local share = LrView.share

    local dialogView = f:column {
        f:row {
            f:static_text {
                title = "Error",
                alignment = 'left',
                font = "<system/bold>",
                width = share "labelWidth",
            },
            f:static_text {
                title = msg,
                alignment = 'left',
                font = "<system/bold>",
            },
        },
        f:row {
            margin_top = 10,
            f:static_text {
                title = "Details",
                alignment = 'left',
                width = share "labelWidth",
            },
            f:static_text {
                title = detail,
                alignment = 'left',
                size = 'small',
            },
        },
    }

    local result = LrDialogs.presentModalDialog({
        title = "Error",
        contents = dialogView,
    })
end