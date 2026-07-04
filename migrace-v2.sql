-- ============================================================
-- Čistá mapa v2 — rozšíření databáze
-- Spusť v Supabase SQL Editoru CELÉ NAJEDNOU
-- ============================================================

-- 1. Profily uživatelů s rolemi
-- ============================================================
CREATE TABLE IF NOT EXISTS profily (
  id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email text NOT NULL,
  jmeno text DEFAULT '',
  role text NOT NULL DEFAULT 'servis' CHECK (role IN ('admin','servis')),
  pristup jsonb DEFAULT '{}',  -- granulární oprávnění
  created_at timestamptz DEFAULT now()
);

ALTER TABLE profily ENABLE ROW LEVEL SECURITY;

-- Admin vidí všechny profily, servis jen svůj
CREATE POLICY "profily_admin" ON profily FOR ALL
  USING (
    EXISTS (SELECT 1 FROM profily p WHERE p.id = auth.uid() AND p.role = 'admin')
    OR id = auth.uid()
  )
  WITH CHECK (
    EXISTS (SELECT 1 FROM profily p WHERE p.id = auth.uid() AND p.role = 'admin')
  );

-- Tvůj admin profil (spusť po přihlášení, nebo uprav UUID)
INSERT INTO profily (id, email, jmeno, role)
SELECT id, email, '', 'admin'
FROM auth.users
WHERE email = 'belohlav.michal@gmail.com'
ON CONFLICT (id) DO UPDATE SET role = 'admin';

-- 2. Vrstvy
-- ============================================================
CREATE TABLE IF NOT EXISTS vrstvy (
  id text PRIMARY KEY DEFAULT gen_random_uuid()::text,
  nazev text NOT NULL,
  typ text NOT NULL DEFAULT 'body' CHECK (typ IN ('body','ucast','useky')),
  barva text DEFAULT '#3da5ff',
  popis text DEFAULT '',
  sdilena boolean DEFAULT false,  -- viditelná pro servisní účty
  aktivni boolean DEFAULT true,
  created_at timestamptz DEFAULT now(),
  created_by uuid REFERENCES auth.users(id)
);

ALTER TABLE vrstvy ENABLE ROW LEVEL SECURITY;
CREATE POLICY "vrstvy_auth" ON vrstvy FOR ALL
  USING (auth.role() = 'authenticated')
  WITH CHECK (auth.role() = 'authenticated');

-- 3. Body ve vrstvách (univerzální: bod na mapě / účast u domu / úsek)
-- ============================================================
CREATE TABLE IF NOT EXISTS vrstva_body (
  id text PRIMARY KEY DEFAULT gen_random_uuid()::text,
  vrstva_id text NOT NULL REFERENCES vrstvy(id) ON DELETE CASCADE,
  lat double precision,
  lon double precision,
  dom_id text REFERENCES domy(id) ON DELETE SET NULL,
  osoba_id text REFERENCES osoby(id) ON DELETE SET NULL,
  popis text DEFAULT '',
  data jsonb DEFAULT '{}',  -- flex pole: linie pro úseky, metadata
  created_at timestamptz DEFAULT now(),
  created_by uuid REFERENCES auth.users(id)
);

CREATE INDEX IF NOT EXISTS idx_vb_vrstva ON vrstva_body(vrstva_id);
CREATE INDEX IF NOT EXISTS idx_vb_dom ON vrstva_body(dom_id);

ALTER TABLE vrstva_body ENABLE ROW LEVEL SECURITY;
CREATE POLICY "vb_auth" ON vrstva_body FOR ALL
  USING (auth.role() = 'authenticated')
  WITH CHECK (auth.role() = 'authenticated');

-- 4. Log změn (audit trail)
-- ============================================================
CREATE TABLE IF NOT EXISTS zmeny_log (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id uuid REFERENCES auth.users(id),
  user_email text,
  tabulka text NOT NULL,
  zaznam_id text NOT NULL,
  akce text NOT NULL CHECK (akce IN ('insert','update','delete')),
  data jsonb DEFAULT '{}',
  created_at timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_zl_time ON zmeny_log(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_zl_user ON zmeny_log(user_id);

ALTER TABLE zmeny_log ENABLE ROW LEVEL SECURITY;

-- Admin vidí vše, servis jen své změny
CREATE POLICY "zl_read" ON zmeny_log FOR SELECT
  USING (
    EXISTS (SELECT 1 FROM profily p WHERE p.id = auth.uid() AND p.role = 'admin')
    OR user_id = auth.uid()
  );
CREATE POLICY "zl_insert" ON zmeny_log FOR INSERT
  WITH CHECK (auth.role() = 'authenticated');

-- 5. Automatické logování změn (trigger)
-- ============================================================
CREATE OR REPLACE FUNCTION log_change()
RETURNS trigger AS $$
DECLARE
  _email text;
BEGIN
  SELECT email INTO _email FROM auth.users WHERE id = auth.uid();
  
  IF TG_OP = 'INSERT' THEN
    INSERT INTO zmeny_log (user_id, user_email, tabulka, zaznam_id, akce, data)
    VALUES (auth.uid(), _email, TG_TABLE_NAME, NEW.id::text, 'insert', to_jsonb(NEW));
    RETURN NEW;
  ELSIF TG_OP = 'UPDATE' THEN
    INSERT INTO zmeny_log (user_id, user_email, tabulka, zaznam_id, akce, data)
    VALUES (auth.uid(), _email, TG_TABLE_NAME, NEW.id::text, 'update', to_jsonb(NEW));
    RETURN NEW;
  ELSIF TG_OP = 'DELETE' THEN
    INSERT INTO zmeny_log (user_id, user_email, tabulka, zaznam_id, akce, data)
    VALUES (auth.uid(), _email, TG_TABLE_NAME, OLD.id::text, 'delete', to_jsonb(OLD));
    RETURN OLD;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Logování na klíčových tabulkách
CREATE TRIGGER log_domy AFTER INSERT OR UPDATE OR DELETE ON domy
  FOR EACH ROW EXECUTE FUNCTION log_change();
CREATE TRIGGER log_osoby AFTER INSERT OR UPDATE OR DELETE ON osoby
  FOR EACH ROW EXECUTE FUNCTION log_change();
CREATE TRIGGER log_znacky AFTER INSERT OR UPDATE OR DELETE ON znacky
  FOR EACH ROW EXECUTE FUNCTION log_change();
CREATE TRIGGER log_vrstva_body AFTER INSERT OR UPDATE OR DELETE ON vrstva_body
  FOR EACH ROW EXECUTE FUNCTION log_change();

-- 6. Nové sloupce na osobách (pokud ještě nebyly)
-- ============================================================
ALTER TABLE osoby ADD COLUMN IF NOT EXISTS jednotka text DEFAULT '';
ALTER TABLE osoby ADD COLUMN IF NOT EXISTS aktivni boolean DEFAULT true;
ALTER TABLE osoby ADD COLUMN IF NOT EXISTS datum_od text DEFAULT '';
ALTER TABLE osoby ADD COLUMN IF NOT EXISTS datum_do text DEFAULT '';

-- 7. View pro servisní režim (bez citlivých dat)
-- ============================================================
CREATE OR REPLACE VIEW osoby_servis AS
SELECT
  id, dom_id, jmeno, rok, jednotka, aktivni, pobyt,
  CASE WHEN tel IS NOT NULL AND tel != '' THEN '***' ELSE '' END AS tel,
  CASE WHEN email IS NOT NULL AND email != '' THEN '***' ELSE '' END AS email,
  '' AS pozn,
  false AS hlas,
  skupina_id
FROM osoby;

-- 8. Aktualizace RLS na hlavních tabulkách
-- ============================================================
-- (přeskoč pokud jsi už spustil zpřísnění z dřívějška)
DO $$
BEGIN
  -- Bezpečně odstraníme staré politiky pokud existují
  DROP POLICY IF EXISTS "full_access" ON stitky;
  DROP POLICY IF EXISTS "full_access" ON skupiny;
  DROP POLICY IF EXISTS "full_access" ON domy;
  DROP POLICY IF EXISTS "full_access" ON osoby;
  DROP POLICY IF EXISTS "full_access" ON znacky;
  DROP POLICY IF EXISTS "full_access" ON meta;
  DROP POLICY IF EXISTS "auth_access" ON stitky;
  DROP POLICY IF EXISTS "auth_access" ON skupiny;
  DROP POLICY IF EXISTS "auth_access" ON domy;
  DROP POLICY IF EXISTS "auth_access" ON osoby;
  DROP POLICY IF EXISTS "auth_access" ON znacky;
  DROP POLICY IF EXISTS "auth_access" ON meta;
END $$;

CREATE POLICY "auth_rw" ON stitky FOR ALL USING (auth.role()='authenticated') WITH CHECK (auth.role()='authenticated');
CREATE POLICY "auth_rw" ON skupiny FOR ALL USING (auth.role()='authenticated') WITH CHECK (auth.role()='authenticated');
CREATE POLICY "auth_rw" ON domy FOR ALL USING (auth.role()='authenticated') WITH CHECK (auth.role()='authenticated');
CREATE POLICY "auth_rw" ON znacky FOR ALL USING (auth.role()='authenticated') WITH CHECK (auth.role()='authenticated');
CREATE POLICY "auth_rw" ON meta FOR ALL USING (auth.role()='authenticated') WITH CHECK (auth.role()='authenticated');

-- Osoby: admin plný přístup, servis čte jen přes view (ale potřebuje INSERT pro nové kontakty)
CREATE POLICY "osoby_rw" ON osoby FOR ALL
  USING (auth.role() = 'authenticated')
  WITH CHECK (auth.role() = 'authenticated');

-- ============================================================
-- HOTOVO. Ověř v Table Editor:
-- Nové tabulky: profily, vrstvy, vrstva_body, zmeny_log
-- Nový view: osoby_servis
-- Nové sloupce na osoby: jednotka, aktivni, datum_od, datum_do
-- ============================================================
