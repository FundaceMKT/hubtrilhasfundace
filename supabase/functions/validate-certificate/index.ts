import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "https://hubtrilhasfundace.vercel.app",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const admin = createClient(supabaseUrl, serviceRoleKey, {
  auth: { persistSession: false, autoRefreshToken: false },
});

function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ ok: false, error: "Método não permitido." }, 405);

  let payload: { code?: string };
  try { payload = await req.json(); }
  catch { return json({ ok: false, error: "Requisição inválida." }, 400); }

  const code = String(payload.code ?? "").trim().toUpperCase();
  if (!/^FDC-[A-Z0-9-]{6,80}$/.test(code)) {
    return json({ ok: true, valid: false });
  }

  const { data: start, error } = await admin
    .from("user_trilha_starts")
    .select("user_id,lead_id,trilha_slug,trilha_nome,certificate_code,certificate_issued_at")
    .eq("certificate_code", code)
    .not("certificate_issued_at", "is", null)
    .maybeSingle();

  if (error) {
    console.error("certificate lookup failed", error);
    return json({ ok: false, error: "Não foi possível validar o certificado agora." }, 500);
  }
  if (!start) {
    const { data: issued, error: manualError } = await admin
      .from("admin_trail_certificates")
      .select("nome_impresso,trilha_nome,certificate_code,certificate_issued_at")
      .eq("certificate_code", code)
      .maybeSingle();
    if (manualError) {
      console.error("manual certificate lookup failed", manualError);
      return json({ ok: false, error: "Não foi possível validar o certificado agora." }, 500);
    }
    if (!issued) return json({ ok: true, valid: false });
    return json({
      ok: true,
      valid: true,
      certificate: {
        code: issued.certificate_code,
        name: issued.nome_impresso,
        trail: issued.trilha_nome,
        issuedAt: issued.certificate_issued_at,
      },
    });
  }

  let name = "";
  if (start.lead_id) {
    const { data: lead } = await admin
      .from("leads")
      .select("nome")
      .eq("id", start.lead_id)
      .maybeSingle();
    name = String(lead?.nome ?? "").trim();
  }

  if (!name && start.user_id) {
    const { data: userData } = await admin.auth.admin.getUserById(start.user_id);
    name = String(
      userData?.user?.user_metadata?.name ??
      userData?.user?.user_metadata?.nome ??
      ""
    ).trim();
  }

  if (!name) name = "Aluno(a) certificado(a)";

  return json({
    ok: true,
    valid: true,
    certificate: {
      code: start.certificate_code,
      name,
      trail: start.trilha_nome || start.trilha_slug,
      issuedAt: start.certificate_issued_at,
    },
  });
});
