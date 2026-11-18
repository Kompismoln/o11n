// Policy: the form's answer is told once, where the form was, and the address drops it.
const params = new URLSearchParams(location.search);
const status = params.get("invite");
if (status) {
  const notice = document.querySelector(`[data-invite="${CSS.escape(status)}"]`);
  if (notice) notice.hidden = false;
  if (status === "sent") document.querySelector(".invite-form").hidden = true;
  params.delete("invite");
  history.replaceState(null, "", location.pathname + (params.size ? `?${params}` : "") + location.hash);
}
