// Cravou / Called It — Edge Function: daily-reminder
//
// Lembra quem AINDA não votou no duelo aberto de hoje. Roda no fim da tarde
// (cron separado). Segurança: verify_jwt=false; só service_role.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

Deno.serve(async (req: Request) => {
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const url = Deno.env.get("SUPABASE_URL")!;
  if ((req.headers.get("Authorization") ?? "") !== `Bearer ${serviceKey}`) {
    return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401 });
  }

  const supabase = createClient(url, serviceKey);

  // duelo aberto da temporada ativa
  const { data: seasons } = await supabase.from("seasons").select("id").eq("status", "active").limit(1);
  const seasonId = seasons?.[0]?.id;
  if (!seasonId) return new Response(JSON.stringify({ ok: true, reminded: 0, reason: "no active season" }));

  const { data: duels } = await supabase
    .from("duels").select("id").eq("season_id", seasonId).eq("status", "open").limit(1);
  const duelId = duels?.[0]?.id;
  if (!duelId) return new Response(JSON.stringify({ ok: true, reminded: 0, reason: "no open duel" }));

  // usuários com token, menos quem já votou nesse duelo
  const { data: tokens } = await supabase.from("device_tokens").select("user_id");
  const { data: voters } = await supabase.from("votes").select("user_id").eq("duel_id", duelId);
  const voted = new Set((voters ?? []).map((v: { user_id: string }) => v.user_id));
  const targets = [...new Set((tokens ?? []).map((t: { user_id: string }) => t.user_id))].filter((u) => !voted.has(u));

  if (!targets.length) return new Response(JSON.stringify({ ok: true, reminded: 0 }));

  const res = await fetch(`${url}/functions/v1/send-push`, {
    method: "POST",
    headers: { Authorization: `Bearer ${serviceKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      title: "Palpite do dia 🎯",
      body: "O duelo de hoje te espera — crava antes de fechar! • Today's call awaits",
      userIds: targets,
    }),
  });

  return new Response(JSON.stringify({ ok: true, reminded: res.ok ? targets.length : 0 }), {
    headers: { "Content-Type": "application/json" },
  });
});
