// Alavancagem VNG — sincronização com o Google Drive.
// Ações (POST JSON {action, ...}):
//   config                      -> e-mail da conta de serviço e quais chaves estão configuradas
//   discover {org_id}           -> lê a pasta-mãe da organização e liga/cria uma empresa por subpasta
//   scan     {company_id}       -> lista os arquivos da pasta da empresa e registra em documents
//   extract  {company_id, run_id, max} -> lê até `max` arquivos pendentes com o Claude e grava os dados
//   finish   {company_id, run_id}      -> consolida dívidas, recalcula o score e fecha o log
// Secrets: GOOGLE_SERVICE_ACCOUNT_JSON, ANTHROPIC_API_KEY, (opcional) ANTHROPIC_MODEL

import { createClient, SupabaseClient } from "npm:@supabase/supabase-js@2.45.4";
import * as XLSX from "npm:xlsx@0.18.5";

function encodeBase64(buf: Uint8Array): string {
  let s = "";
  const CH = 0x8000;
  for (let i = 0; i < buf.length; i += CH) s += String.fromCharCode(...buf.subarray(i, i + CH));
  return btoa(s);
}
import { download, folderIdFromUrl, HttpError, listChildren, serviceAccount, walk, FOLDER } from "./google.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { ...CORS, "Content-Type": "application/json" } });

const MODEL = Deno.env.get("ANTHROPIC_MODEL") || "claude-sonnet-5-5";
const MAX_BYTES = 25 * 1024 * 1024;

/* ---------------- categorias ---------------- */
const norm = (s: string) => s.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase();
export function guessCategory(text: string): string | null {
  const t = " " + norm(text).replace(/[_\-.]+/g, " ") + " ";
  if (/certid|\bcnd\b|\bcndt\b|\bcpen\b|regularidade/.test(t)) {
    if (/trabalh|\btst\b|\bcndt\b/.test(t)) return "Certidão trabalhista";
    if (/fgts|\bcrf\b|caixa/.test(t)) return "FGTS";
    if (/municip|prefeitura|\biss\b/.test(t)) return "Certidão municipal";
    if (/estad|sefaz|\bicms\b|divida ativa estadual/.test(t)) return "Certidão estadual";
    if (/federal|pgfn|\brfb\b|receita federal|tributos federais/.test(t)) return "Certidão federal";
    return null;
  }
  if (/fgts|\bcrf\b/.test(t)) return "FGTS";
  if (/balancete/.test(t)) return "Balancete";
  if (/\bdre\b|demonstra[a-z]* d[oe] resultado|resultado do exercicio/.test(t)) return "DRE";
  if (/balanco|balan[cç]o patrimonial|\bbp\b|demonstra[a-z]* contab|demonstra[a-z]* financ/.test(t)) return "Balanço";
  if (/faturamento|receita bruta|relacao de faturamento|\bfat\b|vendas mensais/.test(t)) return "Faturamento";
  if (/endivid|\bscr\b|registrato|divida[s]? banc|emprestimo|financiamento|posicao banc|extrato de credito/.test(t)) return "Endividamento bancário";
  if (/cartao cnpj|comprovante de inscricao|cnpj/.test(t)) return "Cartão CNPJ";
  if (/contrato social|alteracao contratual|estatuto|consolidad|ato constitutivo|societ/.test(t)) return "Contrato social";
  if (/imposto de renda|\birpf\b|\bdirpf\b|\bir\b/.test(t)) return "IR sócios";
  if (/\bsocio|\brg\b|\bcnh\b|\bcpf\b|comprovante de residencia|identidade/.test(t)) return "Documentos sócios";
  if (/laudo|avaliacao/.test(t)) return "Laudo de avaliação";
  if (/matricula|imovel|imoveis|garantia|escritura|\biptu\b/.test(t)) return "Matrícula de imóvel";
  return null;
}
const NO_EXTRACT = new Set(["IR sócios", "Documentos sócios", "Contrato social"]);
const PRIORITY: Record<string, number> = {
  "Balanço": 1, "DRE": 1, "Balancete": 2, "Faturamento": 1, "Endividamento bancário": 1,
  "Cartão CNPJ": 3, "Matrícula de imóvel": 4, "Laudo de avaliação": 4, "Outros": 6,
};

const SHEET_MIMES = new Set([
  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  "application/vnd.ms-excel", "text/csv", "application/vnd.google-apps.spreadsheet",
  "application/vnd.oasis.opendocument.spreadsheet",
]);
const PDF_MIMES = new Set(["application/pdf", "application/vnd.google-apps.document", "application/vnd.google-apps.presentation"]);
const IMG_MIMES = new Set(["image/jpeg", "image/png", "image/webp", "image/gif"]);
function extractable(mime: string, size: number | null): boolean {
  if (size != null && size > MAX_BYTES) return false;
  return SHEET_MIMES.has(mime) || PDF_MIMES.has(mime) || IMG_MIMES.has(mime);
}

/* ---------------- auth ---------------- */
type Ctx = { admin: SupabaseClient; userId: string };
async function context(req: Request): Promise<Ctx> {
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  const { data, error } = await admin.auth.getUser(jwt);
  if (error || !data.user) throw new HttpError(401, "Sessão inválida. Entre de novo.");
  return { admin, userId: data.user.id };
}
async function roleIn(ctx: Ctx, orgId: string): Promise<string | null> {
  const { data } = await ctx.admin.from("organization_members").select("role").eq("organization_id", orgId).eq("user_id", ctx.userId).maybeSingle();
  return data?.role ?? null;
}
async function requireWriter(ctx: Ctx, companyId: string) {
  const { data: co } = await ctx.admin.from("companies").select("*").eq("id", companyId).maybeSingle();
  if (!co) throw new HttpError(404, "Empresa não encontrada");
  const role = await roleIn(ctx, co.organization_id);
  if (!role || !["owner", "admin", "analyst"].includes(role)) throw new HttpError(403, "Seu papel não permite sincronizar");
  return co;
}

async function addPending(admin: SupabaseClient, companyId: string, code: string, severity: string, title: string, description: string) {
  const { data } = await admin.from("pending_items").select("id").eq("company_id", companyId).eq("code", code).eq("status", "open").maybeSingle();
  if (data) return;
  await admin.from("pending_items").insert({ company_id: companyId, category: "drive", title, description, severity, source: "engine", code });
}

async function logRun(admin: SupabaseClient, runId: string, entry: Record<string, unknown>, inc: Record<string, number> = {}) {
  const { data } = await admin.from("drive_sync_runs").select("log,files_extracted,files_failed").eq("id", runId).maybeSingle();
  if (!data) return;
  const log = Array.isArray(data.log) ? data.log : [];
  log.push({ at: new Date().toISOString(), ...entry });
  const upd: Record<string, unknown> = { log: log.slice(-300) };
  for (const [k, v] of Object.entries(inc)) upd[k] = ((data as Record<string, number>)[k] || 0) + v;
  await admin.from("drive_sync_runs").update(upd).eq("id", runId);
}

/* ---------------- discover ---------------- */
async function discover(ctx: Ctx, orgId: string) {
  const role = await roleIn(ctx, orgId);
  if (!role || !["owner", "admin", "analyst"].includes(role)) throw new HttpError(403, "Seu papel não permite importar empresas");
  const { data: org } = await ctx.admin.from("organizations").select("*").eq("id", orgId).single();
  const rootId = folderIdFromUrl(org?.drive_root_folder_url);
  if (!rootId) throw new HttpError(400, "Cadastre o link da pasta-mãe do Drive na tela Equipe.");
  const children = (await listChildren(rootId)).filter((f) => f.mimeType === FOLDER);
  const { data: cos } = await ctx.admin.from("companies").select("id,legal_name,trade_name,drive_folder_id").eq("organization_id", orgId);
  const companies = cos || [];
  const key = (s: string | null) => s ? norm(s).replace(/\b(ltda|s\/?a|me|epp|eireli|holding)\b/g, "").replace(/[^a-z0-9]/g, "") : "";
  let linked = 0, created = 0, already = 0;
  const ids: string[] = [];
  for (const f of children) {
    const url = `https://drive.google.com/drive/folders/${f.id}`;
    let co = companies.find((c) => c.drive_folder_id === f.id);
    if (co) { already++; ids.push(co.id); continue; }
    const k = key(f.name);
    co = companies.find((c) => !c.drive_folder_id && k && (key(c.legal_name) === k || key(c.trade_name) === k || key(c.legal_name).startsWith(k) || k.startsWith(key(c.legal_name) || "#")));
    if (co) {
      await ctx.admin.from("companies").update({ drive_folder_url: url }).eq("id", co.id);
      co.drive_folder_id = f.id; linked++; ids.push(co.id); continue;
    }
    const { data: ins, error } = await ctx.admin.from("companies").insert({
      organization_id: orgId, legal_name: f.name.trim(), drive_folder_url: url, metadata: { auto_created: true, from_drive_folder: f.name },
    }).select("id").single();
    if (!error && ins) { created++; ids.push(ins.id); companies.push({ id: ins.id, legal_name: f.name, trade_name: null, drive_folder_id: f.id }); }
  }
  return { folders: children.length, already, linked, created, company_ids: ids };
}

/* ---------------- scan ---------------- */
async function scan(ctx: Ctx, companyId: string) {
  const co = await requireWriter(ctx, companyId);
  const folderId = co.drive_folder_id || folderIdFromUrl(co.drive_folder_url);
  if (!folderId) throw new HttpError(400, "Esta empresa não tem pasta do Drive cadastrada.");
  const { data: run } = await ctx.admin.from("drive_sync_runs").insert({ company_id: companyId, started_by: ctx.userId }).select("id").single();
  await ctx.admin.from("companies").update({ drive_sync_status: "running", drive_sync_message: "Lendo a pasta…" }).eq("id", companyId);
  try {
    const files = await walk(folderId);
    const { data: existing } = await ctx.admin.from("documents").select("id,source_external_id,source_modified_at,extraction_status,category")
      .eq("company_id", companyId).eq("source_type", "google_drive");
    const byExt = new Map((existing || []).map((d) => [d.source_external_id, d]));
    let fresh = 0, changed = 0;
    for (const f of files) {
      const size = f.size ? Number(f.size) : null;
      const category = guessCategory(f.name) || guessCategory(f.path) || "Outros";
      const canExtract = extractable(f.mimeType, size) && !NO_EXTRACT.has(category);
      const base = {
        name: f.name, folder_path: f.path || null, mime_type: f.mimeType, file_size: size,
        source_url: f.webViewLink || `https://drive.google.com/file/d/${f.id}/view`, source_modified_at: f.modifiedTime || null,
      };
      const ex = byExt.get(f.id);
      if (!ex) {
        const { error } = await ctx.admin.from("documents").insert({
          company_id: companyId, source_type: "google_drive", source_external_id: f.id, category, status: "available",
          extraction_status: canExtract ? "pending" : (size != null && size > MAX_BYTES ? "skipped" : "not_applicable"),
          extraction_error: size != null && size > MAX_BYTES ? "Arquivo maior que 25 MB" : null, ...base,
        });
        if (!error) fresh++;
      } else {
        const modified = !!f.modifiedTime && !!ex.source_modified_at
          && new Date(f.modifiedTime).getTime() !== new Date(ex.source_modified_at).getTime();
        const upd: Record<string, unknown> = { ...base };
        if (modified && canExtract) { upd.extraction_status = "pending"; changed++; }
        if (ex.extraction_status === "failed" && canExtract) upd.extraction_status = "pending";
        await ctx.admin.from("documents").update(upd).eq("id", ex.id);
        byExt.delete(f.id);
      }
    }
    // arquivos que sumiram do Drive
    const gone = [...byExt.values()].map((d) => d.id);
    if (gone.length) await ctx.admin.from("documents").update({ status: "missing" }).in("id", gone);
    const { count } = await ctx.admin.from("documents").select("id", { count: "exact", head: true }).eq("company_id", companyId).eq("extraction_status", "pending");
    await ctx.admin.from("drive_sync_runs").update({ files_found: files.length, files_new: fresh }).eq("id", run!.id);
    await logRun(ctx.admin, run!.id, { step: "scan", files: files.length, new: fresh, changed, missing: gone.length });
    await ctx.admin.from("companies").update({ drive_sync_message: `${files.length} arquivos; ${count || 0} para ler` }).eq("id", companyId);
    return { run_id: run!.id, found: files.length, new: fresh, changed, missing: gone.length, pending: count || 0 };
  } catch (e) {
    await ctx.admin.from("drive_sync_runs").update({ status: "error", finished_at: new Date().toISOString() }).eq("id", run!.id);
    await logRun(ctx.admin, run!.id, { step: "scan", error: String((e as Error).message) });
    await ctx.admin.from("companies").update({ drive_sync_status: "error", drive_sync_message: String((e as Error).message).slice(0, 300) }).eq("id", companyId);
    throw e;
  }
}

/* ---------------- extração com Claude ---------------- */
const num = { type: ["number", "null"] };
const str = { type: ["string", "null"] };
const TOOL = {
  name: "registrar_documento",
  description: "Registra o tipo do documento e os dados financeiros extraídos.",
  input_schema: {
    type: "object",
    properties: {
      document_type: { type: "string", enum: ["balanco", "dre", "balanco_e_dre", "balancete", "faturamento", "endividamento", "certidao", "cartao_cnpj", "contrato_social", "matricula_imovel", "laudo_avaliacao", "ir_socios", "documento_socio", "outros"] },
      certidao_esfera: { type: ["string", "null"], enum: ["federal", "estadual", "municipal", "trabalhista", "fgts", null] },
      certidao_situacao: { type: ["string", "null"], enum: ["negativa", "positiva_com_efeito_de_negativa", "positiva", null] },
      company: { type: "object", properties: { legal_name: str, tax_id: str } },
      issue_date: { ...str, description: "Data de emissão/referência, AAAA-MM-DD" },
      valid_until: { ...str, description: "Validade, AAAA-MM-DD (certidões)" },
      values_scale_note: { ...str, description: "Se os valores do documento estavam em milhares, diga aqui. Os números retornados devem estar SEMPRE em reais." },
      financial_periods: {
        type: "array",
        items: {
          type: "object",
          properties: {
            period_start: str, period_end: str,
            gross_revenue: num, net_revenue: num, gross_profit: num, ebitda: num, operating_profit: num, net_income: num,
            total_assets: num, current_assets: num, cash_equivalents: num, receivables: num, inventory: num,
            current_liabilities: num, noncurrent_liabilities: num, financial_debt: num, equity: num,
          },
          required: ["period_start", "period_end"],
        },
      },
      monthly_revenue: { type: "array", items: { type: "object", properties: { month: { type: "string", description: "AAAA-MM" }, amount: { type: "number" } }, required: ["month", "amount"] } },
      debts: {
        type: "array",
        items: { type: "object", properties: { creditor: str, product_type: str, outstanding_balance: num, installment_amount: num, installments_remaining: { type: ["integer", "null"] }, reference_date: str } },
      },
      guarantees: {
        type: "array",
        items: { type: "object", properties: { guarantee_type: { type: "string", enum: ["Imóvel", "Veículo", "Recebíveis", "Aplicação financeira", "Equipamento", "Estoque", "Outros"] }, description: str, owner_name: str, registry_number: str, market_value: num, existing_liens: num } },
      },
      confidence: { type: "string", enum: ["alta", "media", "baixa"] },
      warnings: { type: "array", items: { type: "string" } },
      summary: { type: "string", description: "Uma frase em português descrevendo o documento" },
    },
    required: ["document_type", "confidence", "summary"],
  },
};

const PROMPT = (co: Record<string, unknown>, doc: Record<string, unknown>) => `Você é um analista de crédito brasileiro. Leia o documento anexado da empresa ${co.legal_name}${co.tax_id ? ` (CNPJ ${co.tax_id})` : ""} e chame a ferramenta registrar_documento.

Arquivo: "${doc.name}"${doc.folder_path ? ` (pasta: ${doc.folder_path})` : ""}. Hoje: ${new Date().toISOString().slice(0, 10)}.

Regras:
- Todos os valores em REAIS. Se o documento estiver "em milhares" (R$ mil), multiplique por 1.000 e explique em values_scale_note.
- Prejuízo e valores negativos com sinal de menos. Não invente: use null quando o dado não existir.
- Balanço/DRE: um item em financial_periods por exercício ou período que aparecer (inclusive a coluna do ano anterior). period_start/period_end em AAAA-MM-DD. Para balanço sem DRE, use o 1º dia do ano como period_start.
- EBITDA: preencha só se o documento trouxer EBITDA/LAJIDA explicitamente; senão deixe null e preencha operating_profit (lucro operacional / resultado antes do financeiro).
- financial_debt = empréstimos e financiamentos (circulante + não circulante).
- Faturamento: um item por mês (AAAA-MM) com o faturamento bruto do mês.
- Endividamento (SCR/Registrato, relação de dívidas, extratos): um item por contrato/operação com saldo devedor; parcela mensal se houver.
- Matrícula/laudo de imóvel: preencha guarantees com descrição, matrícula, proprietário, valor de avaliação e ônus (hipoteca, alienação) se houver.
- Certidões: esfera, situação e validade.
- Se o CNPJ do documento for de outra empresa, informe em warnings.
- confidence = baixa se o documento estiver ilegível, incompleto ou ambíguo.`;

async function fileContent(doc: Record<string, unknown>): Promise<unknown[]> {
  const { body, mime } = await download({ id: doc.source_external_id as string, mimeType: doc.mime_type as string });
  const buf = new Uint8Array(await body.arrayBuffer());
  if (buf.byteLength > MAX_BYTES) throw new HttpError(413, "Arquivo maior que 25 MB");
  if (mime === "application/pdf") return [{ type: "document", source: { type: "base64", media_type: "application/pdf", data: encodeBase64(buf) } }];
  if (IMG_MIMES.has(mime)) return [{ type: "image", source: { type: "base64", media_type: mime, data: encodeBase64(buf) } }];
  // planilhas -> texto CSV por aba
  const wb = mime === "text/csv" ? XLSX.read(new TextDecoder().decode(buf), { type: "string" }) : XLSX.read(buf, { type: "array" });
  let text = "";
  for (const name of wb.SheetNames.slice(0, 12)) {
    const csv = XLSX.utils.sheet_to_csv(wb.Sheets[name], { blankrows: false });
    text += `\n### Aba: ${name}\n${csv}\n`;
    if (text.length > 180000) break;
  }
  return [{ type: "text", text: "Conteúdo da planilha (CSV por aba):\n" + text.slice(0, 180000) }];
}

async function askClaude(content: unknown[], prompt: string) {
  const key = Deno.env.get("ANTHROPIC_API_KEY");
  if (!key) throw new HttpError(503, "A chave da Anthropic ainda não foi configurada (secret ANTHROPIC_API_KEY).");
  const r = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
    body: JSON.stringify({
      model: MODEL, max_tokens: 8000, tools: [TOOL], tool_choice: { type: "tool", name: TOOL.name },
      messages: [{ role: "user", content: [...content, { type: "text", text: prompt }] }],
    }),
  });
  const j = await r.json();
  if (!r.ok) throw new HttpError(502, "Claude: " + (j?.error?.message || r.status));
  const tool = (j.content || []).find((c: { type: string }) => c.type === "tool_use");
  if (!tool) throw new HttpError(502, "Claude não retornou dados estruturados");
  return { data: tool.input as Record<string, any>, model: j.model as string };
}

const TYPE_CAT: Record<string, string> = {
  balanco: "Balanço", dre: "DRE", balanco_e_dre: "Balanço", balancete: "Balancete", faturamento: "Faturamento",
  endividamento: "Endividamento bancário", cartao_cnpj: "Cartão CNPJ", contrato_social: "Contrato social",
  matricula_imovel: "Matrícula de imóvel", laudo_avaliacao: "Laudo de avaliação", ir_socios: "IR sócios",
  documento_socio: "Documentos sócios", outros: "Outros",
};
const CERT_CAT: Record<string, string> = {
  federal: "Certidão federal", estadual: "Certidão estadual", municipal: "Certidão municipal", trabalhista: "Certidão trabalhista", fgts: "FGTS",
};
const isDate = (s: unknown) => typeof s === "string" && /^\d{4}-\d{2}-\d{2}$/.test(s) && !isNaN(Date.parse(s));
const digits = (s: unknown) => String(s || "").replace(/\D/g, "");
const close = (a: number | null, b: number | null) => a == null || b == null ? a == b : Math.abs(a - b) <= Math.max(1, Math.abs(b) * 0.01);

const FP_FIELDS = ["gross_revenue", "net_revenue", "gross_profit", "ebitda", "operating_profit", "net_income", "total_assets", "current_assets",
  "cash_equivalents", "receivables", "inventory", "current_liabilities", "noncurrent_liabilities", "financial_debt", "equity"];

async function applyExtraction(admin: SupabaseClient, co: Record<string, any>, doc: Record<string, any>, ex: Record<string, any>, model: string) {
  const notes: string[] = [];
  const cat = ex.document_type === "certidao" ? (CERT_CAT[ex.certidao_esfera] || doc.category) : (TYPE_CAT[ex.document_type] || doc.category);
  const today = new Date().toISOString().slice(0, 10);
  let docStatus = "available";
  if (isDate(ex.valid_until) && ex.valid_until < today) docStatus = "expired";
  if (ex.document_type === "certidao" && ex.certidao_situacao === "positiva") docStatus = "needs_review";

  // CNPJ de outra empresa: não aplica dados
  const docCnpj = digits(ex.company?.tax_id), coCnpj = digits(co.tax_id);
  const otherCompany = docCnpj.length === 14 && coCnpj.length === 14 && docCnpj !== coCnpj;
  if (otherCompany) {
    docStatus = "inconsistent";
    await addPending(admin, co.id, "drive_cnpj_" + doc.id, "high", `Documento de outro CNPJ: ${doc.name}`,
      `O arquivo traz o CNPJ ${ex.company.tax_id}, diferente do cadastro (${co.tax_id}). Os dados dele não foram usados.`);
  }

  // completa cadastro da empresa
  if (!otherCompany && docCnpj.length === 14) {
    const upd: Record<string, unknown> = {};
    if (!coCnpj) upd.tax_id = ex.company.tax_id;
    if (co.metadata?.auto_created && ex.company?.legal_name && ["cartao_cnpj", "contrato_social", "balanco", "balanco_e_dre", "dre"].includes(ex.document_type)) {
      upd.legal_name = ex.company.legal_name;
      upd.metadata = { ...(co.metadata || {}), auto_created: false };
    }
    if (Object.keys(upd).length) {
      const { error } = await admin.from("companies").update(upd).eq("id", co.id);
      if (!error) { Object.assign(co, upd); notes.push("cadastro da empresa completado"); }
    }
  }

  let applied = 0;
  if (!otherCompany) {
    // balanço / DRE
    for (const p of (ex.financial_periods || [])) {
      if (!isDate(p.period_start) || !isDate(p.period_end) || p.period_end < p.period_start) continue;
      const row: Record<string, unknown> = { period_start: p.period_start, period_end: p.period_end, source_document_id: doc.id };
      let any = false;
      for (const k of FP_FIELDS) { if (typeof p[k] === "number") { row[k] = p[k]; any = true; } }
      if (!any) continue;
      const { data: cur } = await admin.from("financial_periods").select("*").eq("company_id", co.id).eq("period_end", p.period_end).maybeSingle();
      if (!cur) { await admin.from("financial_periods").insert({ company_id: co.id, ...row }); applied++; continue; }
      if (cur.source_document_id) {
        // mescla: campos novos sobrescrevem, ausentes ficam
        const merged: Record<string, unknown> = {};
        for (const k of Object.keys(row)) merged[k] = row[k];
        await admin.from("financial_periods").update(merged).eq("id", cur.id); applied++;
      } else {
        const diff = FP_FIELDS.filter((k) => typeof p[k] === "number" && cur[k] != null && !close(p[k], Number(cur[k])));
        const fill: Record<string, unknown> = {};
        for (const k of FP_FIELDS) if (typeof p[k] === "number" && cur[k] == null) fill[k] = p[k];
        if (Object.keys(fill).length) { await admin.from("financial_periods").update(fill).eq("id", cur.id); applied++; }
        if (diff.length) await addPending(admin, co.id, `drive_conflito_fp_${p.period_end}`, "medium", `Balanço ${p.period_end}: Drive difere do lançado à mão`,
          `Campos diferentes: ${diff.join(", ")} (arquivo ${doc.name}). Mantive o valor manual.`);
      }
    }
    // faturamento
    const months = (ex.monthly_revenue || []).filter((m: any) => /^\d{4}-\d{2}$/.test(m.month) && typeof m.amount === "number" && m.amount >= 0);
    if (months.length) {
      const keys = months.map((m: any) => m.month + "-01");
      const { data: cur } = await admin.from("monthly_revenue").select("*").eq("company_id", co.id).in("month", keys);
      const byM = new Map((cur || []).map((r) => [String(r.month).slice(0, 10), r]));
      const conflicts: string[] = [];
      for (const m of months) {
        const k = m.month + "-01", c = byM.get(k);
        if (!c) { await admin.from("monthly_revenue").insert({ company_id: co.id, month: k, amount: m.amount, source_document_id: doc.id }); applied++; }
        else if (c.source_document_id) { if (!close(m.amount, Number(c.amount)) || c.source_document_id !== doc.id) { await admin.from("monthly_revenue").update({ amount: m.amount, source_document_id: doc.id }).eq("id", c.id); applied++; } }
        else if (!close(m.amount, Number(c.amount))) conflicts.push(m.month);
      }
      if (conflicts.length) await addPending(admin, co.id, "drive_conflito_fat_" + doc.id, "medium", "Faturamento do Drive difere do lançado à mão",
        `Meses ${conflicts.join(", ")} no arquivo ${doc.name}. Mantive os valores manuais.`);
    }
    // dívidas (substitui as que vieram deste mesmo arquivo)
    const debts = (ex.debts || []).filter((d: any) => typeof d.outstanding_balance === "number" || typeof d.installment_amount === "number");
    if (debts.length) {
      await admin.from("debts").delete().eq("company_id", co.id).eq("source_document_id", doc.id);
      await admin.from("debts").insert(debts.map((d: any) => ({
        company_id: co.id, source_document_id: doc.id, status: "active",
        creditor: d.creditor || "Não identificado", product_type: d.product_type || null,
        outstanding_balance: typeof d.outstanding_balance === "number" ? Math.abs(d.outstanding_balance) : null,
        installment_amount: typeof d.installment_amount === "number" ? Math.abs(d.installment_amount) : null,
        installments_remaining: Number.isInteger(d.installments_remaining) && d.installments_remaining >= 0 ? d.installments_remaining : null,
        reference_date: isDate(d.reference_date) ? d.reference_date : (isDate(ex.issue_date) ? ex.issue_date : null),
      })));
      applied += debts.length;
    }
    // garantias (substitui as deste arquivo; entram como pendentes de verificação)
    const gars = (ex.guarantees || []).filter((g: any) => g.description || g.registry_number || typeof g.market_value === "number");
    if (gars.length) {
      await admin.from("guarantees").delete().eq("company_id", co.id).eq("source_document_id", doc.id).eq("verification_status", "pending");
      await admin.from("guarantees").insert(gars.map((g: any) => ({
        company_id: co.id, source_document_id: doc.id, verification_status: "pending",
        guarantee_type: g.guarantee_type || "Imóvel", description: g.description || null, owner_name: g.owner_name || null,
        registry_number: g.registry_number || null,
        market_value: typeof g.market_value === "number" ? Math.abs(g.market_value) : null,
        existing_liens: typeof g.existing_liens === "number" ? Math.abs(g.existing_liens) : null,
      })));
      applied += gars.length;
    }
  }

  const needsReview = otherCompany || ex.confidence === "baixa";
  if (ex.confidence === "baixa") await addPending(admin, co.id, "drive_revisar_" + doc.id, "medium", `Revisar leitura: ${doc.name}`,
    (ex.warnings || []).join(" ") || "A leitura automática teve baixa confiança.");
  if (ex.document_type === "certidao" && ex.certidao_situacao === "positiva") await addPending(admin, co.id, "drive_cert_" + doc.id, "high",
    `Certidão positiva: ${doc.name}`, "A certidão indica débitos. Regularize ou obtenha certidão positiva com efeito de negativa.");

  await admin.from("documents").update({
    category: cat, status: docStatus,
    reference_date: isDate(ex.issue_date) ? ex.issue_date : doc.reference_date,
    expires_at: isDate(ex.valid_until) ? ex.valid_until : doc.expires_at,
    extracted_data: { ...ex, _model: model, _applied: applied, _notes: notes },
    extraction_status: needsReview ? "needs_review" : "extracted",
    extracted_at: new Date().toISOString(), extraction_error: null,
  }).eq("id", doc.id);
  return { applied, category: cat, confidence: ex.confidence, summary: ex.summary };
}

async function extract(ctx: Ctx, companyId: string, runId: string | null, max: number) {
  const co = await requireWriter(ctx, companyId);
  const { data: pend } = await ctx.admin.from("documents").select("*").eq("company_id", companyId).eq("extraction_status", "pending");
  const list = (pend || []).sort((a, b) => (PRIORITY[a.category] || 5) - (PRIORITY[b.category] || 5)
    || String(b.source_modified_at || "").localeCompare(String(a.source_modified_at || "")));
  const results: unknown[] = [];
  const started = Date.now();
  for (const doc of list.slice(0, Math.max(1, Math.min(max || 2, 4)))) {
    if (Date.now() - started > 90_000) break;
    try {
      const content = await fileContent(doc);
      const { data, model } = await askClaude(content, PROMPT(co, doc));
      const r = await applyExtraction(ctx.admin, co, doc, data, model);
      results.push({ id: doc.id, name: doc.name, ok: true, ...r });
      if (runId) await logRun(ctx.admin, runId, { step: "extract", file: doc.name, ...r }, { files_extracted: 1 });
    } catch (e) {
      const msg = String((e as Error).message || e).slice(0, 500);
      const fatal = e instanceof HttpError && e.status === 503;
      await ctx.admin.from("documents").update({ extraction_status: fatal ? "pending" : "failed", extraction_error: msg }).eq("id", doc.id);
      results.push({ id: doc.id, name: doc.name, ok: false, error: msg });
      if (runId) await logRun(ctx.admin, runId, { step: "extract", file: doc.name, error: msg }, { files_failed: 1 });
      if (fatal) throw e;
    }
  }
  const { count } = await ctx.admin.from("documents").select("id", { count: "exact", head: true }).eq("company_id", companyId).eq("extraction_status", "pending");
  await ctx.admin.from("companies").update({ drive_sync_message: `${count || 0} arquivo(s) ainda para ler` }).eq("id", companyId);
  return { processed: results.length, remaining: count || 0, results };
}

/* ---------------- finish ---------------- */
async function finish(ctx: Ctx, companyId: string, runId: string | null) {
  await requireWriter(ctx, companyId);
  // dívidas: vale só o relatório de endividamento mais recente
  const { data: endiv } = await ctx.admin.from("documents").select("id,reference_date,source_modified_at")
    .eq("company_id", companyId).eq("category", "Endividamento bancário").in("extraction_status", ["extracted", "needs_review"]);
  if (endiv && endiv.length > 1) {
    const { data: withDebts } = await ctx.admin.from("debts").select("source_document_id").eq("company_id", companyId).not("source_document_id", "is", null);
    const ids = new Set((withDebts || []).map((d) => d.source_document_id));
    const cands = endiv.filter((d) => ids.has(d.id)).sort((a, b) =>
      String(b.reference_date || b.source_modified_at || "").localeCompare(String(a.reference_date || a.source_modified_at || "")));
    if (cands.length > 1) {
      const old = cands.slice(1).map((d) => d.id);
      await ctx.admin.from("debts").delete().eq("company_id", companyId).in("source_document_id", old);
    }
  }
  // recalcula score geral e dos pedidos em andamento
  const { data: reqs } = await ctx.admin.from("credit_requests").select("id").eq("company_id", companyId).not("status", "in", "(approved,rejected,cancelled)");
  const scores: unknown[] = [];
  const g = await ctx.admin.rpc("calculate_leverage_score", { p_company_id: companyId });
  if (g.error) scores.push({ error: g.error.message });
  for (const r of reqs || []) {
    const { data: last } = await ctx.admin.from("leverage_scores").select("rationale").eq("credit_request_id", r.id).order("created_at", { ascending: false }).limit(1).maybeSingle();
    const rate = Number(last?.rationale?.assumed_monthly_rate ?? 0.02);
    const x = await ctx.admin.rpc("calculate_leverage_score", { p_company_id: companyId, p_credit_request_id: r.id, p_monthly_rate: rate });
    if (x.error) scores.push({ request: r.id, error: x.error.message });
  }
  const { count: failed } = await ctx.admin.from("documents").select("id", { count: "exact", head: true }).eq("company_id", companyId).eq("extraction_status", "failed");
  const { count: pending } = await ctx.admin.from("documents").select("id", { count: "exact", head: true }).eq("company_id", companyId).eq("extraction_status", "pending");
  const status = (failed || 0) + (pending || 0) > 0 ? "partial" : "ok";
  const msg = status === "ok" ? "Sincronizado" : `${failed || 0} com erro, ${pending || 0} pendente(s)`;
  await ctx.admin.from("companies").update({ drive_sync_status: status, drive_sync_message: msg, drive_last_sync_at: new Date().toISOString() }).eq("id", companyId);
  if (runId) {
    await ctx.admin.from("drive_sync_runs").update({ status, finished_at: new Date().toISOString() }).eq("id", runId);
    await logRun(ctx.admin, runId, { step: "finish", status, scores });
  }
  return { status, message: msg };
}

/* ---------------- servidor ---------------- */
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const body = await req.json().catch(() => ({}));
    const ctx = await context(req);
    switch (body.action) {
      case "config": {
        const sa = serviceAccount();
        return json({ service_account_email: sa?.client_email || null, google: !!sa, anthropic: !!Deno.env.get("ANTHROPIC_API_KEY"), model: MODEL });
      }
      case "discover": return json(await discover(ctx, body.org_id));
      case "scan": return json(await scan(ctx, body.company_id));
      case "extract": return json(await extract(ctx, body.company_id, body.run_id || null, body.max || 2));
      case "finish": return json(await finish(ctx, body.company_id, body.run_id || null));
      default: return json({ error: "Ação inválida" }, 400);
    }
  } catch (e) {
    const status = e instanceof HttpError ? e.status : 500;
    console.error(e);
    return json({ error: String((e as Error).message || e) }, status);
  }
});
