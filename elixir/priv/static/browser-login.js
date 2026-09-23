(() => {
  const form = document.querySelector('form[data-continue="true"]');
  if (!form) return;
  // Back/reload must not repeat the automatic attempt. Google interaction errors
  // return to the ordinary sign-in form, without this script.
  window.history.replaceState(null, "", "/login");
  form.removeAttribute("data-continue");
  form.requestSubmit();
})();
