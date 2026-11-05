# Error offer

Tests whether the notch offers "explain this error?" for a real error and, more important, never for a near miss. A glow for something that is not an error teaches the student to ignore the glow; a miss only means they ask in words. The recognizer runs on the Mac with no model, so these tests need no keys and capture nothing from the screen.

`fixtures/` holds error outputs that should glow and near misses that should not, one per `###` header naming the place it was read (`terminal`, `editor`, `xcode`, `judgeSite`, `browserDeveloperTools`, or `browser` for a page the watcher never reads) and, where the output names one, the file and line the ring should land on. The positives cover Python tracebacks, Node and browser stack traces, tsc, Java and Kotlin exceptions and compilers, Gradle and Maven, Swift compiler and runtime errors, Xcode, XCTest and Swift Testing, rustc, Rust panics, cargo test, Go panics, builds and tests, C and C++ compilers, the linker, crashes, pytest, unittest, Jest, Vitest, Mocha and judge verdicts. The near misses are source files that raise and catch errors, passing test runs, warnings, logs at INFO and WARN (including stack traces logged on purpose), prose and docs pages about errors, an old traceback scrolled up under newer output, Ctrl+C, a breakpoint, and judge pages that are not a fresh verdict.

```bash
swiftc -O -parse-as-library -o "$TMPDIR/error_offer_test" scripts/error_offer/error_offer_test.swift \
  leanring-buddy/ErrorOffer/ErrorRecognizer.swift leanring-buddy/ErrorOffer/ErrorWindowReading.swift
"$TMPDIR/error_offer_test" grade     # the set the patterns were written against
"$TMPDIR/error_offer_test" fresh     # a set written afterwards
"$TMPDIR/error_offer_test" vision    # the same fixtures drawn as window images and read back
"$TMPDIR/error_offer_test" show scripts/error_offer/fixtures jest_failure   # what recognition reads from one
```

The scorer is built from the app's own recognizer and window-reading files, so what is graded is what ships.

**Results**

| Set | Glows | False glows | Points at the right file and line |
|---|---|---|---|
| Written with the patterns | 57 of 57 | 0 of 55 | 42 of 42 |
| Fresh set, first run | 18 of 20 | 0 of 18 | 14 of 15 |
| Fresh set, after fixing the two formats it missed | 20 of 20 | 0 of 18 | 17 of 17 |

The fresh set's first run is the honest figure. It missed Firefox's console, whose frames have no `at`, and IntelliJ's JUnit view, which puts an Expected and Actual diff between the exception and its first frame; both are now recognized. Two docs pages that contain a real traceback would glow if read, and are not read because the watcher reads a browser only on a judge's page or a separate developer tools window. The same error read again with new timings and addresses never glows twice, and no two distinct errors share a fingerprint.

**Through text recognition** (`vision`), on 2400 x 1600 pixel window images with the error at the bottom under earlier output, on an M4:

| Read | Glows | False glows | CPU per read, median |
|---|---|---|---|
| Whole window, accurate | 57 of 57 | 0 of 53 | 127 ms |
| Whole window, fast | 26 of 57 | 0 of 53 | 23 ms |
| Only the rows that changed, accurate | 56 of 57 | 0 of 53 | 41 ms |

Fast recognition loses half the errors (it drops punctuation that the patterns rely on), so the watcher reads accurately, and only the rows that changed since the trigger. The recognizer itself costs 0.2 ms a check, 2.5 ms on an 80-line window. Waiting for output to settle compares 96 x 60 thumbnails made from 240-pixel window captures: 0.4 ms of CPU for two thumbnails and their comparison, three times a second for the first five seconds after a trigger and once a second after that, for at most 45 seconds after a key and 10 after a click, plus one capture in each pause in typing so a fast error has a true before to compare with. The window server does the capturing and scaling; its share is not measured here. Terminal and iTerm2 are read through their accessibility text instead, with no capture at all; that path needs a live terminal and is not timed here. With no terminal, editor or judge page in front there is no monitor, no timer and no work.

The ring is checked too: the line the turn note names, matched by its words against the whole window as the screen index would read it, lands on the right row for 55 of 57. One of the two is Jest's code frame, which recognition garbles; the note then gives the line's box on the canvas instead. The other matched the same line of code in the editor above the terminal, which is where the note asks for the ring anyway.

**What was learned on the way.** Text recognition drops the short word at the start of an indented line, so `File` in a Python frame and `at` in a Node or Java frame are optional when the rest of the frame has its exact shape. It also puts spaces after dots and colons in code (`Grades. java: 17`), which are repaired before matching. A judge's "Wrong Answer" is the same words on every problem, so its fingerprint includes the failing input under it. Low-severity log lines are checked only for traces, since Maven prints its own `BUILD FAILURE` at INFO level.
