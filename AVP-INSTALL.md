# Installing RetroArch on Apple Vision Pro

A native visionOS build of [RetroArch](https://www.retroarch.com), the libretro emulator frontend, with 13 cores built in and a 3D mode that turns NES games into dioramas in your room, in the style of 3dSen. It runs on the headset itself, and every core runs without JIT.

## Requirements

- Apple Vision Pro on visionOS 26 or later
- For the prebuilt app: SideStore on the headset, installed with the [visionOS build of iloader](https://github.com/rebelancap/iloader/releases#release-visionos) from a Mac
- To build from source: macOS with Xcode and the visionOS SDK, and an Apple ID (a free developer account works; sideloaded apps then need re-signing every 7 days)
- Your own games and, for some systems, BIOS files (see Game files)
- About 100 MB to download and 350 MB on the headset
- A Bluetooth game controller that Vision Pro supports (Xbox, PlayStation, Backbone, 8BitDo in Xbox mode). PS VR2 Sense controllers work as the NES Zapper in 3D mode.

## Game files

You need to supply your own game files, legally obtained from a copy you own. This repository and the app contain none, and no BIOS files or 3D profiles.

- Your games, for any of: NES, SNES, Nintendo 64, Game Boy, Game Boy Color, Game Boy Advance, Nintendo DS, Virtual Boy, Genesis / Mega Drive, Master System, Game Gear, Sega CD, PlayStation, PC Engine / TurboGrafx-16, Atari 2600, DOS (a `.zip` or a folder) and arcade (sets matching MAME 0.78).
- Put them anywhere under *On My Apple Vision Pro > RetroArch > RetroArch* in the Files app (a `ROMs/` folder works) and load them from RetroArch's **Load Content**.
- BIOS files go in `RetroArch/system/` with these exact lower-case names. Required: `bios_CD_U.bin`, `bios_CD_E.bin` or `bios_CD_J.bin` for Sega CD, and `syscard3.pce` for PC Engine CD games. Optional: `scph5501.bin`, `scph5500.bin` or `scph5502.bin` (PlayStation), `bios7.bin`, `bios9.bin` and `firmware.bin` (Nintendo DS), `gba_bios.bin` (Game Boy Advance).
- 3D mode needs a 3dSen `.3dn` profile for the game in `RetroArch/system/3dsen/`. Profiles are matched to the game by content, so renamed ROMs still match. Without one, the game stays in the flat window.

## Install the prebuilt app

1. Install SideStore on the headset with the [visionOS build of iloader](https://github.com/rebelancap/iloader/releases#release-visionos). SideStore and AltStore can't be installed on visionOS the usual way.
2. In SideStore, go to *Sources > +*, paste this source and install RetroArch. It updates from this source when new versions ship.

   ```
   https://raw.githubusercontent.com/rebelancap/all-ports/main/apps-visionos.json
   ```

To install by hand instead, download `RetroArch-*-visionOS.ipa` from the [latest release](https://github.com/rebelancap/RetroArch-visionos/releases/latest) and install it through SideStore.

## Build

Start from a checkout of this repository. (The AVP Ports Index gives players a command that clones this repo at the exact commit it scanned, with submodules, so these steps should work from any existing checkout.)

1. `scripts/bootstrap.sh` clones RetroArch and the 13 cores at pinned commits, fetches MoltenVK 1.4.1, and builds ANGLE for visionOS from a sparse checkout of WebKit (about 250 MB).
2. `scripts/apply-overlay.sh` applies this repo's patches on top.
3. `scripts/build-core-xros.sh` builds the cores for the headset.
4. `RA_TEAM=<your team ID> scripts/build-visionos-app.sh` builds and signs `RetroArch.app` into `build-visionos/DerivedData/Build/Products/Release-xros/`. Set `RA_TEAM`: without it the script signs with the developer's own team.

## Install on Apple Vision Pro (from source)

1. Pair the headset with Xcode: on the headset open *Settings > General > Remote Devices*, then pair it from *Window > Devices and Simulators* in Xcode, and turn on Developer Mode on the headset.
2. Install the built app with Xcode's Devices window, or run `scripts/package-visionos-ipa.sh` to make an IPA and install that through SideStore.
3. With a free account, trust your certificate in *Settings > General > VPN & Device Management* before the first launch.

## Controls and known issues

- The controller drives the emulator; gaze and pinch work the menus. The RetroArch menu opens with the usual hotkey combination (*Settings > Input > Hotkeys*).
- In NES 3D mode, tap the **3D** button beside the window. The right stick orbits the camera, the triggers zoom, and clicking the right stick resets the view. Tap **3D** again to return to the flat window.
- Cores can't be downloaded at runtime (a sideloaded app can only load code signed with its own certificate), so new systems arrive with new releases.
- Nintendo 64 runs on an interpreter, so demanding games may not hold full speed. Nintendo DS uses a software renderer, and a few games want the real BIOS.
