@echo off

if exist immich-export.lrplugin (
    echo Build directory alread exists.
) else (
    echo Creating immich-export.lrplugin
    md immich-export.lrplugin
)

echo Compiling LUA files
cd immich-export.lrdevplugin
for %%a in (*.lua) do luac -o ..\immich-export.lrplugin\%%a %%a
cd ..
