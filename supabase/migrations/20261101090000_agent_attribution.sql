-- C5 agent attribution = the hub's (v19.11, Payroll agent_name_map.md 11/01 12:45 PM ET; Orchestrator steering 11/01 12:36 PM).
-- Replaces two slice-three objects (recon_agent_id, board_parse_raw) and adds: recon_name_key, agent_name_aliases.kind,
-- board_submissions.agent_name_typed, board_unknown_agents. Existing board rows are immutable and keep their attribution;
-- only rows imported after this migration use the new rules (the runbook re-imports the newest export after the alias load).
--  * Names match ignoring case and extra spaces (hub aliasLookup_ L559): roster display name, else an alias row.
--  * board_submissions.agent_name = the STANDARD roster name when the typed name resolves (pay totals and agent_pay_rules
--    are keyed on it, like the hub's per-agent settings); agent_name_typed keeps the spelling as typed. Unknown names stay
--    as typed (agent_id NULL) and show as a High 'Unknown agent' flag with a last-name suggestion that is never assigned.
--  * Agent column precedence: F, then S (ACA rows: Deal Type ACA/Yes, or F blank + S filled), then the other 'agent' headers
--    (AP), then a row scan for exactly one known name. ABS Only rows pay the ABS spiff only (never the ACA flat).
--  * The Premier "RHLA - Name" Agent Label is never used for pay attribution (unchanged).
-- Seed: scripts/agent_aliases_sql.py (the hub's live Agent Aliases tab + the hub's code-only defaults). Live behavior change
-- for future imports only; ships with its own paste/rollback (supabase/deploy/agent_attribution_*.sql).

create or replace function public.recon_name_key(t text) returns text
language sql immutable set search_path = public, pg_temp as $$
  select nullif(lower(regexp_replace(btrim(coalesce(t, '')), '\s+', ' ', 'g')), '') $$;
comment on function public.recon_name_key(text) is 'Agent-name match key: lower case, trimmed, inner whitespace collapsed (hub aliasLookup_).';

alter table public.agent_name_aliases add column if not exists kind text not null default 'board';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'agent_name_aliases_kind') then
    alter table public.agent_name_aliases add constraint agent_name_aliases_kind check (kind in ('board', 'dialer'));
  end if;
end $$;
comment on column public.agent_name_aliases.kind is 'board = name as typed on the Sales Board; dialer = dialer "Agent Name" with extension (hub DIALER AGENT MAP).';

alter table public.board_submissions add column if not exists agent_name_typed text;
comment on column public.board_submissions.agent_name_typed is
  'Agent name exactly as typed in the column used (agent_source_col). agent_name is the standard roster name when it resolves.';

create or replace function public.recon_agent_id(name text) returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select a.id from public.agents a where public.recon_name_key(a.display_name) = public.recon_name_key(name)
                    order by a.active desc, a.created_at limit 1),
                  (select x.agent_id from public.agent_name_aliases x where public.recon_name_key(x.alias) = public.recon_name_key(name)
                    order by (x.kind = 'board') desc, x.alias limit 1)) $$;

create or replace function public.board_parse_raw() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare h text[]; r jsonb; keys text[]; i int; f text; s text; ap text; aca boolean; k text;
        prim text; pcol text; pick text; pickcol text; firstnb text; firstcol text; v text; scan_ids uuid[]; hdr_found boolean := false;
begin
  select header into h from public.recon_imports where id = new.import_id and kind = 'sales_board';
  if h is null then raise exception 'import % is not a sales_board import', new.import_id; end if;
  if exists (select 1 from public.recon_imports where id = new.import_id and finalized_at is not null) then
    raise exception 'board import % is finalized: rows can''t be added to it (import the new export as a new file)', new.import_id;
  end if;
  if cardinality(new.raw_fields) <> cardinality(h) then
    raise exception 'Board row % has % fields, header has %', new.row_num, cardinality(new.raw_fields), cardinality(h);
  end if;
  keys := array(select public.recon_col_letter(g - 1) from generate_series(1, cardinality(h)) g);
  new.raw := jsonb_object(keys, new.raw_fields);
  r := new.raw;
  new.submitted_at      := public.recon_parse_ts_et(r->>'A');
  if new.submitted_at is null then
    raise exception 'board row %: Timestamp (col A) % is missing or not MM/DD/YYYY HH:MI:SS; a row without it cannot be identified across exports', new.row_num, coalesce(r->>'A', 'NULL');
  end if;
  new.submission_key    := to_char(new.submitted_at at time zone 'America/New_York', 'YYYYMMDDHH24MISS');
  -- AC (Income) is not contact data and not needed: it must arrive blank (the import script blanks it)
  if coalesce(btrim(r->>'AC'), '') <> '' then
    raise exception 'board row %: column AC (Income) must be blank; the import script blanks it', new.row_num;
  end if;
  new.customer_name     := coalesce(nullif(btrim(r->>'H'), ''), nullif(btrim(r->>'V'), ''));
  new.customer_email    := nullif(btrim(r->>'I'), '');
  new.customer_phone    := coalesce(nullif(btrim(r->>'J'), ''), nullif(btrim(r->>'AM'), ''));
  new.lead_source       := public.recon_scrub_text(r->>'K', regexp_split_to_array(coalesce(new.customer_name, ''), '\s+'));
  new.deal_type         := nullif(btrim(r->>'R'), '');
  new.member_id         := public.recon_digits(r->>'B');
  new.date_booked       := public.recon_parse_date(r->>'C');
  new.board_active_date := public.recon_parse_date(r->>'E');
  new.board_premium     := public.recon_parse_money(r->>'G');
  new.board_post_date   := public.recon_yes(r->>'M');
  new.aca_ffm           := public.recon_digits(r->>'U');
  new.aca_date_booked   := public.recon_parse_date(r->>'Y');
  new.wrap_member_id    := public.recon_digits(r->>'AG');
  new.wrap_premium      := public.recon_parse_money(r->>'AH');
  new.abs_member_id     := public.recon_digits(r->>'AJ');
  new.abs_premium       := public.recon_parse_money(r->>'AK');
  new.increased_answer  := nullif(btrim(r->>'AO'), '');
  f := nullif(btrim(r->>'F'), ''); s := nullif(btrim(r->>'S'), ''); ap := nullif(btrim(r->>'AP'), '');
  -- Row kind: ABS Only rows pay the ABS spiff only, never the ACA flat, whichever agent column is filled (Kyle 11/01 via
  -- the Orchestrator; the hub's isAcaRow v19.11 L1319 sends an ABS Only row with F blank + S filled down the ACA branch).
  aca := lower(coalesce(new.deal_type, '')) like '%aca%' or lower(coalesce(new.deal_type, '')) = 'yes' or (f is null and s is not null);
  if lower(coalesce(new.deal_type, '')) = 'abs only' then
    new.line_kind := 'abs_only';
  else
    new.line_kind := case when aca then 'aca' else 'premier' end;
  end if;
  if new.line_kind = 'premier' then
    new.abs_addon := public.recon_yes(r->>'P');
  else
    new.abs_addon := case when new.line_kind = 'abs_only' then true
                          else public.recon_yes(r->>'AI') or coalesce(new.abs_premium, 0) > 0 end;
  end if;
  -- Agent column (hub v19.11 L1283-L1307, C5): primary S for an ACA row (Deal Type ACA/Yes, or F blank + S filled), else F
  -- (ABS Only rows follow the same F/S rule). Primary blank: every OTHER header containing 'agent' (today only AP), the first
  -- that is a known roster name/alias wins, else the first non-blank; none found: column AP by position. All blank: the row
  -- is scanned for exactly one known roster name/alias. A name is matched ignoring case and extra spaces; an unknown name is
  -- kept as typed (agent_id NULL, High 'Unknown agent' flag in board_unknown_agents). Premier's Agent Label never attributes.
  if aca then prim := s; pcol := 'S'; else prim := f; pcol := 'F'; end if;
  if prim is not null then
    pick := prim; pickcol := pcol;
  else
    for i in 1 .. cardinality(h) loop
      continue when keys[i] in ('F', 'S') or position('agent' in lower(coalesce(h[i], ''))) = 0;
      hdr_found := true;
      v := nullif(btrim(new.raw_fields[i]), '');
      continue when v is null;
      if firstnb is null then firstnb := v; firstcol := keys[i]; end if;
      if public.recon_agent_id(v) is not null then pick := v; pickcol := keys[i]; exit; end if;
    end loop;
    if pick is null and firstnb is not null then pick := firstnb; pickcol := firstcol; end if;
    if pick is null and not hdr_found and ap is not null then
      pick := ap; pickcol := 'AP';   -- no other 'agent' header: column AP by position (hub index 41)
    end if;
    if pick is null then
      select array_agg(distinct public.recon_agent_id(x)) filter (where public.recon_agent_id(x) is not null) into scan_ids
        from unnest(new.raw_fields) x where nullif(btrim(x), '') is not null and btrim(x) !~ '^[0-9/:. $,-]*$';
      if cardinality(scan_ids) = 1 then
        select a.display_name into pick from public.agents a where a.id = scan_ids[1];
        pickcol := 'row_scan';
      end if;
    end if;
  end if;
  new.agent_name_typed := pick;
  new.agent_source_col := pickcol;
  new.agent_id := public.recon_agent_id(pick);
  -- pay is grouped and ruled (agent_pay_rules) by the standard roster name, like the hub; the typed spelling is kept
  new.agent_name := coalesce((select a.display_name from public.agents a where a.id = new.agent_id), pick);
  return new;
end $$;

-- High 'Unknown agent' flag (hub flag + aliasSuggest_): current board rows whose agent did not resolve. The suggestion is
-- a roster agent with the same last name; it is never assigned (an owner adds an alias row and re-imports).
create or replace view public.board_unknown_agents with (security_invoker = true) as
select 'High'::text as severity, 'Unknown agent'::text as flag, b.submission_key, b.row_num, b.import_id,
       b.agent_name as name_as_typed, b.agent_source_col, b.deal_type, b.line_kind, b.week_payday,
       (select string_agg(a.display_name, ', ' order by a.display_name) from public.agents a
         where b.agent_name is not null and split_part(public.recon_name_key(a.display_name), ' ', -1)
               = split_part(public.recon_name_key(b.agent_name), ' ', -1)) as suggestion
  from public.board_submissions_current b
 where b.agent_id is null and public.recon_can_read();
comment on view public.board_unknown_agents is 'High flag: board rows whose agent name (as typed) matches no roster name or alias. Suggestion only; never assigned.';
revoke all on public.board_unknown_agents from public, anon;
grant select on public.board_unknown_agents to authenticated;
revoke execute on function public.recon_name_key(text) from public, anon;
grant execute on function public.recon_name_key(text) to authenticated, service_role;
