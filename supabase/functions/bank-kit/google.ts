// Acesso ao Google Drive com conta de serviço (somente leitura).
// Secret necessário: GOOGLE_SERVICE_ACCOUNT_JSON (conteúdo do arquivo .json da chave).

export class HttpError extends Error {
  status: number;
  constructor(status: number, message: string) { super(message); this.status = status; }
}

type SA = { client_email: string; private_key: string };
let cachedSA: SA | null = null;
let cachedToken: { token: string; exp: number } | null = null;

export function serviceAccount(): SA | null {
  if (cachedSA) return cachedSA;
  const raw = Deno.env.get("GOOGLE_SERVICE_ACCOUNT_JSON");
  if (!raw) return null;
  try {
    const j = JSON.parse(raw);
    if (!j.client_email || !j.private_key) return null;
    cachedSA = { client_email: j.client_email, private_key: j.private_key };
    return cachedSA;
  } catch { return null; }
}

function b64url(bytes: Uint8Array | string): string {
  const b = typeof bytes === "string" ? new TextEncoder().encode(bytes) : bytes;
  let s = "";
  for (let i = 0; i < b.length; i++) s += String.fromCharCode(b[i]);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function importKey(pem: string): Promise<CryptoKey> {
  const body = pem.replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\\n|\s/g, "");
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  return crypto.subtle.importKey("pkcs8", der, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
}

export async function googleToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedToken && cachedToken.exp - 60 > now) return cachedToken.token;
  const sa = serviceAccount();
  if (!sa) throw new HttpError(503, "A conta de serviço do Google ainda não foi configurada (secret GOOGLE_SERVICE_ACCOUNT_JSON).");
  const header = b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = b64url(JSON.stringify({
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/drive.readonly",
    aud: "https://oauth2.googleapis.com/token",
    iat: now, exp: now + 3600,
  }));
  const key = await importKey(sa.private_key);
  const sig = new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(`${header}.${claims}`)));
  const jwt = `${header}.${claims}.${b64url(sig)}`;
  const r = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: jwt }),
  });
  const j = await r.json();
  if (!r.ok) throw new HttpError(502, "Google recusou a conta de serviço: " + (j.error_description || j.error || r.status));
  cachedToken = { token: j.access_token, exp: now + (j.expires_in || 3600) };
  return cachedToken.token;
}

export type DriveFile = {
  id: string; name: string; mimeType: string; modifiedTime?: string; size?: string;
  webViewLink?: string; shortcutDetails?: { targetId: string; targetMimeType: string };
};

const FIELDS = "nextPageToken,files(id,name,mimeType,modifiedTime,size,webViewLink,shortcutDetails)";

async function gfetch(url: string): Promise<Response> {
  const token = await googleToken();
  const r = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
  if (r.status === 404 || r.status === 403) {
    const t = await r.text();
    throw new HttpError(r.status, r.status === 404
      ? "Pasta ou arquivo não encontrado. Confira se foi compartilhado com " + (serviceAccount()?.client_email || "a conta de serviço") + "."
      : "Sem acesso no Google Drive: " + t.slice(0, 200));
  }
  if (!r.ok) throw new HttpError(502, `Google Drive respondeu ${r.status}: ${(await r.text()).slice(0, 200)}`);
  return r;
}

export async function listChildren(folderId: string): Promise<DriveFile[]> {
  const out: DriveFile[] = [];
  let page: string | undefined;
  do {
    const u = new URL("https://www.googleapis.com/drive/v3/files");
    u.searchParams.set("q", `'${folderId}' in parents and trashed = false`);
    u.searchParams.set("fields", FIELDS);
    u.searchParams.set("pageSize", "1000");
    u.searchParams.set("supportsAllDrives", "true");
    u.searchParams.set("includeItemsFromAllDrives", "true");
    if (page) u.searchParams.set("pageToken", page);
    const j = await (await gfetch(u.toString())).json();
    out.push(...(j.files || []));
    page = j.nextPageToken;
  } while (page);
  return out;
}

export async function getFile(id: string): Promise<DriveFile> {
  const u = new URL(`https://www.googleapis.com/drive/v3/files/${id}`);
  u.searchParams.set("fields", "id,name,mimeType,modifiedTime,size,webViewLink,shortcutDetails");
  u.searchParams.set("supportsAllDrives", "true");
  return await (await gfetch(u.toString())).json();
}

export const FOLDER = "application/vnd.google-apps.folder";
export const SHORTCUT = "application/vnd.google-apps.shortcut";

// Percorre a pasta recursivamente. Retorna arquivos com o caminho relativo.
export async function walk(rootId: string, maxDepth = 5, maxFiles = 3000): Promise<Array<DriveFile & { path: string }>> {
  const files: Array<DriveFile & { path: string }> = [];
  const queue: Array<{ id: string; path: string; depth: number }> = [{ id: rootId, path: "", depth: 0 }];
  const seen = new Set<string>();
  while (queue.length && files.length < maxFiles) {
    const cur = queue.shift()!;
    if (seen.has(cur.id)) continue;
    seen.add(cur.id);
    for (const f of await listChildren(cur.id)) {
      let item = f;
      if (f.mimeType === SHORTCUT && f.shortcutDetails) {
        try { item = { ...(await getFile(f.shortcutDetails.targetId)), name: f.name }; } catch { continue; }
      }
      if (item.mimeType === FOLDER) {
        if (cur.depth < maxDepth) queue.push({ id: item.id, path: cur.path ? `${cur.path}/${item.name}` : item.name, depth: cur.depth + 1 });
      } else {
        files.push({ ...item, path: cur.path });
      }
    }
  }
  return files;
}

const EXPORTS: Record<string, { mime: string; ext: string }> = {
  "application/vnd.google-apps.document": { mime: "application/pdf", ext: "pdf" },
  "application/vnd.google-apps.presentation": { mime: "application/pdf", ext: "pdf" },
  "application/vnd.google-apps.drawing": { mime: "application/pdf", ext: "pdf" },
  "application/vnd.google-apps.spreadsheet": { mime: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", ext: "xlsx" },
};

export function exportInfo(mime: string) { return EXPORTS[mime] || null; }

// Baixa o conteúdo (exportando formatos nativos do Google).
export async function download(file: { id: string; mimeType: string }): Promise<{ body: Response; mime: string; ext: string | null }> {
  const ex = EXPORTS[file.mimeType];
  if (ex) {
    const u = `https://www.googleapis.com/drive/v3/files/${file.id}/export?mimeType=${encodeURIComponent(ex.mime)}`;
    return { body: await gfetch(u), mime: ex.mime, ext: ex.ext };
  }
  if (file.mimeType.startsWith("application/vnd.google-apps")) throw new HttpError(415, "Formato do Google não exportável");
  const u = `https://www.googleapis.com/drive/v3/files/${file.id}?alt=media&supportsAllDrives=true`;
  return { body: await gfetch(u), mime: file.mimeType, ext: null };
}

export function folderIdFromUrl(url: string | null | undefined): string | null {
  if (!url) return null;
  const m = url.match(/\/folders\/([A-Za-z0-9_-]{10,})/) || url.match(/[?&]id=([A-Za-z0-9_-]{10,})/);
  if (m) return m[1];
  return /^[A-Za-z0-9_-]{10,}$/.test(url.trim()) ? url.trim() : null;
}
