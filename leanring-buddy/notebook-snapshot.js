// Notebook snapshot of the drawing board.
//
// Run by NotebookRecorder in its own content world once a lesson's program
// has finished running, so nothing the program defined can replace the
// functions used here. It reads the board's DOM and returns, as JSON:
//
//   cards: each paper(...) card as a standalone SVG document, kept as
//          vectors so the notebook and the PDF print it sharp at any size;
//   marks: the marks drawn on the screen, as an SVG cut to the region they
//          cover, with that region in screenshot pixels, so the app can crop
//          the screenshot to the same region and lay the marks over it.
//
// Why read the DOM instead of asking the engine: the engine draws real SVG
// (rough.js and perfect-freehand both produce paths), so the picture already
// exists as vectors. Exporting it needs no change to the engine. What the
// DOM holds mid-animation is fixed up on the copy: every reveal (a hidden
// mark, a stroke drawn along its dash, words behind a widening clip) is
// written out in its finished state, whatever moment the snapshot is taken.
//
// The copy is also cleaned: the program that drew it is model-written code,
// so anything that is not a drawing (scripts, foreign objects, links,
// external images, event attributes) is removed before it leaves the page.

(function () {
  'use strict';

  const board = document.getElementById('board');
  const cardLayer = document.getElementById('card-layer');
  const screenLayer = document.getElementById('screen-layer');
  if (!board || !cardLayer || !screenLayer) return JSON.stringify({ cards: [], marks: null });
  const definitions = board.querySelector('defs');
  const viewBox = board.viewBox && board.viewBox.baseVal;
  const canvasWidth = viewBox && viewBox.width ? viewBox.width : board.clientWidth;
  const canvasHeight = viewBox && viewBox.height ? viewBox.height : board.clientHeight;

  const elementsThatAreNotDrawings = ['script', 'foreignObject', 'iframe', 'a', 'audio', 'video', 'animate', 'set', 'animateMotion', 'animateTransform'];

  // Paths from rough.js carry long decimals; one decimal place is far below
  // a printed pixel and halves the file.
  function shortenNumbers(text) {
    return String(text).replace(/(-?\d+\.\d)\d+/g, '$1');
  }

  function cleanCopy(root) {
    for (const name of elementsThatAreNotDrawings) {
      for (const element of [...root.querySelectorAll(name)]) element.remove();
    }
    for (const image of [...root.querySelectorAll('image')]) {
      const source = image.getAttribute('href') || image.getAttribute('xlink:href') || '';
      if (!source.startsWith('data:image/')) image.remove();
    }
    const everyElement = [root, ...root.querySelectorAll('*')];
    for (const element of everyElement) {
      for (const attribute of [...element.attributes]) {
        const name = attribute.name.toLowerCase();
        const value = attribute.value;
        if (name.startsWith('on')) { element.removeAttribute(attribute.name); continue; }
        if ((name === 'href' || name === 'xlink:href') && !value.startsWith('#') && !value.startsWith('data:image/')) {
          element.removeAttribute(attribute.name);
          continue;
        }
        // A url() may only point inside the document.
        if (/url\(\s*['"]?(?!#)/i.test(value)) { element.removeAttribute(attribute.name); continue; }
        if (name === 'd' || name === 'points') element.setAttribute(attribute.name, shortenNumbers(value));
      }
      // The finished state of every reveal: visible, strokes fully drawn.
      if (element.style) {
        element.style.removeProperty('visibility');
        element.style.removeProperty('stroke-dasharray');
        element.style.removeProperty('stroke-dashoffset');
        element.style.removeProperty('cursor');
        if (!element.getAttribute('style')) element.removeAttribute('style');
      }
      // Words are written behind a clip that widens as they are said; the
      // finished words need no clip at all.
      const clip = element.getAttribute('clip-path') || '';
      if (clip.includes('#write-clip-')) element.removeAttribute('clip-path');
      element.removeAttribute('class');
      element.removeAttribute('pointer-events');
    }
    return root;
  }

  // The definitions (grid patterns, ink masks, filters) a copy refers to,
  // and the ones those refer to in turn.
  function definitionsUsedBy(root) {
    const wanted = new Set();
    const collect = node => {
      for (const element of [node, ...node.querySelectorAll('*')]) {
        for (const attribute of [...element.attributes]) {
          for (const match of attribute.value.matchAll(/url\(\s*['"]?#([^'")\s]+)/g)) wanted.add(match[1]);
          if ((attribute.name === 'href' || attribute.name === 'xlink:href') && attribute.value.startsWith('#')) wanted.add(attribute.value.slice(1));
        }
      }
    };
    collect(root);
    const container = document.createElementNS('http://www.w3.org/2000/svg', 'defs');
    const added = new Set();
    let grew = true;
    while (grew) {
      grew = false;
      for (const id of [...wanted]) {
        if (added.has(id)) continue;
        const original = definitions && definitions.querySelector(`[id="${CSS.escape(id)}"]`);
        added.add(id);
        if (!original) continue;
        const copy = original.cloneNode(true);
        container.appendChild(copy);
        collect(copy);
        grew = true;
      }
    }
    return cleanCopy(container);
  }

  function standaloneSVG(content, x, y, width, height) {
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('xmlns', 'http://www.w3.org/2000/svg');
    svg.setAttribute('viewBox', `${x.toFixed(1)} ${y.toFixed(1)} ${width.toFixed(1)} ${height.toFixed(1)}`);
    svg.setAttribute('width', width.toFixed(0));
    svg.setAttribute('height', height.toFixed(0));
    svg.appendChild(definitionsUsedBy(content));
    svg.appendChild(content);
    return new XMLSerializer().serializeToString(svg);
  }

  // ---------------------------------------------------------------- cards

  function exportCard(container) {
    const frame = container.firstElementChild;
    const viewport = container.children[1];
    if (!frame || !viewport) return null;
    const rectangles = [...frame.children].filter(child => child.tagName === 'rect');
    // shadow, sheet, grid, title strip: the order paper() builds them in.
    const sheet = rectangles[1];
    if (!sheet) return null;
    const x = +sheet.getAttribute('x'), y = +sheet.getAttribute('y');
    let width = +sheet.getAttribute('width'), height = +sheet.getAttribute('height');
    // The card is made as tall as what was drawn on it: a drawing taller
    // than the screen scrolled inside its card and is kept whole, and paper
    // left empty below the drawing is not worth printing.
    const content = viewport.firstElementChild;
    if (content) {
      try {
        const box = content.getBBox();
        if (box && box.height) {
          const titleBarHeight = 30;
          height = Math.max(titleBarHeight + 60, box.y + box.height + 22 - y);
          width = Math.max(width, box.x + box.width + 22 - x);
        }
      } catch (_) {}
    }
    const titleElement = frame.querySelector('text');
    const title = titleElement ? titleElement.textContent : '';

    const copy = container.cloneNode(true);
    copy.removeAttribute('transform');
    const copiedFrame = copy.firstElementChild;
    const copiedRectangles = [...copiedFrame.children].filter(child => child.tagName === 'rect');
    // The shadow belongs to a window floating over the screen, not to a page.
    if (copiedRectangles[0]) copiedRectangles[0].remove();
    for (const rectangle of copiedRectangles.slice(1, 3)) {
      rectangle.setAttribute('height', height);
      rectangle.setAttribute('width', width);
    }
    if (copiedRectangles[3]) copiedRectangles[3].setAttribute('width', width);
    const close = [...copiedFrame.children].find(child => child.tagName === 'g');
    if (close) close.remove();
    if (titleElement) {
      const copiedTitle = copiedFrame.querySelector('text');
      if (copiedTitle) copiedTitle.setAttribute('x', x + width / 2);
    }
    const copiedViewport = copy.children[1];
    copiedViewport.removeAttribute('clip-path');
    if (copiedViewport.firstElementChild) copiedViewport.firstElementChild.removeAttribute('transform');
    cleanCopy(copy);
    return { svg: standaloneSVG(copy, x, y, width, height), width, height, title };
  }

  // ---------------------------------------------------------------- marks

  // Where a screen mark sits. A spotlight's dimming covers the whole screen,
  // so its region is the hole it leaves, not the dimming.
  function regionOfMark(group) {
    const dimmed = group.querySelector('rect[mask^="url(#spot-"]');
    if (dimmed) {
      const id = /#([^)]+)\)/.exec(dimmed.getAttribute('mask'));
      const mask = id && definitions && definitions.querySelector(`[id="${CSS.escape(id[1])}"]`);
      const hole = mask && mask.querySelectorAll('rect')[1];
      if (!hole) return null;
      return { x: +hole.getAttribute('x'), y: +hole.getAttribute('y'), width: +hole.getAttribute('width'), height: +hole.getAttribute('height') };
    }
    try {
      const box = group.getBBox();
      if (!box || (!box.width && !box.height)) return null;
      return { x: box.x, y: box.y, width: box.width, height: box.height };
    } catch (_) { return null; }
  }

  function exportMarks() {
    const marks = [...screenLayer.children];
    if (!marks.length) return null;
    let left = Infinity, top = Infinity, right = -Infinity, bottom = -Infinity;
    for (const mark of marks) {
      const region = regionOfMark(mark);
      if (!region) continue;
      left = Math.min(left, region.x); top = Math.min(top, region.y);
      right = Math.max(right, region.x + region.width); bottom = Math.max(bottom, region.y + region.height);
    }
    if (!Number.isFinite(left)) return null;
    // Room around the marks for the glow and a little context, then at
    // least a readable patch of screen, never more than the screen.
    const padding = 40;
    left -= padding; top -= padding; right += padding; bottom += padding;
    const minimumWidth = Math.min(canvasWidth, 520), minimumHeight = Math.min(canvasHeight, 300);
    if (right - left < minimumWidth) { const grow = (minimumWidth - (right - left)) / 2; left -= grow; right += grow; }
    if (bottom - top < minimumHeight) { const grow = (minimumHeight - (bottom - top)) / 2; top -= grow; bottom += grow; }
    if (left < 0) { right -= left; left = 0; }
    if (top < 0) { bottom -= top; top = 0; }
    if (right > canvasWidth) { left = Math.max(0, left - (right - canvasWidth)); right = canvasWidth; }
    if (bottom > canvasHeight) { top = Math.max(0, top - (bottom - canvasHeight)); bottom = canvasHeight; }
    const width = right - left, height = bottom - top;
    if (width < 4 || height < 4) return null;

    const copy = screenLayer.cloneNode(true);
    // Marks follow the page when it scrolls; the screenshot does not move,
    // so the marks go back to where they were drawn on it.
    copy.removeAttribute('transform');
    copy.removeAttribute('id');
    cleanCopy(copy);
    return { svg: standaloneSVG(copy, left, top, width, height), region: [left, top, width, height] };
  }

  const cards = [...cardLayer.querySelectorAll(':scope > g.card')].map(exportCard).filter(Boolean);
  return JSON.stringify({ cards, marks: exportMarks(), canvas: [canvasWidth, canvasHeight] });
})();
