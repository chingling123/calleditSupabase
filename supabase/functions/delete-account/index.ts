// Cravou / Called It — Edge Function: delete-account
// Apaga PERMANENTEMENTE o usuário autenticado (cascata: profile, votos, cartas,
// scores, achievements, device_tokens). verify_jwt=true → exige JWT do usuário.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

Deno.serve(async (req: Request) => {
  const auth = req.headers.get("Authorization") ?? "";
  const jwt = auth.replace("Bearer ", "");
  if (!jwt) return new Response(JSON.stringify({ error: "no token" }), { status: 401 });

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  const { data: u, error: ue } = await admin.auth.getUser(jwt);
  const uid = u?.user?.id;
  if (ue || !uid) return new Response(JSON.stringify({ error: "invalid user" }), { status: 401 });

  const { error } = await admin.auth.admin.deleteUser(uid);
  if (error) {
    return new Response(JSON.stringify({ ok: false, error: error.message }), {
      status: 500, headers: { "Content-Type": "application/json" },
    });
  }
  return new Response(JSON.stringify({ ok: true }), { headers: { "Content-Type": "application/json" } });
});
