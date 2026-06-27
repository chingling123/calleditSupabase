// Cravou / Called It — Edge Function: send-push
//
// Envia push via APNs (token-based auth, ES256 .p8). Reusa a Auth Key do Team.
// Secured: só service_role (header Authorization).
//
// Secrets necessários (supabase secrets set ...):
//   APNS_KEY_ID     - Key ID da .p8 (ex: ABC123DEFG)
//   APNS_TEAM_ID    - Apple Developer Team ID
//   APNS_BUNDLE_ID  - com.calledit.app
//   APNS_KEY        - conteúdo PEM da .p8 (-----BEGIN PRIVATE KEY----- ...)
//   APNS_HOST       - api.sandbox.push.apple.com (dev) | api.push.apple.com (prod)
//
// Body JSON: { "title": string, "body": string, "userIds"?: string[] }
//   userIds ausente => broadcast p/ todos os tokens.

import { createClient } from "jsr:@supabase/supabase-js@2";

const enc = new TextEncoder();

function b64url(data: ArrayBuffer | Uint8Array): string {
  const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
  let s = btoa(String.fromCharCode(...bytes));
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

let cachedJWT: { token: string; iat: number } | null = null;

async function apnsJWT(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedJWT && now - cachedJWT.iat < 3000) return cachedJWT.token;

  const keyId = Deno.env.get("APNS_KEY_ID")!;
  const teamId = Deno.env.get("APNS_TEAM_ID")!;
  const pem = Deno.env.get("APNS_KEY")!;

  const header = b64url(enc.encode(JSON.stringify({ alg: "ES256", kid: keyId })));
  const claims = b64url(enc.encode(JSON.stringify({ iss: teamId, iat: now })));
  const signingInput = `${header}.${claims}`;

  const key = await crypto.subtle.importKey(
    "pkcs8", pemToPkcs8(pem),
    { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"],
  );
  const sig = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" }, key, enc.encode(signingInput),
  );
  const token = `${signingInput}.${b64url(sig)}`;
  cachedJWT = { token, iat: now };
  return token;
}

Deno.serve(async (req: Request) => {
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  if ((req.headers.get("Authorization") ?? "") !== `Bearer ${serviceKey}`) {
    return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401 });
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

  const jwt = await apnsJWT();
  const host = Deno.env.get("APNS_HOST") ?? "api.sandbox.push.apple.com";
  const topic = Deno.env.get("APNS_BUNDLE_ID")!;
  const payload = JSON.stringify({ aps: { alert: { title, body }, sound: "default" } });

  let sent = 0;
  const stale: string[] = [];
  await Promise.all(tokens.map(async (token) => {
    const res = await fetch(`https://${host}/3/device/${token}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${jwt}`,
        "apns-topic": topic,
        "apns-push-type": "alert",
        "content-type": "application/json",
      },
      body: payload,
    });
    if (res.ok) sent++;
    else if (res.status === 410) stale.push(token); // device no longer registered
  }));

  if (stale.length) await supabase.from("device_tokens").delete().in("token", stale);

  return new Response(JSON.stringify({ ok: true, sent, removed: stale.length }), {
    headers: { "Content-Type": "application/json" },
  });
});
