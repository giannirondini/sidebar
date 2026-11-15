// Picks up the per-launch API token. SidebArc opens the editor with it in the URL
// fragment (never sent over HTTP); it is moved into this tab's history state at
// once, so it leaves the address bar but survives a reload. Static editor files
// need no token; only /api/ requests carry it (editor.js).
(function () {
  "use strict";

  const token = new URLSearchParams(window.location.hash.slice(1)).get("token")
    || (window.history.state && window.history.state.sidebArcAuthToken);

  if (!token) {
    document.getElementById("status").textContent =
      "This editor tab has expired. Reopen the note from SidebArc.";
    document.getElementById("editor").setAttribute("contenteditable", "false");
    return;
  }

  window.history.replaceState({ sidebArcAuthToken: token }, "", window.location.pathname + window.location.search);
  window.sidebArcAuthToken = token;
})();
