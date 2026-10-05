import mermaid from "mermaid";

const maximumSource = 60_000;
const svgNamespace = "http://www.w3.org/2000/svg";
const allowedElements = new Set(["svg", "g", "defs", "marker", "path", "rect", "polygon", "polyline", "circle", "ellipse", "line", "text", "tspan", "textPath", "title", "desc", "style", "clipPath", "linearGradient", "radialGradient", "stop", "symbol", "filter", "feDropShadow", "use"]);
const configuration = {
  startOnLoad: false, securityLevel: "strict", htmlLabels: false,
  suppressErrorRendering: true, maxTextSize: maximumSource, maxEdges: 500,
  fontFamily: "Arial, sans-serif", theme: "neutral",
  flowchart: {htmlLabels: false, useMaxWidth: true},
  secure: ["secure", "securityLevel", "startOnLoad", "maxTextSize", "maxEdges", "suppressErrorRendering", "htmlLabels", "flowchart", "themeCSS"]
};
let counter = 0;
let queue = Promise.resolve();

function sourceFeedback(source) {
  if (!source.trim()) return "Add Mermaid source to preview this diagram.";
  if (source.length > maximumSource) return "Use 60,000 characters or fewer for this diagram.";
  if (/%%\s*\{|^\s*---(?:\r?\n|$)|(?<!<)<\s*[a-z!/?]|(?:https?:|data:|javascript:|vbscript:|file:|mailto:|\/\/)|@import\b|(?:^|[\n;])\s*(?:click|link|links)\b|@\{[\s\S]*?["']?(?:img|image|icon)["']?\s*:|(?:^|[\n;])\s*(?:classDef|style|linkStyle)\b[^\n]*(?:[\\{}@]|\b(?:url|expression)\s*\()/i.test(source)) {
    return "Use local shapes and text; links, images and configuration directives are unavailable.";
  }
  return null;
}

function localReferences(value) {
  // CSS escapes can disguise url()/schemes; generated Mermaid styles need no escapes.
  if (/[\\]|@import\b|expression\s*\(|(?:https?:|data:|javascript:|vbscript:|file:|\/\/)/i.test(value)) return false;
  for (const match of value.matchAll(/url\s*\(([^)]*)\)/gi)) {
    if (!/^#[A-Za-z0-9_-]+$/.test(match[1].trim().replace(/^['"]|['"]$/g, ""))) return false;
  }
  return true;
}

function scopeIdentifiers(svg, scope) {
  const elements = [svg, ...svg.querySelectorAll("*")], identifiers = new Map();
  let index = 0;
  for (const element of elements) {
    const original = element.getAttribute("id");
    if (!original) continue;
    const unique = `${scope}-node-${++index}-${original.replace(/[^A-Za-z0-9_-]/g, "-")}`;
    if (!identifiers.has(original)) identifiers.set(original, unique);
    element.setAttribute("id", unique);
  }
  const fragments = value => {
    let valid = true;
    const result = value.replace(/url\s*\(\s*['"]?#([A-Za-z0-9_-]+)['"]?\s*\)/gi, (_, original) => {
      const target = identifiers.get(original);
      if (!target) valid = false;
      return target ? `url(#${target})` : "";
    });
    return valid ? result : null;
  };
  for (const element of elements) {
    if (element.localName === "style") {
      const css = fragments(element.textContent);
      if (css === null) { element.remove(); continue; }
      // Rewrite ID selectors in selectors only; a color such as #fff is a declaration value.
      element.textContent = css.replace(/([^{}]+)\{/g, (_, selectors) =>
        selectors.replace(/#([A-Za-z0-9_-]+)/g, (match, original) =>
          identifiers.has(original) ? "#" + identifiers.get(original) : match) + "{");
    }
    for (const attribute of [...element.attributes]) {
      const name = attribute.name.toLowerCase();
      let value = fragments(attribute.value);
      if (name === "href" || name === "xlink:href") value = identifiers.has(attribute.value.slice(1)) ? "#" + identifiers.get(attribute.value.slice(1)) : null;
      if (name === "aria-labelledby" || name === "aria-describedby") {
        const targets = attribute.value.trim().split(/\s+/).map(target => identifiers.get(target));
        value = targets.every(Boolean) ? targets.join(" ") : null;
      }
      if (value === null) element.removeAttributeNode(attribute);
      else if (value !== attribute.value) element.setAttribute(attribute.name, value);
    }
  }
}

function svgPreview(markup, document, scope) {
  if (typeof markup !== "string" || markup.length > 2_000_000 || /<!DOCTYPE|<!ENTITY/i.test(markup)) throw new Error("invalid_preview");
  const parser = new document.defaultView.DOMParser();
  const parsed = parser.parseFromString(markup, "image/svg+xml");
  const svg = parsed.documentElement;
  if (svg.localName !== "svg" || svg.namespaceURI !== svgNamespace || parsed.querySelector("parsererror")) throw new Error("invalid_preview");
  for (const element of [svg, ...svg.querySelectorAll("*")]) {
    if (!allowedElements.has(element.localName) || element.namespaceURI !== svgNamespace) { element.remove(); continue; }
    if (element.localName === "style" && !localReferences(element.textContent)) { element.remove(); continue; }
    for (const attribute of [...element.attributes]) {
      const name = attribute.name.toLowerCase();
      if (name === "xmlns" && attribute.value === svgNamespace) continue;
      if (name === "xmlns:xlink" && attribute.value === "http://www.w3.org/1999/xlink") continue;
      const href = name === "href" || name === "xlink:href";
      if (name.startsWith("on") || name === "src" || (href && !/^#[A-Za-z0-9_-]+$/.test(attribute.value)) || !localReferences(attribute.value)) {
        element.removeAttributeNode(attribute);
      }
    }
  }
  scopeIdentifiers(svg, scope);
  const bounds = (svg.getAttribute("viewBox") || "").trim().split(/[\s,]+/).map(Number);
  if (bounds.length !== 4 || !bounds.every(Number.isFinite) || bounds[2] <= 0 || bounds[3] <= 0) throw new Error("invalid_preview");
  const scale = Math.min(1, 4096 / bounds[2], 4096 / bounds[3]);
  svg.setAttribute("role", "img");
  svg.setAttribute("aria-label", "Specification diagram");
  svg.setAttribute("width", String(bounds[2] * scale));
  svg.setAttribute("height", String(bounds[3] * scale));
  svg.style.width = "auto";
  svg.style.maxWidth = "100%";
  svg.style.height = "auto";
  return document.importNode(svg, true);
}

function syntaxFeedback(error) {
  if (error?.message === "invalid_preview") return "Diagram preview unavailable. Simplify the diagram and try again.";
  const line = error?.hash?.loc?.first_line || Number(String(error?.message || "").match(/line\s+(\d+)/i)?.[1]);
  return Number.isInteger(line) && line > 0 && line <= maximumSource
    ? `Check Mermaid syntax near line ${line}.`
    : "Diagram could not be rendered. Check Mermaid syntax.";
}

export function mountSpecificationDiagram(el) {
  let revision = 0, destroyed = false, previous = null, scratch = null, lastStatus = null;
  const themeElement = el.closest("[data-theme]");
  const preview = () => el.querySelector("[data-spec-preview]");
  const feedback = (message, state) => {
    lastStatus = {message, state};
    const label = el.querySelector("[data-spec-feedback]");
    if (label) label.textContent = message;
    const target = preview();
    if (target) { target.dataset.specState = state; target.style.overflow = "auto"; target.style.maxHeight = "min(56vh, 480px)"; }
  };
  const current = request => !destroyed && revision === request && el.isConnected;
  const update = () => {
    if (destroyed) return Promise.resolve();
    const sourceElement = el.querySelector("[data-spec-mermaid][data-spec-diagram-id]");
    const source = sourceElement?.textContent || "";
    const theme = themeElement?.dataset.theme === "dark" ? "dark" : "neutral";
    const identity = [sourceElement?.dataset.specDiagramId || "", source, theme].join("\u0000");
    if (identity === previous) {
      if (lastStatus) feedback(lastStatus.message, lastStatus.state);
      return Promise.resolve();
    }
    previous = identity;
    const request = ++revision;
    preview()?.replaceChildren();
    const problem = sourceFeedback(source);
    if (problem) { feedback(problem, source.trim() ? "error" : "empty"); return Promise.resolve(); }
    feedback("Rendering diagram…", "rendering");
    const work = queue.then(async () => {
      if (!current(request)) return;
      mermaid.initialize({...configuration, theme});
      await mermaid.parse(source);
      if (!current(request)) return;
      const document = el.ownerDocument;
      const container = document.createElement("div");
      scratch = container;
      container.style.position = "absolute"; container.style.left = "-100000px"; container.style.visibility = "hidden";
      document.body.append(container);
      try {
        const id = "specification-diagram-" + (++counter);
        const {svg} = await mermaid.render(id, source, container);
        if (!current(request)) return;
        const node = svgPreview(svg, document, id);
        preview()?.replaceChildren(node);
        feedback("Diagram ready", "ready");
      } finally {
        container.remove();
        if (scratch === container) scratch = null;
      }
    });
    // Keep other diagrams renderable after a rejected parse; this request still reports its error.
    queue = work.then(() => undefined, () => undefined);
    return work.catch(error => { if (current(request)) feedback(syntaxFeedback(error), "error"); });
  };
  const Observer = el.ownerDocument.defaultView.MutationObserver;
  const observer = themeElement && typeof Observer === "function" ? new Observer(() => update()) : null;
  observer?.observe(themeElement, {attributes: true, attributeFilter: ["data-theme"]});
  const controller = {update, destroy() { destroyed = true; revision += 1; observer?.disconnect(); scratch?.remove(); scratch = null; }};
  controller.update();
  return controller;
}
