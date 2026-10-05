import {build} from "esbuild";
import {createHash} from "node:crypto";
import {readdir, readFile, mkdir, rm, writeFile} from "node:fs/promises";
import path from "node:path";
import {fileURLToPath} from "node:url";

const root = path.dirname(fileURLToPath(import.meta.url));
const destination = path.resolve(root, "../priv/static/design-editor");
const excalidraw = path.join(root, "node_modules/@excalidraw/excalidraw/dist/prod");
const check = process.argv.includes("--check");
const digest = bytes => createHash("sha256").update(bytes).digest("hex");
const slash = value => value.split(path.sep).join("/");
const compare = (a, b) => a < b ? -1 : a > b ? 1 : 0;
const files = new Map();
let fallbackPatches = 0;
let radioIdPatches = 0;

// The pinned package adds a public CDN after the configured font origin.
// Keep even its error fallback inside the application, without changing font coverage.
const fallback = '`https://esm.sh/${M.PKG_NAME?`${M.PKG_NAME}@${M.PKG_VERSION}`:"@excalidraw/excalidraw"}/dist/prod/`';
const localFallback = '(new URL(typeof window.EXCALIDRAW_ASSET_PATH === "string" ? window.EXCALIDRAW_ASSET_PATH : "/design-editor/", window.location.origin).href)';
const toolButton = 'var X=mp.forwardRef(({size:e="medium",visible:o=!0,className:t="",...r},n)=>{let{id:i}=Ke(),a=mp.useRef(null);';
const uniqueToolButton = toolButton.replace('a=mp.useRef(null);', 'a=mp.useRef(null),symphonyToolId=mp.useId();');
const result = await build({
  absWorkingDir: root,
  entryPoints: ["design-editor.jsx"],
  outdir: destination,
  entryNames: "editor-[hash]",
  chunkNames: "chunks/[name]-[hash]",
  assetNames: "files/[name]-[hash]",
  loader: {".woff2": "file"},
  bundle: true,
  // Dependency locations must not enter chunk identities when node_modules is symlinked.
  preserveSymlinks: true,
  splitting: true,
  format: "esm",
  platform: "browser",
  target: ["es2022"],
  minify: true,
  sourcemap: false,
  legalComments: "external",
  metafile: true,
  write: false,
  conditions: ["production"],
  define: {"process.env.NODE_ENV": '"production"', "process.env.IS_PREACT": '"false"'},
  plugins: [{
    name: "pinned-editor-integration-fixes",
    setup(builder) {
      builder.onLoad({filter: /@excalidraw\/excalidraw\/dist\/prod\/.*\.js$/}, async ({path: filename}) => {
        const original = await readFile(filename, "utf8");
        let contents = original;
        if (contents.includes(fallback)) {
          const matches = contents.split(fallback).length - 1;
          if (matches !== 1) throw new Error("Pinned Excalidraw font fallback changed; review the vendor patch.");
          fallbackPatches += matches;
          contents = contents.replace(fallback, localFallback);
        }
        if (contents.includes(toolButton)) {
          const matches = contents.split(toolButton).length - 1;
          const radioId = 'id:`${i}-${r.id}`';
          const radioName = 'type:"radio",name:r.name,"aria-label"';
          if (matches !== 1 || contents.split(radioId).length !== 2 || contents.split(radioName).length !== 2) throw new Error("Pinned Excalidraw ToolButton changed; review the scoped radio patch.");
          radioIdPatches += matches;
          contents = contents.replace(toolButton, uniqueToolButton).replace(radioId, 'id:`${i}-${r.id||"tool"}-${symphonyToolId}`').replace(radioName, 'type:"radio",name:`${i}-${r.name}`,"aria-label"');
        }
        return contents === original ? null : {contents, loader: "js"};
      });
    }
  }]
});
if (fallbackPatches !== 1) throw new Error("Expected one pinned Excalidraw same-origin font patch.");
if (radioIdPatches !== 1) throw new Error("Expected one pinned Excalidraw unique radio ID patch.");
// A separate bundle gives Specification its own Mermaid configuration, independent of the editor importer.
const specificationResult = await build({
  absWorkingDir: root,
  entryPoints: ["specification-diagram.js"],
  outdir: path.join(destination, "specification"),
  entryNames: "diagram-[hash]",
  chunkNames: "chunks/[name]-[hash]",
  assetNames: "files/[name]-[hash]",
  loader: {".woff2": "file"},
  bundle: true, preserveSymlinks: true, splitting: true,
  format: "esm", platform: "browser", target: ["es2022"],
  minify: true, sourcemap: false, legalComments: "external",
  metafile: true, write: false, conditions: ["production"],
  define: {"process.env.NODE_ENV": '"production"'}
});
for (const generated of [result, specificationResult]) {
  for (const file of generated.outputFiles) files.set(slash(path.relative(destination, file.path)), Buffer.from(file.contents));
}

async function walk(directory) {
  const found = [];
  for (const entry of (await readdir(directory, {withFileTypes: true})).sort((a, b) => compare(a.name, b.name))) {
    const filename = path.join(directory, entry.name);
    if (entry.isDirectory()) found.push(...await walk(filename));
    else if (entry.isFile()) found.push(filename);
  }
  return found;
}
for (const filename of await walk(path.join(excalidraw, "fonts"))) {
  // Upstream marks Liberation as server-only; every browser family and Unicode subset is retained.
  if (slash(path.relative(excalidraw, filename)).startsWith("fonts/Liberation/")) continue;
  if (!filename.endsWith(".woff2")) throw new Error("Unexpected pinned font format: " + filename);
  files.set(slash(path.relative(excalidraw, filename)), await readFile(filename));
}

// Include the license files of packages whose code was included in the bundle.
const packageRoots = new Set();
for (const input of Object.keys({...result.metafile.inputs, ...specificationResult.metafile.inputs})) {
  const pieces = slash(input).split("node_modules/");
  if (pieces.length < 2) continue;
  const tail = pieces.at(-1).split("/");
  const name = tail[0].startsWith("@") ? tail.slice(0, 2).join("/") : tail[0];
  packageRoots.add(path.resolve(root, pieces.slice(0, -1).join("node_modules/") + "node_modules/" + name));
}
let notices = "Symphony Design editor third-party notices\n\n";
notices += "Excalidraw 0.18.1's public font fallback is replaced with the configured same-origin asset path.\n\n";
notices += "Excalidraw 0.18.1's ToolButton radio IDs include React.useId and their group names include the app ID, keeping DOM IDs unique and editor tool groups independent.\n\n";
for (const directory of [...packageRoots].sort()) {
  const pkg = JSON.parse(await readFile(path.join(directory, "package.json"), "utf8"));
  notices += `--- ${pkg.name} ${pkg.version} (${pkg.license || "see notice"}) ---\n`;
  const licenses = (await readdir(directory)).filter(name => /^(licen[sc]e|copying|notice)([._-]|$)/i.test(name)).sort();
  const supplied = pkg.name === "@excalidraw/excalidraw" ? "excalidraw" : pkg.name.startsWith("@radix-ui/") ? "radix-ui" : ["fastdom", "react-remove-scroll-bar"].includes(pkg.name) ? pkg.name : null;
  if (!licenses.length && !supplied) throw new Error("Missing bundled package license: " + pkg.name);
  for (const filename of licenses) notices += (await readFile(path.join(directory, filename), "utf8")) + "\n";
  if (!licenses.length) notices += await readFile(path.join(root, "licenses", supplied + ".txt"), "utf8");
  notices += "\n";
}
notices += await readFile(path.join(root, "licenses/fonts.txt"), "utf8");
files.set("THIRD_PARTY_NOTICES.txt", Buffer.from(notices));

const inputs = (await walk(root)).filter(filename => !slash(path.relative(root, filename)).startsWith("node_modules/"));
const sources = Object.fromEntries(await Promise.all(inputs.map(async filename => [slash(path.relative(root, filename)), digest(await readFile(filename))])));
const outputs = Object.entries({...result.metafile.outputs, ...specificationResult.metafile.outputs});
const entry = outputs.find(([, info]) => info.entryPoint === "design-editor.jsx");
if (!entry) throw new Error("Excalidraw entry was not generated.");
const entryPath = slash(path.relative(destination, path.resolve(root, entry[0])));
const cssPath = slash(path.relative(destination, path.resolve(root, entry[1].cssBundle)));
const specificationEntry = outputs.find(([, info]) => info.entryPoint === "specification-diagram.js");
if (!specificationEntry) throw new Error("Specification diagram entry was not generated.");
const specificationPath = slash(path.relative(destination, path.resolve(root, specificationEntry[0])));
const contentType = filename => filename.endsWith(".js") ? "application/javascript" : filename.endsWith(".css") ? "text/css" : filename.endsWith(".woff2") ? "font/woff2" : "text/plain";
const assets = Object.fromEntries([...files.entries()].sort(([a], [b]) => compare(a, b)).map(([filename, bytes]) => [filename, {type: contentType(filename), sha256: digest(bytes), bytes: bytes.length}]));
for (const [filename, details] of outputs) {
  const name = slash(path.relative(destination, path.resolve(root, filename)));
  assets[name].imports = details.imports.filter(item => !(item.kind === "url-token" && /^data:(image|font)\//.test(item.path))).map(item => {
    if (item.external) throw new Error("External runtime import is forbidden: " + item.path);
    const target = slash(path.relative(destination, path.resolve(root, item.path)));
    if (!assets[target]) throw new Error("Bundled runtime import is missing: " + target);
    return target;
  }).sort(compare);
}
const manifest = {version: 1, entry: {js: entryPath, css: cssPath}, specification: {js: specificationPath}, sources, assets};
files.set("manifest.json", Buffer.from(JSON.stringify(manifest, null, 2) + "\n"));
if (check) {
  const actual = (await walk(destination)).map(filename => slash(path.relative(destination, filename))).sort();
  const expected = [...files.keys()].sort();
  if (JSON.stringify(actual) !== JSON.stringify(expected)) throw new Error("Generated editor file list is stale; run npm run build.");
  for (const [filename, bytes] of files) {
    if (!(await readFile(path.join(destination, filename))).equals(bytes)) throw new Error("Generated editor asset is stale: " + filename);
  }
} else {
  await rm(destination, {recursive: true, force: true});
  for (const [filename, bytes] of files) {
    const target = path.join(destination, filename);
    await mkdir(path.dirname(target), {recursive: true});
    await writeFile(target, bytes);
  }
}
console.log(`${check ? "Verified" : "Built"} ${files.size} local editor assets (${[...files.values()].reduce((sum, value) => sum + value.length, 0)} bytes).`);
