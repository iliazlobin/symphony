/* Load the self-hosted editor only when a Design workspace is opened. */
(() => {
  const editors = new Map();
  function load(js, css, assets) {
    const paths = [js, css, assets].map(path => new URL(path, document.baseURI));
    if (paths.some(path => path.origin !== window.location.origin || !path.pathname.includes("/design-editor/"))) {
      return Promise.reject(new Error("The design editor must be served by this workspace."));
    }
    if (!editors.has(js)) {
      window.EXCALIDRAW_ASSET_PATH = paths[2].href;
      const sheet = document.createElement("link");
      sheet.rel = "stylesheet"; sheet.href = paths[1].href;
      const styled = new Promise((resolve, reject) => { sheet.onload = resolve; sheet.onerror = () => reject(new Error("The editor stylesheet could not load.")); });
      document.head.append(sheet);
      const loaded = Promise.all([styled, import(paths[0].href)]).then(([, editor]) => editor).catch(error => {
        editors.delete(js); sheet.remove(); throw error;
      });
      editors.set(js, loaded);
    }
    return editors.get(js);
  }
  window.SymphonyDesignCanvas = {load};
})();
