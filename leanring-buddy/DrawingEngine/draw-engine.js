// Clicky Local drawing engine.
//
// The tutor answers with a small program: beats of `say("...")` sentences,
// each followed by the marks drawn while that sentence is spoken. This file
// runs that program and draws it by hand.
//
// Why a program and not tags: a fixed tag vocabulary caps the picture at
// whatever layouts were written in advance. A program can put several cards
// anywhere, draw any shape inside them, and loop to draw a row of cells, which
// is what a real explanation of a DP table or a request path needs.
//
// Timing model. Marks are built the moment their code runs, invisible. Each
// one belongs to the sentence most recently said before it. When the app
// starts speaking a sentence it calls playLine(id, seconds), and that
// sentence's marks are drawn across its duration. The voice never waits for
// the pen: finishLine() completes whatever is still drawing when a sentence
// ends.
//
// Coordinates are the screenshot's pixels, x right and y down. The SVG's
// viewBox is the screenshot's size and fills the screen, so a mark at the
// pixel where text sits in the image lands on that text on screen.
//
// Runs in a page with no network access (see the content security policy in
// the page and the navigation policy in DrawingOverlay.swift). The only way
// out is the `clicky` message handler, which carries buttons, a lesson title
// and errors back to the app.

(function () {
  'use strict';

  const SVG_NS = 'http://www.w3.org/2000/svg';

  // Colour names the program may use. Cards are ink on paper; screen marks
  // default to the cursor's blue so "the tutor marked this" reads at a glance.
  const TONES = {
    ink: '#2B2D33', grey: '#7D828C', blue: '#2F6FEB', sky: '#6FB1F7',
    mint: '#7CD3A0', green: '#2E9D5B', red: '#E5484D', coral: '#F07A6E',
    orange: '#F59A3C', butter: '#FFD95A', yellow: '#FFD95A', lilac: '#A897F5',
    purple: '#7A5CE0', pink: '#F59AB5', white: '#FFFFFF', paper: '#FBF7EE'
  };
  const tone = (name, fallback) => TONES[name] || (typeof name === 'string' && name.startsWith('#') ? name : fallback);

  const HAND_FONT = '"Noteworthy", "Bradley Hand", "Chalkboard SE", cursive';

  const state = {
    svg: null, screenLayer: null, cardLayer: null, defs: null,
    canvasWidth: 1280, canvasHeight: 800,
    targets: {},                 // id -> [x, y, w, h] in canvas pixels
    screenInk: '#2F6FEB',
    unitsPerPoint: 1,            // canvas pixels per screen point, for sizing pens
    lines: [],                   // {id, text, marks: [], startedAt, duration, finished}
    // The voice can start or finish a sentence before the code that says it
    // has streamed in. Those signals wait here for the sentence to exist.
    pendingStarts: {}, pendingFinishes: {},
    currentLineIndex: -1,        // the line new marks attach to; -1 = before any say
    preludeMarks: [],            // marks drawn before the program's first say
    buttons: [], lessonTitle: null, errors: [],
    roughSvg: null, seed: 1,
    scrollOffset: 0,
    markCount: 0,
    cards: []                    // {x, y, w, h, sheets: [rect elements that grow with it]}
  };

  // The bottom of the screen holds the caption and its buttons, so cards keep
  // clear of it. In screen points, converted to canvas pixels where used.
  const BOTTOM_RESERVE_POINTS = 80;
  // The notch panel hangs from the top with the sentence being said.
  const TOP_RESERVE_POINTS = 96;
  const topLimit = () => TOP_RESERVE_POINTS * state.unitsPerPoint;
  const EDGE = 16;
  const bottomLimit = () => state.canvasHeight - BOTTOM_RESERVE_POINTS * state.unitsPerPoint;

  // ------------------------------------------------------------------ set up

  function setup(options) {
    state.canvasWidth = options.canvasWidth || 1280;
    state.canvasHeight = options.canvasHeight || 800;
    state.targets = options.targets || {};
    state.screenInk = options.screenInk || state.screenInk;
    state.unitsPerPoint = options.unitsPerPoint || 1;

    const svg = document.getElementById('board');
    svg.setAttribute('viewBox', `0 0 ${state.canvasWidth} ${state.canvasHeight}`);
    svg.setAttribute('preserveAspectRatio', 'none');
    state.svg = svg;
    state.defs = svg.querySelector('defs');
    state.screenLayer = document.getElementById('screen-layer');
    state.cardLayer = document.getElementById('card-layer');
    state.roughSvg = rough.svg(svg);
    // Programs refer to the canvas size by name, as numbers.
    window.W = state.canvasWidth;
    window.H = state.canvasHeight;
    resetTurn();
  }

  // A new answer: forget its lines and buttons. What is drawn stays until the
  // app clears it, so a follow-up can build on the last picture.
  function resetTurn() {
    state.lines = [];
    state.pendingStarts = {};
    state.pendingFinishes = {};
    state.currentLineIndex = -1;
    state.preludeMarks = [];
    state.buttons = [];
    state.lessonTitle = null;
    state.errors = [];
  }

  function clearAll() {
    state.cards = [];
    state.pillRects = [];
    reportCards();
    for (const layer of [state.screenLayer, state.cardLayer]) {
      while (layer && layer.firstChild) layer.removeChild(layer.firstChild);
    }
    state.scrollOffset = 0;
    if (state.screenLayer) state.screenLayer.removeAttribute('transform');
    resetTurn();
  }

  function clearScreenMarks() {
    state.pillRects = [];
    const layer = state.screenLayer;
    while (layer && layer.firstChild) layer.removeChild(layer.firstChild);
    state.scrollOffset = 0;
    if (layer) layer.removeAttribute('transform');
  }

  // Screen marks move with the page; cards are windows of their own and stay.
  function scrollScreenMarks(deltaInPoints) {
    state.scrollOffset += deltaInPoints * state.unitsPerPoint;
    state.screenLayer.setAttribute('transform', `translate(0 ${state.scrollOffset})`);
  }

  // ------------------------------------------------------- running a program

  // Runs one piece of the answer as it streams in. `const` and `let` become
  // `var` so a card declared in one piece can be used by the next, and so a
  // later answer can reuse a name without a redeclaration error.
  function run(code) {
    const linesBefore = state.lines.length;
    const buttonsBefore = state.buttons.length;
    const errorsBefore = state.errors.length;
    const marksBefore = state.markCount;
    const source = String(code).replace(/\b(const|let)\s+/g, 'var ');
    try {
      (0, eval)(source);
    } catch (error) {
      state.errors.push(String(error && error.message || error));
    }
    return {
      newLines: state.lines.slice(linesBefore).map(line => ({ id: line.id, text: line.text })),
      newButtons: state.buttons.slice(buttonsBefore),
      lessonTitle: state.lessonTitle,
      newErrors: state.errors.slice(errorsBefore),
      newMarks: state.markCount - marksBefore
    };
  }

  // -------------------------------------------------------- speech and pacing

  function say(text) {
    const line = { id: state.lines.length, text: String(text), marks: [], startedAt: null, duration: null, finished: false };
    // Anything drawn before the first sentence belongs with it.
    if (state.lines.length === 0 && state.preludeMarks.length) {
      line.marks.push(...state.preludeMarks);
      state.preludeMarks = [];
    }
    state.lines.push(line);
    state.currentLineIndex = line.id;
    const pending = state.pendingStarts[line.id];
    if (pending) {
      line.startedAt = pending.startedAt;
      line.duration = pending.duration;
      delete state.pendingStarts[line.id];
    }
    if (state.pendingFinishes[line.id]) {
      line.finished = true;
      delete state.pendingFinishes[line.id];
    }
  }

  function step() { /* beats are a reading aid for the model; the engine paces by sentence */ }

  function attachMark(mark) {
    state.markCount += 1;
    const line = state.lines[state.currentLineIndex];
    if (!line) { state.preludeMarks.push(mark); return; }
    line.marks.push(mark);
    // Already said: draw at once. Being said: draw in the time that is left.
    if (line.finished) revealNow(mark);
    else if (line.startedAt !== null) scheduleLine(line);
  }

  function playLine(id, seconds) {
    const line = state.lines[id];
    if (!line) { state.pendingStarts[id] = { startedAt: performance.now(), duration: Math.max(0.6, seconds) }; return; }
    line.startedAt = performance.now();
    line.duration = Math.max(0.6, seconds);
    scheduleLine(line);
  }

  // The real length arrives once the audio has downloaded. Marks not yet
  // started are re-spread across what is left.
  function updateLineDuration(id, seconds) {
    const line = state.lines[id];
    if (!line) { if (state.pendingStarts[id]) state.pendingStarts[id].duration = Math.max(0.6, seconds); return; }
    if (line.startedAt === null) return;
    line.duration = Math.max(0.6, seconds);
    scheduleLine(line);
  }

  function finishLine(id) {
    const line = state.lines[id];
    if (!line) { state.pendingFinishes[id] = true; delete state.pendingStarts[id]; return; }
    line.finished = true;
    for (const mark of line.marks) revealNow(mark);
  }

  function finishAll() {
    for (const line of state.lines) finishLine(line.id);
    for (const mark of state.preludeMarks) revealNow(mark);
    state.preludeMarks = [];
  }

  // Spreads a sentence's waiting marks across the time left in it. Each mark
  // keeps its natural drawing speed when there is room, and is sped up when
  // there is not, so a busy sentence still finishes with the voice.
  function scheduleLine(line) {
    const waiting = line.marks.filter(mark => mark.state === 'waiting');
    if (!waiting.length) return;
    const elapsed = (performance.now() - line.startedAt) / 1000;
    const remaining = Math.max(0.5, line.duration * 0.92 - elapsed);
    const natural = waiting.reduce((sum, mark) => sum + mark.naturalSeconds, 0);
    const speed = Math.min(1, remaining / Math.max(natural, 0.001));
    const slack = Math.max(0, remaining - natural * speed);
    const gap = waiting.length > 1 ? slack / waiting.length : 0;
    let clock = 0;
    for (const mark of waiting) {
      const seconds = mark.naturalSeconds * speed;
      startReveal(mark, clock, seconds);
      clock += seconds + gap;
    }
  }

  // --------------------------------------------------------------- reveals

  // Every mark is a group with a reveal function. Strokes draw along their
  // length, words write left to right, washes and cards fade in.
  function makeMark(group, naturalSeconds, reveal) {
    group.style.visibility = 'hidden';
    if (state.cards.some(card => card.content === group.parentNode)) growCardToFit(group);
    const mark = { group, naturalSeconds, reveal, state: 'waiting', animations: [] };
    attachMark(mark);
    return mark;
  }

  function startReveal(mark, delaySeconds, durationSeconds) {
    if (mark.state !== 'waiting') return;
    mark.state = 'drawing';
    const begin = () => {
      if (mark.state === 'done') return;
      mark.group.style.visibility = 'visible';
      mark.animations = mark.reveal(Math.max(0.12, durationSeconds)) || [];
      const last = mark.animations[mark.animations.length - 1];
      if (last) last.onfinish = () => { mark.state = 'done'; };
      else mark.state = 'done';
    };
    if (delaySeconds <= 0.01) begin(); else mark.timer = setTimeout(begin, delaySeconds * 1000);
  }

  function revealNow(mark) {
    if (mark.state === 'done') return;
    if (mark.timer) clearTimeout(mark.timer);
    if (mark.state === 'waiting') {
      mark.state = 'drawing';
      mark.group.style.visibility = 'visible';
      mark.animations = mark.reveal(0.25) || [];
    }
    for (const animation of mark.animations) { try { animation.finish(); } catch (_) {} }
    mark.state = 'done';
  }

  // Draws each path of a group along its length, one after another.
  function strokeReveal(group) {
    return seconds => {
      const paths = [...group.querySelectorAll('path')].filter(path => path.getAttribute('stroke') && path.getAttribute('stroke') !== 'none');
      const lengths = paths.map(path => { try { return path.getTotalLength(); } catch (_) { return 0; } });
      const total = lengths.reduce((a, b) => a + b, 0) || 1;
      let offset = 0;
      const animations = [];
      paths.forEach((path, index) => {
        const length = lengths[index] || 1;
        const share = seconds * (length / total);
        path.style.strokeDasharray = `${length} ${length}`;
        path.style.strokeDashoffset = `${length}`;
        animations.push(path.animate(
          [{ strokeDashoffset: length }, { strokeDashoffset: 0 }],
          { duration: share * 1000, delay: offset * 1000, fill: 'forwards', easing: 'ease-in-out' }
        ));
        offset += share;
      });
      // Fills under the strokes fade in as the outline closes.
      [...group.querySelectorAll('path')].filter(path => !paths.includes(path)).forEach(fill => {
        animations.unshift(fill.animate([{ opacity: 0 }, { opacity: 1 }], { duration: seconds * 1000, fill: 'forwards' }));
      });
      return animations;
    };
  }

  // A tapered ink stroke is a filled outline, so it is revealed by a mask
  // that strokes along its centre line.
  function inkReveal(group, maskPath) {
    return seconds => {
      let length = 1;
      try { length = maskPath.getTotalLength() || 1; } catch (_) {}
      maskPath.style.strokeDasharray = `${length} ${length}`;
      return [maskPath.animate(
        [{ strokeDashoffset: length }, { strokeDashoffset: 0 }],
        { duration: seconds * 1000, fill: 'forwards', easing: 'ease-in-out' }
      )];
    };
  }

  // Words are written left to right behind a widening clip.
  function writeReveal(group, clipRect, fullWidth) {
    return seconds => [clipRect.animate(
      [{ width: '0px' }, { width: `${fullWidth + 20}px` }],
      { duration: seconds * 1000, fill: 'forwards', easing: 'linear' }
    )];
  }

  function fadeReveal(group) {
    return seconds => [group.animate(
      [{ opacity: 0, transform: 'translateY(4px)' }, { opacity: 1, transform: 'translateY(0)' }],
      { duration: seconds * 1000, fill: 'forwards', easing: 'ease-out' }
    )];
  }

  // A card that something was drawn past is made taller to hold it, up to
  // the bottom limit. Programs underestimate how much room a heading takes.
  // Past the limit the content is clipped, and scrolls inside the card.
  function growCardToFit(group) {
    const card = state.cards.find(candidate => candidate.content === group.parentNode);
    if (!card) return;
    let box;
    try { box = group.getBBox(); } catch (_) { return; }
    if (!box || !box.height) return;
    // Wider too: a row of boxes planned a little too wide was cut off at
    // the card's right edge. The card grows to the screen's edge at most.
    const right = box.x + box.width + 22;
    if (right > card.x + card.w) {
      const newWidth = Math.min(right - card.x, state.canvasWidth - EDGE - card.x);
      if (newWidth > card.w) {
        const grownBy = newWidth - card.w;
        card.w = newWidth;
        card.widened += grownBy;
        for (const sheet of card.sheets) sheet.setAttribute('width', card.w);
        card.strip.setAttribute('width', card.w);
        card.clip.setAttribute('width', card.w);
        if (card.title) card.title.setAttribute('x', card.x + card.w / 2);
        card.closeButton.setAttribute('transform', `translate(${card.widened} 0)`);
        reportCards();
      }
    }
    const bottom = box.y + box.height + 18;
    card.contentBottom = Math.max(card.contentBottom, bottom);
    const needed = bottom - card.y;
    if (needed > card.h) {
      card.h = Math.min(needed, bottomLimit() - card.y);
      for (const sheet of card.sheets) sheet.setAttribute('height', card.h);
      card.clip.setAttribute('height', card.h - card.headerHeight);
      reportCards();
    }
  }

  // ------------------------------------------------------- touching a card
  //
  // The overlay is click-through everywhere except over a card, where the
  // app lets the mouse in (it is told where the cards are below). A card can
  // then be closed with its x, dragged by its title bar, and scrolled when
  // its drawing is taller than the screen allows.

  /// Where the cards are, in canvas pixels, for the app to let the mouse in.
  function reportCards() {
    const rects = state.cards.map(card => [card.x + card.dx, card.y + card.dy, card.w, card.h]);
    try { window.webkit.messageHandlers.clicky.postMessage({ type: 'cards', rects }); } catch (_) {}
  }

  function closeCard(card) {
    card.container.remove();
    state.cards = state.cards.filter(candidate => candidate !== card);
    reportCards();
  }

  function scrollCard(card, delta) {
    const room = Math.max(0, card.contentBottom - (card.y + card.h) + 12);
    card.scroll = Math.max(0, Math.min(room, card.scroll + delta));
    card.content.setAttribute('transform', `translate(0 ${-card.scroll})`);
  }

  /// Screen pixels to canvas pixels, since the canvas is stretched to fit.
  function canvasDelta(dxPixels, dyPixels) {
    const matrix = state.svg.getScreenCTM();
    return matrix ? [dxPixels / matrix.a, dyPixels / matrix.d] : [dxPixels, dyPixels];
  }

  function makeCardInteractive(card, titleStrip, closeButton) {
    closeButton.addEventListener('mousedown', event => { event.stopPropagation(); event.preventDefault(); closeCard(card); });
    titleStrip.addEventListener('mousedown', event => {
      event.preventDefault();
      const startX = event.clientX, startY = event.clientY, startDx = card.dx, startDy = card.dy;
      const move = moveEvent => {
        const [dx, dy] = canvasDelta(moveEvent.clientX - startX, moveEvent.clientY - startY);
        card.dx = startDx + dx;
        card.dy = startDy + dy;
        card.container.setAttribute('transform', `translate(${card.dx} ${card.dy})`);
      };
      const up = () => {
        window.removeEventListener('mousemove', move);
        window.removeEventListener('mouseup', up);
        reportCards();
      };
      window.addEventListener('mousemove', move);
      window.addEventListener('mouseup', up);
    });
    card.container.addEventListener('wheel', event => {
      event.preventDefault();
      scrollCard(card, canvasDelta(0, event.deltaY)[1]);
    }, { passive: false });
  }

  const clampX = (x, width) => Math.max(EDGE, Math.min(x, state.canvasWidth - EDGE - width));

  // ------------------------------------------------------------- primitives

  const nextSeed = () => (state.seed = (state.seed * 16807) % 2147483647);
  const svgElement = (name, attributes = {}) => {
    const element = document.createElementNS(SVG_NS, name);
    for (const [key, value] of Object.entries(attributes)) element.setAttribute(key, value);
    return element;
  };
  const penWidth = points => points * state.unitsPerPoint;
  let uniqueId = 0;

  // A target is an id from the screen listing or explicit numbers.
  function rectOf(args) {
    if (typeof args[0] === 'string') {
      const rect = state.targets[args[0]];
      if (!rect) { state.errors.push(`unknown target ${args[0]}`); return null; }
      return { x: rect[0], y: rect[1], w: rect[2], h: rect[3], rest: args.slice(1) };
    }
    const [x, y, w = 0, h = 0] = args.map(Number);
    if (![x, y].every(Number.isFinite)) { state.errors.push('a mark needs numbers or a target id'); return null; }
    return { x, y, w, h, rest: args.slice(4) };
  }
  const centreOf = target => {
    if (Array.isArray(target)) return { x: target[0], y: target[1] };
    if (typeof target === 'string' && state.targets[target]) {
      const [x, y, w, h] = state.targets[target];
      return { x: x + w / 2, y: y + h / 2, rect: { x, y, w, h } };
    }
    if (target && typeof target === 'object' && 'x' in target) return { x: target.x + (target.w || 0) / 2, y: target.y + (target.h || 0) / 2 };
    return null;
  };

  // Hand pen: a smooth tapered stroke through the points.
  function inkStroke(layer, points, options = {}) {
    const colour = tone(options.tone, state.screenInk);
    const size = penWidth(options.size || 4);
    const outline = perfectFreehand.getStroke(points, {
      size, thinning: 0.55, smoothing: 0.6, streamline: 0.45,
      simulatePressure: true, start: { taper: size * 3 }, end: { taper: size * 4 }
    });
    const group = svgElement('g');
    const maskId = `ink-mask-${++uniqueId}`;
    const mask = svgElement('mask', { id: maskId, maskUnits: 'userSpaceOnUse' });
    const centreLine = svgElement('path', {
      d: smoothPath(points), fill: 'none', stroke: '#fff',
      'stroke-width': size * 3, 'stroke-linecap': 'round', 'stroke-linejoin': 'round'
    });
    mask.appendChild(centreLine);
    state.defs.appendChild(mask);
    const body = svgElement('path', { d: outlinePath(outline), fill: colour, mask: `url(#${maskId})` });
    if (options.glow !== false && layer === state.screenLayer) {
      body.setAttribute('filter', 'url(#ink-glow)');
    }
    group.appendChild(body);
    layer.appendChild(group);
    const length = polylineLength(points);
    return makeMark(group, Math.min(1.4, 0.25 + length / (900 * state.unitsPerPoint)), inkReveal(group, centreLine));
  }

  function outlinePath(points) {
    if (!points.length) return '';
    const [first, ...rest] = points;
    return `M ${first[0]} ${first[1]} ` + rest.map(p => `L ${p[0]} ${p[1]}`).join(' ') + ' Z';
  }
  function smoothPath(points) {
    if (points.length < 2) return '';
    let d = `M ${points[0][0]} ${points[0][1]}`;
    for (let i = 1; i < points.length; i++) d += ` L ${points[i][0]} ${points[i][1]}`;
    return d;
  }
  function polylineLength(points) {
    let total = 0;
    for (let i = 1; i < points.length; i++) total += Math.hypot(points[i][0] - points[i - 1][0], points[i][1] - points[i - 1][1]);
    return total;
  }

  // Rough.js shape added to a layer, drawn along its outline.
  // A dashed outline fades in: drawing it on with a dash-offset animation
  // would overwrite its own dash pattern and leave it solid.
  function roughShape(layer, node, naturalSeconds, dashed = false) {
    const group = svgElement('g');
    group.appendChild(node);
    layer.appendChild(group);
    return makeMark(group, naturalSeconds, dashed ? fadeReveal(group) : strokeReveal(group));
  }

  function roughOptions(options, defaults = {}) {
    const fillName = options.fill;
    const fillColour = fillName ? tone(fillName, null) : undefined;
    return Object.assign({
      seed: nextSeed(), roughness: 1.1, bowing: 0.8,
      stroke: tone(options.tone, TONES.ink), strokeWidth: penWidth(options.size || 1.8),
      fill: fillColour ? hexWithAlpha(fillColour, options.fillAlpha != null ? options.fillAlpha : 0.32) : undefined,
      fillStyle: options.hatch ? 'hachure' : 'solid',
      hachureGap: penWidth(6),
      strokeLineDash: options.dashed ? [penWidth(7), penWidth(6)] : undefined
    }, defaults);
  }
  function hexWithAlpha(hex, alpha) {
    const match = /^#?([0-9a-f]{6})$/i.exec(hex);
    if (!match) return hex;
    const n = parseInt(match[1], 16);
    return `rgba(${n >> 16}, ${(n >> 8) & 255}, ${n & 255}, ${alpha})`;
  }

  function writeText(layer, x, y, words, options = {}) {
    const size = (options.size || 18);
    const group = svgElement('g');
    const clipId = `write-clip-${++uniqueId}`;
    const clip = svgElement('clipPath', { id: clipId });
    const clipRect = svgElement('rect', { x: 0, y: -10000, width: 0, height: 20000 });
    clip.appendChild(clipRect);
    state.defs.appendChild(clip);
    const text = svgElement('text', {
      x, y, 'font-size': size, fill: tone(options.tone, layer === state.screenLayer ? state.screenInk : TONES.ink),
      'font-family': HAND_FONT, 'font-weight': options.bold ? 700 : 400,
      'text-anchor': options.anchor === 'middle' ? 'middle' : options.anchor === 'end' ? 'end' : 'start',
      'clip-path': `url(#${clipId})`
    });
    text.textContent = String(words);
    group.appendChild(text);
    layer.appendChild(group);
    let width = String(words).length * size * 0.5;
    try { width = text.getBBox().width || width; } catch (_) {}
    let left = x;
    if (options.anchor === 'middle') left = x - width / 2;
    if (options.anchor === 'end') left = x - width;
    clipRect.setAttribute('x', left - 10);
    const seconds = Math.min(1.6, 0.2 + String(words).length * 0.035);
    return makeMark(group, seconds, writeReveal(group, clipRect, width));
  }

  // ------------------------------------------------------- the program's API

  const api = {
    step, say,

    // ---- on the real screen, in the cursor's ink

    ring(...args) {
      const target = rectOf(args); if (!target) return;
      const padX = Math.max(8, target.h * 0.45), padY = Math.max(6, target.h * 0.35);
      const cx = target.x + target.w / 2, cy = target.y + target.h / 2;
      const rx = target.w / 2 + padX, ry = target.h / 2 + padY;
      const points = [];
      const turns = 1.08, start = -2.2 + Math.random() * 0.4;
      for (let i = 0; i <= 48; i++) {
        const angle = start + (i / 48) * Math.PI * 2 * turns;
        const wobble = 1 + Math.sin(i * 0.9) * 0.025;
        points.push([cx + Math.cos(angle) * rx * wobble, cy + Math.sin(angle) * ry * wobble]);
      }
      const mark = inkStroke(state.screenLayer, points);
      const label = target.rest[0];
      if (typeof label === 'string' && label) api.label(target.x + target.w + padX + 6, cy - 12, label);
      return mark;
    },

    underline(...args) {
      const target = rectOf(args); if (!target) return;
      // From a listing id the line goes under the box; from numbers, y is
      // already the bottom of the letters and the third number is the width.
      const fromId = typeof args[0] === 'string';
      const y = fromId ? target.y + target.h + 3 : target.y + 3;
      const width = fromId ? target.w : (target.w || 80);
      const points = [];
      for (let i = 0; i <= 12; i++) points.push([target.x + (width * i) / 12, y + Math.sin(i * 0.8) * 0.9]);
      return inkStroke(state.screenLayer, points, { size: 3.6 });
    },

    strike(...args) {
      const target = rectOf(args); if (!target) return;
      const fromId = typeof args[0] === 'string';
      const y = fromId ? target.y + target.h / 2 : target.y;
      const width = fromId ? target.w : (target.w || 80);
      return inkStroke(state.screenLayer, [[target.x - 3, y + 1], [target.x + width / 2, y - 1], [target.x + width + 3, y]], { size: 3.4, tone: 'red' });
    },

    highlight(...args) {
      const target = rectOf(args); if (!target) return;
      const node = svgElement('rect', {
        x: target.x - 3, y: target.y - 2, width: target.w + 6, height: target.h + 4, rx: 3,
        fill: hexWithAlpha(TONES.butter, 0.38)
      });
      const group = svgElement('g'); group.appendChild(node); state.screenLayer.appendChild(group);
      // A highlighter is swept left to right.
      const clipId = `hl-${++uniqueId}`;
      const clip = svgElement('clipPath', { id: clipId });
      const clipRect = svgElement('rect', { x: target.x - 4, y: target.y - 4, width: 0, height: target.h + 8 });
      clip.appendChild(clipRect); state.defs.appendChild(clip);
      node.setAttribute('clip-path', `url(#${clipId})`);
      return makeMark(group, 0.5, writeReveal(group, clipRect, target.w + 8));
    },

    frame(...args) {
      const target = rectOf(args); if (!target) return;
      const pad = 6;
      const node = state.roughSvg.rectangle(target.x - pad, target.y - pad, target.w + pad * 2, target.h + pad * 2, roughOptions({ tone: state.screenInk }, {
        stroke: state.screenInk, strokeWidth: penWidth(2.2), roughness: 0.9,
        fill: hexWithAlpha(state.screenInk, 0.07), fillStyle: 'solid',
        strokeLineDash: [penWidth(9), penWidth(6)]
      }));
      return roughShape(state.screenLayer, node, 0.7);
    },

    num(...args) {
      let x, y, n;
      if (typeof args[0] === 'string') {
        const target = rectOf(args); if (!target) return;
        x = target.x - 16; y = target.y + target.h / 2; n = args[1];
      } else { [x, y, n] = args; }
      const radius = 12 * state.unitsPerPoint;
      const group = svgElement('g');
      group.appendChild(svgElement('circle', { cx: x, cy: y, r: radius, fill: state.screenInk }));
      const label = svgElement('text', {
        x, y: y + radius * 0.38, 'text-anchor': 'middle', 'font-size': radius * 1.15,
        'font-family': '-apple-system, "SF Pro Rounded", sans-serif', 'font-weight': 700, fill: '#fff'
      });
      label.textContent = String(n);
      group.appendChild(label);
      state.screenLayer.appendChild(group);
      return makeMark(group, 0.3, popReveal(group, x, y));
    },

    check(x, y) {
      const s = 18 * state.unitsPerPoint;
      return inkStroke(currentLayerFor(x, y), [[x - s * 0.6, y], [x - s * 0.15, y + s * 0.5], [x + s * 0.7, y - s * 0.6]], { tone: 'green', size: 4.2 });
    },

    cross(x, y) {
      const s = 15 * state.unitsPerPoint;
      const layer = currentLayerFor(x, y);
      inkStroke(layer, [[x - s / 2, y - s / 2], [x + s / 2, y + s / 2]], { tone: 'red', size: 4 });
      return inkStroke(layer, [[x + s / 2, y - s / 2], [x - s / 2, y + s / 2]], { tone: 'red', size: 4 });
    },

    // A curved arrow from one thing to another: ids, [x, y] points, or card boxes.
    connect(from, to, options = {}) {
      const a = centreOf(from), b = centreOf(to);
      if (!a || !b) { state.errors.push('connect needs two targets'); return; }
      const start = edgePoint(a, b), end = edgePoint(b, a);
      const bend = options.bend != null ? options.bend : 0.2;
      const mx = (start.x + end.x) / 2, my = (start.y + end.y) / 2;
      const dx = end.x - start.x, dy = end.y - start.y;
      const control = { x: mx - dy * bend, y: my + dx * bend };
      const points = [];
      for (let i = 0; i <= 24; i++) {
        const t = i / 24;
        points.push([
          (1 - t) * (1 - t) * start.x + 2 * (1 - t) * t * control.x + t * t * end.x,
          (1 - t) * (1 - t) * start.y + 2 * (1 - t) * t * control.y + t * t * end.y
        ]);
      }
      const layer = options.onCard ? cardLayerFor(start.x, start.y) : state.screenLayer;
      const mark = inkStroke(layer, points, { size: 3.2, tone: options.tone });
      arrowHead(layer, points, options.tone);
      if (options.label) api.label(control.x + 6, control.y - 10, options.label);
      return mark;
    },

    point(...args) {
      const target = rectOf(args); if (!target) return;
      const fromRight = target.x < 220 * state.unitsPerPoint;
      const tip = { x: fromRight ? target.x + target.w + 4 : target.x - 4, y: target.y + target.h / 2 };
      const tail = { x: tip.x + (fromRight ? 70 : -70) * state.unitsPerPoint, y: tip.y - 40 * state.unitsPerPoint };
      const points = [];
      for (let i = 0; i <= 12; i++) {
        const t = i / 12;
        points.push([tail.x + (tip.x - tail.x) * t, tail.y + (tip.y - tail.y) * t - Math.sin(t * Math.PI) * 10]);
      }
      inkStroke(state.screenLayer, points, { size: 2.8 });
      arrowHead(state.screenLayer, points);
      const name = target.rest[0];
      if (typeof name === 'string' && name) {
        api.label(fromRight ? tail.x + 10 : tail.x - 10, tail.y - 26 * state.unitsPerPoint, name, { anchor: fromRight ? 'start' : 'end' });
      }
    },

    // A name pill in the cursor's colour.
    label(x, y, words, options = {}) {
      const size = 14 * state.unitsPerPoint;
      const group = svgElement('g');
      const text = svgElement('text', {
        x: 0, y: 0, 'font-size': size, 'font-family': '-apple-system, "SF Pro Rounded", sans-serif',
        'font-weight': 600, fill: '#fff'
      });
      text.textContent = String(words);
      group.appendChild(text);
      state.screenLayer.appendChild(group);
      let width = String(words).length * size * 0.55;
      try { width = text.getBBox().width; } catch (_) {}
      const padX = 9 * state.unitsPerPoint, height = size * 1.7;
      const pillWidth = width + padX * 2;
      // A pill never lands on another: tried where asked, then just below,
      // above, and further out, keeping the first spot that is free. Labels
      // stacked on each other were the clutter people noticed first.
      const askedLeft = clampX(options.anchor === 'end' ? x - pillWidth : x, pillWidth);
      const gap = 4 * state.unitsPerPoint, step = height + gap;
      const overlaps = (left, top) => (state.pillRects || []).some(r =>
        left < r.x + r.w + gap && left + pillWidth + gap > r.x && top < r.y + r.h + gap && top + height + gap > r.y);
      let left = askedLeft, top = y;
      for (const dy of [0, step, -step, 2 * step, -2 * step, 3 * step]) {
        if (!overlaps(askedLeft, y + dy)) { left = askedLeft; top = y + dy; break; }
        const shifted = clampX(askedLeft + pillWidth * 0.6, pillWidth);
        if (!overlaps(shifted, y + dy)) { left = shifted; top = y + dy; break; }
      }
      (state.pillRects = state.pillRects || []).push({ x: left, y: top, w: pillWidth, h: height });
      const pill = svgElement('rect', { x: left, y: top, width: pillWidth, height, rx: height / 2, fill: state.screenInk });
      group.insertBefore(pill, text);
      text.setAttribute('x', left + padX);
      text.setAttribute('y', top + height * 0.68);
      return makeMark(group, 0.3, fadeReveal(group));
    },

    spotlight(...args) {
      const target = rectOf(args); if (!target) return;
      const pad = 10;
      const group = svgElement('g');
      const maskId = `spot-${++uniqueId}`;
      const mask = svgElement('mask', { id: maskId });
      mask.appendChild(svgElement('rect', { x: 0, y: 0, width: state.canvasWidth, height: state.canvasHeight, fill: '#fff' }));
      mask.appendChild(svgElement('rect', { x: target.x - pad, y: target.y - pad, width: target.w + pad * 2, height: target.h + pad * 2, rx: 12, fill: '#000' }));
      state.defs.appendChild(mask);
      group.appendChild(svgElement('rect', { x: -2000, y: -2000, width: state.canvasWidth + 4000, height: state.canvasHeight + 4000, fill: 'rgba(8,10,16,0.55)', mask: `url(#${maskId})` }));
      state.screenLayer.insertBefore(group, state.screenLayer.firstChild);
      return makeMark(group, 0.5, fadeReveal(group));
    },

    // ---- cards: windows on calm space with their own drawing

    paper(x, y, w, h, options = {}) {
      w = Math.min(w, state.canvasWidth - EDGE * 2);
      h = Math.min(h, bottomLimit() - topLimit() - EDGE);
      x = clampX(x, w);
      y = Math.max(topLimit(), Math.min(y, bottomLimit() - h));
      const container = svgElement('g', { class: 'card' });
      const frame = svgElement('g');
      const radius = 14;
      const headerHeight = 30;
      const shadow = svgElement('rect', {
        x: x + 3, y: y + 8, width: w, height: h, rx: radius, fill: 'rgba(0,0,0,0.28)', filter: 'url(#card-shadow)'
      });
      const sheet = svgElement('rect', { x, y, width: w, height: h, rx: radius, fill: TONES.paper });
      frame.appendChild(shadow);
      frame.appendChild(sheet);
      // Faint grid, like squared paper.
      const gridId = `grid-${++uniqueId}`;
      const pattern = svgElement('pattern', { id: gridId, width: 24, height: 24, patternUnits: 'userSpaceOnUse', x, y });
      pattern.appendChild(svgElement('path', { d: 'M 24 0 L 0 0 0 24', fill: 'none', stroke: 'rgba(60,80,120,0.08)', 'stroke-width': 1 }));
      state.defs.appendChild(pattern);
      const grid = svgElement('rect', { x, y, width: w, height: h, rx: radius, fill: `url(#${gridId})` });
      frame.appendChild(grid);

      // Title bar: the handle to drag the card by, and its close button.
      const strip = svgElement('rect', { x, y, width: w, height: headerHeight, rx: radius, fill: 'rgba(0,0,0,0.045)', class: 'card-handle' });
      frame.appendChild(strip);
      let title = null;
      if (options.title) {
        title = svgElement('text', {
          x: x + w / 2, y: y + 20, 'text-anchor': 'middle', 'font-size': 13,
          'font-family': '-apple-system, sans-serif', 'font-weight': 600, fill: TONES.grey, 'pointer-events': 'none'
        });
        title.textContent = String(options.title);
        frame.appendChild(title);
      }
      const closeButton = svgElement('g', { class: 'card-close' });
      closeButton.appendChild(svgElement('circle', { cx: x + w - 18, cy: y + 15, r: 9, fill: 'rgba(0,0,0,0.08)' }));
      closeButton.appendChild(svgElement('path', {
        d: `M ${x + w - 21.5} ${y + 11.5} L ${x + w - 14.5} ${y + 18.5} M ${x + w - 14.5} ${y + 11.5} L ${x + w - 21.5} ${y + 18.5}`,
        stroke: TONES.grey, 'stroke-width': 1.8, 'stroke-linecap': 'round', fill: 'none'
      }));
      frame.appendChild(closeButton);
      container.appendChild(frame);

      // The drawing area, clipped so a long drawing scrolls instead of
      // spilling off the card.
      const clipId = `card-clip-${++uniqueId}`;
      const clipPath = svgElement('clipPath', { id: clipId });
      const clip = svgElement('rect', { x, y: y + headerHeight, width: w, height: h - headerHeight });
      clipPath.appendChild(clip);
      state.defs.appendChild(clipPath);
      const viewport = svgElement('g', { 'clip-path': `url(#${clipId})` });
      const content = svgElement('g');
      viewport.appendChild(content);
      container.appendChild(viewport);
      state.cardLayer.appendChild(container);

      const card = { x, y, w, h, dx: 0, dy: 0, scroll: 0, headerHeight, contentBottom: y + h,
                     container, content, clip, sheets: [shadow, sheet, grid], strip, title, closeButton, widened: 0 };
      state.cards.push(card);
      makeCardInteractive(card, strip, closeButton);
      makeMark(container, 0.35, fadeReveal(frame));
      reportCards();

      let top = y + 42;
      if (options.heading) {
        writeText(content, x + 22, top + 24, options.heading, { size: 26, bold: true });
        top += 46;
      }
      if (options.subtitle) {
        writeText(content, x + 22, top + 14, options.subtitle, { size: 16, tone: 'grey' });
        top += 30;
      }
      return { x: x + 22, y: top + 10, w: w - 44, h: Math.max(40, y + h - top - 28) };
    },

    rect(x, y, w, h, options = {}) {
      const node = state.roughSvg.rectangle(x, y, w, h, roughOptions(options));
      const layer = cardLayerFor(x, y);
      const mark = roughShape(layer, node, 0.55, !!options.dashed);
      if (options.label) writeText(layer, x + w / 2, y + h / 2 + (options.size || 17) * 0.35, options.label, { size: options.labelSize || 17, anchor: 'middle' });
      return { x, y, w, h, mark };
    },

    circle(cx, cy, r, options = {}) {
      const node = state.roughSvg.circle(cx, cy, r * 2, roughOptions(options));
      const layer = cardLayerFor(cx, cy);
      roughShape(layer, node, 0.5);
      if (options.label) writeText(layer, cx, cy + 6, options.label, { size: 16, anchor: 'middle' });
      return { x: cx - r, y: cy - r, w: r * 2, h: r * 2 };
    },

    line(points, options = {}) {
      if (!Array.isArray(points) || points.length < 2) return;
      const node = points.length === 2
        ? state.roughSvg.line(points[0][0], points[0][1], points[1][0], points[1][1], roughOptions(options))
        : state.roughSvg.linearPath(points, roughOptions(options));
      return roughShape(currentLayerFor(points[0][0], points[0][1]), node, 0.4, !!options.dashed);
    },

    arrow(points, options = {}) {
      if (!Array.isArray(points) || points.length < 2) return;
      const layer = currentLayerFor(points[0][0], points[0][1]);
      const node = options.curve
        ? state.roughSvg.curve(points, roughOptions(options))
        : state.roughSvg.linearPath(points, roughOptions(options));
      roughShape(layer, node, 0.45);
      arrowHead(layer, points, options.tone, true);
      if (options.label) {
        const mid = points[Math.floor(points.length / 2)] || points[0];
        const prev = points[Math.max(0, Math.floor(points.length / 2) - 1)];
        writeText(layer, (mid[0] + prev[0]) / 2 + 8, (mid[1] + prev[1]) / 2 - 6, options.label, { size: 15, tone: 'grey' });
      }
    },

    path(d, options = {}) {
      const node = state.roughSvg.path(String(d), roughOptions(options));
      // A path is placed by its first point, the M in its data.
      const start = /M\s*(-?[\d.]+)[\s,]+(-?[\d.]+)/i.exec(String(d));
      const layer = start ? cardLayerFor(+start[1], +start[2]) : state.cardLayer;
      return roughShape(layer, node, 0.8);
    },

    text(x, y, words, options = {}) {
      return writeText(currentLayerFor(x, y), x, y, words, options);
    },

    write(x, y, words, options = {}) { return api.text(x, y, words, options); },

    sticky(x, y, words, colour = 'butter') {
      const w = 190, lines = wrapWords(String(words), 22), h = 26 + lines.length * 24;
      const group = svgElement('g', { transform: `rotate(${(Math.random() - 0.5) * 3} ${x + w / 2} ${y + h / 2})` });
      group.appendChild(svgElement('rect', { x: x + 2, y: y + 5, width: w, height: h, fill: 'rgba(0,0,0,0.18)', filter: 'url(#card-shadow)' }));
      group.appendChild(svgElement('rect', { x, y, width: w, height: h, fill: tone(colour, TONES.butter) }));
      lines.forEach((text, index) => {
        const node = svgElement('text', { x: x + 14, y: y + 30 + index * 24, 'font-size': 18, 'font-family': HAND_FONT, fill: TONES.ink });
        node.textContent = text;
        group.appendChild(node);
      });
      cardLayerFor(x, y).appendChild(group);
      return makeMark(group, 0.4, fadeReveal(group));
    },

    // A component the student's own design could use, drawn dashed and in
    // purple beside their diagram, so it reads as a proposal, not a
    // correction. On the screen, so it scrolls with their canvas.
    suggest(x, y, w, h, words, options = {}) {
      const node = state.roughSvg.rectangle(x, y, w, h, roughOptions(Object.assign(
        { tone: 'purple', fill: 'lilac', fillAlpha: 0.16, dashed: true }, options)));
      const layer = currentLayerFor(x, y);
      const mark = roughShape(layer, node, 0.6, true);
      if (words) writeText(layer, x + w / 2, y + h / 2 + 6, words, { size: 17, anchor: 'middle', tone: 'purple' });
      return { x, y, w, h, mark };
    },

    // ---- what the app does with the answer

    // A follow-up the student can tap. {ask: "..."} asks it as their next
    // question; {copy: "..."} puts text on the clipboard.
    button(words, action = {}) {
      if (typeof words !== 'string') {
        // Accept the other common shape, button(x, y, words, action).
        if (typeof action === 'object' && typeof arguments[2] === 'string') { words = arguments[2]; action = arguments[3] || {}; }
        else return;
      }
      state.buttons.push({ title: words, ask: action.ask || null, copy: action.copy || null });
    },

    lessonTitle(words) { state.lessonTitle = String(words); },
    clear() { clearAll(); },
    // Read by the app from the program text, for the practice hint ladder.
    hintLevel() {},
    // Read by the app from the program text: guide mode's step to watch for.
    waitForStep() {},
    seen() {}, plan() {}, task() {}, waitForUser() {},

    // Constants and small helpers a drawing program reaches for.
    range: n => Array.from({ length: Math.max(0, n | 0) }, (_, i) => i),
    target: id => {
      const rect = state.targets[id];
      return rect ? { x: rect[0], y: rect[1], w: rect[2], h: rect[3] } : null;
    }
  };

  // Marks a program places inside a card belong to that card, so they stay
  // put when the screen scrolls, and move, scroll and close with the card.
  // Coordinates are the program's own, from before any drag.
  function cardAt(x, y) {
    for (let index = state.cards.length - 1; index >= 0; index--) {
      const card = state.cards[index];
      if (x >= card.x && x <= card.x + card.w && y >= card.y && y <= card.y + card.h + 400) return card;
    }
    return null;
  }

  // Pen marks: on a card if they are on one, otherwise on the screen.
  function currentLayerFor(x, y) {
    const card = cardAt(x, y);
    return card ? card.content : state.screenLayer;
  }

  // Shapes that only make sense on paper: on the card under them, or loose
  // on the card layer when a program draws one on calm space without a card.
  function cardLayerFor(x, y) {
    const card = cardAt(x, y);
    return card ? card.content : state.cardLayer;
  }

  function popReveal(group, x, y) {
    return seconds => [group.animate(
      [{ transform: `translate(${x}px, ${y}px) scale(0.2) translate(${-x}px, ${-y}px)`, opacity: 0 },
       { transform: `translate(${x}px, ${y}px) scale(1.12) translate(${-x}px, ${-y}px)`, opacity: 1, offset: 0.7 },
       { transform: 'none', opacity: 1 }],
      { duration: seconds * 1000, fill: 'forwards', easing: 'ease-out' }
    )];
  }

  function arrowHead(layer, points, toneName, rough) {
    const end = points[points.length - 1];
    const before = points[Math.max(0, points.length - 3)];
    const angle = Math.atan2(end[1] - before[1], end[0] - before[0]);
    const size = 11 * state.unitsPerPoint;
    const left = [end[0] - Math.cos(angle - 0.45) * size, end[1] - Math.sin(angle - 0.45) * size];
    const right = [end[0] - Math.cos(angle + 0.45) * size, end[1] - Math.sin(angle + 0.45) * size];
    if (rough) {
      const node = state.roughSvg.linearPath([left, end, right], roughOptions({ tone: toneName }));
      return roughShape(layer, node, 0.15);
    }
    return inkStroke(layer, [left, end, right], { size: 2.6, tone: toneName });
  }

  function edgePoint(from, towards) {
    if (!from.rect) return from;
    const { x, y, w, h } = from.rect;
    const dx = towards.x - from.x, dy = towards.y - from.y;
    const scale = Math.min(Math.abs((w / 2 + 6) / (dx || 1e-6)), Math.abs((h / 2 + 6) / (dy || 1e-6)));
    return { x: from.x + dx * Math.min(1, scale), y: from.y + dy * Math.min(1, scale) };
  }

  function wrapWords(words, width) {
    const lines = []; let current = '';
    for (const word of words.split(/\s+/)) {
      if ((current + ' ' + word).trim().length > width) { if (current) lines.push(current); current = word; }
      else current = (current + ' ' + word).trim();
    }
    if (current) lines.push(current);
    return lines.slice(0, 6);
  }

  // The program sees the API as plain globals.
  Object.assign(window, api, { PI: Math.PI, min: Math.min, max: Math.max, abs: Math.abs, round: Math.round, floor: Math.floor, sqrt: Math.sqrt, sin: Math.sin, cos: Math.cos });

  window.ClickyEngine = {
    setup, run, playLine, updateLineDuration, finishLine, finishAll,
    clearAll, clearScreenMarks, scrollScreenMarks, resetTurn,
    lineCount: () => state.lines.length
  };
})();
