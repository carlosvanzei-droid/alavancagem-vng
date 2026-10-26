# Alavancagem VNG

App web (arquivo único) para organizar dados financeiros de empresas, calcular o score de
alavancagem e simular cenários de crédito. Backend: Supabase (projeto `alavancagem`).

- `index.html` — o app inteiro (HTML + CSS + JS, supabase-js via CDN)
- `supabase/alavancagem_v2.sql` — schema do banco (metodologia 2.0)
- Publicação: Vercel, a partir deste repositório (cada push no `main` publica)

## Google Drive e Kit Banco (2.2)

- `supabase/functions/drive-sync` — lê a pasta de cada empresa no Drive (conta de serviço), classifica os
  arquivos, extrai os números com o Claude e grava em balanço/DRE, faturamento, dívidas e garantias.
  Dados lançados à mão nunca são sobrescritos: divergências viram pendências.
- `supabase/functions/bank-kit` — link público do Kit Banco (`/kit/<token>`), sem score, com download
  dos documentos direto do Drive.
- Secrets no Supabase: `GOOGLE_SERVICE_ACCOUNT_JSON`, `ANTHROPIC_API_KEY` (opcional `ANTHROPIC_MODEL`).
