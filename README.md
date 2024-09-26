# lrc-immich-plugin

A Lightroom Classic plugin created with Lightroom SDK which uploads images to an Immich Server via the Immich API.
It supports exporting as well as publishing.

## Support my work

[![Donate](https://img.shields.io/badge/Donate-PayPal-green.svg)](https://www.paypal.com/donate/?hosted_button_id=2LL4K9LN5CFA6)

## Installation

Download the current release zip file and extract it to the Lightroom plugin folder, which is:

Mac
    `/Users/$USER/Library/Application Support/Adobe/Lightroom/Modules/`

Windows
    `C:\Users\%USERNAME%\AppData\Roaming\Adobe\Lightroom\Modules`

Alternatively extract it somewhere good an go to Lightroom Module Manager and add it via the GUI.

Either there should be a plugin called "Immich" in the list, one you're finished.

## Features

* Setup connection to your Immich instance via URL and API key in the export dialog, or when creating the publish service.

* Publish images:
    * Create/rename/delete album according to published collection.
    * Upload/update/delete images from the published collection.
    * Download comments and likes from Immich to Lightroom. (If album is a shared album.)

* Export images:
    * Optionally choose or create an album to use on export to Immich.
    * Replace existing images.
    * Duplicate detection via Lightroom catalog ID, and based on date and filename.


* Upcoming features:
    * ~~Set Immich album title image from Lightroom in Published collection.~~
    * (Maybe) Additional album options like sharing in the Published Collection settings dialog.
    * (Maybe) [Your feature](https://github.com/bmachek/lrc-immich-plugin/discussions/16)

## Usage

After you successfully installed the plugin, enter the server url and [API key](https://immich.app/docs/features/command-line-interface#obtain-the-api-key) in your export preset or in your Immich publish service.


## CREDITS

All contributors.

[Jeffrey Friedl for JSON.lua](http://regex.info/blog/lua/json)

[Enrique García Cota for inspect.lua](https://github.com/kikito/inspect.lua)

[Min Idzelis for giving me ideas with his Immich Plugin](https://github.com/midzelis/mi.Immich.Publisher)



