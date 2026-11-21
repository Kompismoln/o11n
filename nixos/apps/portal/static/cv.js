const now = new Date().toISOString().slice(0, 7);
const months = [...document.querySelectorAll(".months [data-month]")];
months.forEach((month, i) => {
  const next = months[i + 1];
  if (next && next.dataset.month <= now) month.hidden = true;
});
