-- =====================================================================
-- نظام إدارة أوامر التشغيل والإنتاج والتركيب  |  Phase 1: قاعدة البيانات
-- Supabase / PostgreSQL  |  شغّله في SQL Editor أو ضمن supabase/migrations
-- المبادئ:
--   1) كل شيء مرتبط بـ work_orders.id
--   2) الحالات/الأنواع/الحقول/الصلاحيات كلها بيانات (جداول) وليست كودًا
--   3) البيانات المالية في جدول منفصل + RLS (لا تصل للمشرف أصلًا)
--   4) انتقالات المراحل تتم عبر دوال RPC/Triggers على الخادم
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0) أدوات عامة
-- ---------------------------------------------------------------------
create or replace function public.touch_updated_at() returns trigger
language plpgsql as $$ begin new.updated_at = now(); return new; end $$;

-- ---------------------------------------------------------------------
-- 1) الأقسام والأدوار والصلاحيات والمستخدمون
-- ---------------------------------------------------------------------
create table public.departments (
  id uuid primary key default gen_random_uuid(),
  key text unique not null,
  name_ar text not null,
  is_active boolean not null default true,
  sort int not null default 0
);

create table public.roles (
  id uuid primary key default gen_random_uuid(),
  key text unique not null,
  name_ar text not null,
  is_system boolean not null default false
);

create table public.permissions (
  id uuid primary key default gen_random_uuid(),
  key text unique not null,
  name_ar text not null
);

create table public.role_permissions (
  role_id uuid references public.roles(id) on delete cascade,
  permission_id uuid references public.permissions(id) on delete cascade,
  primary key (role_id, permission_id)
);

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '',
  phone text,
  role_id uuid references public.roles(id),
  department_id uuid references public.departments(id),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger trg_profiles_touch before update on public.profiles
  for each row execute function public.touch_updated_at();

-- إنشاء الملف الشخصي تلقائيًا. الدور يؤخذ من app_metadata (يضبطه الخادم فقط)
-- وليس من user_metadata (يستطيع المستخدم تعديلها = ثغرة رفع صلاحيات).
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name, role_id)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', ''),
    (select id from public.roles where key = new.raw_app_meta_data->>'role_key')
  );
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- دوال الصلاحيات (security definer لتجنب التكرار الذاتي في RLS)
create or replace function public.has_perm(p text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from profiles pr
    join role_permissions rp on rp.role_id = pr.role_id
    join permissions pm on pm.id = rp.permission_id
    where pr.id = auth.uid() and pr.is_active and pm.key = p)
$$;

create or replace function public.my_role_id() returns uuid
language sql stable security definer set search_path = public as $$
  select role_id from profiles where id = auth.uid() and is_active
$$;

create or replace function public.my_department_id() returns uuid
language sql stable security definer set search_path = public as $$
  select department_id from profiles where id = auth.uid() and is_active
$$;

-- منع المستخدم من تغيير دوره/تفعيله بنفسه
create or replace function public.profiles_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (new.role_id is distinct from old.role_id
      or new.is_active is distinct from old.is_active
      or new.department_id is distinct from old.department_id)
     and not public.has_perm('settings.manage') then
    raise exception 'غير مسموح بتغيير الدور أو القسم أو التفعيل';
  end if;
  return new;
end $$;
create trigger trg_profiles_guard before update on public.profiles
  for each row execute function public.profiles_guard();

-- ---------------------------------------------------------------------
-- 2) جداول الإعدادات الديناميكية
-- ---------------------------------------------------------------------
create table public.statuses (
  id uuid primary key default gen_random_uuid(),
  scope text not null check (scope in
    ('work_order','concept','print','manufacturing','installation')),
  key text not null,
  name_ar text not null,
  color text not null default 'gray',
  sort int not null default 0,
  is_final boolean not null default false,
  notify_permission text,        -- عند دخول الأمر هذه الحالة: أشعر كل من يملك هذه الصلاحية
  is_active boolean not null default true,
  unique (scope, key)
);

create table public.priorities (
  id uuid primary key default gen_random_uuid(),
  key text unique not null, name_ar text not null,
  rank int not null default 0, color text not null default 'gray',
  is_urgent boolean not null default false, is_active boolean not null default true
);

create table public.execution_types (
  id uuid primary key default gen_random_uuid(),
  key text unique not null, name_ar text not null,
  sort int not null default 0, is_active boolean not null default true
);

create table public.work_types (
  id uuid primary key default gen_random_uuid(),
  name_ar text not null, sort int not null default 0, is_active boolean not null default true
);

create table public.materials (
  id uuid primary key default gen_random_uuid(),
  name_ar text not null, sort int not null default 0, is_active boolean not null default true
);

create table public.problem_types (
  id uuid primary key default gen_random_uuid(),
  name_ar text not null, sort int not null default 0, is_active boolean not null default true
);

create table public.checklist_templates (
  id uuid primary key default gen_random_uuid(),
  name_ar text not null, is_active boolean not null default true
);
create table public.checklist_template_items (
  id uuid primary key default gen_random_uuid(),
  template_id uuid not null references public.checklist_templates(id) on delete cascade,
  label_ar text not null, is_required boolean not null default true,
  sort int not null default 0, is_active boolean not null default true
);

create table public.custom_field_definitions (
  id uuid primary key default gen_random_uuid(),
  entity text not null default 'work_order',
  key text unique not null,
  label_ar text not null,
  field_type text not null check (field_type in
    ('text','number','select','date','image','file','boolean')),
  options jsonb not null default '[]',
  is_required boolean not null default false,
  is_financial boolean not null default false,       -- الحقول المالية = للمدير/المحاسب فقط
  visible_role_ids uuid[] not null default '{}',     -- فارغ = كل من يصل للأمر
  department_ids uuid[] not null default '{}',
  sort int not null default 0,
  is_active boolean not null default true
);

-- ---------------------------------------------------------------------
-- 3) أمر التشغيل (بدون أي بيانات مالية)
-- ---------------------------------------------------------------------
create table public.wo_counters (year int primary key, last int not null default 0);

create or replace function public.next_wo_number() returns text
language plpgsql security definer set search_path = public as $$
declare y int := extract(year from now())::int; n int;
begin
  insert into wo_counters(year, last) values (y, 1)
  on conflict (year) do update set last = wo_counters.last + 1
  returning last into n;
  return 'WO-' || y || '-' || lpad(n::text, 4, '0');
end $$;

create or replace function public.status_id(p_scope text, p_key text) returns uuid
language sql stable security definer set search_path = public as $$
  select id from statuses where scope = p_scope and key = p_key
$$;

create table public.work_orders (
  id uuid primary key default gen_random_uuid(),
  wo_number text unique not null default public.next_wo_number(),
  client_name text not null,
  client_whatsapp text not null,
  client_phone2 text,
  client_company text,
  title text,
  description text,
  work_type_id uuid references public.work_types(id),
  status_id uuid not null default public.status_id('work_order','new') references public.statuses(id),
  priority_id uuid references public.priorities(id),
  current_department_id uuid references public.departments(id),
  customer_due_at timestamptz,         -- موعد استلام/تسليم العميل
  required_delivery_at timestamptz,
  print_due_at timestamptz,
  install_due_at timestamptz,
  cancel_reason text,
  created_by uuid references public.profiles(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  closed_at timestamptz
);
create index on public.work_orders (status_id);
create index on public.work_orders (current_department_id);
create index on public.work_orders (client_whatsapp);
create index on public.work_orders (client_name);
create trigger trg_wo_touch before update on public.work_orders
  for each row execute function public.touch_updated_at();

create table public.work_order_items (            -- مقاسات/كميات/خامات متعددة
  id uuid primary key default gen_random_uuid(),
  work_order_id uuid not null references public.work_orders(id) on delete cascade,
  description text, width_cm numeric, height_cm numeric,
  quantity numeric not null default 1,
  material_id uuid references public.materials(id), notes text
);

create table public.work_order_execution_types (
  work_order_id uuid references public.work_orders(id) on delete cascade,
  execution_type_id uuid references public.execution_types(id),
  primary key (work_order_id, execution_type_id)
);

create table public.work_order_assignees (        -- توزيع المهام + توقيتات المرحلة
  id uuid primary key default gen_random_uuid(),
  work_order_id uuid not null references public.work_orders(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  stage text not null,                            -- supervise | design | print | install | ...
  assigned_by uuid references public.profiles(id) default auth.uid(),
  assigned_at timestamptz not null default now(),
  received_at timestamptz, started_at timestamptz, finished_at timestamptz,
  unique (work_order_id, user_id, stage)
);
create index on public.work_order_assignees (user_id);

create table public.work_order_notes (
  id uuid primary key default gen_random_uuid(),
  work_order_id uuid not null references public.work_orders(id) on delete cascade,
  kind text not null default 'general'
    check (kind in ('general','supervisor','designer','site','print')),
  body text not null,
  author_id uuid references public.profiles(id) default auth.uid(),
  created_at timestamptz not null default now()
);

-- البيانات المالية: جدول منفصل
create table public.work_order_financials (
  work_order_id uuid primary key references public.work_orders(id) on delete cascade,
  total numeric(14,2) not null default 0,
  paid numeric(14,2) not null default 0,
  cost numeric(14,2) not null default 0,
  payment_method text,
  notes text,
  remaining numeric(14,2) generated always as (total - paid) stored,
  profit numeric(14,2) generated always as (total - cost) stored,
  margin_pct numeric(7,2) generated always as
    (case when total > 0 then round((total - cost) / total * 100, 2) else 0 end) stored,
  updated_by uuid references public.profiles(id),
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 4) الصلاحية على الأمر: من يستطيع رؤية أمر معيّن؟
-- ---------------------------------------------------------------------
create or replace function public.can_access_wo(p_wo uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select p_wo is not null and (
    public.has_perm('orders.view_all')
    or exists (select 1 from work_order_assignees a
               where a.work_order_id = p_wo and a.user_id = auth.uid())
    or (public.has_perm('orders.view_department') and exists (
          select 1 from work_orders w
          where w.id = p_wo and w.current_department_id = public.my_department_id()))
  )
$$;

-- ---------------------------------------------------------------------
-- 5) التصوّر / Test Print / الطباعة / الهدر
-- ---------------------------------------------------------------------
create table public.design_concepts (
  id uuid primary key default gen_random_uuid(),
  work_order_id uuid not null references public.work_orders(id) on delete cascade,
  version_no int not null,
  label text,                                     -- V1 / V2 / Final
  file_path text,                                 -- مسار في Storage
  status_id uuid references public.statuses(id),
  is_approved boolean not null default false,
  notes text, revision_reason text, rejection_reason text,
  uploaded_by uuid references public.profiles(id) default auth.uid(),
  uploaded_at timestamptz not null default now(),
  decided_by uuid references public.profiles(id), decided_at timestamptz,
  unique (work_order_id, version_no)
);
create unique index one_approved_concept on public.design_concepts (work_order_id) where is_approved;

create or replace function public.concept_before_insert() returns trigger
language plpgsql as $$
begin
  select coalesce(max(version_no), 0) + 1 into new.version_no
    from design_concepts where work_order_id = new.work_order_id;
  new.label := coalesce(new.label, 'V' || new.version_no);
  new.status_id := public.status_id('concept', 'pending_approval');
  new.is_approved := false;
  return new;
end $$;
create trigger trg_concept_bi before insert on public.design_concepts
  for each row execute function public.concept_before_insert();

create table public.inventory_categories (
  id uuid primary key default gen_random_uuid(), name_ar text not null, sort int default 0
);

create table public.inventory_items (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,                      -- C5 / C7 / TRANS-WL ...
  name_ar text not null,
  category_id uuid references public.inventory_categories(id),
  unit text not null default 'قطعة',
  quantity numeric not null default 0,            -- يُحدَّث بالـ trigger فقط
  min_quantity numeric not null default 0,
  attrs jsonb not null default '{}',              -- للرولات: {"width_cm":160,"material":"..."}
  notes text,
  is_active boolean not null default true,
  updated_at timestamptz not null default now()
);
create trigger trg_inv_touch before update on public.inventory_items
  for each row execute function public.touch_updated_at();

create table public.test_prints (
  id uuid primary key default gen_random_uuid(),
  work_order_id uuid not null references public.work_orders(id) on delete cascade,
  version_no int not null,
  material_id uuid references public.materials(id),
  dimensions text, quantity numeric,
  roll_id uuid references public.inventory_items(id),
  notes text,
  decision text not null default 'pending' check (decision in ('pending','approved','rejected')),
  rejection_reason text,
  created_by uuid references public.profiles(id) default auth.uid(),
  created_at timestamptz not null default now(),
  decided_by uuid references public.profiles(id), decided_at timestamptz,
  unique (work_order_id, version_no)
);

create table public.print_jobs (
  id uuid primary key default gen_random_uuid(),
  work_order_id uuid not null references public.work_orders(id) on delete cascade,
  test_print_id uuid references public.test_prints(id),
  status_id uuid references public.statuses(id),
  material_id uuid references public.materials(id),
  roll_id uuid references public.inventory_items(id),
  quantity numeric, roll_used_qty numeric,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  operator_id uuid references public.profiles(id) default auth.uid(),
  notes text
);

create table public.waste_reports (
  id uuid primary key default gen_random_uuid(),
  work_order_id uuid not null references public.work_orders(id) on delete cascade,
  roll_id uuid references public.inventory_items(id),
  problem_type_id uuid references public.problem_types(id),
  waste_qty numeric, reason text, notes text,
  reported_by uuid references public.profiles(id) default auth.uid(),
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 6) التصنيع الخارجي
-- ---------------------------------------------------------------------
create table public.external_manufacturing (
  id uuid primary key default gen_random_uuid(),
  work_order_id uuid not null references public.work_orders(id) on delete cascade,
  factory_name text not null, factory_phone text,
  status_id uuid references public.statuses(id),
  sent_at timestamptz, expected_ready_at timestamptz,
  arrived_at timestamptz, arrived_by uuid references public.profiles(id),
  inspected_at timestamptz, inspected_by uuid references public.profiles(id),
  shipment_no text, notes text,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 7) التركيب
-- ---------------------------------------------------------------------
create table public.installation_tasks (
  id uuid primary key default gen_random_uuid(),
  work_order_id uuid not null references public.work_orders(id) on delete cascade,
  template_id uuid references public.checklist_templates(id),
  status_id uuid references public.statuses(id),
  location_text text, map_url text,
  scheduled_at timestamptz, priority_id uuid references public.priorities(id),
  pieces_count int, install_method text, install_details text,
  tools_required text, materials_required text,
  supervisor_notes text, designer_notes text,
  departed_at timestamptz,
  arrived_at timestamptz, arrived_lat double precision, arrived_lng double precision,
  site_notes text,
  started_at timestamptz, finished_at timestamptz, duration_minutes int,
  done_details text, problems text,
  created_by uuid references public.profiles(id) default auth.uid(),
  created_at timestamptz not null default now()
);

create table public.installation_team (
  task_id uuid references public.installation_tasks(id) on delete cascade,
  user_id uuid references public.profiles(id),
  primary key (task_id, user_id)
);

create table public.installation_checklist (      -- نسخة من القالب وقت إنشاء المهمة
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references public.installation_tasks(id) on delete cascade,
  label_ar text not null, is_required boolean not null default true,
  is_done boolean not null default false,
  done_at timestamptz, done_by uuid references public.profiles(id)
);

-- ---------------------------------------------------------------------
-- 8) المخزون
-- ---------------------------------------------------------------------
create table public.inventory_movements (
  id uuid primary key default gen_random_uuid(),
  item_id uuid not null references public.inventory_items(id),
  kind text not null check (kind in ('issue','receive','damage','adjust_in','adjust_out')),
  quantity numeric not null check (quantity > 0),
  work_order_id uuid references public.work_orders(id),
  received_by uuid references public.profiles(id),   -- من استلم
  actor_id uuid references public.profiles(id) default auth.uid(),  -- من صرف/سجّل
  supplier text, invoice_no text, notes text,
  created_at timestamptz not null default now()
);
create index on public.inventory_movements (item_id, created_at desc);

-- ---------------------------------------------------------------------
-- 9) الملفات والصور / الإشعارات / Timeline / Audit / الحقول المخصصة
-- ---------------------------------------------------------------------
create table public.attachments (
  id uuid primary key default gen_random_uuid(),
  work_order_id uuid references public.work_orders(id) on delete cascade,  -- null = مخزون
  entity text not null,     -- concept | test_print | manufacturing | install_before | install_after
                            -- | problem | waste | receiving | invoice | general
  entity_id uuid,
  bucket text not null default 'work-order-files',
  path text not null, file_name text, mime text, size_bytes bigint,
  uploaded_by uuid references public.profiles(id) default auth.uid(),
  created_at timestamptz not null default now()
);
create index on public.attachments (work_order_id, entity);

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  work_order_id uuid references public.work_orders(id) on delete cascade,
  type text not null, title text not null, body text,
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);
create index on public.notifications (user_id, is_read, created_at desc);

create table public.work_order_events (           -- Timeline
  id bigint generated always as identity primary key,
  work_order_id uuid not null references public.work_orders(id) on delete cascade,
  actor_id uuid references public.profiles(id),
  event_type text not null, message_ar text not null, notes text,
  meta jsonb not null default '{}',
  is_financial boolean not null default false,
  created_at timestamptz not null default now()
);
create index on public.work_order_events (work_order_id, created_at);

create table public.audit_logs (
  id bigint generated always as identity primary key,
  table_name text not null, row_id text, action text not null,
  actor_id uuid, old_data jsonb, new_data jsonb,
  is_financial boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.custom_field_values (
  work_order_id uuid references public.work_orders(id) on delete cascade,
  field_id uuid references public.custom_field_definitions(id) on delete cascade,
  value jsonb, updated_by uuid references public.profiles(id) default auth.uid(),
  updated_at timestamptz not null default now(),
  primary key (work_order_id, field_id)
);

-- ---------------------------------------------------------------------
-- 10) دوال داخلية: Timeline + إشعارات + Audit
-- ---------------------------------------------------------------------
create or replace function public.log_event(
  p_wo uuid, p_type text, p_msg text, p_notes text default null,
  p_meta jsonb default '{}', p_fin boolean default false) returns void
language sql security definer set search_path = public as $$
  insert into work_order_events (work_order_id, actor_id, event_type, message_ar, notes, meta, is_financial)
  values (p_wo, auth.uid(), p_type, p_msg, p_notes, p_meta, p_fin)
$$;

-- إشعار كل من يملك صلاحية معيّنة (النص لا يحتوي أي بيانات مالية)
create or replace function public.notify_perm(
  p_perm text, p_wo uuid, p_type text, p_title text, p_body text default null) returns void
language sql security definer set search_path = public as $$
  insert into notifications (user_id, work_order_id, type, title, body)
  select distinct pr.id, p_wo, p_type, p_title, p_body
  from profiles pr
  join role_permissions rp on rp.role_id = pr.role_id
  join permissions pm on pm.id = rp.permission_id
  where pm.key = p_perm and pr.is_active
$$;

create or replace function public.notify_assignees(
  p_wo uuid, p_stage text, p_type text, p_title text) returns void
language sql security definer set search_path = public as $$
  insert into notifications (user_id, work_order_id, type, title)
  select a.user_id, p_wo, p_type, p_title
  from work_order_assignees a where a.work_order_id = p_wo and a.stage = p_stage
$$;

create or replace function public._set_status(p_wo uuid, p_key text) returns void
language plpgsql security definer set search_path = public as $$
declare sid uuid := status_id('work_order', p_key);
begin
  if sid is null then raise exception 'حالة غير معروفة: %', p_key; end if;
  update work_orders set status_id = sid where id = p_wo and status_id <> sid;
end $$;
revoke all on function public._set_status(uuid, text) from public, anon, authenticated;

-- Audit عام
create or replace function public.audit_row() returns trigger
language plpgsql security definer set search_path = public as $$
declare is_fin boolean := coalesce(tg_argv[0], 'false')::boolean; j jsonb;
begin
  j := to_jsonb(coalesce(new, old));
  insert into audit_logs (table_name, row_id, action, actor_id, old_data, new_data, is_financial)
  values (tg_table_name, coalesce(j->>'id', j->>'work_order_id'), tg_op, auth.uid(),
          case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end,
          case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) end, is_fin);
  return coalesce(new, old);
end $$;

do $$
declare t text;
begin
  foreach t in array array['work_orders','design_concepts','test_prints','print_jobs',
    'waste_reports','external_manufacturing','installation_tasks','inventory_movements',
    'inventory_items','statuses','roles','role_permissions','profiles',
    'custom_field_definitions','attachments','work_order_assignees']
  loop
    execute format('create trigger trg_audit_%1$s after insert or update or delete on public.%1$s
                    for each row execute function public.audit_row()', t);
  end loop;
end $$;
create trigger trg_audit_financials after insert or update or delete on public.work_order_financials
  for each row execute function public.audit_row('true');

-- ---------------------------------------------------------------------
-- 11) Triggers للـ Timeline والإشعارات
-- ---------------------------------------------------------------------
create or replace function public.wo_after_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform log_event(new.id, 'created', 'تم إنشاء الأمر ' || new.wo_number);
  perform notify_perm('notifications.new_order', new.id, 'new_order', 'أمر تشغيل جديد ' || new.wo_number);
  return new;
end $$;
create trigger trg_wo_ai after insert on public.work_orders
  for each row execute function public.wo_after_insert();

create or replace function public.wo_after_status_change() returns trigger
language plpgsql security definer set search_path = public as $$
declare s statuses%rowtype;
begin
  select * into s from statuses where id = new.status_id;
  perform log_event(new.id, 'status_changed', 'تغيّرت الحالة إلى: ' || s.name_ar);
  if s.notify_permission is not null then
    perform notify_perm(s.notify_permission, new.id, 'status', s.name_ar || ' — ' || new.wo_number);
  end if;
  if s.is_final and new.closed_at is null then
    update work_orders set closed_at = now() where id = new.id;
  end if;
  return new;
end $$;
create trigger trg_wo_status after update of status_id on public.work_orders
  for each row execute function public.wo_after_status_change();

create or replace function public.financials_touch() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.updated_by := auth.uid(); new.updated_at := now();
  perform log_event(new.work_order_id, 'financial_updated', 'تم تحديث البيانات المالية', null, '{}', true);
  return new;
end $$;
create trigger trg_fin_touch before insert or update on public.work_order_financials
  for each row execute function public.financials_touch();

-- تحويل الأمر لقسم آخر / تعيين مهمة
create or replace function public.assignee_after_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform log_event(new.work_order_id, 'assigned', 'تم توزيع مهمة (' || new.stage || ')');
  insert into notifications (user_id, work_order_id, type, title)
  values (new.user_id, new.work_order_id, 'assigned', 'مهمة جديدة لك');
  return new;
end $$;
create trigger trg_assignee_ai after insert on public.work_order_assignees
  for each row execute function public.assignee_after_insert();

-- رفع تصوّر جديد
create or replace function public.concept_after_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform _set_status(new.work_order_id, 'awaiting_concept_approval');
  perform log_event(new.work_order_id, 'concept_uploaded', 'تم رفع التصوّر ' || new.label,
                    new.notes, jsonb_build_object('concept_id', new.id, 'version', new.version_no));
  update work_order_assignees set finished_at = coalesce(finished_at, now())
   where work_order_id = new.work_order_id and stage = 'design' and user_id = auth.uid();
  return new;
end $$;
create trigger trg_concept_ai after insert on public.design_concepts
  for each row execute function public.concept_after_insert();

-- Test Print جديد
create or replace function public.testprint_before_insert() returns trigger
language plpgsql as $$
begin
  select coalesce(max(version_no), 0) + 1 into new.version_no
    from test_prints where work_order_id = new.work_order_id;
  new.decision := 'pending';
  return new;
end $$;
create trigger trg_tp_bi before insert on public.test_prints
  for each row execute function public.testprint_before_insert();

create or replace function public.testprint_after_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform _set_status(new.work_order_id, 'awaiting_test_print_approval');
  perform log_event(new.work_order_id, 'test_print_uploaded', 'تم رفع Test Print رقم ' || new.version_no, new.notes);
  return new;
end $$;
create trigger trg_tp_ai after insert on public.test_prints
  for each row execute function public.testprint_after_insert();

-- التصنيع الخارجي
create or replace function public.mfg_after_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform _set_status(new.work_order_id, 'external_manufacturing');
  perform log_event(new.work_order_id, 'mfg_started', 'تم تحويل الأمر للتصنيع الخارجي: ' || new.factory_name);
  return new;
end $$;
create trigger trg_mfg_ai after insert on public.external_manufacturing
  for each row execute function public.mfg_after_insert();

create or replace function public.mfg_before_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.arrived_at is not null and old.arrived_at is null then
    new.arrived_by := auth.uid();
    perform _set_status(new.work_order_id, 'arrived');
    perform log_event(new.work_order_id, 'mfg_arrived', 'وصل التصنيع الخارجي', new.notes);
    perform notify_perm('notifications.mfg_arrived', new.work_order_id, 'mfg_arrived', 'وصل التصنيع الخارجي');
  end if;
  if new.inspected_at is not null and old.inspected_at is null then
    if new.arrived_at is null then raise exception 'لا يمكن الفحص قبل الوصول'; end if;
    new.inspected_by := auth.uid();
    perform _set_status(new.work_order_id, 'ready_for_installation');
    perform log_event(new.work_order_id, 'mfg_inspected', 'تم فحص التصنيع الخارجي — جاهز للتركيب');
  end if;
  return new;
end $$;
create trigger trg_mfg_bu before update on public.external_manufacturing
  for each row execute function public.mfg_before_update();

-- المخزون: تحديث الكمية + منع السالب + تنبيه الحد الأدنى
create or replace function public.movement_after_insert() returns trigger
language plpgsql security definer set search_path = public as $$
declare delta numeric; q numeric; m numeric; c text;
begin
  delta := case when new.kind in ('receive','adjust_in') then new.quantity else -new.quantity end;
  update inventory_items set quantity = quantity + delta where id = new.item_id
    returning quantity, min_quantity, code into q, m, c;
  if q < 0 then raise exception 'الكمية غير كافية في المخزون (%)', c; end if;
  if delta < 0 and q <= m then
    perform notify_perm('notifications.low_stock', null, 'low_stock', 'تنبيه مخزون منخفض: ' || c,
                        'الكمية الحالية ' || q || ' (الحد الأدنى ' || m || ')');
  end if;
  if new.work_order_id is not null then
    perform log_event(new.work_order_id, 'inventory_' || new.kind,
      (case when delta < 0 then 'صرف مخزون: ' else 'استلام مخزون: ' end) || c || ' × ' || new.quantity);
  end if;
  return new;
end $$;
create trigger trg_mov_ai after insert on public.inventory_movements
  for each row execute function public.movement_after_insert();

-- نسخ قائمة الفحص عند إنشاء مهمة تركيب + ربط الفريق بالأمر
create or replace function public.install_after_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.template_id is not null then
    insert into installation_checklist (task_id, label_ar, is_required)
    select new.id, label_ar, is_required from checklist_template_items
    where template_id = new.template_id and is_active order by sort;
  end if;
  perform log_event(new.work_order_id, 'install_created', 'تم التحويل للتركيب');
  return new;
end $$;
create trigger trg_inst_ai after insert on public.installation_tasks
  for each row execute function public.install_after_insert();

create or replace function public.team_after_insert() returns trigger
language plpgsql security definer set search_path = public as $$
declare wo uuid;
begin
  select work_order_id into wo from installation_tasks where id = new.task_id;
  insert into work_order_assignees (work_order_id, user_id, stage)
  values (wo, new.user_id, 'install') on conflict do nothing;
  return new;
end $$;
create trigger trg_team_ai after insert on public.installation_team
  for each row execute function public.team_after_insert();

-- ---------------------------------------------------------------------
-- 12) دوال سير العمل (RPC) — كل التحققات على الخادم
-- ---------------------------------------------------------------------
create or replace function public.change_status(p_wo uuid, p_status_key text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare sid uuid := status_id('work_order', p_status_key);
begin
  if not has_perm('orders.update') then raise exception 'غير مصرّح'; end if;
  if sid is null then raise exception 'حالة غير معروفة'; end if;
  if p_status_key = 'cancelled' then
    update work_orders set status_id = sid, cancel_reason = p_note where id = p_wo;
  else
    update work_orders set status_id = sid where id = p_wo;
  end if;
  if p_note is not null then perform log_event(p_wo, 'note', 'ملاحظة على تغيير الحالة', p_note); end if;
end $$;

create or replace function public.approve_concept(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare c design_concepts%rowtype;
begin
  if not has_perm('concepts.approve') then raise exception 'غير مصرّح'; end if;
  select * into c from design_concepts where id = p_id for update;
  update design_concepts set is_approved = false where work_order_id = c.work_order_id and is_approved;
  update design_concepts set is_approved = true, status_id = status_id('concept','approved'),
         decided_by = auth.uid(), decided_at = now(), rejection_reason = null where id = p_id;
  perform _set_status(c.work_order_id, 'concept_approved');
  perform log_event(c.work_order_id, 'concept_approved', 'تم اعتماد التصوّر ' || c.label);
  perform notify_perm('notifications.concept_approved', c.work_order_id, 'concept_approved', 'تم اعتماد التصوّر');
end $$;

create or replace function public.reject_concept(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare c design_concepts%rowtype;
begin
  if not has_perm('concepts.approve') then raise exception 'غير مصرّح'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'سبب الرفض مطلوب'; end if;
  select * into c from design_concepts where id = p_id for update;
  update design_concepts set status_id = status_id('concept','rejected'), is_approved = false,
         rejection_reason = p_reason, decided_by = auth.uid(), decided_at = now() where id = p_id;
  perform _set_status(c.work_order_id, 'revisions_required');
  perform log_event(c.work_order_id, 'concept_rejected', 'تم رفض التصوّر ' || c.label, p_reason);
  perform notify_assignees(c.work_order_id, 'design', 'concept_rejected', 'مطلوب تعديل على التصوّر');
end $$;

create or replace function public.decide_test_print(p_id uuid, p_approve boolean, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare t test_prints%rowtype;
begin
  if not has_perm('testprint.approve') then raise exception 'غير مصرّح'; end if;
  select * into t from test_prints where id = p_id for update;
  if not p_approve and coalesce(trim(p_reason), '') = '' then raise exception 'سبب الرفض مطلوب'; end if;
  update test_prints set decision = case when p_approve then 'approved' else 'rejected' end,
         rejection_reason = case when p_approve then null else p_reason end,
         decided_by = auth.uid(), decided_at = now() where id = p_id;
  if p_approve then
    perform _set_status(t.work_order_id, 'test_print_approved');
    perform log_event(t.work_order_id, 'test_print_approved', 'تم اعتماد Test Print رقم ' || t.version_no);
  else
    perform _set_status(t.work_order_id, 'at_printing');
    perform log_event(t.work_order_id, 'test_print_rejected', 'تم رفض Test Print رقم ' || t.version_no, p_reason);
    perform notify_assignees(t.work_order_id, 'print', 'test_print_rejected', 'تم رفض Test Print');
  end if;
end $$;

create or replace function public.start_print_job(
  p_wo uuid, p_roll uuid default null, p_material uuid default null,
  p_qty numeric default null, p_notes text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare tp test_prints%rowtype; jid uuid;
begin
  if not (has_perm('print.execute') and can_access_wo(p_wo)) then raise exception 'غير مصرّح'; end if;
  select * into tp from test_prints where work_order_id = p_wo order by version_no desc limit 1;
  if tp.id is null or tp.decision <> 'approved' then
    raise exception 'لا يمكن بدء الطباعة قبل اعتماد Test Print';
  end if;
  insert into print_jobs (work_order_id, test_print_id, roll_id, material_id, quantity, notes, status_id)
  values (p_wo, tp.id, p_roll, p_material, p_qty, p_notes, status_id('print','in_progress'))
  returning id into jid;
  perform _set_status(p_wo, 'printing_in_progress');
  perform log_event(p_wo, 'print_started', 'بدأت الطباعة');
  return jid;
end $$;

create or replace function public.finish_print_job(p_job uuid, p_roll_used numeric default null, p_notes text default null)
returns void language plpgsql security definer set search_path = public as $$
declare j print_jobs%rowtype;
begin
  select * into j from print_jobs where id = p_job for update;
  if not (has_perm('print.execute') and can_access_wo(j.work_order_id)) then raise exception 'غير مصرّح'; end if;
  if j.finished_at is not null then raise exception 'الطباعة منتهية مسبقًا'; end if;
  update print_jobs set finished_at = now(), roll_used_qty = coalesce(p_roll_used, roll_used_qty),
         notes = coalesce(p_notes, notes), status_id = status_id('print','done') where id = p_job;
  if j.roll_id is not null and coalesce(p_roll_used, 0) > 0 then
    insert into inventory_movements (item_id, kind, quantity, work_order_id, received_by, notes)
    values (j.roll_id, 'issue', p_roll_used, j.work_order_id, auth.uid(), 'استهلاك طباعة');
  end if;
  perform _set_status(j.work_order_id, 'in_preparation');
  perform log_event(j.work_order_id, 'print_finished', 'انتهت الطباعة');
  perform notify_perm('notifications.print_done', j.work_order_id, 'print_done', 'انتهت الطباعة');
end $$;

-- التركيب: خرج / وصل / بدأ / انتهى
create or replace function public._install_guard(p_task uuid) returns installation_tasks
language plpgsql security definer set search_path = public as $$
declare t installation_tasks%rowtype;
begin
  select * into t from installation_tasks where id = p_task for update;
  if t.id is null then raise exception 'المهمة غير موجودة'; end if;
  if not (has_perm('install.handoff') or (has_perm('install.execute') and exists
      (select 1 from installation_team where task_id = p_task and user_id = auth.uid()))) then
    raise exception 'غير مصرّح';
  end if;
  return t;
end $$;
revoke all on function public._install_guard(uuid) from public, anon, authenticated;

create or replace function public.toggle_checklist_item(p_item uuid, p_done boolean) returns void
language plpgsql security definer set search_path = public as $$
declare tid uuid;
begin
  select task_id into tid from installation_checklist where id = p_item;
  perform _install_guard(tid);
  update installation_checklist set is_done = p_done,
    done_at = case when p_done then now() end, done_by = case when p_done then auth.uid() end
  where id = p_item;
end $$;

create or replace function public.install_depart(p_task uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t installation_tasks%rowtype;
begin
  t := _install_guard(p_task);
  if exists (select 1 from installation_checklist where task_id = p_task and is_required and not is_done) then
    raise exception 'أكمل عناصر قائمة الفحص الإلزامية قبل الخروج';
  end if;
  update installation_tasks set departed_at = now(), status_id = status_id('installation','departed') where id = p_task;
  perform _set_status(t.work_order_id, 'departed_for_install');
  perform log_event(t.work_order_id, 'install_departed', 'خرج فريق التركيب');
  perform notify_perm('notifications.install_events', t.work_order_id, 'install_departed', 'خرج فريق التركيب');
end $$;

create or replace function public.install_arrive(
  p_task uuid, p_lat double precision default null, p_lng double precision default null,
  p_site_notes text default null) returns void
language plpgsql security definer set search_path = public as $$
declare t installation_tasks%rowtype;
begin
  t := _install_guard(p_task);
  if t.departed_at is null then raise exception 'لم يخرج الفريق بعد'; end if;
  if not exists (select 1 from attachments where work_order_id = t.work_order_id and entity = 'install_before') then
    raise exception 'صورة قبل التركيب إلزامية';
  end if;
  update installation_tasks set arrived_at = now(), arrived_lat = p_lat, arrived_lng = p_lng,
         site_notes = p_site_notes, status_id = status_id('installation','arrived') where id = p_task;
  perform _set_status(t.work_order_id, 'arrived_on_site');
  perform log_event(t.work_order_id, 'install_arrived', 'وصل الفريق للموقع', p_site_notes);
  perform notify_perm('notifications.install_events', t.work_order_id, 'install_arrived', 'وصل الفريق للموقع');
end $$;

create or replace function public.install_start(p_task uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t installation_tasks%rowtype;
begin
  t := _install_guard(p_task);
  if t.arrived_at is null then raise exception 'لم يصل الفريق للموقع بعد'; end if;
  update installation_tasks set started_at = now(), status_id = status_id('installation','in_progress') where id = p_task;
  perform _set_status(t.work_order_id, 'installing');
  perform log_event(t.work_order_id, 'install_started', 'بدأ التركيب');
end $$;

create or replace function public.install_finish(
  p_task uuid, p_done_details text, p_problems text default null) returns void
language plpgsql security definer set search_path = public as $$
declare t installation_tasks%rowtype;
begin
  t := _install_guard(p_task);
  if t.started_at is null then raise exception 'لم يبدأ التركيب بعد'; end if;
  if not exists (select 1 from attachments where work_order_id = t.work_order_id and entity = 'install_after') then
    raise exception 'صورة بعد التركيب إلزامية';
  end if;
  update installation_tasks set finished_at = now(),
         duration_minutes = round(extract(epoch from (now() - t.started_at)) / 60),
         done_details = p_done_details, problems = p_problems,
         status_id = status_id('installation','done') where id = p_task;
  perform _set_status(t.work_order_id, 'installed');
  perform log_event(t.work_order_id, 'install_done', 'تم التركيب', p_done_details);
  perform notify_perm('notifications.install_events', t.work_order_id, 'install_done', 'انتهى التركيب');
end $$;

-- ---------------------------------------------------------------------
-- 13) Views (security_invoker = تحترم RLS للمستخدم)
-- ---------------------------------------------------------------------
create view public.v_dashboard_counts with (security_invoker = true) as
select s.key as status_key, s.name_ar, s.sort, count(w.id) as total,
       count(w.id) filter (where p.is_urgent) as urgent,
       count(w.id) filter (where w.required_delivery_at < now() and not s.is_final) as overdue
from public.statuses s
left join public.work_orders w on w.status_id = s.id
left join public.priorities p on p.id = w.priority_id
where s.scope = 'work_order' and s.is_active
group by s.id;

create view public.v_low_stock with (security_invoker = true) as
select * from public.inventory_items where is_active and quantity <= min_quantity;

-- ---------------------------------------------------------------------
-- 14) RLS
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['departments','roles','permissions','role_permissions','profiles',
    'statuses','priorities','execution_types','work_types','materials','problem_types',
    'checklist_templates','checklist_template_items','custom_field_definitions',
    'wo_counters','work_orders','work_order_items','work_order_execution_types',
    'work_order_assignees','work_order_notes','work_order_financials','design_concepts',
    'test_prints','print_jobs','waste_reports','external_manufacturing','installation_tasks',
    'installation_team','installation_checklist','inventory_categories','inventory_items',
    'inventory_movements','attachments','notifications','work_order_events','audit_logs',
    'custom_field_values']
  loop execute format('alter table public.%I enable row level security', t); end loop;
end $$;

-- 14.1 جداول الإعدادات: قراءة للجميع (المصادَقين) — كتابة حسب الصلاحية
do $$
declare t text;
begin
  -- إعدادات تشغيلية: settings.manage أو settings.ops
  foreach t in array array['statuses','priorities','execution_types','work_types','materials',
    'problem_types','checklist_templates','checklist_template_items','inventory_categories']
  loop
    execute format('create policy %1$s_r on public.%1$s for select to authenticated using (true)', t);
    execute format('create policy %1$s_w on public.%1$s for all to authenticated
      using (public.has_perm(''settings.manage'') or public.has_perm(''settings.ops''))
      with check (public.has_perm(''settings.manage'') or public.has_perm(''settings.ops''))', t);
  end loop;
  -- إعدادات إدارية: settings.manage فقط
  foreach t in array array['departments','roles','permissions','role_permissions']
  loop
    execute format('create policy %1$s_r on public.%1$s for select to authenticated using (true)', t);
    execute format('create policy %1$s_w on public.%1$s for all to authenticated
      using (public.has_perm(''settings.manage'')) with check (public.has_perm(''settings.manage''))', t);
  end loop;
end $$;

create policy profiles_r on public.profiles for select to authenticated using (true);
create policy profiles_u_self on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());
create policy profiles_w_admin on public.profiles for all to authenticated
  using (public.has_perm('settings.manage')) with check (public.has_perm('settings.manage'));

-- 14.2 أوامر التشغيل
create policy wo_r on public.work_orders for select to authenticated
  using (public.can_access_wo(id));
create policy wo_i on public.work_orders for insert to authenticated
  with check (public.has_perm('orders.create'));
create policy wo_u on public.work_orders for update to authenticated
  using (public.has_perm('orders.update') and public.can_access_wo(id))
  with check (public.has_perm('orders.update'));
create policy wo_d on public.work_orders for delete to authenticated
  using (public.has_perm('orders.delete'));

-- 14.3 المالية: المدير والمحاسب فقط (على مستوى الصف في القاعدة)
create policy fin_r on public.work_order_financials for select to authenticated
  using (public.has_perm('finance.view'));
create policy fin_w on public.work_order_financials for all to authenticated
  using (public.has_perm('finance.edit')) with check (public.has_perm('finance.edit'));

-- 14.4 جداول فرعية مرتبطة بالأمر: قراءة = can_access_wo ، كتابة = صلاحية
do $$
declare r record;
begin
  for r in select * from (values
    ('work_order_items','orders.update'),
    ('work_order_execution_types','orders.update'),
    ('work_order_assignees','tasks.assign'),
    ('design_concepts','concepts.upload'),
    ('test_prints','print.execute'),
    ('print_jobs','print.execute'),
    ('waste_reports','print.execute'),
    ('installation_tasks','install.handoff')) v(t, perm)
  loop
    execute format('create policy %1$s_r on public.%1$s for select to authenticated
      using (public.can_access_wo(work_order_id))', r.t);
    execute format('create policy %1$s_i on public.%1$s for insert to authenticated
      with check (public.has_perm(%2$L) and public.can_access_wo(work_order_id))', r.t, r.perm);
    if r.t not in ('design_concepts','test_prints','print_jobs') then
      -- التصوّر/Test Print/الطباعة تتغير حالتها عبر RPC فقط (لا UPDATE مباشر)
      execute format('create policy %1$s_u on public.%1$s for update to authenticated
        using (public.has_perm(%2$L) and public.can_access_wo(work_order_id))', r.t, r.perm);
      execute format('create policy %1$s_d on public.%1$s for delete to authenticated
        using (public.has_perm(%2$L) and public.can_access_wo(work_order_id))', r.t, r.perm);
    end if;
  end loop;
end $$;

create policy notes_r on public.work_order_notes for select to authenticated
  using (public.can_access_wo(work_order_id));
create policy notes_i on public.work_order_notes for insert to authenticated
  with check (public.can_access_wo(work_order_id) and author_id = auth.uid());

-- التصنيع الخارجي: المدير/المشرف يديرون، المحاسب يتابع (manufacturing.view)
create policy mfg_r on public.external_manufacturing for select to authenticated
  using (public.can_access_wo(work_order_id)
         and (public.has_perm('manufacturing.view') or public.has_perm('manufacturing.manage')));
create policy mfg_w on public.external_manufacturing for all to authenticated
  using (public.has_perm('manufacturing.manage') and public.can_access_wo(work_order_id))
  with check (public.has_perm('manufacturing.manage') and public.can_access_wo(work_order_id));

-- فريق التركيب وقائمة الفحص (القراءة عبر المهمة، الكتابة عبر RPC)
create policy itm_r on public.installation_team for select to authenticated
  using (exists (select 1 from public.installation_tasks t where t.id = task_id));
create policy itm_w on public.installation_team for all to authenticated
  using (public.has_perm('install.handoff')) with check (public.has_perm('install.handoff'));
create policy icl_r on public.installation_checklist for select to authenticated
  using (exists (select 1 from public.installation_tasks t where t.id = task_id));
create policy icl_w on public.installation_checklist for all to authenticated
  using (public.has_perm('install.handoff')) with check (public.has_perm('install.handoff'));

-- المخزون
create policy inv_r on public.inventory_items for select to authenticated
  using (public.has_perm('inventory.view') or public.has_perm('inventory.manage'));
create policy inv_w on public.inventory_items for all to authenticated
  using (public.has_perm('inventory.manage')) with check (public.has_perm('inventory.manage'));
create policy mov_r on public.inventory_movements for select to authenticated
  using (public.has_perm('inventory.view') or public.has_perm('inventory.manage'));
create policy mov_i on public.inventory_movements for insert to authenticated
  with check (public.has_perm('inventory.manage'));   -- لا UPDATE/DELETE: السجل ثابت

-- الملفات (بيانات الجدول) / الإشعارات / Timeline / Audit
create policy att_r on public.attachments for select to authenticated
  using ((work_order_id is not null and public.can_access_wo(work_order_id))
      or (work_order_id is null and public.has_perm('inventory.view')));
create policy att_i on public.attachments for insert to authenticated
  with check (public.has_perm('files.upload') and uploaded_by = auth.uid()
      and (work_order_id is null or public.can_access_wo(work_order_id)));
create policy att_d on public.attachments for delete to authenticated
  using (public.has_perm('files.delete'));

create policy notif_r on public.notifications for select to authenticated using (user_id = auth.uid());
create policy notif_u on public.notifications for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy ev_r on public.work_order_events for select to authenticated
  using (public.can_access_wo(work_order_id)
         and (not is_financial or public.has_perm('finance.view')));

create policy audit_r on public.audit_logs for select to authenticated
  using (public.has_perm('audit.view') and (not is_financial or public.has_perm('finance.view')));

-- الحقول المخصصة
create or replace function public.field_visible(p_field uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from custom_field_definitions d
    where d.id = p_field and d.is_active
      and (not d.is_financial or public.has_perm('finance.view'))
      and (cardinality(d.visible_role_ids) = 0 or public.my_role_id() = any (d.visible_role_ids)))
$$;
create policy cfd_r on public.custom_field_definitions for select to authenticated
  using (public.field_visible(id) or public.has_perm('settings.manage'));
create policy cfd_w on public.custom_field_definitions for all to authenticated
  using (public.has_perm('settings.manage')) with check (public.has_perm('settings.manage'));
create policy cfv_r on public.custom_field_values for select to authenticated
  using (public.can_access_wo(work_order_id) and public.field_visible(field_id));
create policy cfv_w on public.custom_field_values for all to authenticated
  using (public.can_access_wo(work_order_id) and public.field_visible(field_id))
  with check (public.can_access_wo(work_order_id) and public.field_visible(field_id));

-- ---------------------------------------------------------------------
-- 15) Storage (مسار الملف: {work_order_id}/{entity}/{file} أو inventory/{...})
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('work-order-files', 'work-order-files', false) on conflict do nothing;

create or replace function public.path_wo_id(p_name text) returns uuid
language sql immutable as $$
  select case when split_part(p_name, '/', 1) ~ '^[0-9a-fA-F-]{36}$'
              then split_part(p_name, '/', 1)::uuid end
$$;

create policy wof_select on storage.objects for select to authenticated
  using (bucket_id = 'work-order-files' and (
    public.can_access_wo(public.path_wo_id(name))
    or (name like 'inventory/%' and public.has_perm('inventory.view'))));
create policy wof_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'work-order-files' and public.has_perm('files.upload') and (
    public.can_access_wo(public.path_wo_id(name))
    or (name like 'inventory/%' and public.has_perm('inventory.manage'))));
create policy wof_delete on storage.objects for delete to authenticated
  using (bucket_id = 'work-order-files' and public.has_perm('files.delete'));

-- ---------------------------------------------------------------------
-- 16) بيانات ابتدائية (Seed) — كلها قابلة للتعديل من الإعدادات
-- ---------------------------------------------------------------------
insert into public.roles (key, name_ar, is_system) values
 ('manager','المدير',true),('supervisor','المشرف',true),('accountant','المحاسب',true),
 ('designer','المصمم',true),('printer','موظف الطباعة',true),('installer','فريق التركيب',true);

insert into public.departments (key, name_ar, sort) values
 ('management','الإدارة',1),('supervision','الإشراف',2),('accounting','المحاسبة',3),
 ('design','التصميم',4),('printing','الطباعة',5),('external','التصنيع الخارجي',6),
 ('installation','التركيب',7);

insert into public.permissions (key, name_ar) values
 ('orders.create','إنشاء أمر'),('orders.view_all','مشاهدة كل الأوامر'),
 ('orders.view_department','مشاهدة أوامر قسمه'),('orders.update','تعديل الأوامر وتغيير الحالة'),
 ('orders.delete','حذف الأوامر'),('tasks.assign','توزيع المهام'),
 ('finance.view','مشاهدة البيانات المالية'),('finance.edit','تعديل البيانات المالية'),
 ('concepts.upload','رفع التصوّر'),('concepts.approve','اعتماد/رفض التصوّر'),
 ('testprint.approve','اعتماد/رفض Test Print'),('print.execute','تنفيذ الطباعة'),
 ('manufacturing.view','متابعة التصنيع الخارجي'),('manufacturing.manage','إدارة التصنيع الخارجي'),
 ('inventory.view','مشاهدة المخزون'),('inventory.manage','إدارة المخزون'),
 ('install.handoff','التحويل للتركيب وإدارته'),('install.execute','تنفيذ التركيب'),
 ('reports.ops','التقارير التشغيلية'),('reports.finance','التقارير المالية'),
 ('reports.own','التقارير الخاصة'),
 ('settings.manage','إعدادات النظام الكاملة'),('settings.ops','الإعدادات التشغيلية'),
 ('audit.view','سجل العمليات'),('files.upload','رفع الملفات'),('files.delete','حذف الملفات'),
 ('notifications.new_order','إشعار: أمر جديد'),('notifications.concept_approved','إشعار: اعتماد التصوّر'),
 ('notifications.print_done','إشعار: انتهاء الطباعة'),('notifications.mfg_arrived','إشعار: وصول التصنيع'),
 ('notifications.install_events','إشعار: أحداث التركيب'),('notifications.low_stock','إشعار: مخزون منخفض'),
 ('notifications.awaiting_approval','إشعار: بانتظار اعتماد');

-- المدير: كل الصلاحيات
insert into public.role_permissions select r.id, p.id from public.roles r, public.permissions p where r.key = 'manager';

-- المشرف: كل شيء عدا المالية وإعدادات النظام الكاملة
insert into public.role_permissions select r.id, p.id from public.roles r, public.permissions p
 where r.key = 'supervisor'
   and p.key not in ('finance.view','finance.edit','reports.finance','settings.manage','orders.delete');

-- بقية الأدوار
insert into public.role_permissions select r.id, p.id
from (values
 ('accountant','orders.create'),('accountant','orders.view_all'),('accountant','finance.view'),
 ('accountant','finance.edit'),('accountant','reports.finance'),('accountant','reports.ops'),
 ('accountant','manufacturing.view'),('accountant','inventory.view'),('accountant','files.upload'),
 ('accountant','notifications.new_order'),('accountant','notifications.print_done'),
 ('designer','concepts.upload'),('designer','files.upload'),('designer','reports.own'),
 ('printer','print.execute'),('printer','orders.view_department'),('printer','inventory.view'),
 ('printer','inventory.manage'),('printer','files.upload'),('printer','reports.own'),
 ('installer','install.execute'),('installer','files.upload'),('installer','reports.own')
) v(role_key, perm_key)
join public.roles r on r.key = v.role_key
join public.permissions p on p.key = v.perm_key;

insert into public.priorities (key, name_ar, rank, color, is_urgent) values
 ('normal','عادي',0,'gray',false),('urgent','مستعجل',1,'red',true);

insert into public.execution_types (key, name_ar, sort) values
 ('internal_print','طباعة داخلية',1),('external_mfg','تصنيع خارجي',2),
 ('installation','تركيب',3),('purchase','شراء/توريد',4),('other','عمل آخر',5);

insert into public.problem_types (name_ar, sort) values
 ('عيب في الخامة',1),('تلف رول',2),('خطأ مقاس',3),('مشكلة ألوان',4),
 ('مشكلة ملف',5),('خطأ تشغيل',6),('مشكلة جهاز',7),('أخرى',8);

-- حالات أمر التشغيل (notify_permission = من يُشعَر عند دخول الحالة)
insert into public.statuses (scope, key, name_ar, color, sort, is_final, notify_permission) values
 ('work_order','new','طلب جديد','blue',1,false,null),
 ('work_order','with_supervisor','عند المشرف','blue',2,false,null),
 ('work_order','with_designer','عند المصمم','purple',3,false,null),
 ('work_order','awaiting_concept_approval','بانتظار اعتماد التصوّر','orange',4,false,'concepts.approve'),
 ('work_order','revisions_required','تعديلات مطلوبة','orange',5,false,null),
 ('work_order','concept_approved','التصوّر معتمد','green',6,false,null),
 ('work_order','at_printing','عند الطباعة','blue',7,false,null),
 ('work_order','awaiting_test_print_approval','بانتظار اعتماد Test Print','orange',8,false,'testprint.approve'),
 ('work_order','test_print_approved','Test Print معتمد','green',9,false,null),
 ('work_order','printing_in_progress','قيد الطباعة','blue',10,false,null),
 ('work_order','external_manufacturing','تصنيع خارجي','purple',11,false,null),
 ('work_order','shipping','في الشحن','purple',12,false,null),
 ('work_order','arrived','وصل','green',13,false,null),
 ('work_order','in_preparation','قيد التجهيز','blue',14,false,null),
 ('work_order','ready_for_installation','جاهز للتركيب','purple',15,false,'install.handoff'),
 ('work_order','departed_for_install','خرج للتركيب','blue',16,false,null),
 ('work_order','arrived_on_site','وصل الموقع','blue',17,false,null),
 ('work_order','installing','قيد التركيب','blue',18,false,null),
 ('work_order','installed','تم التركيب','green',19,false,null),
 ('work_order','completed','مكتمل','green',20,true,null),
 ('work_order','closed','مغلق','gray',21,true,null),
 ('work_order','on_hold','متوقف','gray',22,false,null),
 ('work_order','cancelled','ملغي','red',23,true,null),
 ('concept','pending_approval','بانتظار الاعتماد','orange',1,false,null),
 ('concept','approved','معتمد','green',2,false,null),
 ('concept','rejected','مرفوض','red',3,false,null),
 ('print','in_progress','قيد الطباعة','blue',1,false,null),
 ('print','done','تمت الطباعة','green',2,true,null),
 ('manufacturing','waiting','بانتظار التصنيع','gray',1,false,null),
 ('manufacturing','sent','تم إرسال الطلب للمصنع','blue',2,false,null),
 ('manufacturing','in_progress','قيد التصنيع','blue',3,false,null),
 ('manufacturing','ready','جاهز','green',4,false,null),
 ('manufacturing','shipping','في الشحن','purple',5,false,null),
 ('manufacturing','arrived','وصل','green',6,false,null),
 ('manufacturing','inspected','تم الفحص','green',7,false,null),
 ('installation','pending','بانتظار التنفيذ','gray',1,false,null),
 ('installation','departed','خرج للموقع','blue',2,false,null),
 ('installation','arrived','وصل الموقع','blue',3,false,null),
 ('installation','in_progress','قيد التركيب','blue',4,false,null),
 ('installation','done','تم التركيب','green',5,true,null);

-- قالب قائمة فحص التركيب الافتراضي
with t as (insert into public.checklist_templates (name_ar) values ('قائمة فحص التركيب القياسية') returning id)
insert into public.checklist_template_items (template_id, label_ar, is_required, sort)
select t.id, x.label, x.req, x.ord from t, (values
 ('دريل',true,1),('ريش',true,2),('مسامير',true,3),('رول بلاك',false,4),('أدوات تثبيت',true,5),
 ('سلم',true,6),('أسلاك',false,7),('أدوات السلامة',true,8),('المواد المطلوبة',true,9),
 ('جميع القطع',true,10),('المعدات الخاصة',false,11)) x(label, req, ord);

insert into public.inventory_categories (name_ar, sort) values
 ('رولات الطباعة',1),('أحبار',2),('خامات',3),('أسلاك',4),('أدوات',5),
 ('قطع غيار',6),('مواد تركيب',7),('ترنس',8);

-- إنشاء أول مدير: بعد إنشاء مستخدم من لوحة Supabase Auth شغّل:
--   update public.profiles set role_id = (select id from public.roles where key='manager')
--   where id = '<USER_UUID>';
-- (أو أنشئ المستخدمين من الخادم مع app_metadata = {"role_key":"manager"})
