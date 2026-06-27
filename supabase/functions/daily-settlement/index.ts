// Cravou / Called It — Edge Function: daily-settlement
//
// Roda o ciclo de apuração diária chamando run_daily_settlement() no DB.
// Após apurar, se houve duelo recém-fechado, dispara push (send-push).
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

  // Houve duelo apurado nos últimos 15 min? Se sim, notifica os votantes.
  const since = new Date(Date.now() - 15 * 60 * 1000).toISOString();
  const { data: fresh } = await supabase
    .from("duel_results").select("duel_id").gte("settled_at", since);

  let notified = 0;
  if (fresh && fresh.length) {
    const duelIds = fresh.map((r: { duel_id: string }) => r.duel_id);
    const { data: voters } = await supabase
      .from("votes").select("user_id").in("duel_id", duelIds);
    const userIds = [...new Set((voters ?? []).map((v: { user_id: string }) => v.user_id))];

    if (userIds.length) {
      const res = await fetch(`${url}/functions/v1/send-push`, {
        method: "POST",
        headers: { Authorization: `Bearer ${serviceKey}`, "Content-Type": "application/json" },
        body: JSON.stringify({
          title: "Resultado do dia! 🎯",
          body: "Veja se você cravou • See if you called it",
          userIds,
        }),
      });
      notified = res.ok ? userIds.length : 0;
    }
  }

  return new Response(JSON.stringify({ ok: true, notified }), {
    headers: { "Content-Type": "application/json" },
  });
});
