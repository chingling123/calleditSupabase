-- =====================================================================
-- Cravou / Called It — 0014 environment no device_token
-- Guarda o ambiente APNs do token (sandbox = build dev/Xcode; production =
-- TestFlight/App Store). send-push envia ao host certo por token (produção
-- prioritária p/ tokens de produção), com fallback ao outro em BadDeviceToken.
-- =====================================================================
alter table device_tokens add column if not exists environment text not null default 'sandbox';
grant update (environment) on device_tokens to authenticated;
