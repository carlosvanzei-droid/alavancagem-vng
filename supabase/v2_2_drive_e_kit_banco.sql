-- ============================================================
-- ALAVANCAGEM VNG — 2.2
-- Sincronização com Google Drive + Kit Banco
-- ============================================================

-- ---------- Drive: organização e empresas ----------
ALTER TABLE public.organizations
    ADD COLUMN drive_root_folder_url text;

ALTER TABLE public.companies
    ADD COLUMN drive_folder_id text,
    ADD COLUMN drive_last_sync_at timestamptz,
    ADD COLUMN drive_sync_status text NOT NULL DEFAULT 'never'
        CHECK (drive_sync_status IN ('never','running','ok','partial','error')),
    ADD COLUMN drive_sync_message text;

CREATE UNIQUE INDEX companies_org_drive_folder_uidx
    ON public.companies(organization_id, drive_folder_id) WHERE drive_folder_id IS NOT NULL;

-- extrai o ID da pasta de uma URL do Drive (ou aceita o ID puro)
CREATE OR REPLACE FUNCTION private.drive_folder_id_from_url(p_url text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
    SELECT CASE
        WHEN p_url IS NULL OR trim(p_url) = '' THEN NULL
        WHEN p_url ~ '/folders/([A-Za-z0-9_-]{10,})' THEN substring(p_url from '/folders/([A-Za-z0-9_-]{10,})')
        WHEN p_url ~ '[?&]id=([A-Za-z0-9_-]{10,})' THEN substring(p_url from '[?&]id=([A-Za-z0-9_-]{10,})')
        WHEN p_url ~ '^[A-Za-z0-9_-]{10,}$' THEN p_url
        ELSE NULL
    END;
$$;

CREATE OR REPLACE FUNCTION private.companies_set_drive_id()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
    IF TG_OP = 'INSERT' OR NEW.drive_folder_url IS DISTINCT FROM OLD.drive_folder_url THEN
        NEW.drive_folder_id := private.drive_folder_id_from_url(NEW.drive_folder_url);
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER companies_set_drive_id
    BEFORE INSERT OR UPDATE OF drive_folder_url ON public.companies
    FOR EACH ROW EXECUTE FUNCTION private.companies_set_drive_id();

UPDATE public.companies SET drive_folder_id = private.drive_folder_id_from_url(drive_folder_url);

-- ---------- Drive: documentos ----------
ALTER TABLE public.documents
    ADD COLUMN mime_type text,
    ADD COLUMN file_size bigint,
    ADD COLUMN folder_path text,
    ADD COLUMN source_modified_at timestamptz,
    ADD COLUMN extraction_status text NOT NULL DEFAULT 'not_applicable'
        CHECK (extraction_status IN ('not_applicable','pending','extracted','needs_review','failed','skipped')),
    ADD COLUMN extracted_at timestamptz,
    ADD COLUMN extraction_error text;

CREATE UNIQUE INDEX documents_company_external_uidx
    ON public.documents(company_id, source_external_id) WHERE source_external_id IS NOT NULL;
CREATE INDEX documents_extraction_idx
    ON public.documents(company_id, extraction_status);

-- ---------- Log das sincronizações ----------
CREATE TABLE public.drive_sync_runs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
    started_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
    started_at timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz,
    status text NOT NULL DEFAULT 'running' CHECK (status IN ('running','ok','partial','error')),
    files_found int NOT NULL DEFAULT 0,
    files_new int NOT NULL DEFAULT 0,
    files_extracted int NOT NULL DEFAULT 0,
    files_failed int NOT NULL DEFAULT 0,
    log jsonb NOT NULL DEFAULT '[]'::jsonb
);
CREATE INDEX drive_sync_runs_company_idx ON public.drive_sync_runs(company_id, started_at DESC);
CREATE INDEX drive_sync_runs_started_by_idx ON public.drive_sync_runs(started_by);

ALTER TABLE public.drive_sync_runs ENABLE ROW LEVEL SECURITY;
CREATE POLICY drive_sync_runs_select ON public.drive_sync_runs FOR SELECT TO authenticated
    USING (private.can_read_company(company_id));
REVOKE ALL ON public.drive_sync_runs FROM anon;
GRANT SELECT ON public.drive_sync_runs TO authenticated;

-- ---------- Kit Banco ----------
CREATE TABLE public.bank_kits (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
    credit_request_id uuid REFERENCES public.credit_requests(id) ON DELETE SET NULL,
    token text NOT NULL UNIQUE,
    bank_name text NOT NULL CHECK (length(trim(bank_name)) > 0),
    note text,
    expires_at timestamptz NOT NULL,
    revoked_at timestamptz,
    created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    view_count int NOT NULL DEFAULT 0,
    download_count int NOT NULL DEFAULT 0,
    last_viewed_at timestamptz
);
CREATE INDEX bank_kits_company_idx ON public.bank_kits(company_id, created_at DESC);
CREATE INDEX bank_kits_request_idx ON public.bank_kits(credit_request_id);
CREATE INDEX bank_kits_created_by_idx ON public.bank_kits(created_by);

CREATE TABLE public.bank_kit_events (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    kit_id uuid NOT NULL REFERENCES public.bank_kits(id) ON DELETE CASCADE,
    event text NOT NULL CHECK (event IN ('view','download')),
    document_id uuid REFERENCES public.documents(id) ON DELETE SET NULL,
    user_agent text,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX bank_kit_events_kit_idx ON public.bank_kit_events(kit_id, created_at DESC);
CREATE INDEX bank_kit_events_document_idx ON public.bank_kit_events(document_id);

ALTER TABLE public.bank_kits ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bank_kit_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY bank_kits_select ON public.bank_kits FOR SELECT TO authenticated
    USING (private.can_read_company(company_id));
CREATE POLICY bank_kit_events_select ON public.bank_kit_events FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM public.bank_kits k WHERE k.id = kit_id AND private.can_read_company(k.company_id)));
REVOKE ALL ON public.bank_kits, public.bank_kit_events FROM anon;
GRANT SELECT ON public.bank_kits, public.bank_kit_events TO authenticated;

CREATE OR REPLACE FUNCTION public.create_bank_kit(
    p_company_id uuid,
    p_bank_name text,
    p_credit_request_id uuid DEFAULT NULL,
    p_days integer DEFAULT 30,
    p_note text DEFAULT NULL
)
RETURNS public.bank_kits
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_kit public.bank_kits;
BEGIN
    IF NOT private.can_write_company(p_company_id) THEN
        RAISE EXCEPTION 'Sem permissão para gerar Kit Banco desta empresa' USING ERRCODE = '42501';
    END IF;
    IF p_days IS NULL OR p_days < 1 OR p_days > 90 THEN
        RAISE EXCEPTION 'Validade deve ficar entre 1 e 90 dias';
    END IF;
    IF p_credit_request_id IS NOT NULL AND private.request_company(p_credit_request_id) IS DISTINCT FROM p_company_id THEN
        RAISE EXCEPTION 'Pedido de crédito não pertence a esta empresa';
    END IF;

    INSERT INTO public.bank_kits(company_id, credit_request_id, token, bank_name, note, expires_at, created_by)
    VALUES (
        p_company_id, p_credit_request_id,
        translate(encode(extensions.gen_random_bytes(24), 'base64'), '+/=', '-_'),
        trim(p_bank_name), nullif(trim(coalesce(p_note,'')), ''),
        now() + make_interval(days => p_days),
        (SELECT auth.uid())
    )
    RETURNING * INTO v_kit;
    RETURN v_kit;
END;
$$;

CREATE OR REPLACE FUNCTION public.revoke_bank_kit(p_kit_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_company uuid;
BEGIN
    SELECT company_id INTO v_company FROM public.bank_kits WHERE id = p_kit_id;
    IF v_company IS NULL OR NOT private.can_write_company(v_company) THEN
        RAISE EXCEPTION 'Sem permissão' USING ERRCODE = '42501';
    END IF;
    UPDATE public.bank_kits SET revoked_at = now() WHERE id = p_kit_id AND revoked_at IS NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.create_bank_kit(uuid, text, uuid, integer, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.revoke_bank_kit(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_bank_kit(uuid, text, uuid, integer, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.revoke_bank_kit(uuid) TO authenticated;
