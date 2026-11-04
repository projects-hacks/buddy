## [Download Buddy for Mac](https://github.com/projects-hacks/study-buddy/releases/latest/download/Buddy.dmg)

**Install in three steps**

1. Open the downloaded **Buddy.dmg** and drag **Buddy** onto **Applications**.
2. Open Buddy from Applications. The first time only, macOS says it can't check the app: click **Done**, then open **System Settings > Privacy & Security**, scroll down and click **Open Anyway**.
3. Follow the setup window: your name, your keys, three permissions.

Already have Buddy 1.0 or 1.1? Do the same once: download, drag onto Applications, and choose **Replace**. Your keys, memory and permissions stay. From this version on, updates arrive by themselves.

**What's new in 1.2**

- **Buddy updates itself.** Once a day it checks for a newer version; the notch says when one is ready, and **Update** installs it in a click, keeping everything you had. Settings has **Check now** and a switch to turn it off.
- A copy of Buddy opened from somewhere else no longer takes away its open-at-login setting.

Works on any Mac with macOS 14.2 or later, Apple silicon or Intel. Step-by-step help: [docs/install.md](https://github.com/projects-hacks/study-buddy/blob/main/docs/install.md).

<sub>For the careful: each update is checked against `Buddy.dmg.sha256` and against the app's signature before it is installed. To check a download by hand, `shasum -a 256 -c Buddy.dmg.sha256` in the folder holding both.</sub>
