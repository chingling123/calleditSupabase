// Cravou / Called It — Edge Function: send-push
//
// Envia push via APNs (token-based auth, ES256 .p8). Reusa a Auth Key do Team.
// Secured: só service_role (header Authorization == SUPABASE_SERVICE_ROLE_KEY).
//
// Secrets (supabase secrets set ...):
//   APNS_KEY_ID, APNS_TEAM_ID, APNS_BUNDLE_ID (com.calledit.pt), APNS_KEY (.p8 PEM)
//   APNS_HOST (opcional) — se vazio, tenta produção e cai pro sandbox em BadDeviceToken.
//
// Body JSON: { "title": string, "body": string, "userIds"?: string[] }

import { createClient } from "jsr:@supabase/supabase-js@2";

const enc = new TextEncoder();

function b64url(data: ArrayBuffer | Uint8Array): string {
  const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
  const s = btoa(String.fromCharCode(...bytes));
  return s.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToPkcs8(pem: string): Uint8Array {
  const body = pem.replace(/-----BEGIN [^-]+-----/, "")
    .replace(/-----END [^-]+-----/, "").replace(/\s+/g, "");
  const bin = atob(body);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

async function apnsJWT(keyId: string, teamId: string, pem: string): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(enc.encode(JSON.stringify({ alg: "ES256", kid: keyId })));
  const claims = b64url(enc.encode(JSON.stringify({ iss: teamId, iat: now })));
  const signingInput = `${header}.${claims}`;
  const key = await crypto.subtle.importKey(
    "pkcs8", pemToPkcs8(pem),
    { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"],
  );
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, enc.encode(signingInput));
  return `${signingInput}.${b64url(sig)}`;
}

// Tenta produção; se BadDeviceToken/BadEnvironment cai pro sandbox.
async function sendOne(token: string, jwt: string, bundle: string, payload: string, hostEnv: string) {
  const hosts = hostEnv ? [hostEnv] : ["api.push.apple.com", "api.sandbox.push.apple.com"];
  let last = { status: 0, body: "" };
  for (const host of hosts) {
    const res = await fetch(`https://${host}/3/device/${token}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${jwt}`,
        "apns-topic": bundle,
        "apns-push-type": "alert",
        "content-type": "application/json",
      },
      body: payload,
    });
    if (res.ok) return { status: 200, body: "" };
    const body = await res.text();
    last = { status: res.status, body };
    if (!/BadDeviceToken|BadEnvironment/.test(body)) break;
  }
  return last;
}

Deno.serve(async (req: Request) => {
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  if ((req.headers.get("Authorization") ?? "") !== `Bearer ${serviceKey}`) {
    return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401 });
  }

  const keyId = Deno.env.get("APNS_KEY_ID") ?? "";
  const teamId = Deno.env.get("APNS_TEAM_ID") ?? "";
  const bundle = Deno.env.get("APNS_BUNDLE_ID") ?? "";
  const pem = Deno.env.get("APNS_KEY") ?? "";
  const hostEnv = Deno.env.get("APNS_HOST") ?? "";
  const missing = [
    ["APNS_KEY_ID", keyId], ["APNS_TEAM_ID", teamId], ["APNS_BUNDLE_ID", bundle], ["APNS_KEY", pem],
  ].filter(([, v]) => !v).map(([k]) => k);
  if (missing.length) {
    return new Response(JSON.stringify({ ok: false, error: "missing secrets", missing }), { status: 400 });
  }

  const { title, body, userIds } = await req.json().catch(() => ({}));
  if (!title || !body) {
    return new Response(JSON.stringify({ error: "title and body required" }), { status: 400 });
  }

  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, serviceKey);
  let query = supabase.from("device_tokens").select("token");
  if (Array.isArray(userIds) && userIds.length) query = query.in("user_id", userIds);
  const { data: rows, error } = await query;
  if (error) return new Response(JSON.stringify({ ok: false, error: error.message }), { status: 500 });
  const tokens: string[] = (rows ?? []).map((r: { token: string }) => r.token);
  if (!tokens.length) return new Response(JSON.stringify({ ok: true, sent: 0 }));

  let jwt: string;
  try {
    jwt = await apnsJWT(keyId, teamId, pem);
  } catch (e) {
    return new Response(JSON.stringify({ ok: false, error: "apns key invalid: " + String(e) }), { status: 400 });
  }

  const payload = JSON.stringify({ aps: { alert: { title, body }, sound: "default" } });
  const results: { status: number; body?: string }[] = [];
  const stale: string[] = [];
  await Promise.all(tokens.map(async (token) => {
    const r = await sendOne(token, jwt, bundle, payload, hostEnv);
    results.push({ status: r.status, body: r.body || undefined });
    if (r.status === 410 || /BadDeviceToken/.test(r.body)) stale.push(token);
  }));
  if (stale.length) await supabase.from("device_tokens").delete().in("token", stale);

  const sent = results.filter((r) => r.status === 200).length;
  return new Response(JSON.stringify({ ok: true, sent, results }), {
    headers: { "Content-Type": "application/json" },
  });
});
