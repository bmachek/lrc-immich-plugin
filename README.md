# lrc-immich-plugin

A Lightroom Classic plugin created with Lightroom SDK which uploads images to an Immich Server via the Immich API.

## Support my work

[![Donate](https://img.shields.io/badge/Donate-PayPal-green.svg)](https://www.paypal.com/donate/?hosted_button_id=2LL4K9LN5CFA6)

## Installation

Download the current release zip file and extract it to the Lightroom plugin folder, which is:

Mac
    `/Users/$USER/Library/Application Support/Adobe/Lightroom/Modules/`

Windows
    `C:\Users\%USERNAME%\AppData\Roaming\Adobe\Lightroom\Modules`

Alternatively extract it somewhere good an go to Lightroom Module Manager and add it via the GUI.

Either there should be a plugin called "Immich upload plugin" in the list, one you're finished.

## Usage

After you successfully installed the plugin, you can create an export preset in Lightroom.

![Screenshot](screenshots/export-preset.png "Screenshot")

Basically you have to set three parameters:

* Set Export To: Immich Upload (in the dropdown at the top)
* Enter the immich http URL where the web frontend is reachable.
* Enter an API for your Immich account. ([This has to be setup in Immich.](https://documentation.immich.app/docs/features/bulk-upload#obtain-the-api-key))

Once you're done entering the details, edit the usual Lightroom export parameters to your need, and save the preset.

## FINISHED

You should be able to export images directly to your Immich server.
If not open an issue, please.


