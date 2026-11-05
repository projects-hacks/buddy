# Notebook sample

Renders a sample notebook without running Buddy, capturing the screen or drawing on it, so the pages and the PDF can be looked at after any change to their layout.

Four fixture lessons (three drawn, one answered in prose, one long enough to run over several printed pages) are drawn by the real drawing engine in a web view that never joins a window, over a made-up screenshot of a code editor, given at the canvas's pixels and at twice them as a Retina display's own. The shipped `notebook-snapshot.js` reads the board back, `NotebookScreenCropMaker` makes the screen crops, `NotebookStore` writes the pages, and `NotebookPDFExporter` makes an A4 PDF of everything and a US Letter PDF of one day. Every PDF page, and each day as the Notebook window shows it, is rendered to PNG.

```bash
swiftc -O -o build/notebook-sample-runner scripts/notebook/main.swift \
  leanring-buddy/Notebook/NotebookStore.swift leanring-buddy/Notebook/NotebookDocumentHTML.swift \
  leanring-buddy/Notebook/NotebookCapture.swift leanring-buddy/Notebook/NotebookPDFExporter.swift \
  leanring-buddy/App/AppIdentity.swift
build/notebook-sample-runner "$(pwd)" "$(pwd)/build/notebook-sample"
open build/notebook-sample/png
```

It prints each page's size on disk and runs checks the pictures cannot show: a card's SVG keeps its drawing and loses scripts, external images, foreign objects, links and event attributes; unplayed reveals are written out finished; sentences are read out of `say(...)` with their escapes, one paragraph per beat; the paper size follows the region; and a page, a day and the whole notebook delete, with a half-written page never shown.

**Sizes on the sample** (a 1440 by 900 point display, its crop cut from 2880 by 1800 pixels): drawn lessons 92 to 146 KB a page, of which the card SVG is 9 to 35 KB and the screen crop JPEG 82 to 109 KB (1041 by 601 to 1600 by 640 pixels); the prose answer 1.1 KB. Cut from the 1440 by 900 canvas, as before the crop used the display's own pixels, the crops were 27 to 37 KB at 521 by 301 to 818 by 327.
