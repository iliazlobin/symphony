// Native Excalidraw scenes are the sole design-document authority. Tags provide
// a small semantic projection for reviewed agent edits, never a second drawing.
export const SECTION_IDS = ["brief", "requirements", "data", "architecture", "decisions"];
export const FIELD_SECTIONS = {brief: "brief", functional: "requirements", quality: "requirements", entities: "data", components: "architecture", flows: "architecture", decisions: "decisions"};
export const FIELD_TITLES = {brief: "Problem and scope", functional: "Functional requirements", quality: "Non-functional requirements", entities: "Entities and relationships", components: "Components", flows: "Main flows", decisions: "Decisions and open questions"};
export const SCENE_LIMITS = {elements: 500, bytes: 4000000, text: 12000, points: 4000, coordinate: 1000000};

const ID = /^[A-Za-z][A-Za-z0-9_-]{0,63}$/;
const TYPES = new Set(["rectangle", "diamond", "ellipse", "text", "line", "arrow", "freedraw", "frame"]);
const plain = value => value !== null && typeof value === "object" && !Array.isArray(value);
const clone = value => JSON.parse(JSON.stringify(value));
const bytes = value => new TextEncoder().encode(value).length;
const id = value => typeof value === "string" && ID.test(value);
const finite = (value, limit = SCENE_LIMITS.coordinate) => typeof value === "number" && Number.isFinite(value) && Math.abs(value) <= limit;
const validPoint = value => Array.isArray(value) && value.length === 2 && value.every(coordinate => finite(coordinate));
const strict = (value, names) => plain(value) && Object.keys(value).every(key => names.includes(key));
const tag = element => element.customData?.symphony;
const active = element => !element.isDeleted;
const group = element => element.groupIds?.[0] || element.id;
let sequence = 0;
const uid = prefix => prefix + "-" + (globalThis.crypto?.randomUUID?.() || Date.now().toString(36) + "-" + (++sequence).toString(36));
const textValue = element => typeof element?.originalText === "string" ? element.originalText : element?.text || "";
const state = value => ({scrollX: value?.scrollX || 0, scrollY: value?.scrollY || 0, zoom: {value: value?.zoom?.value || 1}});

function serializable(value, depth = 0) {
  if (depth > 32) return false;
  if (value === null || value === undefined || typeof value === "string" || typeof value === "boolean") return true;
  if (typeof value === "number") return Number.isFinite(value);
  if (Array.isArray(value)) return value.every(item => serializable(item, depth + 1));
  return plain(value) && Object.values(value).every(item => serializable(item, depth + 1));
}

function sorted(value) {
  if (Array.isArray(value)) return value.map(sorted);
  return plain(value) ? Object.fromEntries(Object.keys(value).sort().map(key => [key, sorted(value[key])])) : value;
}

function validTag(value, section) {
  if (value === undefined) return true;
  if (!strict(value, ["id", "role", "kind", "field"]) || !id(value.id) || !["node", "title", "body", "edge", "edge-label"].includes(value.role)) return false;
  if (value.role === "node" && !["note", "component", "entity"].includes(value.kind)) return false;
  return value.field === undefined || (value.role === "node" && value.kind === "note" && FIELD_SECTIONS[value.field] === section && value.id === "note-" + value.field);
}

function validNativeProperties(element) {
  const nullableStrings = ["link", "index", "frameId", "containerId", "name"];
  if (nullableStrings.some(key => element[key] !== undefined && element[key] !== null && typeof element[key] !== "string")) return false;
  const strings = ["strokeColor", "backgroundColor", "fillStyle", "strokeStyle", "strokeSharpness", "textAlign", "verticalAlign", "startArrowhead", "endArrowhead"];
  if (strings.some(key => element[key] !== undefined && element[key] !== null && typeof element[key] !== "string")) return false;
  const numbers = ["strokeWidth", "roughness", "opacity", "fontSize", "lineHeight", "updated"];
  if (numbers.some(key => element[key] !== undefined && (!finite(element[key], Number.MAX_SAFE_INTEGER) || element[key] < 0))) return false;
  if (["fontSize", "lineHeight"].some(key => element[key] !== undefined && element[key] === 0)) return false;
  if (["version", "versionNonce"].some(key => element[key] !== undefined && (!Number.isSafeInteger(element[key]) || element[key] < 0))) return false;
  if (element.seed !== undefined && !Number.isSafeInteger(element.seed)) return false;
  if (element.fontFamily !== undefined && ![1, 2, 3, 4, 5, 6, 7, 8, 9, 100, 1000].includes(element.fontFamily)) return false;
  // Excalidraw's legacy restore path calls font.split and normalizeLink.trim.
  if ("font" in element && (typeof element.font !== "string" || !Number.isFinite(parseFloat(element.font)) || parseFloat(element.font) <= 0)) return false;
  const booleans = ["isDeleted", "locked", "autoResize", "simulatePressure", "elbowed"];
  if (booleans.some(key => element[key] !== undefined && typeof element[key] !== "boolean")) return false;
  if (["startIsSpecial", "endIsSpecial"].some(key => element[key] !== undefined && element[key] !== null && typeof element[key] !== "boolean")) return false;
  if (element.customData !== undefined && element.customData !== null && !plain(element.customData)) return false;
  if (element.roundness !== undefined && element.roundness !== null && (!plain(element.roundness) || ![1, 2, 3].includes(element.roundness.type) ||
      (element.roundness.value !== undefined && (!finite(element.roundness.value) || element.roundness.value < 0)))) return false;
  if (element.boundElementIds !== undefined && element.boundElementIds !== null && (!Array.isArray(element.boundElementIds) || element.boundElementIds.some(value => typeof value !== "string"))) return false;
  return true;
}

function validScene(board, section) {
  if (!strict(board, ["elements", "appState"]) || !Array.isArray(board.elements) || board.elements.length > SCENE_LIMITS.elements || !plain(board.appState)) return false;
  const camera = board.appState;
  if (!strict(camera, ["scrollX", "scrollY", "zoom"]) || !finite(camera.scrollX) || !finite(camera.scrollY) || !strict(camera.zoom, ["value"]) || !finite(camera.zoom.value, 30) || camera.zoom.value < 0.05) return false;
  const ids = new Set(), semantic = new Set(), roles = new Set();
  for (const element of board.elements) {
    if (!plain(element) || typeof element.id !== "string" || !element.id || element.id.length > 128 || ids.has(element.id) || !TYPES.has(element.type) ||
        !["x", "y", "width", "height", "angle"].every(key => finite(element[key])) || element.width < 0 || element.height < 0 ||
        (element.groupIds !== undefined && (!Array.isArray(element.groupIds) || element.groupIds.some(value => typeof value !== "string" || value.length > 128))) || !validNativeProperties(element) || !validTag(tag(element), section)) return false;
    ids.add(element.id);
    if (element.type === "text" && (typeof element.text !== "string" || element.text.length > SCENE_LIMITS.text * 2 ||
        (element.originalText !== undefined && (typeof element.originalText !== "string" || element.originalText.length > SCENE_LIMITS.text)))) return false;
    // Native restore reads path.points.length before repairing path elements.
    // Empty/single-point paths are legitimate callbacks while drawing.
    if (["line", "arrow", "freedraw"].includes(element.type) && !Array.isArray(element.points)) return false;
    if (element.points !== undefined && (!Array.isArray(element.points) || element.points.length > SCENE_LIMITS.points || element.points.some(point => !validPoint(point)))) return false;
    if (element.pressures !== undefined && (!Array.isArray(element.pressures) || element.pressures.length > SCENE_LIMITS.points || element.pressures.some(value => !finite(value, 1) || value < 0))) return false;
    if (element.type === "freedraw" && element.simulatePressure !== true && !Array.isArray(element.pressures)) return false;
    if (element.fixedSegments !== undefined && element.fixedSegments !== null && (!Array.isArray(element.fixedSegments) || element.fixedSegments.length > SCENE_LIMITS.points ||
        element.fixedSegments.some(segment => !plain(segment) || !Number.isSafeInteger(segment.index) || segment.index < 0 || segment.index > SCENE_LIMITS.points || !validPoint(segment.start) || !validPoint(segment.end)))) return false;
    const meta = tag(element);
    if (active(element) && meta) {
      const key = meta.id + ":" + meta.role;
      if (roles.has(key)) return false;
      roles.add(key);
      if (["node", "edge"].includes(meta.role)) { if (semantic.has(meta.id)) return false; semantic.add(meta.id); }
      if (["title", "body", "edge-label"].includes(meta.role) && element.type !== "text") return false;
      if (meta.role === "node" && !["rectangle", "diamond", "ellipse"].includes(element.type)) return false;
      if (meta.role === "edge" && element.type !== "arrow") return false;
    }
  }
  // Tombstones and their retained bindings are valid native Undo history.
  for (const element of board.elements) {
    if (element.boundElements !== undefined && element.boundElements !== null && (!Array.isArray(element.boundElements) || element.boundElements.some(bound => !plain(bound) || !["arrow", "text"].includes(bound.type) || !ids.has(bound.id)))) return false;
    if (element.boundElementIds?.some(value => !ids.has(value))) return false;
    for (const name of ["startBinding", "endBinding"]) {
      const binding = element[name];
      if (binding !== undefined && binding !== null && (!plain(binding) || !ids.has(binding.elementId) ||
          (binding.focus !== undefined && !finite(binding.focus)) || (binding.gap !== undefined && (!finite(binding.gap) || binding.gap < 0)) ||
          (binding.fixedPoint !== undefined && (!Array.isArray(binding.fixedPoint) || binding.fixedPoint.length !== 2 || binding.fixedPoint.some(value => !finite(value)))))) return false;
    }
    if (element.containerId !== undefined && element.containerId !== null && !ids.has(element.containerId)) return false;
  }
  return true;
}

function validProposal(value, project) {
  if (!strict(value, ["version", "project", "section", "base_document", "base_revision", "changes"]) || value.version !== 1 || value.project !== project || !SECTION_IDS.includes(value.section) ||
      !id(value.base_document) || !Number.isSafeInteger(value.base_revision) || value.base_revision < 0 || !Array.isArray(value.changes) || !value.changes.length || value.changes.length > 24 || bytes(JSON.stringify(value)) > 32768) return false;
  const affected = new Set();
  const content = value => strict(value, ["title", "text", "x", "y"]) && Object.entries(value).every(([key, v]) =>
    ["x", "y"].includes(key) ? finite(v, 10000) : typeof v === "string" && bytes(v) <= (key === "title" ? 160 : 4000));
  for (const change of value.changes) {
    if (!plain(change)) return false;
    let identity;
    if (change.op === "add_node") {
      const node = change.node;
      if (!strict(change, ["op", "node"]) || !strict(node, ["id", "kind", "title", "text", "x", "y"]) ||
          (node.id !== undefined && !id(node.id)) || !["note", "component", "entity"].includes(node.kind) || typeof node.title !== "string" || typeof node.text !== "string" ||
          !content(Object.fromEntries(Object.entries(node).filter(([key]) => !["id", "kind"].includes(key))))) return false;
      identity = node.id;
    } else if (change.op === "update_node") {
      if (!strict(change, ["op", "id", "patch"]) || !id(change.id) || !content(change.patch) || !Object.keys(change.patch).length) return false;
      identity = change.id;
    } else if (["remove_node", "remove_edge"].includes(change.op)) {
      if (!strict(change, ["op", "id"]) || !id(change.id)) return false;
      identity = change.id;
    } else if (change.op === "add_edge") {
      const edge = change.edge;
      if (!strict(change, ["op", "edge"]) || !strict(edge, ["id", "from", "to", "label"]) || (edge.id !== undefined && !id(edge.id)) || !id(edge.from) || !id(edge.to) || edge.from === edge.to || typeof edge.label !== "string" || bytes(edge.label) > 160) return false;
      identity = edge.id;
    } else return false;
    if (identity && affected.has(identity)) return false;
    if (identity) affected.add(identity);
  }
  return true;
}

function legacyValid(value, project) {
  if (!strict(value, ["version", "project", "document_id", "revision", "boards"]) || value.version !== 1 || value.project !== project || !id(value.document_id) ||
      (value.revision !== undefined && (!Number.isSafeInteger(value.revision) || value.revision < 0)) || !strict(value.boards, SECTION_IDS) || bytes(JSON.stringify(value)) > 700000) return false;
  const ids = new Set(), fields = new Set();
  for (const section of SECTION_IDS) {
    const board = value.boards[section];
    if (!strict(board, ["nodes", "edges", "strokes", "viewport"]) || !Array.isArray(board.nodes) || board.nodes.length > 30 || !Array.isArray(board.edges) || board.edges.length > 60 ||
        !Array.isArray(board.strokes) || board.strokes.length > 30 || !strict(board.viewport, ["x", "y", "scale"]) || !finite(board.viewport.x, 30000) || !finite(board.viewport.y, 30000) ||
        !finite(board.viewport.scale, 2.5) || board.viewport.scale < 0.2) return false;
    const local = new Set();
    for (const node of board.nodes) {
      if (!strict(node, ["id", "kind", "title", "text", "x", "y", "width", "field"]) || !id(node.id) || ids.has(node.id) || !["note", "component", "entity"].includes(node.kind) ||
          typeof node.title !== "string" || node.title.length > 160 || typeof node.text !== "string" || node.text.length > 12000 || !finite(node.x, 10000) || !finite(node.y, 10000) ||
          (node.width !== undefined && (!finite(node.width, 480) || node.width < 180)) || (node.field !== undefined && (fields.has(node.field) || node.kind !== "note" || FIELD_SECTIONS[node.field] !== section || node.id !== "note-" + node.field))) return false;
      ids.add(node.id); local.add(node.id); if (node.field) fields.add(node.field);
    }
    for (const edge of board.edges) {
      if (!strict(edge, ["id", "from", "to", "label"]) || !id(edge.id) || ids.has(edge.id) || !local.has(edge.from) || !local.has(edge.to) || edge.from === edge.to || typeof edge.label !== "string" || edge.label.length > 160) return false;
      ids.add(edge.id);
    }
    for (const stroke of board.strokes) {
      if (!strict(stroke, ["id", "points"]) || !id(stroke.id) || ids.has(stroke.id) || !Array.isArray(stroke.points) || stroke.points.length < 2 || stroke.points.length > 600 || stroke.points.some(point => !Array.isArray(point) || point.length !== 2 || point.some(value => !finite(value, 10000)))) return false;
      ids.add(stroke.id);
    }
  }
  return fields.size === Object.keys(FIELD_SECTIONS).length;
}

export function createSceneModel(convert) {
  if (typeof convert !== "function") throw Error("The native Excalidraw converter is required.");
  const convertElements = skeletons => convert(skeletons, {regenerateIds: false});

  function nativeText(skeleton, width) {
    const original = skeleton.originalText ?? skeleton.text, fontSize = skeleton.fontSize || 16, fontFamily = skeleton.fontFamily || 2;
    const measure = value => convertElements([{type: "text", x: 0, y: 0, text: value, fontSize, fontFamily}])[0].width;
    const lines = [];
    for (const paragraph of original.split("\n")) {
      let remaining = paragraph;
      if (!remaining) { lines.push(""); continue; }
      while (remaining) {
        if (measure(remaining) <= width) { lines.push(remaining); break; }
        let low = 1, high = remaining.length;
        while (low < high) {
          const middle = Math.ceil((low + high) / 2);
          if (measure(remaining.slice(0, middle)) <= width) low = middle; else high = middle - 1;
        }
        const space = remaining.lastIndexOf(" ", low);
        let cut = space > 0 ? space + 1 : low;
        if (cut > 1 && /[\uD800-\uDBFF]/.test(remaining[cut - 1]) && /[\uDC00-\uDFFF]/.test(remaining[cut])) cut--;
        lines.push(remaining.slice(0, cut)); remaining = remaining.slice(cut);
      }
    }
    const converted = convertElements([{...skeleton, text: lines.join("\n"), originalText: original, autoResize: false}])[0];
    return {...converted, x: skeleton.x, y: skeleton.y, width, originalText: original, autoResize: false};
  }

  function validate(value, project) {
    try {
      if (!serializable(value) || !strict(value, ["version", "project", "document_id", "revision", "boards"]) || value.version !== 2 || value.project !== project || typeof project !== "string" || !project || project.length > 512 ||
          !id(value.document_id) || !Number.isSafeInteger(value.revision) || value.revision < 0 || !strict(value.boards, SECTION_IDS) ||
          !SECTION_IDS.every(section => validScene(value.boards[section], section)) || bytes(JSON.stringify(value)) > SCENE_LIMITS.bytes) return null;
      return clone(value);
    } catch (_) { return null; }
  }

  function nodeElements(node) {
    const width = node.width || (node.kind === "note" ? 320 : 260), groupId = uid("group"), owner = uid("shape");
    const skeletons = [
      {type: "rectangle", id: owner, x: node.x, y: node.y, width, height: 140, roundness: {type: 3}, backgroundColor: node.kind === "note" ? "#fff9db" : "#ffffff", fillStyle: "solid", strokeColor: "#495057", roughness: 0, groupIds: [groupId], customData: {symphony: {id: node.id, role: "node", kind: node.kind, ...(node.field ? {field: node.field} : {})}}},
      {type: "text", id: uid("title"), x: node.x + 14, y: node.y + 12, width: width - 28, text: node.title, fontSize: 18, fontFamily: 2, strokeColor: "#343a40", groupIds: [groupId], customData: {symphony: {id: node.id, role: "title"}}},
      {type: "text", id: uid("body"), x: node.x + 14, y: node.y + 45, width: width - 28, text: node.text, fontSize: 16, fontFamily: 2, strokeColor: "#495057", groupIds: [groupId], customData: {symphony: {id: node.id, role: "body"}}}
    ];
    const elements = [convertElements([skeletons[0]])[0], nativeText(skeletons[1], width - 28), nativeText(skeletons[2], width - 28)];
    const shape = elements.find(element => element.id === owner), title = elements.find(element => tag(element)?.role === "title"), body = elements.find(element => tag(element)?.role === "body");
    if (!shape || !title || !body) throw Error("The native converter did not retain the semantic group.");
    body.y = title.y + title.height + 12;
    shape.height = Math.max(140, body.y + body.height - shape.y + 14);
    return elements;
  }

  function projection(canvas, section) {
    const elements = canvas.boards[section]?.elements || [], live = elements.filter(active);
    const nodes = live.filter(element => tag(element)?.role === "node").map(element => {
      const meta = tag(element), siblings = live.filter(item => tag(item)?.id === meta.id);
      return {id: meta.id, kind: meta.kind, title: textValue(siblings.find(item => tag(item)?.role === "title")), text: textValue(siblings.find(item => tag(item)?.role === "body")), x: element.x, y: element.y, width: element.width, ...(meta.field ? {field: meta.field} : {})};
    });
    const nativeNodes = new Map(live.filter(element => tag(element)?.role === "node").map(element => [element.id, tag(element).id]));
    const edges = live.filter(element => tag(element)?.role === "edge").flatMap(element => {
      const from = nativeNodes.get(element.startBinding?.elementId), to = nativeNodes.get(element.endBinding?.elementId);
      if (!from || !to || from === to) return [];
      return [{id: tag(element).id, from, to, label: textValue(live.find(item => tag(item)?.id === tag(element).id && tag(item)?.role === "edge-label"))}];
    });
    return {nodes, edges};
  }

  function fields(canvas) {
    const result = Object.fromEntries(Object.keys(FIELD_SECTIONS).map(field => [field, ""]));
    for (const section of SECTION_IDS) for (const node of projection(canvas, section).nodes) if (node.field) result[node.field] = node.text;
    return result;
  }

  function edgeElements(edge, elements) {
    const from = elements.find(element => active(element) && tag(element)?.role === "node" && tag(element).id === edge.from);
    const to = elements.find(element => active(element) && tag(element)?.role === "node" && tag(element).id === edge.to);
    if (!from || !to) throw Error("A relationship endpoint is unavailable.");
    const start = [from.x + from.width, from.y + from.height / 2], end = [to.x, to.y + to.height / 2];
    const owner = uid("arrow"), groupId = uid("group");
    const converted = convertElements([{type: "arrow", id: owner, x: start[0], y: start[1], points: [[0, 0], [end[0] - start[0], end[1] - start[1]]], strokeColor: "#5c5fce", roughness: 0, endArrowhead: "arrow", groupIds: [groupId], customData: {symphony: {id: edge.id, role: "edge"}}},
      {type: "text", id: uid("label"), x: (start[0] + end[0]) / 2, y: (start[1] + end[1]) / 2 - 22, text: edge.label, fontSize: 14, fontFamily: 2, strokeColor: "#495057", groupIds: [groupId], customData: {symphony: {id: edge.id, role: "edge-label"}}}]);
    const arrow = converted.find(element => element.id === owner);
    if (!arrow) throw Error("The native converter did not create the relationship.");
    arrow.startBinding = {elementId: from.id, focus: 0, gap: 1}; arrow.endBinding = {elementId: to.id, focus: 0, gap: 1};
    const label = converted.find(element => tag(element)?.role === "edge-label");
    label.containerId = arrow.id; label.textAlign = "center"; label.verticalAlign = "middle";
    label.x -= label.width / 2; arrow.boundElements = [{id: label.id, type: "text"}];
    for (const shape of [from, to]) shape.boundElements = [...(shape.boundElements || []).filter(bound => bound.id !== owner), {id: owner, type: "arrow"}];
    return converted;
  }

  function empty(project, sourceFields = {}) {
    const canvas = {version: 2, project, document_id: uid("design"), revision: 0, boards: Object.fromEntries(SECTION_IDS.map(section => [section, {elements: [], appState: state()}]))};
    for (const [field, section] of Object.entries(FIELD_SECTIONS)) {
      const index = canvas.boards[section].elements.filter(element => tag(element)?.role === "node").length;
      canvas.boards[section].elements.push(...nodeElements({id: "note-" + field, kind: "note", field, title: FIELD_TITLES[field], text: sourceFields[field] || "", x: index * 370, y: 0, width: 320}));
    }
    return validate(canvas, project);
  }

  function migrate(source, project, sourceFields = {}) {
    try {
      if (source === null || source === undefined) return empty(project, sourceFields);
      if (source.version === 2) return validate(source, project);
      if (!legacyValid(source, project)) return null;
      const canvas = {version: 2, project, document_id: source.document_id, revision: source.revision || 0, boards: {}};
      for (const section of SECTION_IDS) {
        const old = source.boards[section], elements = old.nodes.flatMap(nodeElements);
        for (const edge of old.edges) elements.push(...edgeElements(edge, elements));
        for (const stroke of old.strokes) {
          const [first] = stroke.points, points = stroke.points.map(point => [point[0] - first[0], point[1] - first[1]]);
          const minX = Math.min(...points.map(point => point[0])), maxX = Math.max(...points.map(point => point[0])), minY = Math.min(...points.map(point => point[1])), maxY = Math.max(...points.map(point => point[1]));
          const base = convertElements([{type: "line", id: stroke.id, x: first[0], y: first[1], width: maxX - minX, height: maxY - minY, points, strokeColor: "#495057", roughness: 0}])[0];
          for (const key of ["startBinding", "endBinding", "startArrowhead", "endArrowhead"]) delete base[key];
          elements.push({...base, type: "freedraw", points, pressures: [], simulatePressure: true, lastCommittedPoint: null});
        }
        canvas.boards[section] = {elements, appState: {scrollX: old.viewport.x / old.viewport.scale, scrollY: old.viewport.y / old.viewport.scale, zoom: {value: old.viewport.scale}}};
      }
      return validate(canvas, project);
    } catch (_) { return null; }
  }

  function fingerprint(elements) {
    return JSON.stringify(sorted(elements.map(element => Object.fromEntries(Object.entries(element).filter(([key]) => !["version", "versionNonce", "updated", "index"].includes(key))))));
  }

  function stampElements(before, after) {
    const previous = new Map(before.map(element => [element.id, element]));
    let changed = false;
    for (const element of after) {
      const old = previous.get(element.id);
      if (!old) { changed = true; continue; }
      if (fingerprint([old]) === fingerprint([element])) continue;
      // Native Undo and render snapshots compare versionNonce, not deep content.
      element.version = (Number.isSafeInteger(old.version) ? old.version : 0) + 1;
      const nonce = (Date.now() + ++sequence) % 2147483647;
      element.versionNonce = nonce === old.versionNonce ? (nonce + 1) % 2147483647 : nonce;
      element.updated = Date.now(); changed = true;
    }
    return changed || before.length !== after.length;
  }

  function normalizeElements(source, section, {adoptBoundText = true, fitTextId = null} = {}) {
    const elements = clone(source), claimed = new Set(), owners = new Map();
    for (const element of elements) {
      const meta = tag(element);
      if (!active(element) || !meta || meta.role !== "node") continue;
      const original = meta.id, copied = claimed.has(original);
      if (copied) meta.id = uid("node");
      if (copied || (section && meta.field && FIELD_SECTIONS[meta.field] !== section)) delete meta.field;
      claimed.add(meta.id); owners.set(group(element), {original, current: meta.id});
    }
    for (const element of elements) {
      const meta = tag(element), owner = owners.get(group(element));
      if (active(element) && meta && ["title", "body"].includes(meta.role) && owner && meta.id === owner.original) meta.id = owner.current;
    }
    const edges = new Set();
    for (const element of elements) {
      const meta = tag(element);
      if (!active(element) || meta?.role !== "edge") continue;
      if (edges.has(meta.id)) {
        const old = meta.id; meta.id = uid("edge");
        for (const label of elements) if (active(label) && tag(label)?.role === "edge-label" && tag(label).id === old && group(label) === group(element)) tag(label).id = meta.id;
      }
      edges.add(meta.id);
    }
    const nativeOwners = new Set(elements.filter(element => active(element) && ["node", "edge"].includes(tag(element)?.role)).map(element => tag(element).id));
    const roles = new Set();
    for (const element of elements) {
      const meta = tag(element);
      if (!active(element) || !meta || !["title", "body", "edge-label"].includes(meta.role)) continue;
      const key = meta.id + ":" + meta.role;
      // A copied individual text or text left after deleting its container stays
      // an ordinary native annotation instead of becoming a second model field.
      if (!nativeOwners.has(meta.id) || roles.has(key)) delete element.customData.symphony;
      else roles.add(key);
    }
    for (const shape of adoptBoundText ? elements.filter(element => active(element) && tag(element)?.role === "node") : []) {
      const semanticId = tag(shape).id;
      const bodies = elements.filter(element => active(element) && tag(element)?.id === semanticId && tag(element)?.role === "body");
      if (bodies.some(element => textValue(element).trim() || element.text.trim())) continue;
      const bindings = new Set((shape.boundElements || []).filter(bound => bound.type === "text").map(bound => bound.id));
      const candidates = elements.filter(element => active(element) && element.type === "text" && tag(element) === undefined && element.containerId === shape.id && bindings.has(element.id));
      // Adopt only the native text the operator actually typed inside this empty
      // shape. Loose annotations and populated model content retain their owners.
      if (candidates.length !== 1 || !textValue(candidates[0]).trim()) continue;
      const nativeBody = candidates[0], redundant = new Set(bodies.map(element => element.id));
      for (const body of bodies) body.isDeleted = true;
      shape.boundElements = (shape.boundElements || []).filter(bound => !redundant.has(bound.id));
      nativeBody.customData = {...nativeBody.customData, symphony: {id: semanticId, role: "body"}};
      nativeBody.groupIds = [...(shape.groupIds || [])];
    }
    const nodes = new Map(elements.filter(element => active(element) && tag(element)?.role === "node").map(element => [element.id, element]));
    for (const arrow of adoptBoundText ? elements.filter(element => active(element) && element.type === "arrow") : []) {
      const from = nodes.get(arrow.startBinding?.elementId), to = nodes.get(arrow.endBinding?.elementId);
      if (!from || !to || from.id === to.id || (tag(arrow) !== undefined && tag(arrow)?.role !== "edge")) continue;
      const bindings = new Set((arrow.boundElements || []).filter(bound => bound.type === "text").map(bound => bound.id));
      const boundLabels = elements.filter(element => active(element) && element.type === "text" && element.containerId === arrow.id && bindings.has(element.id));
      if (boundLabels.length > 1 || boundLabels.some(element => tag(element) !== undefined && (tag(element)?.role !== "edge-label" || tag(element)?.id !== tag(arrow)?.id))) continue;
      if (tag(arrow) === undefined) arrow.customData = {...arrow.customData, symphony: {id: uid("edge"), role: "edge"}};
      const semanticId = tag(arrow).id, label = boundLabels[0];
      if (!label || tag(label) !== undefined || !textValue(label).trim()) continue;
      const previous = elements.filter(element => active(element) && tag(element)?.id === semanticId && tag(element)?.role === "edge-label");
      if (previous.some(element => textValue(element).trim() || element.text.trim())) continue;
      const redundant = new Set(previous.map(element => element.id));
      for (const element of previous) element.isDeleted = true;
      arrow.boundElements = (arrow.boundElements || []).filter(bound => !redundant.has(bound.id));
      label.customData = {...label.customData, symphony: {id: semanticId, role: "edge-label"}};
    }
    const fitting = fitTextId && elements.find(element => active(element) && element.id === fitTextId && ["title", "body"].includes(tag(element)?.role));
    if (fitting) {
      const shape = elements.find(element => active(element) && tag(element)?.id === tag(fitting).id && tag(element)?.role === "node");
      if (shape) {
        const previous = new Map([[shape.id, clone(shape)]]), board = {elements};
        fitNode(board, tag(shape).id); updateBoundArrows(board, previous);
      }
    }
    stampElements(source, elements);
    return elements;
  }

  function reviseText(element, value) {
    const converted = nativeText({...element, text: value, originalText: value}, element.width);
    if (!converted) throw Error("The native converter did not update the text.");
    return {...element, ...converted, customData: clone(element.customData)};
  }

  function fitNode(board, semanticId) {
    const shape = board.elements.find(element => active(element) && tag(element)?.role === "node" && tag(element).id === semanticId);
    const texts = board.elements.filter(element => active(element) && tag(element)?.id === semanticId && element.type === "text");
    const title = texts.find(element => tag(element)?.role === "title"), body = texts.find(element => tag(element)?.role === "body");
    if (title && body && body.y < title.y + title.height + 12) {
      if (body.containerId === shape.id) title.y = shape.y - title.height - 12;
      else body.y = title.y + title.height + 12;
    }
    for (const member of texts) shape.height = Math.max(shape.height, member.y + member.height - shape.y + 14);
  }

  function updateBoundArrows(board, previousShapes) {
    const live = board.elements.filter(active), native = new Map(live.map(element => [element.id, element]));
    for (const arrow of live.filter(element => element.type === "arrow")) {
      const from = native.get(arrow.startBinding?.elementId), to = native.get(arrow.endBinding?.elementId);
      if (!arrow.points?.length || (!previousShapes.has(from?.id) && !previousShapes.has(to?.id))) continue;
      const oldStart = [arrow.x + arrow.points[0][0], arrow.y + arrow.points[0][1]], last = arrow.points.at(-1), oldEnd = [arrow.x + last[0], arrow.y + last[1]];
      const anchor = (point, shape) => {
        const previous = previousShapes.get(shape?.id);
        return previous ? [shape.x + (point[0] - previous.x) * (previous.width ? shape.width / previous.width : 1), shape.y + (point[1] - previous.y) * (previous.height ? shape.height / previous.height : 1)] : point;
      };
      const start = anchor(oldStart, from), end = anchor(oldEnd, to);
      const middle = arrow.points.slice(1, -1).map(point => [arrow.x + point[0] - start[0], arrow.y + point[1] - start[1]]);
      arrow.x = start[0]; arrow.y = start[1]; arrow.points = [[0, 0], ...middle, [end[0] - start[0], end[1] - start[1]]];
      arrow.width = Math.max(...arrow.points.map(point => point[0])) - Math.min(...arrow.points.map(point => point[0]));
      arrow.height = Math.max(...arrow.points.map(point => point[1])) - Math.min(...arrow.points.map(point => point[1]));
      const label = live.find(element => element.type === "text" && element.containerId === arrow.id);
      if (label) { label.x += (start[0] + end[0] - oldStart[0] - oldEnd[0]) / 2; label.y += (start[1] + end[1] - oldStart[1] - oldEnd[1]) / 2; }
    }
  }

  function proposal(source, suggestion) {
    try {
      if (!validate(source, source.project) || !validProposal(suggestion, source.project) || suggestion.base_document !== source.document_id || suggestion.base_revision !== source.revision) return null;
      const next = clone(source), board = next.boards[suggestion.section], previousShapes = new Map();
      for (const change of suggestion.changes) {
        const before = projection(next, suggestion.section);
        if (change.op === "add_node") {
          const node = {...change.node, id: change.node.id || uid("node"), x: change.node.x ?? (before.nodes.length % 3) * 370, y: change.node.y ?? Math.floor(before.nodes.length / 3) * 260};
          if (board.elements.some(element => tag(element)?.id === node.id)) return null;
          board.elements.push(...nodeElements(node));
        } else if (change.op === "update_node") {
          const node = before.nodes.find(item => item.id === change.id);
          if (!node || (change.patch.text !== undefined && node.text.length > 600) || (change.patch.title !== undefined && node.title.length > 160)) return null;
          const shape = board.elements.find(element => active(element) && tag(element)?.role === "node" && tag(element).id === change.id);
          previousShapes.set(shape.id, clone(shape));
          const dx = change.patch.x === undefined ? 0 : change.patch.x - shape.x, dy = change.patch.y === undefined ? 0 : change.patch.y - shape.y;
          for (const element of board.elements) if (active(element) && tag(element)?.id === change.id) { element.x += dx; element.y += dy; }
          for (const [key, role] of [["title", "title"], ["text", "body"]]) if (change.patch[key] !== undefined) {
            const index = board.elements.findIndex(element => active(element) && tag(element)?.id === change.id && tag(element).role === role);
            if (index >= 0) board.elements[index] = reviseText(board.elements[index], change.patch[key]);
            else {
              const created = nodeElements({...node, ...change.patch}).find(element => tag(element)?.role === role);
              created.groupIds = shape.groupIds; board.elements.push(created);
            }
          }
          fitNode(board, change.id);
        } else if (change.op === "remove_node") {
          const node = before.nodes.find(item => item.id === change.id);
          if (!node || node.field || node.text.length > 600 || node.title.length > 160 || before.edges.some(edge => (edge.from === change.id || edge.to === change.id) && edge.label.length > 160)) return null;
          const removing = new Set([change.id, ...before.edges.filter(edge => edge.from === change.id || edge.to === change.id).map(edge => edge.id)]);
          for (const element of board.elements) if (removing.has(tag(element)?.id)) element.isDeleted = true;
        } else if (change.op === "add_edge") {
          const edge = {...change.edge, id: change.edge.id || uid("edge")};
          if (board.elements.some(element => tag(element)?.id === edge.id)) return null;
          board.elements.push(...edgeElements(edge, board.elements));
        } else if (change.op === "remove_edge") {
          if (!before.edges.some(edge => edge.id === change.id && edge.label.length <= 160)) return null;
          for (const element of board.elements) if (tag(element)?.id === change.id) element.isDeleted = true;
        }
      }
      updateBoundArrows(board, previousShapes);
      stampElements(source.boards[suggestion.section].elements, board.elements);
      next.revision++;
      return validate(next, next.project);
    } catch (_) { return null; }
  }

  function add(source, section, kind, content = {}) {
    return proposal(source, {version: 1, project: source.project, section, base_document: source.document_id, base_revision: source.revision,
      changes: [{op: "add_node", node: {kind, title: kind === "entity" ? "New entity" : kind === "component" ? "New component" : "New note", text: "", ...content}}]});
  }

  function withFields(source, values) {
    try {
      const next = validate(source, source.project);
      if (!next || !strict(values, Object.keys(FIELD_SECTIONS)) || Object.values(values).some(value => typeof value !== "string" || value.length > SCENE_LIMITS.text)) return null;
      const previousShapes = new Map();
      for (const [field, value] of Object.entries(values)) {
        const section = FIELD_SECTIONS[field], board = next.boards[section], node = projection(next, section).nodes.find(node => node.field === field);
        if (!node && !value) continue;
        if (!node) {
          const index = Object.keys(FIELD_SECTIONS).filter(name => FIELD_SECTIONS[name] === section).indexOf(field);
          board.elements.push(...nodeElements({id: "note-" + field, kind: "note", field, title: FIELD_TITLES[field], text: value, x: index * 370, y: 0, width: 320})); continue;
        }
        const previousShape = board.elements.find(element => active(element) && tag(element)?.role === "node" && tag(element).id === node.id);
        previousShapes.set(previousShape.id, clone(previousShape));
        const bodyIndex = board.elements.findIndex(element => active(element) && tag(element)?.id === node.id && tag(element)?.role === "body");
        if (bodyIndex >= 0) board.elements[bodyIndex] = reviseText(board.elements[bodyIndex], value);
        else {
          const shape = board.elements.find(element => active(element) && tag(element)?.role === "node" && tag(element).id === node.id);
          const body = nodeElements({...node, text: value}).find(element => tag(element)?.role === "body");
          body.groupIds = shape.groupIds; board.elements.push(body);
        }
        fitNode(board, node.id);
      }
      for (const board of Object.values(next.boards)) updateBoundArrows(board, previousShapes);
      let changed = false;
      for (const section of SECTION_IDS) changed = stampElements(source.boards[section].elements, next.boards[section].elements) || changed;
      if (changed) next.revision++;
      return validate(next, next.project);
    } catch (_) { return null; }
  }

  function example(source) {
    let next = validate(source, source.project);
    if (!next) return null;
    let changed = false;
    for (const section of ["data", "architecture"]) {
      const board = next.boards[section], fieldIds = new Set(projection(next, section).nodes.filter(node => node.field).map(node => node.id));
      if (board.elements.some(element => active(element) && !fieldIds.has(tag(element)?.id))) continue;
      const values = section === "data" ? [["User", "id: identifier\ninterests: topics\narea: location"], ["Saved choice", "id: identifier\nuser_id: reference\nevent_id: reference"], ["Event", "id: identifier\ntitle: text\nstarts_at: timestamp"]] : [["Web client", "Collect preferences and show events"], ["Backend", "Rank discovery results and save choices"], ["Data store", "Events, sources and saved choices"]];
      const nodes = values.map(([title, text], index) => ({id: uid("node"), kind: section === "data" ? "entity" : "component", title, text, x: index * 420, y: 290}));
      for (const node of nodes) board.elements.push(...nodeElements(node));
      for (let index = 0; index < 2; index++) board.elements.push(...edgeElements({id: uid("edge"), from: nodes[index].id, to: nodes[index + 1].id, label: section === "data" ? index === 0 ? "1 → many" : "many → 1" : index === 0 ? "requests" : "reads / writes"}, board.elements));
      changed = true;
    }
    if (!changed) return null;
    for (const section of SECTION_IDS) stampElements(source.boards[section].elements, next.boards[section].elements);
    next.revision++;
    return validate(next, next.project);
  }

  // Human edits use the full retained text, independently of the bounded agent
  // excerpt. The native scene remains the only model; the outline edits it.
  function edit(source, section, semanticId, patch) {
    try {
      if (!validate(source, source.project) || !SECTION_IDS.includes(section) || !strict(patch, ["title", "text"]) ||
          typeof patch.title !== "string" || bytes(patch.title) > 160 || typeof patch.text !== "string" || patch.text.length > SCENE_LIMITS.text) return null;
      const node = projection(source, section).nodes.find(item => item.id === semanticId);
      if (!node) return null;
      const next = clone(source), board = next.boards[section];
      const shape = board.elements.find(element => active(element) && tag(element)?.role === "node" && tag(element).id === semanticId);
      const before = new Map([[shape.id, clone(shape)]]);
      for (const [key, role] of [["title", "title"], ["text", "body"]]) {
        const index = board.elements.findIndex(element => active(element) && tag(element)?.id === semanticId && tag(element).role === role);
        if (index >= 0) board.elements[index] = reviseText(board.elements[index], patch[key]);
        else {
          const member = nodeElements({...node, ...patch}).find(element => tag(element)?.role === role);
          member.groupIds = shape.groupIds; board.elements.push(member);
        }
      }
      fitNode(board, semanticId); updateBoundArrows(board, before);
      if (stampElements(source.boards[section].elements, board.elements)) next.revision++;
      return validate(next, next.project);
    } catch (_) { return null; }
  }
  function changes(source, baseline) {
    return SECTION_IDS.flatMap(section => {
      const current = projection(source, section), previous = baseline ? projection(baseline, section) : {nodes: [], edges: []};
      const rows = [];
      for (const name of ["nodes", "edges"]) {
        const before = new Map(previous[name].map(item => [item.id, item]));
        for (const item of current[name]) {
          const old = before.get(item.id); before.delete(item.id);
          const signature = value => JSON.stringify(name === "nodes" ? [value.kind, value.title, value.text] : [value.from, value.to, value.label]);
          if (!old || signature(old) !== signature(item)) rows.push({section, id: item.id, change: old ? "Change" : "Add", title: item.title || item.label || "Relationship"});
        }
        for (const item of before.values()) rows.push({section, id: item.id, change: "Remove", title: item.title || item.label || "Relationship"});
      }
      if (fingerprint(source.boards[section].elements) !== fingerprint(baseline?.boards[section]?.elements || []) && !rows.length)
        rows.push({section, change: "Update", title: "Drawing or layout"});
      return rows;
    });
  }
  return {empty, migrate, validate, projection, fields, fingerprint, normalizeElements, proposal, add, withFields, example, edit, changes};
}
