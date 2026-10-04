<p align="center">
  <img src="docs/icon.png" width="140" alt="Cream app icon: a white keycap">
</p>

<p align="center">
  <a href="https://github.com/Christianships/Cream/archive/refs/heads/main.zip"><img src="https://img.shields.io/badge/Download-.zip-000000?style=for-the-badge&logo=github&logoColor=white" alt="Download Cream as a .zip"></a>
  <a href="https://github.com/Christianships/Cream/stargazers"><img src="https://img.shields.io/github/stars/Christianships/Cream?style=for-the-badge&logo=github&logoColor=white&color=000000&label=Star" alt="Star Cream on GitHub"></a>
</p>

<h1 align="center">Cream</h1>

<p align="center">Mechanical keyboard and mouse click sounds for your whole Mac.</p>

![Using the Cream settings panel](docs/demo.gif)

## Install

Needs an Apple Silicon Mac on macOS 13+ with the Xcode command line tools
(`xcode-select --install`).

1. Download and unzip this repo.
2. Add sounds. They aren't included, because they're other people's recordings.
   In the unzipped folder, create:
   - `Sounds/nk-cream/` with any [Mechvibes](https://mechvibes.com) keyboard pack's files inside
   - `Sounds/mouse/minecraft_click.mp3`: any short click sound, under that name
3. In the folder, run `./build.sh`. It installs Cream to `~/Applications` and opens it.
4. When macOS asks, turn Cream on under **System Settings → Privacy & Security →
   Input Monitoring**.

## Use

- **Click the keycap** in the menu bar for on/off, volume and **Settings…**
- **Right-click** it to mute everything.
- In Settings, **Add Sounds…** imports more keyboard packs (folder or `.zip`)
  or mouse click files.

**Only modifier keys make a sound?** Cream doesn't have Input Monitoring
permission yet (step 4).

---

<p align="center">⭐ If Cream makes your typing sound better, <a href="https://github.com/Christianships/Cream">star the repo</a>.</p>
