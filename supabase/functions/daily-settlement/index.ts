// Cravou / Called It — Edge Function: daily-settlement
//
// Roda a apuração diária (run_daily_settlement) e dispara pushes:
//  - resultado do dia → votantes dos duelos recém-apurados
//  - nova temporada → broadcast quando o duelo do dia 1 de uma season abre (rollover)
// Segurança: verify_jwt=false. Só service_role (header Authorization).

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

Deno.serve(async (req: Request) => {
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const url = Deno.env.get("SUPABASE_URL")!;

  if ((req.headers.get("Authorization") ?? "") !== `Bearer ${serviceKey}`) {
    return new Response(JSON.stringify({ error: "unauthorized" }), {
      status: 401, headers: { "Content-Type": "application/json" },
    });
  }

  const supabase = createClient(url, serviceKey);

  const { error } = await supabase.rpc("run_daily_settlement");
  if (error) {
    console.error("run_daily_settlement failed:", error);
    return new Response(JSON.stringify({ ok: false, error: error.message }), {
      status: 500, headers: { "Content-Type": "application/json" },
    });
  }

  const since = new Date(Date.now() - 15 * 60 * 1000).toISOString();
  const push = (body: Record<string, unknown>) =>
    fetch(`${url}/functions/v1/send-push`, {
      method: "POST",
      headers: { Authorization: `Bearer ${serviceKey}`, "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });

  // 1) resultado do dia → votantes
  let notified = 0;
  const { data: fresh } = await supabase
    .from("duel_results").select("duel_id").gte("settled_at", since);
  if (fresh && fresh.length) {
    const duelIds = fresh.map((r: { duel_id: string }) => r.duel_id);
    const { data: voters } = await supabase.from("votes").select("user_id").in("duel_id", duelIds);
    const userIds = [...new Set((voters ?? []).map((v: { user_id: string }) => v.user_id))];
    if (userIds.length) {
      const res = await push({
        title: "Resultado do dia! 🎯",
        body: "Veja se você cravou • See if you called it",
        userIds,
      });
      notified = res.ok ? userIds.length : 0;
    }
  }

  // 2) nova temporada → broadcast (duelo do dia 1 recém-aberto = rollover)
  let newSeason = false;
  const { data: starts } = await supabase
    .from("duels").select("opens_at, season:seasons(theme, emoji)")
    .eq("day_number", 1).eq("status", "open").gte("opens_at", since);
  if (starts && starts.length) {
    const s = (starts[0] as { season: { theme: string; emoji: string } }).season;
    await push({
      title: `Nova temporada! ${s?.emoji ?? "🎉"}`,
      body: `${s?.theme ?? "Nova rodada"} começou — crave o palpite do dia 🎯`,
    });
    newSeason = true;
  }

  return new Response(JSON.stringify({ ok: true, notified, newSeason }), {
    headers: { "Content-Type": "application/json" },
  });
});
