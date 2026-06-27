// Cravou / Called It — Edge Function: daily-settlement
//
// Roda o ciclo de apuração diária chamando run_daily_settlement() no DB
// (fonte da verdade). Ponto de extensão p/ efeitos externos: push, webhooks.
//
// Segurança: verify_jwt=false. Autoriza só quem apresenta o SERVICE_ROLE_KEY
// no header Authorization (cron via pg_net). Usuário logado comum NÃO dispara.
//
// Agendamento: ver bloco comentado em migrations/0004_cron_and_achievements.sql
// (cron.schedule + net.http_post). O pg_cron que chama run_daily_settlement()
// direto continua válido; use UM dos dois, não ambos.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

Deno.serve(async (req: Request) => {
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const url = Deno.env.get("SUPABASE_URL")!;

  // autorização: só o servidor (portador do service_role key)
  const auth = req.headers.get("Authorization") ?? "";
  if (auth !== `Bearer ${serviceKey}`) {
    return new Response(JSON.stringify({ error: "unauthorized" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }

  const supabase = createClient(url, serviceKey);

  const { error } = await supabase.rpc("run_daily_settlement");
  if (error) {
    console.error("run_daily_settlement failed:", error);
    return new Response(JSON.stringify({ ok: false, error: error.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  // TODO push: após apuração, buscar duelos recém 'settled' e notificar
  // (resultado, pontos, cards dourados). Requer config APNs/FCM.

  return new Response(JSON.stringify({ ok: true }), {
    headers: { "Content-Type": "application/json" },
  });
});
