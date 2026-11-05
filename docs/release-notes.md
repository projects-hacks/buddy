## [Download Buddy for Mac](https://github.com/projects-hacks/buddy/releases/latest/download/Buddy.dmg)

**Install in three steps**

1. Open the downloaded **Buddy.dmg** and drag **Buddy** onto **Applications**.
2. Open Buddy from Applications. The first time only, macOS says it can't check the app: click **Done**, then open **System Settings > Privacy & Security**, scroll down and click **Open Anyway**.
3. Follow the setup window: your name, your keys, three permissions.

Already have Buddy 1.2 or 1.3? It offers this update in the notch by itself: click **Update**. On 1.0 or 1.1, download it once and drag it onto Applications, choosing **Replace**. Your keys, memory and permissions stay.

## What's new in 1.4

**Repeat tasks, answered from memory**

When Buddy walks you through something in an app and you reach the end, it now keeps the steps. Ask for the same thing again, in whatever words, "how do I get a PDF of this" after "how do I save this as a PDF", and Buddy walks you through from memory: the same steps, pointing at the same buttons, without asking a model at all, so it is quicker and costs only the voice. It replays only when the request is plainly the same task; something that just sounds like it, "save as PNG" after "save as PDF", gets a fresh answer. If the app has changed since, Buddy notices the missing button and works out that step afresh. The notch says **from memory** while it replays.

**See what you've spent**

Settings now shows **Spent today**, with this month's total and how many questions Buddy answered. It is worked out from what each reply says it used, at the providers' published prices, so there are no surprises on your bill.

**Easier first install**

The download window now shows the three install steps as pictures: drag Buddy to Applications, click **Done** when macOS says it can't check Buddy, then **Open Anyway** in Privacy & Security. No need to find the instructions anywhere else.

**Also in this release**

- **Control + Option + T** has its own sound, three soft key taps, and no longer turns the microphone on or stops an answer that is playing before the chat box opens.
- Buddy points at the right button even when it names it instead of using its place on screen, so fewer arrows go missing.
- A smaller, tighter app: an unused analytics package from the project Buddy grew out of is gone, along with the two permissions it needed, one of them the camera, which Buddy never used.
- Buddy's files on your Mac now live in a folder named Buddy, moved there for you on first launch.

Works on any Mac with macOS 14.2 or later, Apple silicon or Intel. Step-by-step help: [docs/install.md](https://github.com/projects-hacks/buddy/blob/main/docs/install.md).

<sub>For the careful: each update is checked against `Buddy.dmg.sha256` and against the app's signature before it is installed. To check a download by hand, `shasum -a 256 -c Buddy.dmg.sha256` in the folder holding both.</sub>
