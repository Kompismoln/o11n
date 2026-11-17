const config = JSON.parse(document.getElementById("auth-config").textContent);
const endpoint = `${config.issuer}/protocol/openid-connect`;
const here = () => location.origin + location.pathname;

const base64url = (bytes) =>
  btoa(String.fromCharCode(...new Uint8Array(bytes)))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");

const random = () => base64url(crypto.getRandomValues(new Uint8Array(32)));

const claims = (token) => {
  const payload = atob(token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/"));
  return JSON.parse(new TextDecoder().decode(Uint8Array.from(payload, (c) => c.charCodeAt(0))));
};

async function login() {
  const verifier = random();
  const state = random();
  sessionStorage.setItem("auth.pending", JSON.stringify({ verifier, state }));
  const challenge = base64url(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier)));
  location.assign(
    `${endpoint}/auth?` +
      new URLSearchParams({
        client_id: config.clientId,
        response_type: "code",
        scope: "openid",
        redirect_uri: here(),
        state,
        code_challenge: challenge,
        code_challenge_method: "S256",
      }),
  );
}

function logout() {
  const token = sessionStorage.getItem("auth.id_token");
  sessionStorage.removeItem("auth.id_token");
  const params = new URLSearchParams({ client_id: config.clientId, post_logout_redirect_uri: here() });
  if (token) params.set("id_token_hint", token);
  location.assign(`${endpoint}/logout?${params}`);
}

// Policy: the code is exchanged where it lands, and the address drops it, so that a reload or a shared link doesn't
// carry it.
async function landed() {
  const params = new URLSearchParams(location.search);
  if (!params.has("state")) return;
  const code = params.get("code");
  const state = params.get("state");
  const pending = JSON.parse(sessionStorage.getItem("auth.pending") || "null");
  sessionStorage.removeItem("auth.pending");
  for (const key of ["code", "state", "session_state", "iss", "error", "error_description"]) params.delete(key);
  history.replaceState(null, "", here() + (params.size ? `?${params}` : "") + location.hash);
  if (!code || !pending || pending.state !== state) return;
  sessionStorage.setItem("auth.id_token", await exchange(code, pending.verifier));
}

async function exchange(code, verifier) {
  const response = await fetch(`${endpoint}/token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "authorization_code",
      client_id: config.clientId,
      code,
      redirect_uri: here(),
      code_verifier: verifier,
    }),
  });
  if (!response.ok) throw new Error(`${response.status} ${await response.text()}`);
  return (await response.json()).id_token;
}

function show() {
  const root = document.getElementById("auth");
  const token = sessionStorage.getItem("auth.id_token");
  const who = token && claims(token);
  root.querySelector('[data-auth="login"]').hidden = Boolean(who);
  root.querySelector('[data-auth="who"]').hidden = !who;
  if (who) root.querySelector('[data-auth="name"]').textContent = who.name || who.preferred_username;
  root.hidden = false;
}

document.querySelector('[data-auth="login"]').addEventListener("click", login);
document.querySelector('[data-auth="logout"]').addEventListener("click", logout);

landed()
  .catch((error) => console.error("login:", error))
  .finally(show);
