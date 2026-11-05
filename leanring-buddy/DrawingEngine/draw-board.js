// Buddy teaching board.
//
// A full-screen sheet of paper over the dimmed screen, drawn on over several
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
// Layers, bottom to top: the dimming scrim, the paper, then the board world
// (groups, arrows, elements, highlight rings) under one transform that the
// view zooms and scrolls, clipped to the paper.

(function () {
  'use strict';

  const kit = () => window.BuddyEngine.boardKit;

  const board = {
    layer: null, world: null, groupLayer: null, linkLayer: null, elementLayer: null, highlightLayer: null,
    titleLayer: null, titleGroup: null,
    content: { x: 0, y: 0, w: 0, h: 0 },
    elements: {},   // id -> { group, textGroup, drawnX, drawnY, offsetX, offsetY }
    links: {},      // id -> group
    highlights: [],
    worldTransform: 'translate(0px, 0px) scale(1)'
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

  // ------------------------------------------------------------- open, close

  // options: { paper: [x, y, w, h], content: [x, y, w, h] } in canvas pixels.
  function open(options) {
    removeNow();
    const engineState = kit().state();
    const svgElement = kit().svgElement;
    const canvasWidth = engineState.canvasWidth, canvasHeight = engineState.canvasHeight;
    const [paperX, paperY, paperW, paperH] = options.paper;
    const [contentX, contentY, contentW, contentH] = options.content;
    board.content = { x: contentX, y: contentY, w: contentW, h: contentH };

    const layer = svgElement('g', { id: 'board-layer' });
    layer.style.pointerEvents = 'none';
    // The screen stays visible, dimmed, around the paper: the board is a
    // moment away from the work, not a different app.
    layer.appendChild(svgElement('rect', { x: -10, y: -10, width: canvasWidth + 20, height: canvasHeight + 20, fill: 'rgba(12, 14, 20, 0.62)' }));
    layer.appendChild(svgElement('rect', {
      x: paperX + 4, y: paperY + 12, width: paperW, height: paperH, rx: 20, fill: 'rgba(0,0,0,0.35)', filter: 'url(#card-shadow)'
    }));
    layer.appendChild(svgElement('rect', { x: paperX, y: paperY, width: paperW, height: paperH, rx: 20, fill: kit().TONES.paper }));
    const gridId = 'board-grid';
    const oldPattern = document.getElementById(gridId);
    if (oldPattern) oldPattern.remove();
    const pattern = svgElement('pattern', { id: gridId, width: 32, height: 32, patternUnits: 'userSpaceOnUse', x: paperX, y: paperY });
    pattern.appendChild(svgElement('path', { d: 'M 32 0 L 0 0 0 32', fill: 'none', stroke: 'rgba(60,80,120,0.07)', 'stroke-width': 1 }));
    engineState.defs.appendChild(pattern);
    layer.appendChild(svgElement('rect', { x: paperX, y: paperY, width: paperW, height: paperH, rx: 20, fill: `url(#${gridId})` }));

    board.titleLayer = svgElement('g');
    layer.appendChild(board.titleLayer);

    const clipId = 'board-clip';
    const oldClip = document.getElementById(clipId);
    if (oldClip) oldClip.remove();
    const clipPath = svgElement('clipPath', { id: clipId });
    clipPath.appendChild(svgElement('rect', { x: paperX + 6, y: contentY - 18, width: paperW - 12, height: paperY + paperH - contentY + 12 }));
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

    // Under the cards, over the screen marks: nothing marks the dimmed screen
    // while the board is up, and nothing should hide the board.
    engineState.svg.insertBefore(layer, engineState.cardLayer);
    board.layer = layer;
    setWorldTransform({ scale: 1, scrolledDownBy: 0, horizontalInset: 0 }, 0);
    layer.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 450, easing: 'ease-out' });
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
    board.layer = null;
    board.world = null;
    board.elements = {};
    board.links = {};
    board.highlights = [];
    board.titleGroup = null;
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
      kit().writeText(group, board.content.x, board.content.y - 30, command.text, { size: 34, bold: true });
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
      const node = points.length === 3
        ? kit().state().roughSvg.curve(points, options)
        : kit().state().roughSvg.linearPath(points, options);
      kit().roughShape(group, node, 0.5, !!command.isDashed);
      // Along a bowed curve the head should point the way the curve arrives,
      // which is from its middle, not from where the arrow started.
      kit().arrowHead(group, points.length === 3 ? [points[1], points[2]] : points, command.tone || 'ink', true);
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

  function drawShape(group, kind, geometry, toneName) {
    const rough = kit().state().roughSvg;
    const frame = geometry.frame;
    const svgElement = kit().svgElement;
    const TONES = kit().TONES;
    switch (kind) {
      case 'box': {
        // An unfilled box still gets a near-white wash, so an arrow passing
        // behind it never shows through the words.
        const options = toneName
          ? kit().roughOptions({ tone: 'ink', fill: toneName, size: 2.4 })
          : kit().roughOptions({ tone: 'ink', fill: '#FFFFFF', fillAlpha: 0.85, size: 2.4 });
        kit().roughShape(group, rough.rectangle(frame.x, frame.y, frame.width, frame.height, options), 0.6);
        break;
      }
      case 'circle': {
        const options = toneName
          ? kit().roughOptions({ tone: 'ink', fill: toneName, size: 2.4 })
          : kit().roughOptions({ tone: 'ink', fill: '#FFFFFF', fillAlpha: 0.85, size: 2.4 });
        kit().roughShape(group, rough.circle(frame.x + frame.width / 2, frame.y + frame.height / 2, Math.min(frame.width, frame.height), options), 0.6);
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
    open, close, beginTurn, apply,
    reportError: message => kit().reportError(message),
    isOpen: () => !!board.layer
  };
})();
