ErrorHandler = {}

function ErrorHandler.handleError(errorMessage, detailedInfo)
    log:error("Error: " .. errorMessage)
    log:error("Details: " .. (detailedInfo or "No additional details provided."))
    ErrorHandler.customErrorDialog(errorMessage, detailedInfo)
end


function ErrorHandler.customErrorDialog(errorMessage, detailedInfo)
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
                title = errorMessage,
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
                title = detailedInfo or "No additional details provided.",
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