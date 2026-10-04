-- Fix current_tenant_id() to read from the HTTP request header "x-tenant-id"
-- sent by the Supabase client's global headers config.
CREATE OR REPLACE FUNCTION current_tenant_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT NULLIF(current_setting('request.headers', true)::json->>'x-tenant-id', '')::uuid;
$$;
