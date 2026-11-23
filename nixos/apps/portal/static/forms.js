// Policy: a form's answer is told once, where the form was, and the address drops it.
const params = new URLSearchParams(location.search);
for (const section of document.querySelectorAll("[data-form]")) {
  const status = params.get(section.dataset.form);
  if (!status) continue;
  const notice = section.querySelector(`[data-status="${CSS.escape(status)}"]`);
  if (notice) notice.hidden = false;
  if (status === "sent") section.querySelector("form").hidden = true;
  params.delete(section.dataset.form);
  history.replaceState(null, "", location.pathname + (params.size ? `?${params}` : "") + location.hash);
}
