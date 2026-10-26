-- ============================================================
-- ALAVANCAGEM VNG
-- Backend: Supabase / PostgreSQL
-- Versão 2.0
--
-- Mudanças em relação ao MVP 1.0:
--  * Funções de permissão em schema privado, SECURITY DEFINER
--    (corrige a recursão infinita do RLS em organization_members)
--  * Onboarding: create_organization() e add_organization_member()
--  * Papéis aplicados: viewer só lê; analyst+ edita; owner/admin gerenciam
--  * Score, execuções, cenários e análises de IA são somente leitura
--    para o usuário: só as funções do motor (ou service_role) escrevem
--  * Metodologia 2.0: considera valor/prazo pedidos, parcela nova,
--    comprometimento de receita, DSCR, dívida/receita, dívida/EBITDA
--    e cobertura de garantias. Dado ausente não pontua: vira pendência.
--  * Faturamento usa os últimos 12 meses
--  * Geração automática de 3 cenários de crédito
--  * Triggers de updated_at e CHECKs de integridade
-- ============================================================

CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC;
GRANT USAGE ON SCHEMA private TO authenticated, service_role;

-- ============================================================
-- 1. ORGANIZAÇÕES E USUÁRIOS
-- ============================================================

CREATE TABLE public.organizations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL CHECK (length(trim(name)) > 0),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.organization_members (
    organization_id uuid NOT NULL
        REFERENCES public.organizations(id) ON DELETE CASCADE,
    user_id uuid NOT NULL
        REFERENCES auth.users(id) ON DELETE CASCADE,
    role text NOT NULL DEFAULT 'viewer'
        CHECK (role IN ('owner','admin','analyst','viewer')),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (organization_id, user_id)
);

-- ============================================================
-- 2. EMPRESAS
-- ============================================================

CREATE TABLE public.companies (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL
        REFERENCES public.organizations(id) ON DELETE CASCADE,
    legal_name text NOT NULL,
    trade_name text,
    tax_id text,
    status text NOT NULL DEFAULT 'active'
        CHECK (status IN ('active','inactive','archived')),
    drive_folder_url text,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- ============================================================
-- 3. DOCUMENTOS
-- ============================================================

CREATE TABLE public.documents (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL
        REFERENCES public.companies(id) ON DELETE CASCADE,
    category text NOT NULL,
    name text NOT NULL,
    source_type text NOT NULL DEFAULT 'google_drive',
    source_url text,
    source_external_id text,
    reference_date date,
    expires_at date,
    status text NOT NULL DEFAULT 'available'
        CHECK (status IN ('available','missing','expired','needs_review','inconsistent')),
    extracted_data jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- ============================================================
-- 4. DEMONSTRAÇÕES FINANCEIRAS
-- ============================================================

CREATE TABLE public.financial_periods (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL
        REFERENCES public.companies(id) ON DELETE CASCADE,
    period_start date NOT NULL,
    period_end date NOT NULL,

    gross_revenue numeric(18,2),
    net_revenue numeric(18,2),
    gross_profit numeric(18,2),
    ebitda numeric(18,2),           -- novo: base para DSCR e dívida/EBITDA
    operating_profit numeric(18,2),  -- usado como proxy se ebitda vier vazio
    net_income numeric(18,2),

    total_assets numeric(18,2),
    current_assets numeric(18,2),
    cash_equivalents numeric(18,2),
    receivables numeric(18,2),
    inventory numeric(18,2),

    current_liabilities numeric(18,2),
    noncurrent_liabilities numeric(18,2),
    financial_debt numeric(18,2),
    equity numeric(18,2),

    source_document_id uuid
        REFERENCES public.documents(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CHECK (period_end >= period_start),
    UNIQUE (company_id, period_end)
);

-- ============================================================
-- 5. FATURAMENTO MENSAL
-- ============================================================

CREATE TABLE public.monthly_revenue (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL
        REFERENCES public.companies(id) ON DELETE CASCADE,
    month date NOT NULL
        CHECK (month = date_trunc('month', month)::date),  -- sempre dia 1
    amount numeric(18,2) NOT NULL CHECK (amount >= 0),
    source_document_id uuid
        REFERENCES public.documents(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (company_id, month)
);

-- ============================================================
-- 6. ENDIVIDAMENTO
-- ============================================================

CREATE TABLE public.debts (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL
        REFERENCES public.companies(id) ON DELETE CASCADE,
    creditor text,
    product_type text,
    outstanding_balance numeric(18,2) CHECK (outstanding_balance >= 0),
    installment_amount numeric(18,2) CHECK (installment_amount >= 0),  -- parcela MENSAL
    installments_remaining integer CHECK (installments_remaining >= 0),
    reference_date date,
    source_document_id uuid
        REFERENCES public.documents(id) ON DELETE SET NULL,
    status text NOT NULL DEFAULT 'active'
        CHECK (status IN ('active','settled','renegotiated')),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- ============================================================
-- 7. GARANTIAS
-- ============================================================

CREATE TABLE public.guarantees (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL
        REFERENCES public.companies(id) ON DELETE CASCADE,
    guarantee_type text NOT NULL,
    description text,
    owner_name text,
    registry_number text,
    market_value numeric(18,2) CHECK (market_value >= 0),
    conservative_value numeric(18,2) CHECK (conservative_value >= 0),
    existing_liens numeric(18,2) CHECK (existing_liens >= 0),
    eligible_value numeric(18,2) CHECK (eligible_value >= 0),
    verification_status text NOT NULL DEFAULT 'pending'
        CHECK (verification_status IN ('pending','verified','eligible','rejected')),
    source_document_id uuid
        REFERENCES public.documents(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- ============================================================
-- 8. SOLICITAÇÕES DE CRÉDITO
-- ============================================================

CREATE TABLE public.credit_requests (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL
        REFERENCES public.companies(id) ON DELETE CASCADE,
    requested_amount numeric(18,2) NOT NULL CHECK (requested_amount > 0),
    purpose text,
    desired_term_months integer NOT NULL CHECK (desired_term_months BETWEEN 1 AND 360),
    status text NOT NULL DEFAULT 'draft'
        CHECK (status IN ('draft','submitted','analysis','under_review','approved','rejected','cancelled')),
    created_by uuid
        REFERENCES auth.users(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- ============================================================
-- 9. SCORE ALAVANCAGEM (escrito só pelo motor)
-- ============================================================

CREATE TABLE public.leverage_scores (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL
        REFERENCES public.companies(id) ON DELETE CASCADE,
    credit_request_id uuid
        REFERENCES public.credit_requests(id) ON DELETE CASCADE,
    score_total numeric(5,2) NOT NULL CHECK (score_total BETWEEN 0 AND 100),
    documentation_score numeric(5,2),
    financial_score numeric(5,2),
    debt_score numeric(5,2),
    payment_capacity_score numeric(5,2),
    guarantees_score numeric(5,2),
    methodology_version text NOT NULL DEFAULT '2.0',
    rationale jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- ============================================================
-- 10. PENDÊNCIAS
-- ============================================================

CREATE TABLE public.pending_items (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL
        REFERENCES public.companies(id) ON DELETE CASCADE,
    credit_request_id uuid
        REFERENCES public.credit_requests(id) ON DELETE CASCADE,
    category text NOT NULL,
    title text NOT NULL,
    description text,
    severity text NOT NULL DEFAULT 'medium'
        CHECK (severity IN ('low','medium','high','critical')),
    status text NOT NULL DEFAULT 'open'
        CHECK (status IN ('open','resolved','dismissed')),
    source text NOT NULL DEFAULT 'manual'
        CHECK (source IN ('manual','engine')),
    code text,  -- identificador das pendências automáticas do motor
    resolved_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- ============================================================
-- 11. ANÁLISES DAS IAs
-- ============================================================

CREATE TABLE public.ai_analyses (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL
        REFERENCES public.companies(id) ON DELETE CASCADE,
    credit_request_id uuid
        REFERENCES public.credit_requests(id) ON DELETE CASCADE,
    provider text NOT NULL
        CHECK (provider IN ('openai','anthropic','consolidated')),
    model text,
    analysis_type text NOT NULL,
    input_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
    output jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- ============================================================
-- 12. EXECUÇÕES DO MOTOR
-- ============================================================

CREATE TABLE public.credit_engine_runs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL
        REFERENCES public.companies(id) ON DELETE CASCADE,
    credit_request_id uuid
        REFERENCES public.credit_requests(id) ON DELETE CASCADE,
    score_id uuid
        REFERENCES public.leverage_scores(id) ON DELETE CASCADE,
    status text NOT NULL DEFAULT 'calculated'
        CHECK (status IN ('calculated','needs_reconciliation','ready_for_ai','completed')),
    metrics jsonb NOT NULL DEFAULT '{}'::jsonb,
    recommendations jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- ============================================================
-- 13. CENÁRIOS DE CRÉDITO
-- ============================================================

CREATE TABLE public.credit_scenarios (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    credit_request_id uuid NOT NULL
        REFERENCES public.credit_requests(id) ON DELETE CASCADE,
    scenario_name text NOT NULL,
    principal numeric(18,2) NOT NULL,
    term_months integer NOT NULL,
    monthly_rate numeric(9,6),
    monthly_payment numeric(18,2),
    annual_debt_service numeric(18,2),
    coverage_proxy numeric(12,4),   -- DSCR mensal: EBITDA / serviço total da dívida
    ltv numeric(12,4),              -- principal / garantias elegíveis
    assessment text NOT NULL DEFAULT 'pending'
        CHECK (assessment IN ('pending','indicative','viable','tight','not_viable','insufficient_data')),
    assumptions jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- ============================================================
-- 14. FILA CHATGPT / CLAUDE
-- ============================================================

CREATE TABLE public.ai_review_jobs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL
        REFERENCES public.companies(id) ON DELETE CASCADE,
    credit_request_id uuid
        REFERENCES public.credit_requests(id) ON DELETE CASCADE,
    provider text NOT NULL CHECK (provider IN ('openai','anthropic')),
    review_role text NOT NULL,
    status text NOT NULL DEFAULT 'queued'
        CHECK (status IN ('queued','processing','completed','failed','blocked_missing_secret')),
    payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    error_message text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- ============================================================
-- ÍNDICES
-- ============================================================

CREATE UNIQUE INDEX companies_org_tax_id_uidx
    ON public.companies(organization_id, tax_id) WHERE tax_id IS NOT NULL;
CREATE INDEX companies_org_idx ON public.companies(organization_id);
CREATE INDEX org_members_user_idx ON public.organization_members(user_id);

CREATE INDEX documents_company_idx ON public.documents(company_id, category);
CREATE INDEX financial_periods_company_idx ON public.financial_periods(company_id, period_end DESC);
CREATE INDEX monthly_revenue_company_idx ON public.monthly_revenue(company_id, month DESC);
CREATE INDEX debts_company_idx ON public.debts(company_id);
CREATE INDEX guarantees_company_idx ON public.guarantees(company_id);
CREATE INDEX credit_requests_company_idx ON public.credit_requests(company_id);
CREATE INDEX requests_created_by_idx ON public.credit_requests(created_by);

CREATE INDEX financial_source_doc_idx ON public.financial_periods(source_document_id);
CREATE INDEX revenue_source_doc_idx ON public.monthly_revenue(source_document_id);
CREATE INDEX debts_source_doc_idx ON public.debts(source_document_id);
CREATE INDEX guarantees_source_doc_idx ON public.guarantees(source_document_id);

CREATE INDEX scores_company_idx ON public.leverage_scores(company_id, created_at DESC);
CREATE INDEX scores_request_idx ON public.leverage_scores(credit_request_id);
CREATE INDEX pending_company_idx ON public.pending_items(company_id);
CREATE INDEX pending_request_idx ON public.pending_items(credit_request_id);
CREATE UNIQUE INDEX pending_open_code_uidx
    ON public.pending_items(company_id, code) WHERE status = 'open' AND code IS NOT NULL;
CREATE INDEX ai_analyses_company_idx ON public.ai_analyses(company_id, created_at DESC);
CREATE INDEX analyses_request_idx ON public.ai_analyses(credit_request_id);
CREATE INDEX credit_engine_runs_company_idx ON public.credit_engine_runs(company_id);
CREATE INDEX credit_engine_runs_request_idx ON public.credit_engine_runs(credit_request_id, created_at DESC);
CREATE INDEX credit_engine_runs_score_idx ON public.credit_engine_runs(score_id);
CREATE INDEX credit_scenarios_request_idx ON public.credit_scenarios(credit_request_id);
CREATE INDEX ai_review_jobs_company_idx ON public.ai_review_jobs(company_id);
CREATE INDEX ai_review_jobs_request_idx ON public.ai_review_jobs(credit_request_id);

-- ============================================================
-- FUNÇÕES PRIVADAS (permissão, utilitários)
-- ============================================================

-- Papel do usuário logado na organização (NULL se não for membro).
-- SECURITY DEFINER: lê organization_members sem passar pelo RLS,
-- o que elimina a recursão infinita da versão 1.0.
CREATE OR REPLACE FUNCTION private.org_role(p_org uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
    SELECT m.role
    FROM public.organization_members m
    WHERE m.organization_id = p_org
      AND m.user_id = (SELECT auth.uid());
$$;

CREATE OR REPLACE FUNCTION private.is_org_member(p_org uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
    SELECT private.org_role(p_org) IS NOT NULL;
$$;

CREATE OR REPLACE FUNCTION private.has_org_role(p_org uuid, p_roles text[])
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
    SELECT coalesce(private.org_role(p_org) = ANY (p_roles), false);
$$;

CREATE OR REPLACE FUNCTION private.company_org(p_company uuid)
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
    SELECT c.organization_id FROM public.companies c WHERE c.id = p_company;
$$;

CREATE OR REPLACE FUNCTION private.request_company(p_request uuid)
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
    SELECT r.company_id FROM public.credit_requests r WHERE r.id = p_request;
$$;

CREATE OR REPLACE FUNCTION private.can_read_company(p_company uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
    SELECT private.is_org_member(private.company_org(p_company));
$$;

-- owner, admin e analyst editam; viewer só lê
CREATE OR REPLACE FUNCTION private.can_write_company(p_company uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
    SELECT private.has_org_role(private.company_org(p_company),
                                ARRAY['owner','admin','analyst']);
$$;

CREATE OR REPLACE FUNCTION private.is_service_role()
RETURNS boolean LANGUAGE sql STABLE SET search_path = '' AS $$
    SELECT coalesce((SELECT auth.jwt() ->> 'role'), '') = 'service_role';
$$;

-- Parcela (Price): PMT = PV * i / (1 - (1+i)^-n)
CREATE OR REPLACE FUNCTION private.pmt(p_rate numeric, p_n integer, p_pv numeric)
RETURNS numeric LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
    SELECT CASE
        WHEN p_n IS NULL OR p_n <= 0 OR p_pv IS NULL THEN NULL
        WHEN coalesce(p_rate, 0) = 0 THEN round(p_pv / p_n, 2)
        ELSE round(p_pv * p_rate / (1 - power(1 + p_rate, -p_n::numeric)), 2)
    END;
$$;

CREATE OR REPLACE FUNCTION private.set_updated_at()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'organizations','companies','documents','financial_periods','debts',
        'guarantees','credit_requests','pending_items','ai_review_jobs'
    ] LOOP
        EXECUTE format(
            'CREATE TRIGGER %I BEFORE UPDATE ON public.%I
             FOR EACH ROW EXECUTE FUNCTION private.set_updated_at()',
            t || '_set_updated_at', t);
    END LOOP;
END $$;

-- ============================================================
-- SEGURANÇA / RLS
-- ============================================================

DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'organizations','organization_members','companies','documents',
        'financial_periods','monthly_revenue','debts','guarantees',
        'credit_requests','leverage_scores','pending_items','ai_analyses',
        'credit_engine_runs','credit_scenarios','ai_review_jobs'
    ] LOOP
        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    END LOOP;
END $$;

-- ORGANIZAÇÕES (INSERT só via create_organization)
CREATE POLICY org_select ON public.organizations
    FOR SELECT TO authenticated
    USING (private.is_org_member(id));

CREATE POLICY org_update ON public.organizations
    FOR UPDATE TO authenticated
    USING (private.has_org_role(id, ARRAY['owner','admin']))
    WITH CHECK (private.has_org_role(id, ARRAY['owner','admin']));

CREATE POLICY org_delete ON public.organizations
    FOR DELETE TO authenticated
    USING (private.has_org_role(id, ARRAY['owner']));

-- MEMBROS (INSERT só via add_organization_member)
CREATE POLICY member_select ON public.organization_members
    FOR SELECT TO authenticated
    USING (private.is_org_member(organization_id));

CREATE POLICY member_update ON public.organization_members
    FOR UPDATE TO authenticated
    USING (private.has_org_role(organization_id, ARRAY['owner']))
    WITH CHECK (private.has_org_role(organization_id, ARRAY['owner']));

-- owner remove qualquer um; demais podem sair por conta própria
CREATE POLICY member_delete ON public.organization_members
    FOR DELETE TO authenticated
    USING (
        private.has_org_role(organization_id, ARRAY['owner'])
        OR (user_id = (SELECT auth.uid()) AND role <> 'owner')
    );

-- EMPRESAS
CREATE POLICY company_select ON public.companies
    FOR SELECT TO authenticated
    USING (private.is_org_member(organization_id));

CREATE POLICY company_insert ON public.companies
    FOR INSERT TO authenticated
    WITH CHECK (private.has_org_role(organization_id, ARRAY['owner','admin','analyst']));

CREATE POLICY company_update ON public.companies
    FOR UPDATE TO authenticated
    USING (private.has_org_role(organization_id, ARRAY['owner','admin','analyst']))
    WITH CHECK (private.has_org_role(organization_id, ARRAY['owner','admin','analyst']));

CREATE POLICY company_delete ON public.companies
    FOR DELETE TO authenticated
    USING (private.has_org_role(organization_id, ARRAY['owner','admin']));

-- TABELAS DE ENTRADA (todos os membros leem; analyst+ escreve)
DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'documents','financial_periods','monthly_revenue','debts',
        'guarantees','credit_requests','pending_items'
    ] LOOP
        EXECUTE format(
            'CREATE POLICY %I ON public.%I FOR SELECT TO authenticated
             USING (private.can_read_company(company_id))', t || '_select', t);
        EXECUTE format(
            'CREATE POLICY %I ON public.%I FOR INSERT TO authenticated
             WITH CHECK (private.can_write_company(company_id))', t || '_insert', t);
        EXECUTE format(
            'CREATE POLICY %I ON public.%I FOR UPDATE TO authenticated
             USING (private.can_write_company(company_id))
             WITH CHECK (private.can_write_company(company_id))', t || '_update', t);
        EXECUTE format(
            'CREATE POLICY %I ON public.%I FOR DELETE TO authenticated
             USING (private.can_write_company(company_id))', t || '_delete', t);
    END LOOP;
END $$;

-- TABELAS DE SAÍDA (somente leitura para o usuário)
DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'leverage_scores','credit_engine_runs','ai_analyses','ai_review_jobs'
    ] LOOP
        EXECUTE format(
            'CREATE POLICY %I ON public.%I FOR SELECT TO authenticated
             USING (private.can_read_company(company_id))', t || '_select', t);
    END LOOP;
END $$;

CREATE POLICY credit_scenarios_select ON public.credit_scenarios
    FOR SELECT TO authenticated
    USING (private.can_read_company(private.request_company(credit_request_id)));

-- GRANTS
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon;

GRANT SELECT, INSERT, UPDATE, DELETE ON
    public.organizations, public.organization_members, public.companies,
    public.documents, public.financial_periods, public.monthly_revenue,
    public.debts, public.guarantees, public.credit_requests, public.pending_items
TO authenticated;

REVOKE INSERT, UPDATE, DELETE ON
    public.leverage_scores, public.credit_engine_runs, public.credit_scenarios,
    public.ai_analyses, public.ai_review_jobs
FROM authenticated;

GRANT SELECT ON
    public.leverage_scores, public.credit_engine_runs, public.credit_scenarios,
    public.ai_analyses, public.ai_review_jobs
TO authenticated;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA private FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION
    private.org_role(uuid), private.is_org_member(uuid),
    private.has_org_role(uuid, text[]), private.company_org(uuid),
    private.request_company(uuid), private.can_read_company(uuid),
    private.can_write_company(uuid)
TO authenticated;

-- ============================================================
-- VIEW EXECUTIVA
-- ============================================================

CREATE OR REPLACE VIEW public.company_credit_snapshot
WITH (security_invoker = true)
AS
SELECT
    c.id AS company_id,
    c.organization_id,
    c.legal_name,
    c.trade_name,
    c.tax_id,

    fp.period_start,
    fp.period_end,
    fp.period_months,
    fp.net_revenue,
    fp.net_income,
    fp.ebitda_used,
    fp.total_assets,
    fp.current_assets,
    fp.current_liabilities,
    fp.financial_debt,
    fp.equity,

    CASE WHEN fp.current_liabilities > 0
         THEN round(fp.current_assets / fp.current_liabilities, 2) END AS current_ratio,
    CASE WHEN fp.equity > 0
         THEN round(coalesce(fp.financial_debt, 0) / fp.equity, 4) END AS debt_to_equity,
    CASE WHEN fp.net_revenue > 0
         THEN round(fp.net_income / fp.net_revenue, 4) END AS net_margin,
    CASE WHEN fp.ebitda_used IS NOT NULL
         THEN round(fp.ebitda_used / fp.period_months, 2) END AS monthly_ebitda,

    rev.months_count            AS revenue_months_12m,
    rev.last_month              AS last_revenue_month,
    rev.avg_amount              AS avg_monthly_revenue_12m,
    round(rev.avg_amount * 12, 2) AS annualized_revenue_12m,

    dbt.declared_debt,
    dbt.monthly_debt_service,

    gar.eligible_guarantee_value,
    gar.eligible_guarantees_count,

    pend.open_pending_items,
    pend.high_pending_items

FROM public.companies c

-- último balanço/DRE
LEFT JOIN LATERAL (
    SELECT x.*,
           coalesce(x.ebitda, x.operating_profit) AS ebitda_used,
           GREATEST(1, round((x.period_end - x.period_start + 1) / 30.4375))::int AS period_months
    FROM public.financial_periods x
    WHERE x.company_id = c.id
    ORDER BY x.period_end DESC
    LIMIT 1
) fp ON true

-- faturamento: janela de 12 meses até o último mês informado
LEFT JOIN LATERAL (
    SELECT count(*)::int          AS months_count,
           max(mr.month)          AS last_month,
           round(avg(mr.amount), 2) AS avg_amount
    FROM public.monthly_revenue mr
    WHERE mr.company_id = c.id
      AND mr.month > (
          SELECT max(m2.month) FROM public.monthly_revenue m2
          WHERE m2.company_id = c.id
      ) - interval '12 months'
) rev ON true

-- dívidas ativas
LEFT JOIN LATERAL (
    SELECT coalesce(sum(d.outstanding_balance), 0) AS declared_debt,
           coalesce(sum(d.installment_amount), 0)  AS monthly_debt_service
    FROM public.debts d
    WHERE d.company_id = c.id AND d.status = 'active'
) dbt ON true

-- garantias verificadas/elegíveis
-- valor elegível: eligible_value; senão (valor conservador ou 70% do
-- valor de mercado) menos ônus existentes
LEFT JOIN LATERAL (
    SELECT coalesce(sum(GREATEST(0, coalesce(
               g.eligible_value,
               coalesce(g.conservative_value, g.market_value * 0.70)
                   - coalesce(g.existing_liens, 0)
           ))), 0)          AS eligible_guarantee_value,
           count(*)::int    AS eligible_guarantees_count
    FROM public.guarantees g
    WHERE g.company_id = c.id
      AND g.verification_status IN ('verified','eligible')
) gar ON true

-- pendências abertas
LEFT JOIN LATERAL (
    SELECT count(*)::int AS open_pending_items,
           (count(*) FILTER (WHERE p.severity IN ('high','critical')))::int AS high_pending_items
    FROM public.pending_items p
    WHERE p.company_id = c.id AND p.status = 'open'
) pend ON true;

REVOKE ALL ON public.company_credit_snapshot FROM anon;
GRANT SELECT ON public.company_credit_snapshot TO authenticated;

-- ============================================================
-- ONBOARDING
-- ============================================================

-- Cria a organização e torna quem chamou o owner
CREATE OR REPLACE FUNCTION public.create_organization(p_name text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_uid uuid := (SELECT auth.uid());
    v_org uuid;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'Faça login para criar uma organização' USING ERRCODE = '42501';
    END IF;

    INSERT INTO public.organizations(name) VALUES (trim(p_name))
    RETURNING id INTO v_org;

    INSERT INTO public.organization_members(organization_id, user_id, role)
    VALUES (v_org, v_uid, 'owner');

    RETURN v_org;
END;
$$;

-- Adiciona (ou muda o papel de) um usuário já cadastrado, pelo e-mail.
-- owner e admin podem adicionar; só owner concede owner/admin.
CREATE OR REPLACE FUNCTION public.add_organization_member(
    p_org uuid,
    p_email text,
    p_role text DEFAULT 'analyst'
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_user uuid;
BEGIN
    IF NOT private.has_org_role(p_org, ARRAY['owner','admin']) THEN
        RAISE EXCEPTION 'Sem permissão para adicionar membros' USING ERRCODE = '42501';
    END IF;

    IF p_role NOT IN ('owner','admin','analyst','viewer') THEN
        RAISE EXCEPTION 'Papel inválido: %', p_role;
    END IF;

    IF p_role IN ('owner','admin') AND NOT private.has_org_role(p_org, ARRAY['owner']) THEN
        RAISE EXCEPTION 'Só o owner pode conceder owner/admin' USING ERRCODE = '42501';
    END IF;

    SELECT u.id INTO v_user
    FROM auth.users u
    WHERE lower(u.email) = lower(trim(p_email));

    IF v_user IS NULL THEN
        RAISE EXCEPTION 'Nenhum usuário com o e-mail %. A pessoa precisa criar a conta primeiro.', p_email;
    END IF;

    INSERT INTO public.organization_members(organization_id, user_id, role)
    VALUES (p_org, v_user, p_role)
    ON CONFLICT (organization_id, user_id) DO UPDATE SET role = EXCLUDED.role;

    RETURN v_user;
END;
$$;

-- ============================================================
-- MOTOR: PENDÊNCIAS AUTOMÁTICAS
-- ============================================================

CREATE OR REPLACE FUNCTION private.sync_engine_pending(
    p_company uuid,
    p_request uuid,
    p_code text,
    p_active boolean,
    p_severity text,
    p_title text,
    p_description text
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    IF p_active THEN
        INSERT INTO public.pending_items(
            company_id, credit_request_id, category, title, description,
            severity, source, code
        )
        VALUES (p_company, p_request, 'dados', p_title, p_description,
                p_severity, 'engine', p_code)
        ON CONFLICT DO NOTHING;
    ELSE
        UPDATE public.pending_items
        SET status = 'resolved', resolved_at = now()
        WHERE company_id = p_company
          AND code = p_code
          AND source = 'engine'
          AND status = 'open';
    END IF;
END;
$$;

-- ============================================================
-- MOTOR DE SCORE  — metodologia 2.0
--
--  Documentação ............ 15  categorias distintas de docs válidos
--  Financeiro .............. 25  liquidez, margem, PL, lucro
--  Endividamento ........... 20  dívida pró-forma / receita 12m (12)
--                                dívida pró-forma / EBITDA anual (8)
--  Capacidade de pagamento . 25  comprometimento da receita (15)
--                                DSCR = EBITDA mensal / serviço da dívida (10)
--  Garantias ............... 15  garantias elegíveis / valor pedido
--
--  "Pró-forma" = dívida atual + crédito pedido; serviço da dívida =
--  parcelas atuais + parcela nova (Price, taxa p_monthly_rate).
--  Dado ausente = 0 ponto + pendência automática.
--  Penalidade: -3 por pendência alta/crítica aberta (máx. -10).
-- ============================================================

CREATE OR REPLACE FUNCTION public.calculate_leverage_score(
    p_company_id uuid,
    p_credit_request_id uuid DEFAULT NULL,
    p_monthly_rate numeric DEFAULT 0.02
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    s  record;
    r  record;
    sc record;

    v_rate   numeric := coalesce(p_monthly_rate, 0.02);
    v_amount numeric := 0;
    v_term   integer;
    v_new_pmt numeric := 0;

    v_docs int;
    v_proforma_debt numeric;
    v_debt_rev numeric;
    v_debt_ebitda numeric;
    v_service numeric;
    v_commit numeric;
    v_dscr numeric;
    v_guar_cov numeric;

    doc_score  numeric := 0;
    fin_score  numeric := 0;
    debt_score numeric := 0;
    pay_score  numeric := 0;
    guar_score numeric := 0;

    v_raw numeric;
    v_penalty numeric;
    v_total numeric;
    v_open_high int;
    v_status text;
    v_id uuid;

    v_sc_pmt numeric;
    v_sc_service numeric;
    v_sc_dscr numeric;
    v_sc_commit numeric;
    v_sc_ltv numeric;
BEGIN
    -- permissão: analyst+ da organização, ou backend com service_role
    IF NOT private.can_write_company(p_company_id) AND NOT private.is_service_role() THEN
        RAISE EXCEPTION 'Sem permissão para calcular o score desta empresa' USING ERRCODE = '42501';
    END IF;

    IF v_rate < 0 OR v_rate > 0.20 THEN
        RAISE EXCEPTION 'Taxa mensal fora do intervalo permitido (0 a 20%%)';
    END IF;

    IF p_credit_request_id IS NOT NULL THEN
        SELECT * INTO r
        FROM public.credit_requests
        WHERE id = p_credit_request_id AND company_id = p_company_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Pedido de crédito não encontrado para esta empresa';
        END IF;

        v_amount  := r.requested_amount;
        v_term    := r.desired_term_months;
        v_new_pmt := coalesce(private.pmt(v_rate, v_term, v_amount), 0);
    END IF;

    SELECT * INTO s FROM public.company_credit_snapshot WHERE company_id = p_company_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Empresa não encontrada';
    END IF;

    -- ---------- pendências automáticas ----------
    PERFORM private.sync_engine_pending(p_company_id, p_credit_request_id,
        'sem_balanco', s.period_end IS NULL, 'high',
        'Balanço/DRE não informado',
        'Cadastre ao menos um período em financial_periods.');

    PERFORM private.sync_engine_pending(p_company_id, p_credit_request_id,
        'balanco_desatualizado',
        s.period_end IS NOT NULL AND s.period_end < current_date - interval '18 months',
        'medium', 'Balanço/DRE desatualizado',
        'Último período tem mais de 18 meses.');

    PERFORM private.sync_engine_pending(p_company_id, p_credit_request_id,
        'sem_ebitda', s.period_end IS NOT NULL AND s.ebitda_used IS NULL, 'medium',
        'EBITDA não informado',
        'Informe ebitda ou operating_profit no último período.');

    PERFORM private.sync_engine_pending(p_company_id, p_credit_request_id,
        'sem_faturamento', coalesce(s.revenue_months_12m, 0) = 0, 'high',
        'Faturamento mensal não informado',
        'Cadastre o faturamento dos últimos 12 meses.');

    PERFORM private.sync_engine_pending(p_company_id, p_credit_request_id,
        'faturamento_incompleto', coalesce(s.revenue_months_12m, 0) BETWEEN 1 AND 5,
        'medium', 'Faturamento com menos de 6 meses',
        'A média de receita fica pouco confiável com menos de 6 meses.');

    IF v_amount > 0 THEN
        PERFORM private.sync_engine_pending(p_company_id, p_credit_request_id,
            'sem_garantia', coalesce(s.eligible_guarantee_value, 0) = 0, 'medium',
            'Nenhuma garantia elegível',
            'Não há garantia verificada para o crédito pedido.');
    END IF;

    -- relê com as contagens de pendências atualizadas
    SELECT * INTO s FROM public.company_credit_snapshot WHERE company_id = p_company_id;

    -- ---------- DOCUMENTAÇÃO: 15 ----------
    SELECT count(DISTINCT d.category) INTO v_docs
    FROM public.documents d
    WHERE d.company_id = p_company_id
      AND d.status = 'available'
      AND (d.expires_at IS NULL OR d.expires_at >= current_date);

    doc_score := CASE
        WHEN v_docs >= 8 THEN 15
        WHEN v_docs >= 5 THEN 11
        WHEN v_docs >= 2 THEN 7
        WHEN v_docs >= 1 THEN 3
        ELSE 0 END;

    -- ---------- FINANCEIRO: 25 ----------
    IF s.period_end IS NOT NULL THEN
        fin_score := LEAST(25,
            CASE WHEN s.current_ratio >= 2   THEN 8
                 WHEN s.current_ratio >= 1.5 THEN 6
                 WHEN s.current_ratio >= 1   THEN 4
                 WHEN s.current_ratio IS NOT NULL THEN 1
                 ELSE 0 END
          + CASE WHEN s.net_margin >= 0.10 THEN 8
                 WHEN s.net_margin >= 0.05 THEN 6
                 WHEN s.net_margin > 0     THEN 4
                 ELSE 0 END
          + CASE WHEN s.equity > 0 THEN 5 ELSE 0 END
          + CASE WHEN s.net_income > 0 THEN 4 ELSE 0 END
        );
    END IF;

    -- ---------- ENDIVIDAMENTO: 20 ----------
    v_proforma_debt := GREATEST(coalesce(s.declared_debt, 0), coalesce(s.financial_debt, 0))
                       + v_amount;

    IF coalesce(s.annualized_revenue_12m, 0) > 0 THEN
        v_debt_rev := round(v_proforma_debt / s.annualized_revenue_12m, 4);
    END IF;

    IF coalesce(s.monthly_ebitda, 0) > 0 THEN
        v_debt_ebitda := round(v_proforma_debt / (s.monthly_ebitda * 12), 4);
    END IF;

    debt_score :=
        CASE WHEN v_debt_rev IS NULL  THEN 0
             WHEN v_debt_rev <= 0.15 THEN 12
             WHEN v_debt_rev <= 0.30 THEN 9
             WHEN v_debt_rev <= 0.50 THEN 6
             WHEN v_debt_rev <= 0.80 THEN 3
             ELSE 0 END
      + CASE WHEN v_debt_ebitda IS NULL THEN 0
             WHEN v_debt_ebitda <= 1.5 THEN 8
             WHEN v_debt_ebitda <= 2.5 THEN 6
             WHEN v_debt_ebitda <= 3.5 THEN 3
             ELSE 0 END;

    -- ---------- CAPACIDADE DE PAGAMENTO: 25 ----------
    v_service := coalesce(s.monthly_debt_service, 0) + v_new_pmt;

    IF coalesce(s.avg_monthly_revenue_12m, 0) > 0 THEN
        v_commit := round(v_service / s.avg_monthly_revenue_12m, 4);
    END IF;

    IF v_service > 0 AND s.monthly_ebitda IS NOT NULL THEN
        v_dscr := round(s.monthly_ebitda / v_service, 4);
    END IF;

    pay_score :=
        CASE WHEN v_commit IS NULL  THEN 0
             WHEN v_commit <= 0.10 THEN 15
             WHEN v_commit <= 0.20 THEN 11
             WHEN v_commit <= 0.30 THEN 7
             WHEN v_commit <= 0.40 THEN 3
             ELSE 0 END
      + CASE WHEN v_service = 0 AND coalesce(s.monthly_ebitda, 0) > 0 THEN 10
             WHEN v_dscr IS NULL THEN 0
             WHEN v_dscr >= 2.0  THEN 10
             WHEN v_dscr >= 1.5  THEN 7
             WHEN v_dscr >= 1.2  THEN 4
             ELSE 0 END;

    -- ---------- GARANTIAS: 15 ----------
    IF v_amount > 0 THEN
        v_guar_cov := round(coalesce(s.eligible_guarantee_value, 0) / v_amount, 4);
        guar_score := CASE
            WHEN v_guar_cov >= 1.5 THEN 15
            WHEN v_guar_cov >= 1.0 THEN 11
            WHEN v_guar_cov >= 0.5 THEN 6
            WHEN v_guar_cov > 0    THEN 3
            ELSE 0 END;
    ELSE
        -- sem pedido: pontua pela existência de garantias (máx. 10)
        guar_score := CASE
            WHEN s.eligible_guarantees_count >= 2 THEN 10
            WHEN s.eligible_guarantees_count = 1  THEN 6
            ELSE 0 END;
    END IF;

    -- ---------- TOTAL ----------
    v_open_high := coalesce(s.high_pending_items, 0);
    v_raw       := doc_score + fin_score + debt_score + pay_score + guar_score;
    v_penalty   := LEAST(10, v_open_high * 3);
    v_total     := GREATEST(0, v_raw - v_penalty);

    v_status := CASE
        WHEN v_open_high > 0 THEN 'needs_reconciliation'
        WHEN v_total >= 70   THEN 'ready_for_ai'
        ELSE 'calculated' END;

    INSERT INTO public.leverage_scores(
        company_id, credit_request_id, score_total,
        documentation_score, financial_score, debt_score,
        payment_capacity_score, guarantees_score,
        methodology_version, rationale
    )
    VALUES (
        p_company_id, p_credit_request_id, v_total,
        doc_score, fin_score, debt_score, pay_score, guar_score,
        '2.0',
        jsonb_build_object(
            'version', '2.0',
            'raw_score', v_raw,
            'high_pending_penalty', v_penalty,
            'assumed_monthly_rate', v_rate,
            'requested_amount', v_amount,
            'term_months', v_term,
            'new_monthly_payment', v_new_pmt,
            'valid_document_categories', v_docs,
            'note', 'Indicador interno de prontidão; não representa aprovação bancária.'
        )
    )
    RETURNING id INTO v_id;

    INSERT INTO public.credit_engine_runs(
        company_id, credit_request_id, score_id, status, metrics, recommendations
    )
    VALUES (
        p_company_id, p_credit_request_id, v_id, v_status,
        jsonb_build_object(
            'score_total',             v_total,
            'current_ratio',           s.current_ratio,
            'debt_to_equity',          s.debt_to_equity,
            'net_margin',              s.net_margin,
            'monthly_ebitda',          s.monthly_ebitda,
            'avg_monthly_revenue_12m', s.avg_monthly_revenue_12m,
            'revenue_months_12m',      s.revenue_months_12m,
            'declared_debt',           s.declared_debt,
            'proforma_debt',           v_proforma_debt,
            'debt_to_revenue',         v_debt_rev,
            'debt_to_ebitda',          v_debt_ebitda,
            'monthly_debt_service',    v_service,
            'revenue_commitment',      v_commit,
            'dscr',                    v_dscr,
            'guarantee_coverage',      v_guar_cov,
            'open_high_items',         v_open_high
        ),
        jsonb_build_object(
            'next_step', CASE
                WHEN v_open_high > 0 THEN 'reconcile_high_priority_items'
                WHEN v_total >= 70   THEN 'run_ai_credit_review'
                ELSE 'improve_score_before_review' END
        )
    );

    -- ---------- CENÁRIOS ----------
    IF p_credit_request_id IS NOT NULL THEN
        DELETE FROM public.credit_scenarios WHERE credit_request_id = p_credit_request_id;

        FOR sc IN
            SELECT * FROM (VALUES
                ('Solicitado',            v_amount,                v_term),
                ('Prazo estendido',       v_amount,                LEAST(360, ceil(v_term * 1.5)::int)),
                ('Valor reduzido (70%)',  round(v_amount * 0.7, 2), v_term)
            ) AS t(scenario_name, principal, term_months)
        LOOP
            v_sc_pmt     := private.pmt(v_rate, sc.term_months, sc.principal);
            v_sc_service := coalesce(s.monthly_debt_service, 0) + v_sc_pmt;
            v_sc_dscr    := CASE WHEN s.monthly_ebitda IS NOT NULL AND v_sc_service > 0
                                 THEN round(s.monthly_ebitda / v_sc_service, 4) END;
            v_sc_commit  := CASE WHEN s.avg_monthly_revenue_12m > 0
                                 THEN round(v_sc_service / s.avg_monthly_revenue_12m, 4) END;
            v_sc_ltv     := CASE WHEN s.eligible_guarantee_value > 0
                                 THEN round(sc.principal / s.eligible_guarantee_value, 4) END;

            INSERT INTO public.credit_scenarios(
                credit_request_id, scenario_name, principal, term_months,
                monthly_rate, monthly_payment, annual_debt_service,
                coverage_proxy, ltv, assessment, assumptions
            )
            VALUES (
                p_credit_request_id, sc.scenario_name, sc.principal, sc.term_months,
                v_rate, v_sc_pmt, v_sc_pmt * 12,
                v_sc_dscr, v_sc_ltv,
                CASE
                    WHEN v_sc_dscr IS NULL OR v_sc_commit IS NULL THEN 'insufficient_data'
                    WHEN v_sc_dscr >= 1.3 AND v_sc_commit <= 0.30 THEN 'viable'
                    WHEN v_sc_dscr >= 1.0 THEN 'tight'
                    ELSE 'not_viable'
                END,
                jsonb_build_object(
                    'amortization', 'price',
                    'existing_monthly_debt_service', s.monthly_debt_service,
                    'total_monthly_debt_service', v_sc_service,
                    'revenue_commitment', v_sc_commit,
                    'criteria', 'viable: DSCR >= 1,3 e comprometimento <= 30%; tight: DSCR >= 1,0'
                )
            );
        END LOOP;
    END IF;

    RETURN v_id;
END;
$$;

-- ============================================================
-- CRIAÇÃO DE OPERAÇÃO DE CRÉDITO
-- ============================================================

CREATE OR REPLACE FUNCTION public.create_credit_request(
    p_company_id uuid,
    p_amount numeric,
    p_purpose text,
    p_term integer,
    p_monthly_rate numeric DEFAULT 0.02
)
RETURNS uuid
LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE
    rid uuid;
BEGIN
    -- o INSERT passa pelo RLS: só analyst+ consegue
    INSERT INTO public.credit_requests(
        company_id, requested_amount, purpose, desired_term_months, created_by
    )
    VALUES (p_company_id, p_amount, p_purpose, p_term, (SELECT auth.uid()))
    RETURNING id INTO rid;

    PERFORM public.calculate_leverage_score(p_company_id, rid, p_monthly_rate);

    RETURN rid;
END;
$$;

-- ============================================================
-- FILA DE REVISÃO POR IA
-- Só enfileira se a última execução do motor estiver 'ready_for_ai'.
-- Os jobs são processados por uma Edge Function com service_role.
-- ============================================================

CREATE OR REPLACE FUNCTION public.enqueue_ai_review(p_credit_request_id uuid)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_company uuid := private.request_company(p_credit_request_id);
    v_run record;
    v_snapshot jsonb;
    v_count int := 0;
    v_provider text;
    v_role text;
BEGIN
    IF v_company IS NULL THEN
        RAISE EXCEPTION 'Pedido de crédito não encontrado';
    END IF;

    IF NOT private.can_write_company(v_company) AND NOT private.is_service_role() THEN
        RAISE EXCEPTION 'Sem permissão' USING ERRCODE = '42501';
    END IF;

    SELECT * INTO v_run
    FROM public.credit_engine_runs
    WHERE credit_request_id = p_credit_request_id
    ORDER BY created_at DESC
    LIMIT 1;

    IF NOT FOUND OR v_run.status <> 'ready_for_ai' THEN
        RAISE EXCEPTION 'O pedido precisa estar com status ready_for_ai (atual: %)',
            coalesce(v_run.status, 'sem cálculo');
    END IF;

    SELECT to_jsonb(x) INTO v_snapshot
    FROM public.company_credit_snapshot x
    WHERE x.company_id = v_company;

    FOR v_provider, v_role IN
        SELECT * FROM (VALUES ('openai','credit_analyst'),
                              ('anthropic','risk_reviewer')) t(p, r)
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM public.ai_review_jobs j
            WHERE j.credit_request_id = p_credit_request_id
              AND j.provider = v_provider
              AND j.status IN ('queued','processing')
        ) THEN
            INSERT INTO public.ai_review_jobs(
                company_id, credit_request_id, provider, review_role, payload
            )
            VALUES (
                v_company, p_credit_request_id, v_provider, v_role,
                jsonb_build_object(
                    'engine_run_id', v_run.id,
                    'metrics', v_run.metrics,
                    'snapshot', v_snapshot
                )
            );
            v_count := v_count + 1;
        END IF;
    END LOOP;

    RETURN v_count;
END;
$$;

-- ============================================================
-- PERMISSÕES DAS FUNÇÕES PÚBLICAS
-- ============================================================

REVOKE ALL ON FUNCTION public.create_organization(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.add_organization_member(uuid, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.calculate_leverage_score(uuid, uuid, numeric) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.create_credit_request(uuid, numeric, text, integer, numeric) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.enqueue_ai_review(uuid) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.create_organization(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.add_organization_member(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.calculate_leverage_score(uuid, uuid, numeric) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_credit_request(uuid, numeric, text, integer, numeric) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.enqueue_ai_review(uuid) TO authenticated, service_role;

-- ============================================================
-- 2.1 — convites, lista de membros e proteção do último owner
-- (aplicado como migration v2_1_invites_and_members)
-- ============================================================
-- organization_invites(organization_id, email, role, invited_by)
-- trigger em auth.users: ao confirmar o e-mail, convites viram membros
-- add_organization_member(): adiciona ou cria convite; retorna 'member' | 'invited'
-- list_organization_members(): membros com e-mail
-- keep_one_owner(): impede remover/rebaixar o último owner
