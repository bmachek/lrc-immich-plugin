std = "lua54"

-- Lightroom SDK exposes `import` as a global, and the plugin promotes Lr*
-- modules onto `_G` from Init.lua so every other file can use them bare.
globals = {
    "import",
    "JSON",
    "inspect",
    "log",
    "prefs",
    "LrApplication",
    "LrBinding",
    "LrColor",
    "LrDate",
    "LrDialogs",
    "LrErrors",
    "LrFileUtils",
    "LrFunctionContext",
    "LrHttp",
    "LrLogger",
    "LrPathUtils",
    "LrPrefs",
    "LrProgressScope",
    "LrShell",
    "LrSystemInfo",
    "LrTasks",
    "LrView",
    -- Lightroom plugin runtime globals
    "MAC_ENV",
    "WIN_ENV",
    "_PLUGIN",
    -- Plugin's own modules, loaded as side-effect requires from Init.lua / Info.lua
    "AssetStampTask",
    "ErrorHandler",
    "ExportDialogSections",
    "ExportTask",
    "ImmichAPI",
    "ImportDialog",
    "MetadataTask",
    "PluginInfoDialogSections",
    "PublishDialogSections",
    "PublishTask",
    "SharedDialogSections",
    "StackManager",
    "SyncFromImmichTask",
    "UploadHelpers",
    "Util",
}

exclude_files = {
    "immich-plugin.lrplugin/JSON.lua",
    "immich-plugin.lrplugin/inspect.lua",
    ".venv/",
    "lua_env/",
}

-- Lightroom plugin entry-point files return values implicitly via
-- top-level table assignments, and dialog property tables shadow upvalues
-- by design. Relax the noisier checks rather than churning the codebase.
ignore = {
    "212", -- unused argument (common in LR callbacks)
    "213", -- unused loop variable
    "421", -- shadowing a local variable
    "431", -- shadowing an upvalue
    "432", -- shadowing an upvalue argument
    "542", -- empty if branch
}
