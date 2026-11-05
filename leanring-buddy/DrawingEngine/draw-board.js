// Buddy teaching board.
//
// The whole display becomes paper and a lesson is drawn on it over several
// turns, like a teacher's whiteboard. This file only draws. What is on the
// board and where it goes is decided on the Mac (BoardState.swift,
// BoardLayout.swift, TeachingBoard.swift): the model's `board.box(...)`
// calls are read there and replaced, before the program runs here, by
// `BuddyBoard.apply([...])` carrying exact strokes in board units.
//
// Every stroke is made with draw-engine.js's own pen (BuddyEngine.boardKit),
// so the board has the cards' hand-drawn look, and every stroke is a mark of
// the sentence before it, so it is drawn while that sentence is spoken.
//
// Layers, bottom to top: the paper with its dot grid; the title and the
// current part; the "Today's board" card; the board world (groups, arrows,
// elements, highlight rings) under one transform that the view zooms and
// scrolls, clipped to the drawing area; and the dark bottom bar, the
// board's one control, in the notch's own language rather than on paper.

(function () {
  'use strict';

  const kit = () => window.BuddyEngine.boardKit;
  const UI_FONT = '-apple-system, "SF Pro Text", "Helvetica Neue", sans-serif';

  const board = {
    layer: null, world: null, groupLayer: null, linkLayer: null, elementLayer: null, highlightLayer: null,
    titleLayer: null, titleGroup: null, partLineGroup: null, partsCardLayer: null, barLayer: null,
    content: { x: 0, y: 0, w: 0, h: 0 }, titleOrigin: [56, 112], partsCard: [0, 0, 280], barBand: [0, 44],
    elements: {},   // id -> { group, textGroup, drawnX, drawnY, offsetX, offsetY }
    links: {},      // id -> group
    highlights: [],
    worldTransform: 'translate(0px, 0px) scale(1)',
    isSpeaking: false
  };

  // A mark that draws nothing itself and runs `action` when its turn in the
  // sentence comes: a move, a zoom, a removal.
  function actionMark(naturalSeconds, action) {
    const placeholder = kit().svgElement('g');
    board.layer.appendChild(placeholder);
    return kit().makeMark(placeholder, naturalSeconds, seconds => action(seconds) || []);
  }

  function fadeAwayAndRemove(node, seconds) {
    if (!node) return [];
    const animation = node.animate([{ opacity: 1 }, { opacity: 0 }], { duration: seconds * 1000, fill: 'forwards', easing: 'ease-out' });
    animation.finished.then(() => node.remove()).catch(() => node.remove());
    return [animation];
  }

  function textWidth(node, fallbackCharacters, size) {
    try { return node.getBBox().width || fallbackCharacters * size * 0.55; } catch (_) { return fallbackCharacters * size * 0.55; }
  }

  // ------------------------------------------------------------- open, close

  // options, in canvas pixels: { paper: [x, y, w, h], content: [x, y, w, h],
  // title: [x, y], partsCard: [x, y, w], bar: [y, h] }
  function open(options) {
    removeNow();
    const engineState = kit().state();
    const svgElement = kit().svgElement;
    const [paperX, paperY, paperW, paperH] = options.paper;
    const [contentX, contentY, contentW, contentH] = options.content;
    board.content = { x: contentX, y: contentY, w: contentW, h: contentH };
    board.titleOrigin = options.title || [contentX, contentY - 80];
    board.partsCard = options.partsCard || [paperX + paperW - 336, contentY, 280];
    board.barBand = options.bar || [paperY + paperH - 68, 44];

    const layer = svgElement('g', { id: 'board-layer' });
    // The board takes the mouse while it is open (DrawingOverlay), and only
    // the bar's controls react to it.
    layer.style.pointerEvents = 'none';
    // The whole display is paper: nothing from the desktop shows, so there
    // is never any doubt which surface a click or a question is about.
    layer.appendChild(svgElement('rect', { x: paperX - 10, y: paperY - 10, width: paperW + 20, height: paperH + 20, fill: kit().TONES.paper }));
    const gridId = 'board-grid';
    const oldPattern = document.getElementById(gridId);
    if (oldPattern) oldPattern.remove();
    const pattern = svgElement('pattern', { id: gridId, width: 22, height: 22, patternUnits: 'userSpaceOnUse', x: 0, y: 0 });
    pattern.appendChild(svgElement('circle', { cx: 11, cy: 11, r: 1.1, fill: 'rgba(60, 70, 90, 0.20)' }));
    engineState.defs.appendChild(pattern);
    layer.appendChild(svgElement('rect', { x: paperX, y: paperY, width: paperW, height: paperH, fill: `url(#${gridId})` }));

    board.titleLayer = svgElement('g');
    layer.appendChild(board.titleLayer);
    board.partsCardLayer = svgElement('g');
    layer.appendChild(board.partsCardLayer);

    const clipId = 'board-clip';
    const oldClip = document.getElementById(clipId);
    if (oldClip) oldClip.remove();
    const clipPath = svgElement('clipPath', { id: clipId });
    clipPath.appendChild(svgElement('rect', { x: contentX - 24, y: contentY - 14, width: contentW + 48, height: contentH + 28 }));
    engineState.defs.appendChild(clipPath);
    const viewport = svgElement('g', { 'clip-path': `url(#${clipId})` });
    const world = svgElement('g');
    world.style.transformOrigin = '0 0';
    board.groupLayer = svgElement('g');
    board.linkLayer = svgElement('g');
    board.elementLayer = svgElement('g');
    board.highlightLayer = svgElement('g');
    for (const sublayer of [board.groupLayer, board.linkLayer, board.elementLayer, board.highlightLayer]) world.appendChild(sublayer);
    viewport.appendChild(world);
    layer.appendChild(viewport);
    board.world = world;

    board.barLayer = svgElement('g');
    layer.appendChild(board.barLayer);

    engineState.svg.insertBefore(layer, engineState.cardLayer);
    board.layer = layer;
    setWorldTransform({ scale: 1, scrolledDownBy: 0, horizontalInset: 0 }, 0);
    setParts({ parts: [], current: -1 });
    layer.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 450, easing: 'ease-out' });

    // The bar comes back to full strength whenever the pointer moves.
    window.addEventListener('mousemove', restoreBar);
  }

  function close(seconds) {
    const layer = board.layer;
    if (!layer) return;
    reset();
    const animation = layer.animate([{ opacity: 1 }, { opacity: 0 }], { duration: (seconds || 0.6) * 1000, fill: 'forwards', easing: 'ease-in' });
    animation.finished.then(() => layer.remove()).catch(() => layer.remove());
  }

  function removeNow() {
    if (board.layer) board.layer.remove();
    reset();
  }

  function reset() {
    window.removeEventListener('mousemove', restoreBar);
    board.layer = null;
    board.world = null;
    board.elements = {};
    board.links = {};
    board.highlights = [];
    board.titleGroup = null;
    board.partLineGroup = null;
  }

  // ------------------------------------------------- parts, title and bar

  // { parts: ["why hash mod n breaks", "servers on a ring"], current: 1 }:
  // the parts of the lesson so far, one per turn, the current one last.
  function setParts(partsUpdate) {
    const parts = partsUpdate.parts || [];
    const current = partsUpdate.current != null ? partsUpdate.current : parts.length - 1;
    board.parts = parts;
    board.currentPart = current;
    drawPartLine();
    drawPartsCard();
    drawBar();
  }

  // Under the title: which part this is, in the hand, grey.
  function drawPartLine() {
    if (board.partLineGroup) board.partLineGroup.remove();
    const group = kit().svgElement('g');
    board.titleLayer.appendChild(group);
    board.partLineGroup = group;
    const part = board.parts[board.currentPart];
    if (!part) return;
    const text = kit().svgElement('text', {
      x: board.titleOrigin[0], y: board.titleOrigin[1] + 40, 'font-size': 26, 'font-family': kit().HAND_FONT,
      fill: kit().TONES.grey
    });
    text.textContent = `Part ${board.currentPart + 1}: ${part}`;
    group.appendChild(text);
  }

  // "Today's board": every part so far, done ones struck through in green,
  // the current one in blue. Paper, not a control: it takes no clicks.
  function drawPartsCard() {
    const layer = board.partsCardLayer;
    while (layer.firstChild) layer.removeChild(layer.firstChild);
    if (!board.parts.length) return;
    const svgElement = kit().svgElement;
    const [x, y, width] = board.partsCard;
    const rowHeight = 40;
    const height = 76 + board.parts.length * rowHeight;
    layer.appendChild(svgElement('rect', { x: x + 2, y: y + 6, width, height, rx: 10, fill: 'rgba(0,0,0,0.12)', filter: 'url(#card-shadow)' }));
    layer.appendChild(svgElement('rect', { x, y, width, height, rx: 10, fill: '#FFFFFF' }));
    const heading = svgElement('text', { x: x + 24, y: y + 46, 'font-size': 28, 'font-family': kit().HAND_FONT, 'font-weight': 700, fill: kit().TONES.ink });
    heading.textContent = 'Today’s board';
    layer.appendChild(heading);
    board.parts.forEach((part, index) => {
      const isDone = index < board.currentPart, isCurrent = index === board.currentPart;
      const colour = isDone ? kit().TONES.green : isCurrent ? kit().TONES.blue : kit().TONES.grey;
      const baseline = y + 76 + index * rowHeight + 22;
      const row = svgElement('text', { x: x + 24, y: baseline, 'font-size': 23, 'font-family': kit().HAND_FONT,
                                       'font-weight': isCurrent ? 700 : 400, fill: colour });
      let words = `${index + 1}  ${part}`;
      const longest = isCurrent ? 17 : 23;
      if (words.length > longest) words = words.slice(0, longest - 1).trimEnd() + '\u2026';
      row.textContent = isCurrent ? `${words}  ← now` : words;
      layer.appendChild(row);
      if (isDone) {
        const width = textWidth(row, words.length, 23);
        layer.appendChild(svgElement('line', { x1: x + 22, y1: baseline - 7, x2: x + 26 + width, y2: baseline - 7,
                                               stroke: colour, 'stroke-width': 1.6 }));
      }
    });
  }

  // One dark capsule, bottom centre: the part, how to ask, how to leave.
  function drawBar() {
    const layer = board.barLayer;
    while (layer.firstChild) layer.removeChild(layer.firstChild);
    const svgElement = kit().svgElement;
    const [barTop, barHeight] = board.barBand;
    const middle = barTop + barHeight / 2;
    const capsule = svgElement('rect', { x: 0, y: barTop, width: 10, height: barHeight, rx: barHeight / 2, fill: 'rgba(0,0,0,0.86)' });
    layer.appendChild(capsule);
    let cursor = 22;
    const pieces = [];
    function label(words, options = {}) {
      const node = svgElement('text', { x: cursor, y: middle + 5, 'font-size': 14, 'font-family': UI_FONT,
                                        'font-weight': options.bold ? 600 : 400,
                                        fill: options.dim ? 'rgba(255,255,255,0.55)' : 'rgba(255,255,255,0.92)' });
      node.textContent = words;
      layer.appendChild(node);
      pieces.push(node);
      cursor += textWidth(node, words.length, 14) + (options.gap != null ? options.gap : 10);
      return node;
    }
    function separator() {
      layer.appendChild(svgElement('line', { x1: cursor + 4, y1: middle - 12, x2: cursor + 4, y2: middle + 12, stroke: 'rgba(255,255,255,0.18)', 'stroke-width': 1 }));
      pieces.push(null);
      cursor += 22;
    }
    function keycap(glyph) {
      const cap = svgElement('rect', { x: cursor, y: middle - 11, width: 22, height: 22, rx: 5, fill: 'none', stroke: 'rgba(255,255,255,0.45)', 'stroke-width': 1 });
      layer.appendChild(cap);
      const node = svgElement('text', { x: cursor + 11, y: middle + 5, 'text-anchor': 'middle', 'font-size': 13, 'font-family': UI_FONT, fill: 'rgba(255,255,255,0.92)' });
      node.textContent = glyph;
      layer.appendChild(node);
      cursor += 28;
    }
    const partCount = board.parts ? board.parts.length : 0;
    label(partCount ? `Part ${board.currentPart + 1}` : 'Starting', { bold: true, gap: 14 });
    separator();
    label('Hold', { gap: 8 });
    keycap('⌃');
    keycap('⌥');
    label('to ask about it', { gap: 14 });
    separator();
    // Leave board: a real button, pointer cursor and a hover wash, in the
    // notch's own button style.
    const button = svgElement('g', { class: 'board-leave', cursor: 'pointer' });
    button.style.pointerEvents = 'auto';
    button.style.cursor = 'pointer';
    const buttonStart = cursor - 8;
    const wash = svgElement('rect', { x: buttonStart, y: middle - 15, width: 10, height: 30, rx: 15, fill: 'rgba(255,255,255,0.10)' });
    button.appendChild(wash);
    const buttonLabel = svgElement('text', { x: cursor + 6, y: middle + 5, 'font-size': 14, 'font-family': UI_FONT, 'font-weight': 600, fill: 'rgba(255,255,255,0.95)' });
    buttonLabel.textContent = 'Leave board';
    button.appendChild(buttonLabel);
    layer.appendChild(button);
    const leaveWidth = textWidth(buttonLabel, 11, 14);
    const escape = svgElement('text', { x: cursor + 6 + leaveWidth + 8, y: middle + 5, 'font-size': 13, 'font-family': UI_FONT, fill: 'rgba(255,255,255,0.5)' });
    escape.textContent = 'esc';
    button.appendChild(escape);
    const escapeWidth = textWidth(escape, 3, 13);
    wash.setAttribute('width', leaveWidth + escapeWidth + 34);
    cursor += leaveWidth + escapeWidth + 34;
    button.addEventListener('mouseenter', () => wash.setAttribute('fill', 'rgba(255,255,255,0.20)'));
    button.addEventListener('mouseleave', () => wash.setAttribute('fill', 'rgba(255,255,255,0.10)'));
    button.addEventListener('mousedown', event => {
      event.preventDefault();
      try { window.webkit.messageHandlers.clicky.postMessage({ type: 'leaveBoard' }); } catch (_) {}
    });

    // Centre the capsule on the screen, sized to what it holds.
    const barWidth = cursor + 10;
    const canvasWidth = kit().state().canvasWidth;
    const left = (canvasWidth - barWidth) / 2;
    capsule.setAttribute('width', barWidth);
    layer.setAttribute('transform', `translate(${left} 0)`);
    layer.style.opacity = board.isSpeaking ? '0.4' : '1';
  }

  // While Buddy speaks the bar steps back to 40%, and returns on any pointer
  // movement or when the turn is over.
  function setSpeaking(isSpeaking) {
    board.isSpeaking = !!isSpeaking;
    if (board.barLayer) board.barLayer.style.opacity = board.isSpeaking ? '0.4' : '1';
  }

  function restoreBar() {
    if (board.barLayer) board.barLayer.style.opacity = '1';
  }

  // Last turn's highlight rings were about last turn's sentences.
  function beginTurn() {
    for (const ring of board.highlights) fadeAwayAndRemove(ring, 0.5);
    board.highlights = [];
  }

  // ------------------------------------------------------------------ view

  function transformFor(viewport) {
    const scale = viewport.scale || 1;
    const x = board.content.x + (viewport.horizontalInset || 0) * scale;
    const y = board.content.y - (viewport.scrolledDownBy || 0) * scale;
    return `translate(${x}px, ${y}px) scale(${scale})`;
  }

  function setWorldTransform(viewport, seconds) {
    const from = board.worldTransform;
    const to = transformFor(viewport);
    board.worldTransform = to;
    if (!seconds) { board.world.style.transform = to; return []; }
    const animation = board.world.animate([{ transform: from }, { transform: to }],
      { duration: seconds * 1000, fill: 'forwards', easing: 'ease-in-out' });
    animation.finished.then(() => { if (board.world) board.world.style.transform = to; }).catch(() => {});
    return [animation];
  }

  // -------------------------------------------------------------- drawing

  const handlers = {
    title(command) {
      if (board.titleGroup) fadeAwayAndRemove(board.titleGroup, 0.3);
      const group = kit().svgElement('g');
      board.titleLayer.appendChild(group);
      board.titleGroup = group;
      kit().writeText(group, board.titleOrigin[0], board.titleOrigin[1], command.text, { size: 44, bold: true });
    },

    element(command) {
      const existing = board.elements[command.identifier];
      const geometry = command.geometry;
      if (existing && command.keepsShape) {
        // Only the words change: the outline the student has been looking
        // at stays exactly as it was.
        const oldText = existing.textGroup;
        actionMark(0.25, seconds => fadeAwayAndRemove(oldText, seconds));
        existing.textGroup = kit().svgElement('g');
        existing.group.appendChild(existing.textGroup);
        writeLines(existing.textGroup, geometry.textLines, existing);
        return;
      }
      if (existing) {
        const oldGroup = existing.group;
        actionMark(0.3, seconds => fadeAwayAndRemove(oldGroup, seconds));
      }
      const layer = command.kind === 'group' ? board.groupLayer : board.elementLayer;
      const group = kit().svgElement('g', { 'data-board': command.identifier });
      layer.appendChild(group);
      const entry = { group, textGroup: null, drawnX: geometry.frame.x, drawnY: geometry.frame.y, offsetX: 0, offsetY: 0 };
      board.elements[command.identifier] = entry;
      drawShape(group, command.kind, geometry, command.tone);
      entry.textGroup = kit().svgElement('g');
      group.appendChild(entry.textGroup);
      writeLines(entry.textGroup, geometry.textLines, entry);
    },

    link(command) {
      const existing = board.links[command.identifier];
      if (existing) actionMark(0.25, seconds => fadeAwayAndRemove(existing, seconds));
      const group = kit().svgElement('g', { 'data-board-link': command.identifier });
      board.linkLayer.appendChild(group);
      board.links[command.identifier] = group;
      const points = command.route.map(point => [point.x, point.y]);
      const options = kit().roughOptions({ tone: command.tone || 'ink', size: 2.2, dashed: !!command.isDashed }, { roughness: 0.9 });
      if (points.length >= 2) {
        const node = points.length === 3
          ? kit().state().roughSvg.curve(points, options)
          : kit().state().roughSvg.linearPath(points, options);
        kit().roughShape(group, node, 0.5, !!command.isDashed);
      }
      if (command.stubTag != null && command.arrivingRoute) {
        // Two stubs with the same number instead of a line across the board:
        // one leaves the start towards its tag, the other leaves the matching
        // tag and arrives at the end.
        const arriving = command.arrivingRoute.map(point => [point.x, point.y]);
        for (const frame of command.tagFrames || []) drawStubTag(group, frame, command.stubTag, command.tone);
        // An end boxed in on every side has a badge on its corner and no line.
        if (arriving.length >= 2) {
          const arrivingNode = kit().state().roughSvg.linearPath(arriving,
            kit().roughOptions({ tone: command.tone || 'ink', size: 2.2, dashed: !!command.isDashed }, { roughness: 0.9 }));
          kit().roughShape(group, arrivingNode, 0.35, !!command.isDashed);
          kit().arrowHead(group, arriving, command.tone || 'ink', true);
        }
      } else {
        // Along a bowed curve the head should point the way the curve arrives,
        // which is from its middle, not from where the arrow started.
        kit().arrowHead(group, points.length === 3 ? [points[1], points[2]] : points, command.tone || 'ink', true);
      }
      for (const line of command.labelLines || []) {
        kit().writeText(group, line.x, line.y, line.text, { size: line.size, tone: 'grey' });
      }
    },

    unlink(command) {
      const group = board.links[command.identifier];
      delete board.links[command.identifier];
      if (group) actionMark(0.3, seconds => fadeAwayAndRemove(group, seconds));
    },

    move(command) {
      const entry = board.elements[command.identifier];
      if (!entry) return;
      const fromTransform = `translate(${entry.offsetX}px, ${entry.offsetY}px)`;
      entry.offsetX = command.frame.x - entry.drawnX;
      entry.offsetY = command.frame.y - entry.drawnY;
      const toTransform = `translate(${entry.offsetX}px, ${entry.offsetY}px)`;
      actionMark(0.6, seconds => {
        const animation = entry.group.animate([{ transform: fromTransform }, { transform: toTransform }],
          { duration: seconds * 1000, fill: 'forwards', easing: 'ease-in-out' });
        animation.finished.then(() => { entry.group.style.transform = toTransform; }).catch(() => {});
        return [animation];
      });
    },

    highlight(command) {
      const frame = command.frame;
      const centreX = frame.x + frame.width / 2, centreY = frame.y + frame.height / 2;
      const radiusX = frame.width / 2 + 16, radiusY = frame.height / 2 + 14;
      const points = [];
      const turns = 1.08, start = -2.2;
      for (let index = 0; index <= 48; index++) {
        const angle = start + (index / 48) * Math.PI * 2 * turns;
        const wobble = 1 + Math.sin(index * 0.9) * 0.025;
        points.push([centreX + Math.cos(angle) * radiusX * wobble, centreY + Math.sin(angle) * radiusY * wobble]);
      }
      // The ring belongs to what it circles, so it slides with it and is
      // rubbed out with it; an arrow's label has no group, so its ring sits
      // on the top layer.
      const entry = board.elements[command.identifier];
      const ring = kit().svgElement('g');
      if (entry) {
        ring.setAttribute('transform', `translate(${-entry.offsetX} ${-entry.offsetY})`);
        entry.group.appendChild(ring);
      } else {
        board.highlightLayer.appendChild(ring);
      }
      kit().inkStroke(ring, points, { tone: 'orange', size: 3.6, glow: false });
      board.highlights.push(ring);
    },

    remove(command) {
      const nodes = [];
      for (const identifier of command.removedIdentifiers || []) {
        if (board.elements[identifier]) { nodes.push(board.elements[identifier].group); delete board.elements[identifier]; }
        if (board.links[identifier]) { nodes.push(board.links[identifier]); delete board.links[identifier]; }
      }
      actionMark(0.4, seconds => nodes.flatMap(node => fadeAwayAndRemove(node, seconds)));
    },

    viewport(command) {
      actionMark(0.7, seconds => setWorldTransform(command.viewport, Math.max(0.5, seconds)));
    }
  };

  // Words are given at the element's current place; an element that slid
  // since it was drawn has its own translate, so new words are written in
  // the coordinates it was drawn in.
  function writeLines(layer, textLines, entry) {
    const shiftX = entry ? entry.offsetX : 0, shiftY = entry ? entry.offsetY : 0;
    for (const line of textLines || []) {
      kit().writeText(layer, line.x - shiftX, line.y - shiftY, line.text,
        { size: line.size, bold: line.isBold, anchor: line.anchor === 'middle' ? 'middle' : 'start' });
    }
  }

  // A box or circle is filled solid: its colour washed onto the paper, or
  // white. An arrow that has to pass an element then goes behind it, never
  // across its words.
  function solidFill(toneName) {
    const paper = kit().TONES.paper;
    const colour = toneName ? (kit().tone(toneName, null) || '#FFFFFF') : '#FFFFFF';
    const strength = toneName ? 0.32 : 1;
    const channel = (hex, index) => parseInt(hex.slice(1 + index * 2, 3 + index * 2), 16);
    const blended = [0, 1, 2].map(index => Math.round(channel(colour, index) * strength + channel(paper, index) * (1 - strength)));
    const hex = '#' + blended.map(value => value.toString(16).padStart(2, '0')).join('');
    return kit().roughOptions({ tone: 'ink', fill: hex, fillAlpha: 1, size: 2.4 });
  }

  function drawShape(group, kind, geometry, toneName) {
    const rough = kit().state().roughSvg;
    const frame = geometry.frame;
    const svgElement = kit().svgElement;
    const TONES = kit().TONES;
    switch (kind) {
      case 'box': {
        kit().roughShape(group, rough.rectangle(frame.x, frame.y, frame.width, frame.height, solidFill(toneName)), 0.6);
        break;
      }
      case 'circle': {
        kit().roughShape(group, rough.circle(frame.x + frame.width / 2, frame.y + frame.height / 2, Math.min(frame.width, frame.height), solidFill(toneName)), 0.6);
        break;
      }
      case 'note': {
        const note = svgElement('g', { transform: `rotate(-1.2 ${frame.x + frame.width / 2} ${frame.y + frame.height / 2})` });
        note.appendChild(svgElement('rect', { x: frame.x + 2, y: frame.y + 6, width: frame.width, height: frame.height, fill: 'rgba(0,0,0,0.16)', filter: 'url(#card-shadow)' }));
        note.appendChild(svgElement('rect', { x: frame.x, y: frame.y, width: frame.width, height: frame.height, fill: kit().tone(toneName, TONES.butter) }));
        group.appendChild(note);
        kit().makeMark(note, 0.4, kit().fadeReveal(note));
        break;
      }
      case 'group': {
        const options = kit().roughOptions({ tone: toneName || 'grey', size: 2, dashed: true, fill: toneName || 'sky', fillAlpha: 0.08 }, { roughness: 0.8 });
        kit().roughShape(group, rough.rectangle(frame.x, frame.y, frame.width, frame.height, options), 0.5, true);
        break;
      }
      case 'list':
      case 'table': {
        const lines = svgElement('g');
        for (const rule of geometry.ruleLines || []) {
          if (rule.length < 2) continue;
          lines.appendChild(rough.line(rule[0].x, rule[0].y, rule[1].x, rule[1].y,
            kit().roughOptions({ tone: kind === 'list' ? (toneName || 'blue') : 'ink', size: 1.8 }, { roughness: 0.7 })));
        }
        group.appendChild(lines);
        kit().makeMark(lines, kind === 'table' ? 0.9 : 0.3, kit().strokeReveal(lines));
        break;
      }
      default:
        break;   // a label is words alone
    }
  }

  // A small numbered circle at a stub's end, in the hand.
  function drawStubTag(layer, frame, number, toneName) {
    const centreX = frame.x + frame.width / 2, centreY = frame.y + frame.height / 2;
    const node = kit().state().roughSvg.circle(centreX, centreY, frame.width,
      kit().roughOptions({ tone: toneName || 'ink', size: 1.8, fill: 'butter', fillAlpha: 0.6 }, { roughness: 0.7 }));
    kit().roughShape(layer, node, 0.25);
    kit().writeText(layer, centreX, centreY + 7, String(number), { size: 19, anchor: 'middle', bold: true });
  }

  function apply(commands) {
    if (!board.layer) { kit().reportError('the board is not open'); return; }
    for (const command of commands || []) {
      const handler = handlers[command.action];
      if (!handler) { kit().reportError(`board command ${command.action} is unknown`); continue; }
      try { handler(command); } catch (error) { kit().reportError(`board ${command.action}: ${error && error.message || error}`); }
    }
  }

  // Board calls are replaced on the Mac before a program runs. One that
  // reaches the page was not readable there, and is reported, not guessed at.
  window.board = new Proxy({}, {
    get: (_, name) => () => kit().reportError(`board.${String(name)} was not read by the app, so it was not drawn`)
  });

  window.BuddyBoard = {
    open, close, beginTurn, apply, setParts, setSpeaking,
    reportError: message => kit().reportError(message),
    isOpen: () => !!board.layer
  };
})();
