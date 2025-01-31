<p align="center">
    <a href="https://files.lowtechguys.com/IsThereNet.zip"><img width="128" height="128" src="IsThereNet/Assets.xcassets/AppIcon.appiconset/mac256.png" style="filter: drop-shadow(0px 2px 4px rgba(80, 50, 6, 0.2));"></a>
    <h1 align="center"><code style="text-shadow: 0px 3px 10px rgba(8, 0, 6, 0.35); font-size: 3rem; font-family: ui-monospace, Menlo, monospace; font-weight: 800; background: transparent; color: #4d3e56; padding: 0.2rem 0.2rem; border-radius: 6px">IsThereNet</code></h1>
    <h4 align="center" style="padding: 0; margin: 0; font-family: ui-monospace, monospace;">Your internet connection status</h4>
    <h4 align="center" style="padding: 0; margin: 0; font-family: ui-monospace, monospace;">at a glance</h4>
</p>

<p align="center">
    <a href="https://files.lowtechguys.com/releases/IsThereNet.dmg">
        <img width=300 src="https://files.alinpanaitiu.com/download-button-dark.svg">
    </a>
</p>

## Installation

- Download, unzip, move to `/Applications`
- or `brew install --cask istherenet`


## What does this do?

IsThereNet watches for internet connection status changes and draws a colored line at the top of the screen to indicate the status.

Colors:

- 🟢 **Green**: connected *(fades out after 5 seconds)*
- 🔴 **Red**: disconnected *(stays on screen until connection is restored)*
- 🟡 **Yellow**: slow internet *(fades out after 10 seconds)*

The top status line does not appear in screenshots and does not interfere with clicking on the menu bar.

![connected](Resources/connected.png)
![disconnected](Resources/disconnected.png)

## How does it achieve that?

IsThereNet uses the native [NWPathMonitor](https://developer.apple.com/documentation/network/nwpathmonitor) API to efficiently check if a connection can be established to Cloudflare's DNS IP `1.1.1.1`.

That IP was chosen for multiple reasons:

- it should connect to a server that's close to you
- it's a well-known IP that's unlikely to change
- it's unlikely to be blocked by firewalls
- it should not sell your data to advertisers like Google's `8.8.8.8` does


## Uh.. how do I quit this app?

The app has no Dock icon and no menubar icon so to quit it you'd need to do *one of the following*:

- Launch **Activity Monitor**, find **IsThereNet** and press the ❌ button at the top
- Run the following command in the Terminal: `killall 'IsThereNet'`

## Alternatives

If you want to monitor more complex network conditions, you can use a few different alternatives:

- [iStat Menus](https://bjango.com/mac/istatmenus/) which is a paid app but does a lot more than just network monitoring (CPU, RAM, Disk, etc)
- [PeakHour](https://peakhourapp.com/) which is a subscription-based app that does a lot of network monitoring, latency checks, etc

## Logging

IsThereNet logs internet connection status changes to:

- the system log (accessible via Console.app)
- to a file in `~/.logs/istherenet.log`
- to the command line if you run the binary directly

## Config

To keep the no-UI approach, the app can be configured through editing a JSON file. The file is located at:

```sh
~/.config/istherenet/config.json
```

The config file looks like this:

```json
{
  "sounds" : {
    "disconnected" : "Mezzo",
    "slow" : "Submerge",
    "volume" : 0.4,
    "connected" : "Funky"
  },
  "pingIntervalSeconds" : 5,
  "pingIP" : "1.1.1.1",
  "pingSlowThresholdMilliseconds" : 300,
  "fadeSeconds" : {
    "connected" : 5,
    "disconnected" : 0,
    "slow" : 10
  },
  "colors" : {
    "slow" : "systemYellow",
    "connected" : "systemGreen",
    "disconnected" : "systemRed"
  },
  "pingTimeoutSeconds" : 1,
  "screen": "all",
  "launchAtLogin": true,
  "shellCommandOnStatusChange" : "echo 'Status changed to: '$STATUS' with ping time:' $PING_TIME"
}
```
