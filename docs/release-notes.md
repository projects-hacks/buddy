Buddy 1.2, for Macs on macOS 14.2 or later, on Apple silicon and Intel.

**Buddy now updates itself.** Once a day it checks for a newer release. When there is one, the open notch says so, with **What's new** and **Update**. Update downloads it, checks it against the published checksum and that it is signed like the copy you have, swaps it in and relaunches, keeping your keys, memory and permissions. Settings has **Check now** and a switch to turn the daily check off.

**Coming from 1.0 or 1.1:** those have no updater, so install this one by hand: download `Buddy-1.2.dmg`, drag Buddy into Applications and replace the old one. Your keys, memory and permissions carry over. Every update after this one arrives in the notch.

**New install:** drag Buddy into Applications and open it. macOS asks once before opening an app that is not notarized: open System Settings > Privacy & Security and click Open Anyway. Full steps in [docs/install.md](https://github.com/projects-hacks/study-buddy/blob/main/docs/install.md).

**Also fixed:** a copy of Buddy opened from somewhere else could take away its open-at-login setting.

Verify the download with the `.sha256` file attached: `shasum -a 256 -c Buddy-1.2.dmg.sha256`.
