// Alavancagem VNG — Kit Banco (link público, sem login).
//   GET ?t=TOKEN            -> dados do kit (sem score, sem pendências)
//   GET ?t=TOKEN&doc=ID     -> baixa um documento (direto do Google Drive)
//   GET ?t=TOKEN&zip=1      -> baixa todos os documentos num .zip
// O token é a única credencial: link expira em 30 dias e pode ser revogado no app.

import { createClient, SupabaseClient } from "npm:@supabase/supabase-js@2.45.4";
import { zipSync } from "npm:fflate@0.8.2";
import { download, exportInfo, HttpError } from "./google.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
  "Access-Control-Expose-Headers": "Content-Disposition",
};
const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { ...CORS, "Content-Type": "application/json", "Cache-Control": "no-store" } });

const SHOW_DOC_STATUS = ["available"];
const MAX_ZIP = 120 * 1024 * 1024;

function safeName(s: string) { return s.replace(/[\\/:*?"<>|\u0000-\u001f]+/g, "_").slice(0, 150); }
function fileName(doc: Record<string, any>) {
  const ex = exportInfo(doc.mime_type || "");
  let n = safeName(doc.name || "documento");
  if (ex && !n.toLowerCase().endsWith("." + ex.ext)) n += "." + ex.ext;
  return n;
}
function disposition(name: string) {
  const ascii = name.normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/[^\x20-\x7e]/g, "_");
  return `attachment; filename="${ascii.replace(/"/g, "")}"; filename*=UTF-8''${encodeURIComponent(name)}`;
}

async function loadKit(admin: SupabaseClient, token: string) {
  if (!token || token.length < 20) throw new HttpError(404, "Link inválido.");
  const { data: kit } = await admin.from("bank_kits").select("*").eq("token", token).maybeSingle();
  if (!kit) throw new HttpError(404, "Link inválido.");
  if (kit.revoked_at) throw new HttpError(410, "Este link foi desativado pela empresa.");
  if (new Date(kit.expires_at).getTime() < Date.now()) throw new HttpError(410, "Este link expirou. Peça um novo à empresa.");
  return kit;
}

async function visibleDocs(admin: SupabaseClient, companyId: string) {
  const today = new Date().toISOString().slice(0, 10);
  const { data } = await admin.from("documents")
    .select("id,category,name,mime_type,file_size,reference_date,expires_at,source_type,source_external_id,source_url,status")
    .eq("company_id", companyId).in("status", SHOW_DOC_STATUS).order("category").order("name");
  return (data || []).filter((d) => !d.expires_at || d.expires_at >= today);
}

async function event(admin: SupabaseClient, kit: Record<string, any>, ev: "view" | "download", req: Request, docId: string | null = null) {
  await admin.from("bank_kit_events").insert({ kit_id: kit.id, event: ev, document_id: docId, user_agent: (req.headers.get("user-agent") || "").slice(0, 300) });
  const upd: Record<string, unknown> = ev === "view"
    ? { view_count: (kit.view_count || 0) + 1, last_viewed_at: new Date().toISOString() }
    : { download_count: (kit.download_count || 0) + 1 };
  await admin.from("bank_kits").update(upd).eq("id", kit.id);
}

async function kitData(admin: SupabaseClient, kit: Record<string, any>) {
  const cid = kit.company_id;
  const [co, org, req, fps, rev, debts, gars, docs] = await Promise.all([
    admin.from("companies").select("legal_name,trade_name,tax_id,organization_id").eq("id", cid).single(),
    admin.from("companies").select("organizations(name)").eq("id", cid).single(),
    kit.credit_request_id
      ? admin.from("credit_requests").select("requested_amount,desired_term_months,purpose").eq("id", kit.credit_request_id).maybeSingle()
      : Promise.resolve({ data: null }),
    admin.from("financial_periods").select("period_start,period_end,gross_revenue,net_revenue,gross_profit,ebitda,operating_profit,net_income,total_assets,current_assets,cash_equivalents,receivables,inventory,current_liabilities,noncurrent_liabilities,financial_debt,equity")
      .eq("company_id", cid).order("period_end", { ascending: false }).limit(6),
    admin.from("monthly_revenue").select("month,amount").eq("company_id", cid).order("month", { ascending: false }).limit(24),
    admin.from("debts").select("creditor,product_type,outstanding_balance,installment_amount,installments_remaining,reference_date")
      .eq("company_id", cid).eq("status", "active").order("outstanding_balance", { ascending: false }),
    admin.from("guarantees").select("guarantee_type,description,owner_name,registry_number,market_value,existing_liens")
      .eq("company_id", cid).neq("verification_status", "rejected"),
    visibleDocs(admin, cid),
  ]);
  const months = (rev.data || []).slice().reverse();
  const last12 = months.slice(-12);
  const total12 = last12.reduce((s, m) => s + Number(m.amount), 0);
  return {
    kit: { bank_name: kit.bank_name, note: kit.note, created_at: kit.created_at, expires_at: kit.expires_at },
    presented_by: (org.data as any)?.organizations?.name || null,
    company: { legal_name: co.data?.legal_name, trade_name: co.data?.trade_name, tax_id: co.data?.tax_id },
    request: req.data,
    financial_periods: fps.data || [],
    monthly_revenue: months,
    revenue_summary: { months: last12.length, total: total12, average: last12.length ? total12 / last12.length : null },
    debts: debts.data || [],
    debt_total: (debts.data || []).reduce((s, d) => s + Number(d.outstanding_balance || 0), 0),
    guarantees: gars.data || [],
    documents: docs.map((d) => ({ id: d.id, category: d.category, name: fileName(d), reference_date: d.reference_date, expires_at: d.expires_at, size: d.file_size })),
    generated_at: new Date().toISOString(),
  };
}

async function fetchDoc(doc: Record<string, any>): Promise<{ body: Response | null; redirect?: string }> {
  if (doc.source_type === "google_drive" && doc.source_external_id) {
    const { body } = await download({ id: doc.source_external_id, mimeType: doc.mime_type || "application/octet-stream" });
    return { body };
  }
  if (doc.source_url && /^https?:\/\//.test(doc.source_url)) return { body: null, redirect: doc.source_url };
  throw new HttpError(404, "Documento sem arquivo disponível.");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "GET") return json({ error: "Método não permitido" }, 405);
  try {
    const url = new URL(req.url);
    const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
    const kit = await loadKit(admin, url.searchParams.get("t") || "");
    const docId = url.searchParams.get("doc");

    if (docId) {
      const docs = await visibleDocs(admin, kit.company_id);
      const doc = docs.find((d) => d.id === docId);
      if (!doc) throw new HttpError(404, "Documento não disponível neste kit.");
      const r = await fetchDoc(doc);
      await event(admin, kit, "download", req, doc.id);
      if (r.redirect) return new Response(null, { status: 302, headers: { ...CORS, Location: r.redirect } });
      const ex = exportInfo(doc.mime_type || "");
      return new Response(r.body!.body, {
        headers: { ...CORS, "Content-Type": ex?.mime || doc.mime_type || "application/octet-stream", "Content-Disposition": disposition(fileName(doc)), "Cache-Control": "no-store" },
      });
    }

    if (url.searchParams.get("zip")) {
      const docs = (await visibleDocs(admin, kit.company_id)).filter((d) => d.source_type === "google_drive" && d.source_external_id);
      const files: Record<string, Uint8Array> = {};
      let total = 0;
      const skipped: string[] = [];
      for (const d of docs) {
        if (total > MAX_ZIP) { skipped.push(d.name); continue; }
        try {
          const r = await fetchDoc(d);
          const buf = new Uint8Array(await r.body!.arrayBuffer());
          total += buf.byteLength;
          let path = `${safeName(d.category || "Outros")}/${fileName(d)}`;
          let i = 2;
          while (files[path]) path = `${safeName(d.category || "Outros")}/${i++}_${fileName(d)}`;
          files[path] = buf;
        } catch { skipped.push(d.name); }
      }
      if (skipped.length) files["LEIA-ME.txt"] = new TextEncoder().encode("Arquivos não incluídos (baixe individualmente pelo link):\n" + skipped.join("\n"));
      const zip = zipSync(files, { level: 0 });
      await event(admin, kit, "download", req, null);
      const { data: co } = await admin.from("companies").select("legal_name").eq("id", kit.company_id).single();
      return new Response(zip as unknown as BodyInit, {
        headers: { ...CORS, "Content-Type": "application/zip", "Content-Disposition": disposition(`Kit ${safeName(co?.legal_name || "empresa")}.zip`), "Cache-Control": "no-store" },
      });
    }

    const data = await kitData(admin, kit);
    await event(admin, kit, "view", req);
    return json(data);
  } catch (e) {
    const status = e instanceof HttpError ? e.status : 500;
    if (status === 500) console.error(e);
    return json({ error: String((e as Error).message || e) }, status);
  }
});
