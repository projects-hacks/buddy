## [Download Buddy for Mac](https://github.com/projects-hacks/buddy/releases/latest/download/Buddy.dmg)

**Install in three steps**

1. Open the downloaded **Buddy.dmg** and drag **Buddy** onto **Applications**.
2. Open Buddy from Applications. The first time only, macOS says it can't check the app: click **Done**, then open **System Settings > Privacy & Security**, scroll down and click **Open Anyway**.
3. Follow the setup window: your name, your keys, three permissions.

Already have Buddy 1.2? It offers this update in the notch by itself: click **Update**. On 1.0 or 1.1, download it once and drag it onto Applications, choosing **Replace**. Your keys, memory and permissions stay.

## What's new in 1.3

Two new ways to use Buddy: type instead of talk, and get walked through any app one step at a time.

**Type instead of talk**

Press **Control + Option + T** from any app, or click the chat box in the open notch, type your question and press Return. Shift + Return starts a new line, and Esc puts the box away with your text kept. Buddy answers exactly as it does a spoken question, out loud and drawn on your screen, so it works in a library, a shared room, or when the question is a pasted error message. The chat tab in the notch keeps the whole day's conversation, spoken and typed.

**Learn any app, step by step**

New to an editing app, a design tool, or a settings screen? Ask how to do the thing you want, "how do I export this as a PDF?", and Buddy gives one step at a time: it says what to click and points at the exact button or menu, then waits. Do the step and it notices on its own and says the next one, until the task is done. If you take a wrong turn it tells you how to get back. There is nothing to switch on: Buddy guides whenever the question is a task, and the step it is waiting for shows under the notch. Esc stops it any time.

Watching for your step happens entirely on your Mac and costs nothing. Buddy only looks after you click, type or scroll, and asks the model again only once the screen has changed, which is one ordinary answer, about a cent.

**Also in this release**

- Setup and the notch describe both new features, and the privacy wording says exactly when the screen is captured.
- Opening **Name and API keys** from the notch no longer leaves the setup window hidden behind it.
- An answer that started with a stray sentence before its drawing no longer loses the drawing.

Works on any Mac with macOS 14.2 or later, Apple silicon or Intel. Step-by-step help: [docs/install.md](https://github.com/projects-hacks/buddy/blob/main/docs/install.md).

<sub>For the careful: each update is checked against `Buddy.dmg.sha256` and against the app's signature before it is installed. To check a download by hand, `shasum -a 256 -c Buddy.dmg.sha256` in the folder holding both.</sub>
