-- =============================================================================
--  لوحة قرار التعليم الحضوري المدمج — كلية فلسطين التقنية (دير البلح)
--  إعداد قاعدة بيانات Supabase: الجداول + الصلاحيات (RLS) + سجل التتبع + البيانات
--
--  طريقة التشغيل: Supabase ← SQL Editor ← New query ← الصق الملف كاملًا ← Run
--  الملف قابل لإعادة التشغيل بأمان (لا يحذف بيانات موجودة).
--
--  ⚠️ قبل التشغيل عدّل القيمتين في القسم (0) بالأسفل:
--     1) نطاق بريد الكلية المسموح بالتسجيل
--     2) بريد نائب العميد (يُعتمد تلقائيًا كمسؤول عن اللوحة)
-- =============================================================================

create schema if not exists app;
grant usage on schema app to anon, authenticated;

-- -----------------------------------------------------------------------------
-- 1) الجداول
-- -----------------------------------------------------------------------------
create table if not exists public.departments (
  id                    text primary key,
  name                  text not null,
  year                  text not null default '',
  sort_order            int  not null default 0,
  stage1_locked         boolean not null default false,
  stage1_locked_by      uuid,
  stage1_locked_by_name text not null default '',
  stage1_locked_at      timestamptz
);

create table if not exists public.profiles (
  id             uuid primary key references auth.users(id) on delete cascade,
  email          text not null unique,
  full_name      text not null check (length(trim(full_name)) between 2 and 120),
  requested_role text not null default 'lecturer' check (requested_role in ('lecturer','head','viewer')),
  role           text check (role in ('vp','head','lecturer','viewer')),
  dept_ids       text[] not null default '{}',
  residency      text check (residency in ('gaza','outside')),
  status         text not null default 'pending' check (status in ('pending','approved','rejected','suspended')),
  email_verified boolean not null default false,
  review_note    text not null default '',
  reviewed_by    uuid references public.profiles(id) on delete set null,
  reviewed_at    timestamptz,
  created_at     timestamptz not null default now(),
  constraint approved_needs_role check (status <> 'approved' or role is not null)
  -- ملاحظة: لا يوجد قيد يُلزم رئيس القسم بقسم عند التسجيل — رئيس القسم يُسجَّل
  -- بلا قسم مبدئيًا، ونائب العميد يُسند له قسمًا واحدًا أو أكثر لاحقًا من شاشة الحسابات
);

-- ترحيل: رئيس القسم كان يرتبط بقسم واحد فقط (dept_id) — الآن يمكن أن يرتبط بأكثر من قسم/مساق (dept_ids)
do $$ begin
  if exists (select 1 from information_schema.columns
             where table_schema='public' and table_name='profiles' and column_name='dept_id') then
    if not exists (select 1 from information_schema.columns
                    where table_schema='public' and table_name='profiles' and column_name='dept_ids') then
      alter table public.profiles add column dept_ids text[] not null default '{}';
    end if;
    update public.profiles
       set dept_ids = array[dept_id]
     where dept_id is not null and (dept_ids is null or dept_ids = '{}');
    alter table public.profiles drop column dept_id;
  end if;
  alter table public.profiles drop constraint if exists head_needs_dept;
end $$;
create index if not exists profiles_dept_ids_idx on public.profiles using gin(dept_ids);

create table if not exists public.app_settings (
  id                     int primary key default 1 check (id = 1),
  allowed_domains        text[] not null,
  vp_email               text not null,
  final_approved         boolean not null default false,
  final_approved_by      uuid references public.profiles(id) on delete set null,
  final_approved_by_name text not null default '',
  final_approved_at      timestamptz
);

create table if not exists public.courses (
  id              text primary key default ('m' || substr(md5(random()::text || clock_timestamp()::text), 1, 10)),
  dept_id         text not null references public.departments(id) on delete cascade,
  code            text not null default '—' check (length(code) <= 30),
  name            text not null check (length(trim(name)) between 1 and 200),
  credit          text not null default '' check (length(credit) <= 5),
  req_type        text not null default 'غير محدد',
  semester        int,
  source          text not null default 'manual' check (source in ('catalog','manual')),
  status          text not null default 'remote' check (status in ('remote','review','onsite','hybrid')),
  decided         boolean not null default false,
  justification   text not null default '' check (length(justification) <= 2000),
  updated_by      uuid,
  updated_by_name text not null default '',
  updated_at      timestamptz,
  sort_order      int not null default 0,
  created_at      timestamptz not null default now()
);
alter table public.courses add column if not exists semester int;
create index if not exists courses_dept_idx on public.courses(dept_id);

create table if not exists public.course_lecturers (
  id             uuid primary key default gen_random_uuid(),
  course_id      text not null references public.courses(id) on delete cascade,
  profile_id     uuid references public.profiles(id) on delete cascade,
  name           text not null check (length(trim(name)) between 2 and 120),
  residency      text not null check (residency in ('gaza','outside')),
  assigned       boolean not null default false,
  self_nominated boolean not null default false,
  added_by       uuid,
  created_at     timestamptz not null default now(),
  constraint outside_cannot_be_assigned check (not (assigned and residency = 'outside'))
);
create unique index if not exists course_lecturers_profile_uq
  on public.course_lecturers(course_id, profile_id) where profile_id is not null;
create unique index if not exists course_lecturers_name_uq
  on public.course_lecturers(course_id, lower(trim(name))) where profile_id is null;
create index if not exists course_lecturers_course_idx on public.course_lecturers(course_id);

create table if not exists public.audit_log (
  id          bigint generated always as identity primary key,
  ts          timestamptz not null default now(),
  actor_id    uuid,
  actor_label text not null default '',
  dept_id     text,
  dept_name   text not null default '',
  text        text not null
);
create index if not exists audit_log_ts_idx on public.audit_log(ts desc);

-- -----------------------------------------------------------------------------
-- 0) الإعدادات — ✏️ عدّل هنا
-- -----------------------------------------------------------------------------
insert into public.app_settings (id, allowed_domains, vp_email)
values (1, array['ptcdb.edu.ps', 'gmail.com'], 'hashawish@ptcdb.edu.ps')          -- ✏️ النطاق + بريد نائب العميد
on conflict (id) do update
  set allowed_domains = excluded.allowed_domains,
      vp_email        = excluded.vp_email;

-- -----------------------------------------------------------------------------
-- 2) دوال مساعدة (تعمل بصلاحية المالك حتى لا تتعارض مع RLS)
-- -----------------------------------------------------------------------------
create or replace function app.my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid() and status = 'approved'
$$;

create or replace function app.my_depts() returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce(dept_ids, '{}') from public.profiles where id = auth.uid() and status = 'approved'
$$;

create or replace function app.is_approved() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and status = 'approved')
$$;

create or replace function app.is_vp() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(app.my_role() = 'vp', false)
$$;

create or replace function app.final_locked() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select final_approved from public.app_settings where id = 1), false)
$$;

create or replace function app.can_edit_dept(p_dept text) returns boolean
language sql stable security definer set search_path = public as $$
  select not app.final_locked()
     and (app.is_vp() or (app.my_role() = 'head' and p_dept = any(app.my_depts())))
$$;

create or replace function app.course_dept(p_course text) returns text
language sql stable security definer set search_path = public as $$
  select dept_id from public.courses where id = p_course
$$;

create or replace function app.course_accepts_lecturers(p_course text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.courses c join public.departments d on d.id = c.dept_id
    where c.id = p_course and d.stage1_locked and c.decided and c.status in ('onsite','hybrid')
  )
$$;

create or replace function app.role_label(p_role text) returns text
language sql immutable as $$
  select case p_role
    when 'vp'       then 'نائب العميد للشؤون الأكاديمية'
    when 'head'     then 'رئيس قسم'
    when 'lecturer' then 'محاضر'
    when 'viewer'   then 'مشاهد'
    else coalesce(p_role, '—') end
$$;

create or replace function app.status_label(p_status text) returns text
language sql immutable as $$
  select case p_status
    when 'remote' then 'عن بُعد'
    when 'review' then 'قيد المراجعة'
    when 'onsite' then 'حضوري بالكامل'
    when 'hybrid' then 'هجين (مدمج)'
    else p_status end
$$;

create or replace function app.actor_label() returns text
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select full_name || ' (' || app.role_label(role) || ')' from public.profiles where id = auth.uid()),
    'النظام')
$$;

create or replace function app.log(p_dept text, p_text text) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into public.audit_log (actor_id, actor_label, dept_id, dept_name, text)
  values (auth.uid(), app.actor_label(), p_dept,
          coalesce((select name from public.departments where id = p_dept), ''), p_text);
end $$;

-- -----------------------------------------------------------------------------
-- 3) التسجيل: كل حساب جديد ← ملف شخصي "بانتظار المراجعة" لدى نائب العميد
-- -----------------------------------------------------------------------------
create or replace function app.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  s       public.app_settings;
  meta    jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  v_email text  := lower(new.email);
  v_req   text  := meta->>'requested_role';
  v_depts text[];
  v_res   text  := nullif(meta->>'residency', '');
  v_name  text  := nullif(trim(meta->>'full_name'), '');
  v_is_vp boolean;
  v_dept0 text;
begin
  select coalesce(array_agg(distinct d), '{}') into v_depts from (
    select jsonb_array_elements_text(coalesce(meta->'dept_ids', '[]'::jsonb)) as d
    union
    select meta->>'dept_id' where nullif(meta->>'dept_id', '') is not null
  ) x where d is not null;

  select * into s from public.app_settings where id = 1;
  if s.id is null then
    raise exception 'APP_SETTINGS_MISSING';
  end if;
  if v_email is null or not (split_part(v_email, '@', 2) = any (select lower(unnest(s.allowed_domains)))) then
    raise exception 'EMAIL_DOMAIN_NOT_ALLOWED';
  end if;

  if v_req not in ('lecturer','head','viewer') or v_req is null then v_req := 'lecturer'; end if;
  select coalesce(array_agg(dep), '{}') into v_depts
    from unnest(v_depts) dep where exists (select 1 from public.departments where id = dep);
  if v_res not in ('gaza','outside') then v_res := null; end if;
  if v_name is null or length(v_name) < 2 then v_name := split_part(v_email, '@', 1); end if;
  v_is_vp := v_email = lower(s.vp_email);
  v_dept0 := v_depts[1];

  insert into public.profiles (id, email, full_name, requested_role, role, dept_ids, residency, status, email_verified)
  values (new.id, v_email, left(v_name, 120), v_req,
          case when v_is_vp then 'vp' else v_req end,
          v_depts, v_res,
          'approved',
          new.email_confirmed_at is not null)
  on conflict (id) do nothing;

  insert into public.audit_log (actor_id, actor_label, dept_id, dept_name, text)
  values (new.id, v_name, v_dept0, coalesce((select name from public.departments where id = v_dept0), ''),
          case when v_is_vp then 'تفعيل حساب نائب العميد تلقائيًا'
               else format('تسجيل حساب جديد وتفعيله تلقائيًا بصفة: %s', app.role_label(v_req)) end);
  return new;
end $$;

create or replace function app.handle_user_confirmed() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.email_confirmed_at is not null and old.email_confirmed_at is null then
    update public.profiles set email_verified = true where id = new.id;
  end if;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function app.handle_new_user();

drop trigger if exists on_auth_user_confirmed on auth.users;
create trigger on_auth_user_confirmed after update of email_confirmed_at on auth.users
  for each row execute function app.handle_user_confirmed();

-- -----------------------------------------------------------------------------
-- 4) حراسة الأعمدة + التوثيق التلقائي
-- -----------------------------------------------------------------------------

-- 4.1 الأقسام
create or replace function app.departments_before() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not app.is_vp()
     and (new.id, new.name, new.year, new.sort_order) is distinct from (old.id, old.name, old.year, old.sort_order) then
    raise exception 'تعديل بيانات القسم متاح لنائب العميد فقط';
  end if;
  if new.stage1_locked is distinct from old.stage1_locked then
    if new.stage1_locked then
      new.stage1_locked_by := auth.uid();
      new.stage1_locked_by_name := app.actor_label();
      new.stage1_locked_at := now();
    else
      new.stage1_locked_by := null;
      new.stage1_locked_by_name := '';
      new.stage1_locked_at := null;
    end if;
  else
    new.stage1_locked_by := old.stage1_locked_by;
    new.stage1_locked_by_name := old.stage1_locked_by_name;
    new.stage1_locked_at := old.stage1_locked_at;
  end if;
  return new;
end $$;

create or replace function app.departments_after() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return null; end if;
  if new.stage1_locked is distinct from old.stage1_locked then
    perform app.log(new.id, case when new.stage1_locked
      then 'اعتماد قائمة المقررات — الانتقال إلى مرحلة اختيار المحاضرين'
      else 'إعادة فتح قائمة المقررات للتعديل' end);
  end if;
  return null;
end $$;

drop trigger if exists departments_before on public.departments;
create trigger departments_before before update on public.departments
  for each row execute function app.departments_before();
drop trigger if exists departments_after on public.departments;
create trigger departments_after after update on public.departments
  for each row execute function app.departments_after();

-- 4.2 المقررات
create or replace function app.courses_before() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if auth.uid() is not null then
      new.source := 'manual';
      new.status := 'remote';
      new.decided := false;
      new.justification := '';
      new.code := coalesce(nullif(trim(new.code), ''), '—');
      new.name := trim(new.name);
      new.sort_order := coalesce((select max(sort_order) + 1 from public.courses where dept_id = new.dept_id), 0);
      new.updated_by := null; new.updated_by_name := ''; new.updated_at := null;
    end if;
    return new;
  end if;

  if (new.id, new.dept_id, new.source) is distinct from (old.id, old.dept_id, old.source) then
    raise exception 'لا يمكن تغيير رمز المقرر الداخلي أو قسمه أو مصدره';
  end if;
  if auth.uid() is not null and not app.is_vp()
     and (new.code, new.name, new.credit, new.req_type, new.sort_order)
         is distinct from (old.code, old.name, old.credit, old.req_type, old.sort_order) then
    raise exception 'تعديل بيانات المقرر الأساسية متاح لنائب العميد فقط';
  end if;
  if new.status is distinct from old.status then new.decided := true; end if;
  if (new.status, new.decided, new.justification) is distinct from (old.status, old.decided, old.justification) then
    new.updated_by := auth.uid();
    new.updated_by_name := app.actor_label();
    new.updated_at := now();
  else
    new.updated_by := old.updated_by;
    new.updated_by_name := old.updated_by_name;
    new.updated_at := old.updated_at;
  end if;
  return new;
end $$;

create or replace function app.courses_after() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return null; end if;
  if tg_op = 'INSERT' then
    perform app.log(new.dept_id, format('إضافة مقرر جديد يدويًا: «%s»', new.name));
  else
    if new.status is distinct from old.status or (new.decided and not old.decided) then
      perform app.log(new.dept_id, format('تغيير حالة المقرر «%s» (%s) إلى: %s', new.name, new.code, app.status_label(new.status)));
    end if;
    if new.justification is distinct from old.justification then
      perform app.log(new.dept_id, format('تحديث المبرر لمقرر «%s» (%s)', new.name, new.code));
    end if;
  end if;
  return null;
end $$;

drop trigger if exists courses_before on public.courses;
create trigger courses_before before insert or update on public.courses
  for each row execute function app.courses_before();
drop trigger if exists courses_after on public.courses;
create trigger courses_after after insert or update on public.courses
  for each row execute function app.courses_after();

-- 4.3 محاضرو المقررات
create or replace function app.lecturers_before() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  p public.profiles;
begin
  if tg_op = 'INSERT' then
    new.added_by := auth.uid();
    if new.profile_id is not null then
      select * into p from public.profiles where id = new.profile_id and status = 'approved';
      if p.id is null then
        raise exception 'المحاضر المحدد غير معتمد في النظام';
      end if;
      if p.residency is null then
        raise exception 'لم يحدد هذا المحاضر مكان إقامته بعد — يجب تحديده من «حسابي»';
      end if;
      new.name := p.full_name;
      new.residency := p.residency;
    else
      new.name := regexp_replace(trim(new.name), '\s+', ' ', 'g');
    end if;
    new.self_nominated := new.profile_id is not null and new.profile_id = auth.uid();
    if new.self_nominated and not app.can_edit_dept(app.course_dept(new.course_id)) then
      new.assigned := false;
    end if;
  else
    if (new.id, new.course_id, new.profile_id, new.self_nominated, new.added_by)
         is distinct from (old.id, old.course_id, old.profile_id, old.self_nominated, old.added_by)
       or ((new.name, new.residency) is distinct from (old.name, old.residency)
           and coalesce(current_setting('app.syncing', true), '') <> 'on') then
      raise exception 'يُسمح فقط بتغيير حالة التعيين للحضور';
    end if;
  end if;
  if new.residency = 'outside' then new.assigned := false; end if;
  return new;
end $$;

create or replace function app.lecturers_after() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  r      public.course_lecturers := coalesce(new, old);
  c_name text;
  c_dept text;
begin
  if auth.uid() is null then return null; end if;
  select name, dept_id into c_name, c_dept from public.courses where id = r.course_id;
  if c_name is null then return null; end if;   -- cascade from a deleted course
  if tg_op = 'INSERT' then
    perform app.log(c_dept, format('%s «%s» لمقرر «%s»%s',
      case when new.self_nominated then 'ترشيح ذاتي من المحاضر' else 'إضافة محاضر' end,
      new.name, c_name,
      case when new.residency = 'outside' then ' — تم إدراجه كمستبعد تلقائيًا (يقيم خارج قطاع غزة)' else '' end));
  elsif tg_op = 'UPDATE' then
    if new.assigned is distinct from old.assigned then
      perform app.log(c_dept, format('%s المحاضر «%s» للتدريس الحضوري في «%s»%s',
        case when new.assigned then 'تعيين' else 'إلغاء تعيين' end, new.name, c_name,
        case when new.residency = 'outside' and old.residency = 'gaza' then ' (بسبب تحديث مكان الإقامة إلى خارج القطاع)' else '' end));
    end if;
  else
    perform app.log(c_dept, format('%s «%s» من مقرر «%s»',
      case when old.profile_id = auth.uid() then 'سحب الترشيح الذاتي للمحاضر' else 'إزالة المحاضر' end,
      old.name, c_name));
  end if;
  return null;
end $$;

drop trigger if exists lecturers_before on public.course_lecturers;
create trigger lecturers_before before insert or update on public.course_lecturers
  for each row execute function app.lecturers_before();
drop trigger if exists lecturers_after on public.course_lecturers;
create trigger lecturers_after after insert or update or delete on public.course_lecturers
  for each row execute function app.lecturers_after();

-- 4.4 الملفات الشخصية (اعتماد نائب العميد)
create or replace function app.profiles_before() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not app.is_vp() then
    if (new.id, new.email, new.requested_role, new.role, new.dept_ids, new.status,
        new.email_verified, new.review_note, new.reviewed_by, new.reviewed_at, new.created_at)
       is distinct from
       (old.id, old.email, old.requested_role, old.role, old.dept_ids, old.status,
        old.email_verified, old.review_note, old.reviewed_by, old.reviewed_at, old.created_at) then
      raise exception 'يمكنك تعديل اسمك ومكان إقامتك فقط';
    end if;
  end if;

  if auth.uid() is not null and app.is_vp() then
    if (new.id, new.email, new.created_at) is distinct from (old.id, old.email, old.created_at) then
      raise exception 'لا يمكن تغيير البريد أو المعرّف';
    end if;
    if old.id = auth.uid() and (new.role is distinct from 'vp' or new.status <> 'approved') then
      raise exception 'لا يمكنك إزالة صلاحية نائب العميد عن حسابك';
    end if;
    if new.status = 'approved' and new.role is null then new.role := new.requested_role; end if;
    if new.role = 'head' and array_length(new.dept_ids, 1) is null then
      raise exception 'يجب تحديد قسم واحد على الأقل عند اعتماد رئيس قسم';
    end if;
    if (new.status, new.role, new.dept_ids) is distinct from (old.status, old.role, old.dept_ids) then
      new.reviewed_by := auth.uid();
      new.reviewed_at := now();
    end if;
  end if;

  new.full_name := regexp_replace(trim(new.full_name), '\s+', ' ', 'g');
  return new;
end $$;

create or replace function app.profiles_after() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- مزامنة الاسم ومكان الإقامة مع ترشيحات المقررات
  if (new.full_name, new.residency) is distinct from (old.full_name, old.residency) and new.residency is not null then
    perform set_config('app.syncing', 'on', true);
    update public.course_lecturers
       set name = new.full_name,
           residency = new.residency,
           assigned = case when new.residency = 'outside' then false else assigned end
     where profile_id = new.id;
    perform set_config('app.syncing', '', true);
  end if;

  -- إلغاء تعيين من عُلّق حسابه أو رُفض
  if new.status in ('suspended','rejected') and old.status = 'approved' then
    update public.course_lecturers set assigned = false where profile_id = new.id and assigned;
  end if;

  if auth.uid() is null then return null; end if;

  if new.status is distinct from old.status then
    perform app.log(new.dept_ids[1], case new.status
      when 'approved'  then format('اعتماد حساب «%s» (%s) بصفة: %s', new.full_name, new.email, app.role_label(new.role))
      when 'rejected'  then format('رفض طلب تسجيل «%s» (%s)%s', new.full_name, new.email,
                                   case when new.review_note <> '' then ' — السبب: ' || new.review_note else '' end)
      when 'suspended' then format('تعليق حساب «%s» (%s)', new.full_name, new.email)
      else format('إعادة حساب «%s» إلى المراجعة', new.full_name) end);
  elsif new.status = 'approved' and (new.role, new.dept_ids) is distinct from (old.role, old.dept_ids) then
    perform app.log(new.dept_ids[1], format('تعديل صلاحية «%s» إلى: %s%s', new.full_name, app.role_label(new.role),
      coalesce(' — ' || (select string_agg(name, '، ') from public.departments where id = any(new.dept_ids)), '')));
  end if;
  if new.residency is distinct from old.residency and new.id = auth.uid() then
    perform app.log(null, format('تحديث مكان الإقامة إلى: %s',
      case new.residency when 'gaza' then 'داخل قطاع غزة' else 'خارج قطاع غزة' end));
  end if;
  return null;
end $$;

drop trigger if exists profiles_before on public.profiles;
create trigger profiles_before before update on public.profiles
  for each row execute function app.profiles_before();
drop trigger if exists profiles_after on public.profiles;
create trigger profiles_after after update on public.profiles
  for each row execute function app.profiles_after();

-- 4.5 الاعتماد النهائي
create or replace function app.settings_before() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null
     and (new.allowed_domains, new.vp_email) is distinct from (old.allowed_domains, old.vp_email) then
    raise exception 'تُعدَّل إعدادات النطاق وبريد نائب العميد من SQL Editor فقط';
  end if;
  if new.final_approved is distinct from old.final_approved then
    if new.final_approved then
      new.final_approved_by := auth.uid();
      new.final_approved_by_name := app.actor_label();
      new.final_approved_at := now();
    else
      new.final_approved_by := null;
      new.final_approved_by_name := '';
      new.final_approved_at := null;
    end if;
  else
    new.final_approved_by := old.final_approved_by;
    new.final_approved_by_name := old.final_approved_by_name;
    new.final_approved_at := old.final_approved_at;
  end if;
  return new;
end $$;

create or replace function app.settings_after() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return null; end if;
  if new.final_approved is distinct from old.final_approved then
    perform app.log(null, case when new.final_approved
      then 'الاعتماد النهائي لخطة التعليم الحضوري المدمج للفصل الدراسي الأول'
      else 'إعادة فتح اللوحة للتعديل بعد الاعتماد النهائي' end);
  end if;
  return null;
end $$;

drop trigger if exists settings_before on public.app_settings;
create trigger settings_before before update on public.app_settings
  for each row execute function app.settings_before();
drop trigger if exists settings_after on public.app_settings;
create trigger settings_after after update on public.app_settings
  for each row execute function app.settings_after();

-- -----------------------------------------------------------------------------
-- 5) سياسات الصلاحيات (Row Level Security)
-- -----------------------------------------------------------------------------
alter table public.departments      enable row level security;
alter table public.profiles         enable row level security;
alter table public.app_settings     enable row level security;
alter table public.courses          enable row level security;
alter table public.course_lecturers enable row level security;
alter table public.audit_log        enable row level security;

-- الأقسام: أسماؤها ظاهرة لنموذج التسجيل، والتعديل لمن يملك صلاحية القسم
drop policy if exists departments_select on public.departments;
create policy departments_select on public.departments
  for select to anon, authenticated using (true);
drop policy if exists departments_update on public.departments;
create policy departments_update on public.departments
  for update to authenticated
  using ((select app.can_edit_dept(id)))
  with check ((select app.can_edit_dept(id)));

-- الإعدادات: القراءة للمعتمدين، التعديل (الاعتماد النهائي) لنائب العميد
drop policy if exists settings_select on public.app_settings;
create policy settings_select on public.app_settings
  for select to authenticated using ((select app.is_approved()));
drop policy if exists settings_update on public.app_settings;
create policy settings_update on public.app_settings
  for update to authenticated
  using ((select app.is_vp())) with check ((select app.is_vp()));

-- المقررات
drop policy if exists courses_select on public.courses;
create policy courses_select on public.courses
  for select to authenticated using ((select app.is_approved()));
drop policy if exists courses_insert on public.courses;
create policy courses_insert on public.courses
  for insert to authenticated with check ((select app.can_edit_dept(dept_id)));
drop policy if exists courses_update on public.courses;
create policy courses_update on public.courses
  for update to authenticated
  using ((select app.can_edit_dept(dept_id)))
  with check ((select app.can_edit_dept(dept_id)));

-- محاضرو المقررات
drop policy if exists lecturers_select on public.course_lecturers;
create policy lecturers_select on public.course_lecturers
  for select to authenticated using ((select app.is_approved()));
drop policy if exists lecturers_insert on public.course_lecturers;
create policy lecturers_insert on public.course_lecturers
  for insert to authenticated with check (
    not app.final_locked()
    and app.course_accepts_lecturers(course_id)
    and (
      app.can_edit_dept(app.course_dept(course_id))
      or (app.my_role() in ('lecturer','head') and profile_id = auth.uid() and assigned = false)
    )
  );
drop policy if exists lecturers_update on public.course_lecturers;
create policy lecturers_update on public.course_lecturers
  for update to authenticated
  using (app.can_edit_dept(app.course_dept(course_id)))
  with check (app.can_edit_dept(app.course_dept(course_id)));
drop policy if exists lecturers_delete on public.course_lecturers;
create policy lecturers_delete on public.course_lecturers
  for delete to authenticated using (
    app.can_edit_dept(app.course_dept(course_id))
    or (profile_id = auth.uid() and not assigned and not app.final_locked())
  );

-- الملفات الشخصية
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles
  for select to authenticated using (
    id = auth.uid()
    or (select app.is_vp())
    or ((select app.is_approved()) and status = 'approved')
  );
drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles
  for update to authenticated
  using (id = auth.uid() or (select app.is_vp()))
  with check (id = auth.uid() or (select app.is_vp()));
-- لا يوجد INSERT/DELETE من المتصفح: الإنشاء عبر التسجيل فقط، والإيقاف بالتعليق

-- سجل التتبع: قراءة فقط، ولا يمكن لأحد تعديله أو حذفه من المتصفح
drop policy if exists audit_select on public.audit_log;
create policy audit_select on public.audit_log
  for select to authenticated using ((select app.is_approved()));

-- صلاحيات تنفيذ الدوال (بما فيها خدمة المصادقة التي تستدعي مشغّل التسجيل)
grant execute on all functions in schema app to anon, authenticated;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'supabase_auth_admin') then
    execute 'grant usage on schema app to supabase_auth_admin';
    execute 'grant execute on all functions in schema app to supabase_auth_admin';
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- 6) التحديث اللحظي (Realtime)
-- -----------------------------------------------------------------------------
do $$
declare t text;
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  foreach t in array array['departments','courses','course_lecturers','app_settings','profiles','audit_log'] loop
    if not exists (select 1 from pg_publication_tables
                   where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- -----------------------------------------------------------------------------
-- 7) ربط حساب نائب العميد إن كان مسجّلًا قبل تشغيل الملف
-- -----------------------------------------------------------------------------
insert into public.profiles (id, email, full_name, role, status, email_verified)
select u.id, lower(u.email), coalesce(nullif(trim(u.raw_user_meta_data->>'full_name'), ''), 'نائب العميد'),
       'vp', 'approved', u.email_confirmed_at is not null
from auth.users u, public.app_settings s
where s.id = 1 and lower(u.email) = lower(s.vp_email)
on conflict (id) do update set role = 'vp', status = 'approved';

-- -----------------------------------------------------------------------------
-- 8) بيانات مقررات الفصل الدراسي الأول
-- -----------------------------------------------------------------------------
insert into public.departments (id, name, year, sort_order) values
  ('d1', 'الإدارة الإلكترونية', '2023-2024', 0),
  ('d2', 'الإدارة وأتمتة المكاتب', '2023-2024', 1),
  ('d3', 'الإعلام الإذاعي والتلفزيوني', '2023-2024', 2),
  ('d4', 'الإعلام الرقمي', '2023-2024', 3),
  ('d5', 'التربية التكنولوجية', '2023-2024', 4),
  ('d6', 'الصيانة الإلكترونية', '2023-2024', 5),
  ('d7', 'إدارة الطعام والشراب', '2023-2024', 6),
  ('d8', 'المحاسبة والتأمين', '2023-2024', 7),
  ('d9', 'المحاسبة والتمويل', '2023-2024', 8),
  ('d10', 'الوسائط المتعددة والرسوم المتحركة (بكالوريوس)', '2023-2024', 9),
  ('d11', 'تصميم وتطوير مواقع الإنترنت', '2023-2024', 10),
  ('d12', 'تقنيات التسويق الرقمي', '2023-2024', 11),
  ('d13', 'تكنولوجيا الويب وأمن المعلومات', '2023-2024', 12),
  ('d14', 'الوسائط المتعددة والرسوم المتحركة (دبلوم)', '2023-2024', 13),
  ('d15', 'علوم التغذية والصحة العامة', '2023-2024', 14),
  ('d16', 'هندسة أنظمة الحاسوب (خطة 2020-2021)', '2020-2021', 15),
  ('d17', 'هندسة أنظمة الحاسوب (خطة 2025-2026)', '2025-2026', 16)
on conflict (id) do nothing;

-- ملاحظة: الكتلة أدناه آمنة لإعادة التشغيل — تُدرج أي مقرر (قسم+كود) غير موجود بعد،
-- وتُحدّث رقم الفصل الدراسي لأي مقرر أُدرج سابقًا (مثلًا من نسخة سابقة من هذا الملف
-- قبل إضافة عمود semester) دون المساس بأي قرار حضوري/محاضرين تم إدخاله يدويًا.
with v(id, dept_id, code, name, credit, req_type, semester, source, sort_order) as (values
  ('c0001', 'd1', 'BUS93201', 'تسويق الخدمات', '3', 'تخصص', 0, 'catalog', 0),
  ('c0002', 'd1', 'BUS93008', 'مبادئ القانون', '3', 'تخصص', 0, 'catalog', 1),
  ('c0003', 'd1', 'BUS93207', 'خدمات العملاء *', '3', 'تخصص', 0, 'catalog', 2),
  ('c0004', 'd1', 'ACD03180', 'فن الخطابة والعروض التقديمية', '3', 'كلية', 0, 'catalog', 3),
  ('c0005', 'd1', 'BUS13360', 'العلاقات العامة', '3', 'برنامج', 0, 'catalog', 4),
  ('c0006', 'd1', 'BUS03450', 'إدارة المشروعات الصغيرة', '3', 'تخصص', 0, 'catalog', 5),
  ('c0007', 'd1', 'ACD03159', 'لغة إنجليزية I', '3', 'كلية', 1, 'catalog', 6),
  ('c0008', 'd1', 'ACD03158', 'لغة عربية', '3', 'كلية', 1, 'catalog', 7),
  ('c0009', 'd1', 'BUS23150', 'مبادئ الاقتصاد الجزئي', '3', 'برنامج', 1, 'catalog', 8),
  ('c0010', 'd1', 'BUS13150', 'مبادئ إدارة الأعمال', '3', 'برنامج', 1, 'catalog', 9),
  ('c0011', 'd1', 'BUS33150', 'مبادئ المحاسبة I', '3', 'برنامج', 1, 'catalog', 10),
  ('c0012', 'd1', 'COMP03150', 'المهارات الرقمية', '3', 'كلية', 1, 'catalog', 11),
  ('c0013', 'd1', 'ACD03262', 'الثقافة الإسلامية', '3', 'كلية', 2, 'catalog', 12),
  ('c0014', 'd1', 'CMP13150', 'مقدمة في البرمجة', '3', 'تخصص', 2, 'catalog', 13),
  ('c0015', 'd1', 'BUS23151', 'مبادئ الاقتصاد الكلي', '3', 'برنامج', 2, 'catalog', 14),
  ('c0016', 'd1', 'CMP43350', 'تصميم مواقع الويب', '3', 'تخصص', 2, 'catalog', 15),
  ('c0017', 'd1', 'ACD03160', 'لغة انجليزية II', '3', 'كلية', 2, 'catalog', 16),
  ('c0018', 'd1', 'BUS33152', 'مبادئ المحاسبة II', '3', 'برنامج', 2, 'catalog', 17),
  ('c0019', 'd1', 'CMP13251', 'البرمجة المرئية', '3', 'تخصص', 3, 'catalog', 18),
  ('c0020', 'd1', 'CMP23251', 'مقدمة في نظم قواعد البيانات', '3', 'تخصص', 3, 'catalog', 19),
  ('c0021', 'd1', 'BUS13457', 'الإدارة الاستراتيجية', '3', 'تخصص', 3, 'catalog', 20),
  ('c0022', 'd1', 'BUS11350', 'مهارات الطباعة', '1', 'برنامج', 3, 'catalog', 21),
  ('c0023', 'd1', 'BUS53251', 'مبادئ التسويق', '3', 'تخصص', 3, 'catalog', 22),
  ('c0024', 'd1', 'ACD03255', 'الإحصاء', '3', 'برنامج', 3, 'catalog', 23),
  ('c0025', 'd1', 'ACD03161', 'اللغة الإنجليزية للأعمال', '3', 'تخصص', 4, 'catalog', 24),
  ('c0026', 'd1', 'BUS13152', 'إدارة الموارد البشرية', '3', 'تخصص', 4, 'catalog', 25),
  ('c0027', 'd1', 'BUS13258', 'نظم المعلومات الإدارية', '3', 'تخصص', 4, 'catalog', 26),
  ('c0028', 'd1', 'CMP23252', 'تحليل وتصميم النظم', '3', 'تخصص', 4, 'catalog', 27),
  ('c0029', 'd1', 'CMP43352', 'الوسائط المتعددة للإنترنت', '3', 'تخصص', 4, 'catalog', 28),
  ('c0030', 'd1', 'BUS13263', 'الرياضيات المالية', '3', 'برنامج', 4, 'catalog', 29),
  ('c0031', 'd1', 'BUS13359', 'الأعمال الإلكترونية', '3', 'تخصص', 5, 'catalog', 30),
  ('c0032', 'd1', 'BUS00001', 'متطلب اختياري 1', '3', 'تخصص', 5, 'catalog', 31),
  ('c0033', 'd1', 'CMP13451', 'برمجة ويب', '3', 'تخصص', 5, 'catalog', 32),
  ('c0034', 'd1', 'BUS13458', 'بحوث العمليات', '3', 'تخصص', 5, 'catalog', 33),
  ('c0035', 'd1', 'BUS03351', 'قانون المعاملات التجارية والالكترونية', '3', 'تخصص', 5, 'catalog', 34),
  ('c0036', 'd1', 'BUS13351', 'الإدارة المالية والمصرفية', '3', 'تخصص', 6, 'catalog', 35),
  ('c0037', 'd1', 'BUS03450', 'البحث العلمي', '3', 'برنامج', 6, 'catalog', 36),
  ('c0038', 'd1', 'BUS01450', 'أخلاقيات الأعمال', '1', 'تخصص', 6, 'catalog', 37),
  ('c0039', 'd1', 'ACD03351', 'قضايا فقهية معاصرة', '3', 'كلية', 6, 'catalog', 38),
  ('c0040', 'd1', 'BUS53352', 'التجارة الالكترونية', '3', 'تخصص', 6, 'catalog', 39),
  ('c0041', 'd1', 'CMP13453', 'نظم إدارة المحتوى CMS', '2', 'تخصص', 6, 'catalog', 40),
  ('c0042', 'd1', 'ACD03370', 'قضية فلسطين', '3', 'كلية', 7, 'catalog', 41),
  ('c0043', 'd1', 'BUS00002', 'متطلب اختياري 2', '3', 'برنامج', 7, 'catalog', 42),
  ('c0044', 'd1', 'BUS13354', 'إدارة الإنتاج والعمليات', '3', 'تخصص', 7, 'catalog', 43),
  ('c0045', 'd1', 'CMP33454', 'أمن البيانات والشبكات', '3', 'تخصص', 7, 'catalog', 44),
  ('c0046', 'd1', 'BUS53461', 'التسويق الالكتروني', '3', 'تخصص', 7, 'catalog', 45),
  ('c0047', 'd1', 'BUS13255', 'إدارة الشراء والتخزين', '3', 'تخصص', 8, 'catalog', 46),
  ('c0048', 'd1', 'BUS13353', 'السلوك التنظيمي', '3', 'تخصص', 8, 'catalog', 47),
  ('c0049', 'd1', 'BUS13465', 'مشروع التخرج', '3', 'برنامج', 8, 'catalog', 48),
  ('c0050', 'd1', 'BUS13420', 'إدارة الجودة الشاملة', '3', 'تخصص', 8, 'catalog', 49),
  ('c0051', 'd1', 'EEE03352', 'التكنولوجيا والمجتمع', '3', 'كلية', 8, 'catalog', 50),
  ('c0052', 'd2', 'ACD03001', 'اللغة الإنجليزية', '3', 'كلية', 1, 'catalog', 0),
  ('c0053', 'd2', 'BUS13000', 'مبادئ الإدارة', '3', 'برنامج', 1, 'catalog', 1),
  ('c0054', 'd2', 'BUS33000', 'المحاسبة', '3', 'تخصص', 1, 'catalog', 2),
  ('c0055', 'd2', 'ACD03002', 'دراسات في الفكر العربي الإسلامي', '3', 'كلية', 1, 'catalog', 3),
  ('c0056', 'd2', 'BUS04000', 'طباعة باللغة العربية', '2', 'تخصص', 1, 'catalog', 4),
  ('c0057', 'd2', 'COMP03150', 'المهارات الرقمية', '3', 'كلية', 1, 'catalog', 5),
  ('c0058', 'd2', 'ACD03000', 'اللغة العربية', '3', 'كلية', 2, 'catalog', 6),
  ('c0059', 'd2', 'BUS23100', 'الإقتصاد', '3', 'تخصص', 2, 'catalog', 7),
  ('c0060', 'd2', 'BUS12204', 'المراسلات التجارية باللغة العربية', '2', 'برنامج', 2, 'catalog', 8),
  ('c0061', 'd2', 'CMP52102', 'تطبيقات برمجية I', '2', 'تخصص', 2, 'catalog', 9),
  ('c0062', 'd2', 'ACD13263', 'الرياضيات', '3', 'برنامج', 2, 'catalog', 10),
  ('c0063', 'd2', 'ACD03003', 'انجليزي تجاري فني', '3', 'برنامج', 2, 'catalog', 11),
  ('c0064', 'd2', 'BUS04001', 'طباعة باللغة الإنجليزية', '2', 'تخصص', 2, 'catalog', 12),
  ('c0065', 'd2', 'BUS13202', 'أعمال المكاتب والسكرتارية', '3', 'برنامج', 3, 'catalog', 13),
  ('c0066', 'd2', 'CMP52208', 'تطبيقات برمجية II', '2', 'برنامج', 3, 'catalog', 14),
  ('c0067', 'd2', 'BUS12206', 'المراسلات التجارية بالإنجليزية', '2', 'تخصص', 3, 'catalog', 15),
  ('c0068', 'd2', 'BUS13206', 'أنظمة المعلومات الإدارية', '3', 'برنامج', 3, 'catalog', 16),
  ('c0069', 'd2', 'BUS13208', 'طباعة III', '2', 'تخصص', 3, 'catalog', 17),
  ('c0070', 'd2', 'BUS03007', 'مبادئ الإحصاء المحوسب', '3', 'برنامج', 3, 'catalog', 18),
  ('c0071', 'd2', 'BUS13203', 'إدارة الموارد البشرية', '3', 'برنامج', 3, 'catalog', 19),
  ('c0072', 'd2', 'BUS01144', 'ريادة الأعمال I', '1', 'كلية', 3, 'catalog', 20),
  ('c0073', 'd2', 'BUS13210', 'مبادئ العلاقات العامة', '3', 'تخصص', 4, 'catalog', 21),
  ('c0074', 'd2', 'BUS13207', 'السلوك التنظيمي', '3', 'تخصص', 4, 'catalog', 22),
  ('c0075', 'd2', 'BUS02206', 'تطبيقات على الطباعة والنشر المكتبي', '2', 'برنامج', 4, 'catalog', 23),
  ('c0076', 'd2', 'BUS52207', 'تدريب ميداني', '2', 'برنامج', 4, 'catalog', 24),
  ('c0077', 'd2', 'ACD03120', 'تاريخ القدس', '3', 'كلية', 4, 'catalog', 25),
  ('c0078', 'd2', 'BUS13205', 'اتمتة مكاتب', '3', 'تخصص', 4, 'catalog', 26),
  ('c0079', 'd2', 'BUS02245', 'ريادة الأعمال II', '2', 'كلية', 4, 'catalog', 27),
  ('c0080', 'd3', 'MEB23370', 'التصميم والديكور', '3', 'تخصص', 0, 'catalog', 0),
  ('c0081', 'd3', 'MEB23371', 'السينما الرقمية التفاعلية', '3', 'تخصص', 0, 'catalog', 1),
  ('c0082', 'd3', 'MPH33481', 'الإذاعات والقنوات المتخصصة', '3', 'تخصص', 0, 'catalog', 2),
  ('c0083', 'd3', 'MPH33482', 'النقد الإذاعي والتلفزيوني', '3', 'تخصص', 0, 'catalog', 3),
  ('c0084', 'd3', 'REM00001', 'العلاقات العامة*', '2', 'برنامج', 0, 'catalog', 4),
  ('c0085', 'd3', 'REM00002', 'فن الإتتيكيت والبروتوكول*', '3', 'برنامج', 0, 'catalog', 5),
  ('c0086', 'd3', 'ACD03158', 'لغة عربية', '3', 'كلية', 1, 'catalog', 6),
  ('c0087', 'd3', 'BUS03451', 'مبادئ الإدارة', '3', 'كلية', 1, 'catalog', 7),
  ('c0088', 'd3', 'MED03114', 'الإعلام الجديد', '3', 'برنامج', 1, 'catalog', 8),
  ('c0089', 'd3', 'MED03115', 'مدخل إلى الإذاعة والتليفزيون', '3', 'برنامج', 1, 'catalog', 9),
  ('c0090', 'd3', 'MED02116', 'إعلام الهاتف المحمول', '2', 'برنامج', 1, 'catalog', 10),
  ('c0091', 'd3', 'COMP03150', 'المهارات الرقمية', '3', 'كلية', 1, 'catalog', 11),
  ('c0092', 'd3', 'EEE03355', 'التكنولوجيا والمجتمع', '3', 'كلية', 2, 'catalog', 12),
  ('c0093', 'd3', 'MEB23152', 'كتابة السيناريو', '3', 'تخصص', 2, 'catalog', 13),
  ('c0094', 'd3', 'MEB13153', 'التصوير الفوتوغرافي', '3', 'برنامج', 2, 'catalog', 14),
  ('c0095', 'd3', 'MEB23154', 'الهندسة الصوتية', '3', 'تخصص', 2, 'catalog', 15),
  ('c0096', 'd3', 'MEB23155', 'الاخبار الإذاعية والتليفزيونية', '3', 'تخصص', 2, 'catalog', 16),
  ('c0097', 'd3', 'MEB12260', 'مهارات إعلامية باللغة الإنجليزية', '2', 'برنامج', 2, 'catalog', 17),
  ('c0098', 'd3', 'ACD03159', 'لغة إنجليزية I', '3', 'كلية', 3, 'catalog', 18),
  ('c0099', 'd3', 'ACD03262', 'الثقافة الإسلامية', '3', 'كلية', 3, 'catalog', 19),
  ('c0100', 'd3', 'ACD03370', 'قضية فلسطين', '3', 'كلية', 3, 'catalog', 20),
  ('c0101', 'd3', 'MEB23257', 'الدراما الإذاعية', '3', 'تخصص', 3, 'catalog', 21),
  ('c0102', 'd3', 'MEB23258', 'الإعلان الإذاعي والتليفزيوني', '3', 'تخصص', 3, 'catalog', 22),
  ('c0103', 'd3', 'MEB23259', 'الراديو الرقمي', '3', 'تخصص', 3, 'catalog', 23),
  ('c0104', 'd3', 'ACD03160', 'لغة انجليزية II', '3', 'كلية', 4, 'catalog', 24),
  ('c0105', 'd3', 'MEB23261', 'التلفزيون الرقمي', '3', 'تخصص', 4, 'catalog', 25),
  ('c0106', 'd3', 'MEB23262', 'التصوير التليفزيوني I', '3', 'تخصص', 4, 'catalog', 26),
  ('c0107', 'd3', 'MEB23263', 'الدراما التليفزيونية', '3', 'تخصص', 4, 'catalog', 27),
  ('c0108', 'd3', 'MEB23264', 'هندسة البث والإرسال', '3', 'تخصص', 4, 'catalog', 28),
  ('c0109', 'd3', 'MEB13365', 'الإحصاء الإعلامي', '3', 'برنامج', 4, 'catalog', 29),
  ('c0110', 'd3', 'ACD03351', 'قضايا فقهية معاصرة', '3', 'كلية', 5, 'catalog', 30),
  ('c0111', 'd3', 'MEB12256', 'نظريات الإعلام', '2', 'برنامج', 5, 'catalog', 31),
  ('c0112', 'd3', 'MEB23366', 'الإخراج الإذاعي', '3', 'تخصص', 5, 'catalog', 32),
  ('c0113', 'd3', 'MEB23367', 'المونتاج التلفزيوني I', '3', 'تخصص', 5, 'catalog', 33),
  ('c0114', 'd3', 'MEB23368', 'التصوير التليفزيوني II', '3', 'تخصص', 5, 'catalog', 34),
  ('c0115', 'd3', 'MEB23369', 'التصميم الجرافيكي', '3', 'تخصص', 5, 'catalog', 35),
  ('c0116', 'd3', 'MEB12372', 'تشريعات وأخلاقيات المهنة', '2', 'برنامج', 6, 'catalog', 36),
  ('c0117', 'd3', 'MEB13373', 'مناهج البحث الإعلامي', '3', 'برنامج', 6, 'catalog', 37),
  ('c0118', 'd3', 'MEB23374', 'إنتاج الأفلام', '3', 'تخصص', 6, 'catalog', 38),
  ('c0119', 'd3', 'MEB23375', 'الإخراج التلفزيوني', '3', 'تخصص', 6, 'catalog', 39),
  ('c0120', 'd3', 'MEB23376', 'إعداد وتقديم البرامج الإذاعية والتلفزيونية', '3', 'تخصص', 6, 'catalog', 40),
  ('c0121', 'd3', 'ELT00001', 'متطلب اختياري 1', '3', 'تخصص', 6, 'catalog', 41),
  ('c0122', 'd3', 'MPH33477', 'التصوير التليفزيوني الاحترافي', '3', 'تخصص', 7, 'catalog', 42),
  ('c0123', 'd3', 'MPH33478', 'مونتاج تلفزيوني II', '3', 'تخصص', 7, 'catalog', 43),
  ('c0124', 'd3', 'MPH33479', 'الصوت الرقمي', '3', 'تخصص', 7, 'catalog', 44),
  ('c0125', 'd3', 'MPH33480', 'الإخراج الاحترافي', '3', 'تخصص', 7, 'catalog', 45),
  ('c0126', 'd3', 'MEB33481', 'الإضاءة التلفزيونية', '3', 'تخصص', 7, 'catalog', 46),
  ('c0127', 'd3', 'EEE02202', 'مشروع التخرج', '2', 'تخصص', 8, 'catalog', 47),
  ('c0128', 'd3', 'MPH33483', 'الخدع والمؤثرات البصرية', '3', 'تخصص', 8, 'catalog', 48),
  ('c0129', 'd3', 'MPH33484', 'مونتاج تلفزيوني III', '3', 'تخصص', 8, 'catalog', 49),
  ('c0130', 'd3', 'MPH32485', 'تدريب ميداني', '2', 'تخصص', 8, 'catalog', 50),
  ('c0131', 'd3', 'ELT00002', 'متطلب اختياري 2', '3', 'تخصص', 8, 'catalog', 51),
  ('c0132', 'd4', 'DME23211', 'العلاقات العامة عبر الإنترنت', '3', 'تخصص', 0, 'catalog', 0),
  ('c0133', 'd4', 'DME23212', 'الإعلام الإستقصائي', '3', 'تخصص', 0, 'catalog', 1),
  ('c0134', 'd4', 'ACD03000', 'اللغة العربية', '3', 'كلية', 1, 'catalog', 2),
  ('c0135', 'd4', 'DME13101', 'مدخل إلى الإذاعة والتليفزيون', '3', 'برنامج', 1, 'catalog', 3),
  ('c0136', 'd4', 'DME13102', 'التصوير الفوتوغرافي', '3', 'برنامج', 1, 'catalog', 4),
  ('c0137', 'd4', 'DME13103', 'الهندسة الصوتية', '3', 'برنامج', 1, 'catalog', 5),
  ('c0138', 'd4', 'DME13104', 'مدخل إلى الإعلام الإلكتروني', '3', 'برنامج', 1, 'catalog', 6),
  ('c0139', 'd4', 'COMP03150', 'المهارات الرقمية', '3', 'كلية', 1, 'catalog', 7),
  ('c0140', 'd4', 'ACD03002', 'دراسات في الفكر العربي الإسلامي', '3', 'كلية', 2, 'catalog', 8),
  ('c0141', 'd4', 'ACD03120', 'تاريخ القدس', '3', 'كلية', 2, 'catalog', 9),
  ('c0142', 'd4', 'DME13105', 'تصوير تلفزيوني', '3', 'برنامج', 2, 'catalog', 10),
  ('c0143', 'd4', 'DME23106', 'المدونات والشبكات الاجتماعية', '3', 'تخصص', 2, 'catalog', 11),
  ('c0144', 'd4', 'DME23107', 'الراديو الرقمي', '3', 'تخصص', 2, 'catalog', 12),
  ('c0145', 'd4', 'CMP43101', 'معالجة الصور رقمياً', '3', 'تخصص', 2, 'catalog', 13),
  ('c0146', 'd4', 'BUS01144', 'ريادة الأعمال I', '1', 'كلية', 2, 'catalog', 14),
  ('c0147', 'd4', 'ACD03001', 'اللغة الإنجليزية', '3', 'كلية', 3, 'catalog', 15),
  ('c0148', 'd4', 'DME23208', 'التلفزيون الرقمي', '3', 'تخصص', 3, 'catalog', 16),
  ('c0149', 'd4', 'DME33104', 'المونتاج الرقمي I', '3', 'تخصص', 3, 'catalog', 17),
  ('c0150', 'd4', 'DME23210', 'التحرير الصحفي الإلكتروني I', '3', 'تخصص', 3, 'catalog', 18),
  ('c0151', 'd4', 'DME23213', 'تدريب ميداني', '3', 'تخصص', 3, 'catalog', 19),
  ('c0152', 'd4', 'ELD00000', 'مساق اختياري', '3', 'تخصص', 3, 'catalog', 20),
  ('c0153', 'd4', 'BUS02245', 'ريادة الأعمال II', '2', 'كلية', 3, 'catalog', 21),
  ('c0154', 'd4', 'DME23214', 'التحرير الصحفي الإلكتروني II', '3', 'برنامج', 4, 'catalog', 22),
  ('c0155', 'd4', 'DME13215', 'إعلام الهاتف المحمول', '2', 'برنامج', 4, 'catalog', 23),
  ('c0156', 'd4', 'DME13216', 'تشريعات وأخلاقيات المهنة', '2', 'برنامج', 4, 'catalog', 24),
  ('c0157', 'd4', 'DME23217', 'المونتاج الرقمي II', '3', 'تخصص', 4, 'catalog', 25),
  ('c0158', 'd4', 'CMP43205', 'التصميم الجرافيكي', '3', 'تخصص', 4, 'catalog', 26),
  ('c0159', 'd4', 'DME23218', 'مشروع التخرج', '3', 'تخصص', 4, 'catalog', 27),
  ('c0160', 'd5', 'ACD03483', 'علوم الصحة والبيئة', '3', 'تخصص', 0, 'catalog', 0),
  ('c0161', 'd5', 'ACD03486', 'كيمياء صناعية', '3', 'تخصص', 0, 'catalog', 1),
  ('c0162', 'd5', 'ACD03485', 'مدخل إلى العلوم التقنية', '3', 'تخصص', 0, 'catalog', 2),
  ('c0163', 'd5', 'CMP43350', 'تصميم مواقع الويب', '3', 'تخصص', 0, 'catalog', 3),
  ('c0164', 'd5', 'CMP13451', 'برمجة ويب', '3', 'تخصص', 0, 'catalog', 4),
  ('c0165', 'd5', 'CMP43352', 'الوسائط المتعددة للإنترنت', '3', 'تخصص', 0, 'catalog', 5),
  ('c0166', 'd5', 'EEE13464', 'مساحات الصانع', '3', 'تخصص', 0, 'catalog', 6),
  ('c0167', 'd5', 'CMP13459', 'ريادة الأعمال والعمل الحر عبر الإنترنت', '3', 'تخصص', 0, 'catalog', 7),
  ('c0168', 'd5', 'CMP13460', 'تطبيقات الذكاء الاصطناعي في التعليم', '3', 'تخصص', 0, 'catalog', 8),
  ('c0169', 'd5', 'CMP13461', 'التعلم القائم على المشاريع', '3', 'تخصص', 0, 'catalog', 9),
  ('c0170', 'd5', 'CMP13463', 'تكنولوجيا المعلومات وتعليم رياض الأطفال', '3', 'تخصص', 0, 'catalog', 10),
  ('c0171', 'd5', 'COM43179', 'تصميم واجهة المستخدم وتجربة المستخدم', '3', 'تخصص', 0, 'catalog', 11),
  ('c0172', 'd5', 'EDU13461', 'إنشاء موارد تعليمية لتعليم الطفولة المبكرة', '3', 'تخصص', 0, 'catalog', 12),
  ('c0173', 'd5', 'ACD03488', 'تكنولوجيا المعلومات لذوي الاحتياجات الخاصة', '3', 'تخصص', 0, 'catalog', 13),
  ('c0174', 'd5', 'ACD03152', 'I فيزياء عامة', '3', 'برنامج', 1, 'catalog', 14),
  ('c0175', 'd5', 'ACD03159', 'لغة إنجليزية I', '3', 'كلية', 1, 'catalog', 15),
  ('c0176', 'd5', 'ACD03158', 'لغة عربية', '3', 'كلية', 1, 'catalog', 16),
  ('c0177', 'd5', 'MEE02152', 'مشغل هندسي', '2', 'تخصص', 1, 'catalog', 17),
  ('c0178', 'd5', 'ACD03178', 'I رياضيات عامة', '3', 'برنامج', 1, 'catalog', 18),
  ('c0179', 'd5', 'COMP03150', 'المهارات الرقمية', '3', 'كلية', 1, 'catalog', 19),
  ('c0180', 'd5', 'EEE14259', 'مبادئ الكهرباء', '4', 'تخصص', 2, 'catalog', 20),
  ('c0181', 'd5', 'EDU13150', 'مدخل إلى التربية', '3', 'برنامج', 2, 'catalog', 21),
  ('c0182', 'd5', 'MEE03153', 'رسم هندسي', '3', 'تخصص', 2, 'catalog', 22),
  ('c0183', 'd5', 'CMP03253', 'تكنولوجيا المعلومات', '3', 'تخصص', 2, 'catalog', 23),
  ('c0184', 'd5', 'ACD03160', 'لغة انجليزية II', '3', 'كلية', 2, 'catalog', 24),
  ('c0185', 'd5', 'CMP13351', 'وسائط متعددة للتعليم', '3', 'تخصص', 2, 'catalog', 25),
  ('c0186', 'd5', 'EEE12160', 'مشغل كهرباء', '2', 'تخصص', 3, 'catalog', 26),
  ('c0187', 'd5', 'EDU13251', 'علم نفس تربوي', '3', 'برنامج', 3, 'catalog', 27),
  ('c0188', 'd5', 'CMP23250', 'مقدمة في قواعد البيانات', '3', 'تخصص', 3, 'catalog', 28),
  ('c0189', 'd5', 'ACD03370', 'قضية فلسطين', '3', 'كلية', 3, 'catalog', 29),
  ('c0190', 'd5', 'ACD03360', 'I كيمياء عامة', '3', 'برنامج', 3, 'catalog', 30),
  ('c0191', 'd5', 'BUS03451', 'مبادئ الإدارة', '3', 'كلية', 3, 'catalog', 31),
  ('c0192', 'd5', 'CMP02151', 'تطبيقات برمجية', '2', 'تخصص', 4, 'catalog', 32),
  ('c0193', 'd5', 'EEE14261', 'مبادئ الإلكترونيات', '4', 'تخصص', 4, 'catalog', 33),
  ('c0194', 'd5', 'EDU13252', 'أساليب تدريس العلوم والتكنولوجيا', '3', 'تخصص', 4, 'catalog', 34),
  ('c0195', 'd5', 'ACD03484', 'الطاقة ومصادرها', '3', 'تخصص', 4, 'catalog', 35),
  ('c0196', 'd5', 'CMP13353', 'تطوير مواقع ويب تعليمية', '3', 'تخصص', 4, 'catalog', 36),
  ('c0197', 'd5', 'ACD03388', 'علوم حياتية عامة', '3', 'برنامج', 4, 'catalog', 37),
  ('c0198', 'd5', 'ACD03262', 'الثقافة الإسلامية', '3', 'كلية', 5, 'catalog', 38),
  ('c0199', 'd5', 'CMP13350', 'I لغات برمجة حديثة', '3', 'تخصص', 5, 'catalog', 39),
  ('c0200', 'd5', 'EDU13355', 'تكنولوجيا التربية', '3', 'تخصص', 5, 'catalog', 40),
  ('c0201', 'd5', 'ACD03280', 'مبادئ الإحصاء', '3', 'برنامج', 5, 'catalog', 41),
  ('c0202', 'd5', 'ACD00001', 'مادة اختيارية 1', '3', 'تخصص', 5, 'catalog', 42),
  ('c0203', 'd5', 'CMP13354', 'تحريك عناصر ثنائية الأبعاد', '3', 'تخصص', 5, 'catalog', 43),
  ('c0204', 'd5', 'ACD03268', 'مدخل إلى هندسة البيئة', '3', 'تخصص', 6, 'catalog', 44),
  ('c0205', 'd5', 'EDU13354', 'القياس والتقويم', '3', 'برنامج', 6, 'catalog', 45),
  ('c0206', 'd5', 'CMP13351', 'II لغات برمجة حديثة', '3', 'تخصص', 6, 'catalog', 46),
  ('c0207', 'd5', 'EDU13356', 'تصميم المناهج', '3', 'برنامج', 6, 'catalog', 47),
  ('c0208', 'd5', 'ACD03351', 'قضايا فقهية معاصرة', '3', 'كلية', 6, 'catalog', 48),
  ('c0209', 'd5', 'EDU13357', 'التصميم التعليمي والتعليم الإلكتروني', '3', 'تخصص', 6, 'catalog', 49),
  ('c0210', 'd5', 'EDU02450', 'I تربية عملية', '2', 'تخصص', 7, 'catalog', 50),
  ('c0211', 'd5', 'CMP02452', 'صيانة أجهزة الحاسوب', '2', 'تخصص', 7, 'catalog', 51),
  ('c0212', 'd5', 'EDU13459', 'إدارة مجمعات تعليمية', '3', 'تخصص', 7, 'catalog', 52),
  ('c0213', 'd5', 'ACD03269', 'مناهج البحث العلمي', '3', 'برنامج', 7, 'catalog', 53),
  ('c0214', 'd5', 'ACD00002', 'مادة إختيارية 2', '3', 'تخصص', 7, 'catalog', 54),
  ('c0215', 'd5', 'EEE43468', 'شبكات واتصالات', '3', 'تخصص', 8, 'catalog', 55),
  ('c0216', 'd5', 'EDU02451', 'II تربية عملية', '2', 'تخصص', 8, 'catalog', 56),
  ('c0217', 'd5', 'ACD00003', 'مادة إختيارية 3', '3', 'تخصص', 8, 'catalog', 57),
  ('c0218', 'd5', 'EEE03352', 'التكنولوجيا والمجتمع', '3', 'كلية', 8, 'catalog', 58),
  ('c0219', 'd6', 'ACD03001', 'اللغة الإنجليزية', '3', 'كلية', 1, 'catalog', 0),
  ('c0220', 'd6', 'EEE13109', 'إلكترونيات', '3', 'برنامج', 1, 'catalog', 1),
  ('c0221', 'd6', 'ACD13263', 'الرياضيات', '3', 'برنامج', 1, 'catalog', 2),
  ('c0222', 'd6', 'EEE13106', 'طرق الفحص وأجهزة القياس', '3', 'تخصص', 1, 'catalog', 3),
  ('c0223', 'd6', 'EEE13107', 'مبادئ الدوائر الكهربائية', '3', 'برنامج', 1, 'catalog', 4),
  ('c0224', 'd6', 'COMP03150', 'المهارات الرقمية', '3', 'كلية', 1, 'catalog', 5),
  ('c0225', 'd6', 'ACD03000', 'اللغة العربية', '3', 'كلية', 2, 'catalog', 6),
  ('c0226', 'd6', 'ACD03002', 'دراسات في الفكر العربي الإسلامي', '3', 'كلية', 2, 'catalog', 7),
  ('c0227', 'd6', 'EEE33100', 'مبادئ الاتصالات', '3', 'تخصص', 2, 'catalog', 8),
  ('c0228', 'd6', 'EEE13204', 'إلكترونيات رقمية', '3', 'تخصص', 2, 'catalog', 9),
  ('c0229', 'd6', 'MEE01104', 'مشغل هندسي', '1', 'برنامج', 2, 'catalog', 10),
  ('c0230', 'd6', 'EEE93100', 'مقدمة في الصيانة الإلكترونية', '3', 'تخصص', 2, 'catalog', 11),
  ('c0231', 'd6', 'BUS01144', 'ريادة الأعمال I', '1', 'كلية', 2, 'catalog', 12),
  ('c0232', 'd6', 'EEE12108', 'رسم كهربائي بالحاسوب', '2', 'تخصص', 2, 'catalog', 13),
  ('c0233', 'd6', 'EEE13208', 'إلكترونيات القوى', '3', 'تخصص', 3, 'catalog', 14),
  ('c0234', 'd6', 'EEE62200', 'أنظمة الحماية والتحكم', '2', 'تخصص', 3, 'catalog', 15),
  ('c0235', 'd6', 'EEE93204', 'صيانة أجهزة مكتبة I', '3', 'تخصص', 3, 'catalog', 16),
  ('c0236', 'd6', 'EEE02207', 'تدريب ميداني I', '2', 'تخصص', 3, 'catalog', 17),
  ('c0237', 'd6', 'BUS02245', 'ريادة الأعمال II', '2', 'كلية', 3, 'catalog', 18),
  ('c0238', 'd6', 'EEE11112', 'الأنظمة والسلامة', '1', 'تخصص', 3, 'catalog', 19),
  ('c0239', 'd6', 'EEE93208', 'صيانة الشواحن والعواكس', '3', 'تخصص', 3, 'catalog', 20),
  ('c0240', 'd6', 'EEE93209', 'صيانة شاشات العرض', '3', 'تخصص', 3, 'catalog', 21),
  ('c0241', 'd6', 'EEE63209', 'أنظمة مضمنة', '3', 'تخصص', 4, 'catalog', 22),
  ('c0242', 'd6', 'EEE93205', 'صيانة أجهزة مكتبية II', '3', 'تخصص', 4, 'catalog', 23),
  ('c0243', 'd6', 'EEE93206', 'صيانة أجهزة الاتصالات الخليوية', '3', 'تخصص', 4, 'catalog', 24),
  ('c0244', 'd6', 'EEE93207', 'صيانة اللوحات الصناعية', '3', 'تخصص', 4, 'catalog', 25),
  ('c0245', 'd6', 'EEE02208', 'تدريب ميداني II', '2', 'تخصص', 4, 'catalog', 26),
  ('c0246', 'd6', 'ACD03120', 'تاريخ القدس', '3', 'كلية', 4, 'catalog', 27),
  ('c0247', 'd7', 'ACD02113', 'اللغة الفرنسية I', '2', 'برنامج', 0, 'catalog', 0),
  ('c0248', 'd7', 'ACD02114', 'اللغة الفرنسية II', '2', 'برنامج', 0, 'catalog', 1),
  ('c0249', 'd7', 'ACD02215', 'اللغة الفرنسية III', '2', 'برنامج', 0, 'catalog', 2),
  ('c0250', 'd7', 'ACD02218', 'اللغة الفرنسية IV', '2', 'برنامج', 0, 'catalog', 3),
  ('c0251', 'd7', 'ACD02236', 'لغة عبرية I', '2', 'برنامج', 0, 'catalog', 4),
  ('c0252', 'd7', 'ACD02237', 'لغة عبرية II', '2', 'برنامج', 0, 'catalog', 5),
  ('c0253', 'd7', 'ACD03001', 'اللغة الإنجليزية', '3', 'كلية', 1, 'catalog', 6),
  ('c0254', 'd7', 'ACD03000', 'اللغة العربية', '3', 'كلية', 1, 'catalog', 7),
  ('c0255', 'd7', 'BUS13000', 'مبادئ الإدارة', '3', 'برنامج', 1, 'catalog', 8),
  ('c0256', 'd7', 'HOT03100', 'صحة الأغذية', '3', 'تخصص', 1, 'catalog', 9),
  ('c0257', 'd7', 'HNP12151', 'I فرنسي', '2', 'برنامج', 1, 'catalog', 10),
  ('c0258', 'd7', 'COMP03150', 'المهارات الرقمية', '3', 'كلية', 1, 'catalog', 11),
  ('c0259', 'd7', 'BUS33000', 'المحاسبة', '3', 'برنامج', 2, 'catalog', 12),
  ('c0260', 'd7', 'ACD03002', 'دراسات في الفكر العربي الإسلامي', '3', 'كلية', 2, 'catalog', 13),
  ('c0261', 'd7', 'HOT02101', 'تحضير الطعام وإنتاجه I', '2', 'تخصص', 2, 'catalog', 14),
  ('c0262', 'd7', 'HOT02102', 'خدمات الطعام والشراب I', '2', 'تخصص', 2, 'catalog', 15),
  ('c0263', 'd7', 'HOT03103', 'علم الأغذية', '3', 'برنامج', 2, 'catalog', 16),
  ('c0264', 'd7', 'ACD03120', 'تاريخ القدس', '3', 'كلية', 2, 'catalog', 17),
  ('c0265', 'd7', 'BUS01144', 'ريادة الأعمال I', '1', 'كلية', 2, 'catalog', 18),
  ('c0266', 'd7', 'ACD03005', 'اللغة الإنجليزية الفنية I', '3', 'برنامج', 3, 'catalog', 19),
  ('c0267', 'd7', 'HOT03210', 'تغذية الإنسان', '3', 'تخصص', 3, 'catalog', 20),
  ('c0268', 'd7', 'HOT02204', 'تحضير الطعام وإنتاجه II', '2', 'تخصص', 3, 'catalog', 21),
  ('c0269', 'd7', 'HOT02205', 'خدمات الطعام والشراب II', '2', 'تخصص', 3, 'catalog', 22),
  ('c0270', 'd7', 'HOT03206', 'تدريب ميداني I', '3', 'تخصص', 3, 'catalog', 23),
  ('c0271', 'd7', 'BUS02245', 'ريادة الأعمال II', '2', 'كلية', 3, 'catalog', 24),
  ('c0272', 'd7', 'ACD02225', 'لغة أجنبية I', '2', 'تخصص', 3, 'catalog', 25),
  ('c0273', 'd7', 'HOT02122', 'فن التعامل مع الضيوف', '2', 'تخصص', 3, 'catalog', 26),
  ('c0274', 'd7', 'ACD03206', 'اللغة الإنجليزية الفنية II', '3', 'برنامج', 4, 'catalog', 27),
  ('c0275', 'd7', 'HOT02211', 'الصحة العامة', '2', 'برنامج', 4, 'catalog', 28),
  ('c0276', 'd7', 'HOT02207', 'مبادئ السياحة', '2', 'برنامج', 4, 'catalog', 29),
  ('c0277', 'd7', 'HOT03221', 'تدريب ميداني II', '3', 'تخصص', 4, 'catalog', 30),
  ('c0278', 'd7', 'HOT02208', 'تحضير الطعام وإنتاجه III', '2', 'تخصص', 4, 'catalog', 31),
  ('c0279', 'd7', 'HOT02209', 'خدمات الطعام والشراب III', '2', 'تخصص', 4, 'catalog', 32),
  ('c0280', 'd7', 'ACD02235', 'لغة أجنبية II', '2', 'تخصص', 4, 'catalog', 33),
  ('c0281', 'd8', 'ACD03001', 'اللغة الإنجليزية', '3', 'كلية', 1, 'catalog', 0),
  ('c0282', 'd8', 'ACD03000', 'اللغة العربية', '3', 'كلية', 1, 'catalog', 1),
  ('c0283', 'd8', 'BUS13000', 'مبادئ الإدارة', '3', 'برنامج', 1, 'catalog', 2),
  ('c0284', 'd8', 'BUS33100', 'المحاسبة المالية I', '3', 'تخصص', 1, 'catalog', 3),
  ('c0285', 'd8', 'BUS93008', 'مبادئ القانون', '3', 'تخصص', 1, 'catalog', 4),
  ('c0286', 'd8', 'COMP03150', 'المهارات الرقمية', '3', 'كلية', 1, 'catalog', 5),
  ('c0287', 'd8', 'ACD03002', 'دراسات في الفكر العربي الإسلامي', '3', 'كلية', 2, 'catalog', 6),
  ('c0288', 'd8', 'BUS23100', 'الإقتصاد', '3', 'برنامج', 2, 'catalog', 7),
  ('c0289', 'd8', 'BUS03007', 'الرياضيات المالية', '3', 'تخصص', 2, 'catalog', 8),
  ('c0290', 'd8', 'BUS33101', 'المحاسبة المالية II', '3', 'تخصص', 2, 'catalog', 9),
  ('c0291', 'd8', 'BUS43100', 'مبادئ في التأمين', '3', 'تخصص', 2, 'catalog', 10),
  ('c0292', 'd8', 'ACD03003', 'انجليزي تجاري فني', '3', 'برنامج', 2, 'catalog', 11),
  ('c0293', 'd8', 'BUS01144', 'ريادة الأعمال I', '1', 'كلية', 2, 'catalog', 12),
  ('c0294', 'd8', 'BUS12107', 'تطبيقات برمجية', '2', 'تخصص', 3, 'catalog', 13),
  ('c0295', 'd8', 'BUS93201', 'تسويق الخدمات', '3', 'تخصص', 3, 'catalog', 14),
  ('c0296', 'd8', 'BUS43201', 'التأمين في الإسلام', '3', 'تخصص', 3, 'catalog', 15),
  ('c0297', 'd8', 'BUS33202', 'محاسبة التكاليف', '3', 'تخصص', 3, 'catalog', 16),
  ('c0298', 'd8', 'BUS33203', 'محاسبة شركات', '3', 'تخصص', 3, 'catalog', 17),
  ('c0299', 'd8', 'ACD03120', 'تاريخ القدس', '3', 'كلية', 3, 'catalog', 18),
  ('c0300', 'd8', 'BUS02245', 'ريادة الأعمال II', '2', 'كلية', 3, 'catalog', 19),
  ('c0301', 'd8', 'BUS33204', 'محاسبة بنوك وشركات التأمين', '3', 'تخصص', 4, 'catalog', 20),
  ('c0302', 'd8', 'BUS33205', 'محاسبة حكومية', '3', 'تخصص', 4, 'catalog', 21),
  ('c0303', 'd8', 'BUS33206', 'محاسبة ضريبية', '3', 'تخصص', 4, 'catalog', 22),
  ('c0304', 'd8', 'BUS43202', 'إدارة الخطر والتأمين', '3', 'تخصص', 4, 'catalog', 23),
  ('c0305', 'd8', 'BUS32207', 'تدريب ميداني', '2', 'تخصص', 4, 'catalog', 24),
  ('c0306', 'd8', 'BUS03007', 'مبادئ الإحصاء المحوسب', '3', 'برنامج', 4, 'catalog', 25),
  ('c0307', 'd9', 'ACC13259', 'النظرية المحاسبية', '3', 'تخصص', 0, 'catalog', 0),
  ('c0308', 'd9', 'BUS53353', 'التحارة الاإلكترونية', '3', 'تخصص', 0, 'catalog', 1),
  ('c0309', 'd9', 'ACD03159', 'لغة إنجليزية I', '3', 'كلية', 1, 'catalog', 2),
  ('c0310', 'd9', 'ACD03158', 'لغة عربية', '3', 'كلية', 1, 'catalog', 3),
  ('c0311', 'd9', 'BUS23150', 'مبادئ الاقتصاد الجزئي', '3', 'برنامج', 1, 'catalog', 4),
  ('c0312', 'd9', 'BUS13150', 'مبادئ إدارة الأعمال', '3', 'كلية', 1, 'catalog', 5),
  ('c0313', 'd9', 'BUS33150', 'مبادئ المحاسبة I', '3', 'برنامج', 1, 'catalog', 6),
  ('c0314', 'd9', 'COMP03150', 'المهارات الرقمية', '3', 'كلية', 1, 'catalog', 7),
  ('c0315', 'd9', 'ACD03262', 'الثقافة الإسلامية', '3', 'كلية', 2, 'catalog', 8),
  ('c0316', 'd9', 'BUS33151', 'مبادئ المحاسبة II', '3', 'تخصص', 2, 'catalog', 9),
  ('c0317', 'd9', 'BUS23151', 'مبادئ الاقتصاد الكلي', '3', 'تخصص', 2, 'catalog', 10),
  ('c0318', 'd9', 'ACD03160', 'لغة انجليزية II', '3', 'كلية', 2, 'catalog', 11),
  ('c0319', 'd9', 'BUS13263', 'الرياضيات المالية', '3', 'برنامج', 2, 'catalog', 12),
  ('c0320', 'd9', 'BUS13354', 'الإدارة المالية', '3', 'تخصص', 2, 'catalog', 13),
  ('c0321', 'd9', 'FIN23222', 'نقود وبنوك', '3', 'تخصص', 3, 'catalog', 14),
  ('c0322', 'd9', 'FIN23223', 'إدارة الاستثمار', '3', 'تخصص', 3, 'catalog', 15),
  ('c0323', 'd9', 'ACC13254', 'محاسبة التكاليف', '3', 'تخصص', 3, 'catalog', 16),
  ('c0324', 'd9', 'BUS03256', 'الإحصاء التطبيقي', '3', 'برنامج', 3, 'catalog', 17),
  ('c0325', 'd9', 'ACC13357', 'المحاسبة المتوسطة 1', '3', 'تخصص', 3, 'catalog', 18),
  ('c0326', 'd9', 'ACD03370', 'قضية فلسطين', '3', 'كلية', 4, 'catalog', 19),
  ('c0327', 'd9', 'BUS43202', 'إدارة الخطر والتأمين', '3', 'برنامج', 4, 'catalog', 20),
  ('c0328', 'd9', 'BUS03350', 'قانون المعاملات التجارية', '3', 'تخصص', 4, 'catalog', 21),
  ('c0329', 'd9', 'ACC13257', 'المحاسبة الإدارية', '3', 'تخصص', 4, 'catalog', 22),
  ('c0330', 'd9', 'FIN23380', 'مساق اختياري 1', '3', 'تخصص', 4, 'catalog', 23),
  ('c0331', 'd9', 'ACC13258', 'المحاسبة المتوسطة 2', '3', 'تخصص', 4, 'catalog', 24),
  ('c0332', 'd9', 'FIN23338', 'إدارة التسهيلات الائتمانية', '3', 'تخصص', 5, 'catalog', 25),
  ('c0333', 'd9', 'ACC13358', 'المحاسبة الحكومية', '3', 'تخصص', 5, 'catalog', 26),
  ('c0334', 'd9', 'FIN33232', 'أسس التمويل الإسلامي', '3', 'تخصص', 5, 'catalog', 27),
  ('c0335', 'd9', 'ACC33305', 'محاسبة بنوك', '3', 'تخصص', 5, 'catalog', 28),
  ('c0336', 'd9', 'BUS03310', 'مهارات الاتصال', '3', 'برنامج', 5, 'catalog', 29),
  ('c0337', 'd9', 'FIN43358', 'دراسات الجدوى الاقتصادية', '3', 'تخصص', 6, 'catalog', 30),
  ('c0338', 'd9', 'FIN23225', 'أسواق المال', '3', 'تخصص', 6, 'catalog', 31),
  ('c0339', 'd9', 'FIN32310', 'التحليل المالي والائتماني الالكتروني', '3', 'تخصص', 6, 'catalog', 32),
  ('c0340', 'd9', 'ACC13360', 'محاسبة الضرائب', '3', 'تخصص', 6, 'catalog', 33),
  ('c0341', 'd9', 'BUS03452', 'التكنولوجيا والمجتمع', '3', 'كلية', 6, 'catalog', 34),
  ('c0342', 'd9', 'FIN33366', 'نظم المعلومات المحاسبية', '3', 'تخصص', 6, 'catalog', 35),
  ('c0343', 'd9', 'ACC13461', 'تدقيق الحسابات', '3', 'تخصص', 7, 'catalog', 36),
  ('c0344', 'd9', 'ACC13462', 'المحاسبة باللغة الإنجليزية', '3', 'تخصص', 7, 'catalog', 37),
  ('c0345', 'd9', 'FIN23411', 'التحليل الأساسي والفني', '3', 'تخصص', 7, 'catalog', 38),
  ('c0346', 'd9', 'ACC23467', 'محاسبة مالية متقدمة', '3', 'تخصص', 7, 'catalog', 39),
  ('c0347', 'd9', 'FIN23414', 'التمويل الدولي', '3', 'تخصص', 7, 'catalog', 40),
  ('c0348', 'd9', 'BUS03450', 'مناهج البحث العلمي', '3', 'برنامج', 7, 'catalog', 41),
  ('c0349', 'd9', 'FIN23415', 'التمويل باللغة الإنجليزية', '3', 'تخصص', 8, 'catalog', 42),
  ('c0350', 'd9', 'ACC13464', 'حلقة بحث في المحاسبة والتمويل', '3', 'تخصص', 8, 'catalog', 43),
  ('c0351', 'd9', 'FIN23416', 'المحاسبة الدولية', '3', 'تخصص', 8, 'catalog', 44),
  ('c0352', 'd9', 'FIN23411', 'مساق اختياري 2', '3', 'تخصص', 8, 'catalog', 45),
  ('c0353', 'd9', 'FIN33462', 'تطبيقات محاسبية محوسبة', '3', 'تخصص', 8, 'catalog', 46),
  ('c0354', 'd10', 'ELEC0002', 'نظرية الألعاب', '2', 'برنامج', 0, 'catalog', 0),
  ('c0355', 'd10', 'ELEC0003', 'إدارة الفريق', '2', 'برنامج', 0, 'catalog', 1),
  ('c0356', 'd10', 'ELEC0004', 'تصميم واجهات الألعاب', '2', 'برنامج', 0, 'catalog', 2),
  ('c0357', 'd10', 'ELEC0005', 'الكتابة الإبداعية', '2', 'برنامج', 0, 'catalog', 3),
  ('c0358', 'd10', 'ELEC0006', 'التفكير الإبداعي', '2', 'برنامج', 0, 'catalog', 4),
  ('c0359', 'd10', 'ELEC0007', 'ضمان جودة الألعاب', '2', 'برنامج', 0, 'catalog', 5),
  ('c0360', 'd10', 'ELEC0001', 'الدراما الحديثة والنقد الفني', '2', 'برنامج', 0, 'catalog', 6),
  ('c0361', 'd10', 'ACD03159', 'لغة إنجليزية I', '3', 'كلية', 1, 'catalog', 7),
  ('c0362', 'd10', 'ACD03158', 'لغة عربية', '3', 'كلية', 1, 'catalog', 8),
  ('c0363', 'd10', 'COMP03150', 'المهارات الرقمية', '3', 'كلية', 1, 'catalog', 9),
  ('c0364', 'd10', 'MMD42153', 'معالجة الصور الرقمية', '2', 'تخصص', 1, 'catalog', 10),
  ('c0365', 'd10', 'MMD03151', 'مقدمة في الوسائط المتعددة', '3', 'برنامج', 1, 'catalog', 11),
  ('c0366', 'd10', 'MMD02152', 'الرسم الحر', '2', 'تخصص', 1, 'catalog', 12),
  ('c0367', 'd10', 'BUS03451', 'مبادئ الإدارة', '3', 'كلية', 2, 'catalog', 13),
  ('c0368', 'd10', 'ACD03160', 'لغة انجليزية II', '3', 'كلية', 2, 'catalog', 14),
  ('c0369', 'd10', 'MMD02156', 'صناعة الأفلام', '2', 'تخصص', 2, 'catalog', 15),
  ('c0370', 'd10', 'MMD42154', 'الرسم الرقمي', '2', 'تخصص', 2, 'catalog', 16),
  ('c0371', 'd10', 'MMD41161', 'تصميم الشخصيات ثنائية الأبعاد', '1', 'تخصص', 2, 'catalog', 17),
  ('c0372', 'd10', 'MMD43157', 'أساسيات التصميم ثلاثي الأبعاد', '3', 'تخصص', 2, 'catalog', 18),
  ('c0373', 'd10', 'MMD43158', 'معالجة وتحرير الصوت والفيديو الرقمي', '3', 'تخصص', 2, 'catalog', 19),
  ('c0374', 'd10', 'ACD03351', 'قضايا فقهية معاصرة', '3', 'كلية', 3, 'catalog', 20),
  ('c0375', 'd10', 'CMP02265', 'التفكير المنطقي', '2', 'برنامج', 3, 'catalog', 21),
  ('c0376', 'd10', 'MMD43259', 'الهوية البصرية ونظرية الألوان', '3', 'تخصص', 3, 'catalog', 22),
  ('c0377', 'd10', 'MMD43260', 'نمذجة العناصر ثلاثية الأبعاد', '3', 'تخصص', 3, 'catalog', 23),
  ('c0378', 'd10', 'MMD43264', 'التحريك ثنائي الأبعاد البسيط', '3', 'تخصص', 3, 'catalog', 24),
  ('c0379', 'd10', 'ACD03351', 'كتابة السيناريو وإعداد القصص', '2', 'تخصص', 3, 'catalog', 25),
  ('c0380', 'd10', 'MMD43262', 'التحريك ثلاثي الأبعاد', '3', 'تخصص', 4, 'catalog', 26),
  ('c0381', 'd10', 'MMD43263', 'الإضائة والخامات ثلاثية الأبعاد', '3', 'تخصص', 4, 'catalog', 27),
  ('c0382', 'd10', 'CMP03289', 'التكنولوجيا والمجتمع', '3', 'كلية', 4, 'catalog', 28),
  ('c0383', 'd10', 'MMD42269', 'التحريك ثنائي الأبعاد المتقدم', '2', 'تخصص', 4, 'catalog', 29),
  ('c0384', 'd10', 'CMP13266', 'مبادئ البرمجة', '3', 'برنامج', 4, 'catalog', 30),
  ('c0385', 'd10', 'MMD43267', 'محركات الألعاب', '3', 'تخصص', 4, 'catalog', 31),
  ('c0386', 'd10', 'ACD03262', 'الثقافة الإسلامية', '3', 'كلية', 5, 'catalog', 32),
  ('c0387', 'd10', 'MMD43368', 'انتاج الموشن جرافيك', '3', 'تخصص', 5, 'catalog', 33),
  ('c0388', 'd10', 'MMD42375', 'تصميم العمارة', '2', 'تخصص', 5, 'catalog', 34),
  ('c0389', 'd10', 'MMD02370', 'التصوير السينمائي', '2', 'تخصص', 5, 'catalog', 35),
  ('c0390', 'd10', 'MMD43371', 'العظام والأوزان ثلاثية الأبعاد', '3', 'تخصص', 5, 'catalog', 36),
  ('c0391', 'd10', 'MMD43372', 'النحت ثلاثي الأبعاد', '3', 'تخصص', 5, 'catalog', 37),
  ('c0392', 'd10', 'ACD03286', 'الاحصاء والاحتمالات', '3', 'برنامج', 6, 'catalog', 38),
  ('c0393', 'd10', 'ACD03384', 'بحوث العمليات', '3', 'برنامج', 6, 'catalog', 39),
  ('c0394', 'd10', 'ELE00001', 'مساق اختياري 1', '3', 'برنامج', 6, 'catalog', 40),
  ('c0395', 'd10', 'MMD43373', 'انتاج الموشن جرافيك المتقدم', '3', 'تخصص', 6, 'catalog', 41),
  ('c0396', 'd10', 'MMD43374', 'تحريك الشخصيات ثلاثية الأبعاد', '3', 'تخصص', 6, 'catalog', 42),
  ('c0397', 'd10', 'MMD42376', 'الوسائط المتعددة التفاعلية', '2', 'تخصص', 6, 'catalog', 43),
  ('c0398', 'd10', 'ACD03370', 'قضية فلسطين', '3', 'كلية', 7, 'catalog', 44),
  ('c0399', 'd10', 'MMD43477', 'تحريك الشخصيات ثلاثية الأبعاد المتقدمة', '3', 'تخصص', 7, 'catalog', 45),
  ('c0400', 'd10', 'MMD43478', 'المؤثرات البصرية', '3', 'تخصص', 7, 'catalog', 46),
  ('c0401', 'd10', 'MMD01479', 'مقدمة في مشروع التخرج', '1', 'برنامج', 7, 'catalog', 47),
  ('c0402', 'd10', 'CMP02481', 'تطوير المهارات الميدانية', '2', 'برنامج', 7, 'catalog', 48),
  ('c0403', 'd10', 'MMD43482', 'المحاكاة ثلاثية الأبعاد', '3', 'تخصص', 7, 'catalog', 49),
  ('c0404', 'd10', 'MMD03483', 'تدريب ميداني', '3', 'برنامج', 7, 'catalog', 50),
  ('c0405', 'd10', '000000', 'مساق حر', '3', 'تخصص', 8, 'catalog', 51),
  ('c0406', 'd10', 'ELE00002', 'مساق اختياري 2', '3', 'برنامج', 8, 'catalog', 52),
  ('c0407', 'd10', 'MMD43484', 'الخدع السينمائية', '3', 'تخصص', 8, 'catalog', 53),
  ('c0408', 'd10', 'MMD02485', 'ادارة مشاريع الوسائط المتعددة', '2', 'تخصص', 8, 'catalog', 54),
  ('c0409', 'd10', 'MMD03486', 'تقنيات التحريك الرقمي', '2', 'تخصص', 8, 'catalog', 55),
  ('c0410', 'd10', 'CMP01488', 'أخلاقيات المهنة', '1', 'برنامج', 8, 'catalog', 56),
  ('c0411', 'd10', 'MMD03486', 'مشروع التخرج', '3', 'تخصص', 8, 'catalog', 57),
  ('c0412', 'd11', 'ACD03001', 'اللغة الإنجليزية', '3', 'كلية', 1, 'catalog', 0),
  ('c0413', 'd11', 'BUS13000', 'مبادئ الإدارة', '3', 'برنامج', 1, 'catalog', 1),
  ('c0414', 'd11', 'CMP13211', 'الخوارزميات ومبادئ البرمجة', '3', 'تخصص', 1, 'catalog', 2),
  ('c0415', 'd11', 'CMP43100', 'مقدمة في الوسائط المتعددة', '3', 'تخصص', 1, 'catalog', 3),
  ('c0416', 'd11', 'CMP43103', 'تصميم مواقع الويب', '3', 'تخصص', 1, 'catalog', 4),
  ('c0417', 'd11', 'COMP03150', 'المهارات الرقمية', '3', 'كلية', 1, 'catalog', 5),
  ('c0418', 'd11', 'ACD03000', 'اللغة العربية', '3', 'كلية', 2, 'catalog', 6),
  ('c0419', 'd11', 'ACD03004', 'اللغة الإنجليزية الفنية', '3', 'برنامج', 2, 'catalog', 7),
  ('c0420', 'd11', 'CMP13201', 'البرمجة الشيئية', '3', 'تخصص', 2, 'catalog', 8),
  ('c0421', 'd11', 'CMP43101', 'معالجة الصور', '3', 'تخصص', 2, 'catalog', 9),
  ('c0422', 'd11', 'CMP13202', 'برمجة الويب I', '3', 'تخصص', 2, 'catalog', 10),
  ('c0423', 'd11', 'CMP23250', 'مقدمة في قواعد البيانات', '3', 'تخصص', 2, 'catalog', 11),
  ('c0424', 'd11', 'BUS01144', 'ريادة الأعمال I', '1', 'كلية', 2, 'catalog', 12),
  ('c0425', 'd11', 'CMP23200', 'تحليل وتصميم النظم', '3', 'تخصص', 3, 'catalog', 13),
  ('c0426', 'd11', 'CMP43204', 'معالجة الصوت والفيديو', '3', 'تخصص', 3, 'catalog', 14),
  ('c0427', 'd11', 'CMP23202', 'قواعد البيانات للويب', '3', 'تخصص', 3, 'catalog', 15),
  ('c0428', 'd11', 'CMP13203', 'برمجة الويب II', '3', 'تخصص', 3, 'catalog', 16),
  ('c0429', 'd11', 'ACD03120', 'تاريخ القدس', '3', 'كلية', 3, 'catalog', 17),
  ('c0430', 'd11', 'CMP33202', 'مبادئ شبكات الحاسوب', '3', 'تخصص', 3, 'catalog', 18),
  ('c0431', 'd11', 'BUS02245', 'ريادة الأعمال II', '2', 'كلية', 3, 'catalog', 19),
  ('c0432', 'd11', 'ACD03002', 'دراسات في الفكر العربي الإسلامي', '3', 'كلية', 4, 'catalog', 20),
  ('c0433', 'd11', 'CMP03203', 'نظم التشغيل', '3', 'برنامج', 4, 'catalog', 21),
  ('c0434', 'd11', 'CMP03101', 'تكنولوجيا المعلومات', '3', 'تخصص', 4, 'catalog', 22),
  ('c0435', 'd11', 'CMP42202', 'مقدمة في الرسوم المتحركة', '2', 'تخصص', 4, 'catalog', 23),
  ('c0436', 'd11', 'CMP03202', 'أمن البيانات', '3', 'تخصص', 4, 'catalog', 24),
  ('c0437', 'd11', 'CMP52200', 'تدريب ميداني', '3', 'برنامج', 4, 'catalog', 25),
  ('c0438', 'd11', 'CMP53206', 'مشروع التخرج', '3', 'برنامج', 4, 'catalog', 26),
  ('c0439', 'd12', 'ACD03001', 'اللغة الإنجليزية', '3', 'كلية', 1, 'catalog', 0),
  ('c0440', 'd12', 'BUS13000', 'مبادئ الإدارة', '3', 'برنامج', 1, 'catalog', 1),
  ('c0441', 'd12', 'EMK53000', 'مبادئ التسويق', '3', 'تخصص', 1, 'catalog', 2),
  ('c0442', 'd12', 'BUS23101', 'مبادئ الاقتصاد', '3', 'تخصص', 1, 'catalog', 3),
  ('c0443', 'd12', 'CMP43022', 'تطبيقات حاسوبية في الإدارة', '3', 'تخصص', 1, 'catalog', 4),
  ('c0444', 'd12', 'COMP03150', 'المهارات الرقمية', '3', 'كلية', 1, 'catalog', 5),
  ('c0445', 'd12', 'ACD03000', 'اللغة العربية', '3', 'كلية', 2, 'catalog', 6),
  ('c0446', 'd12', 'BUS33001', 'مبادئ المحاسبة', '3', 'برنامج', 2, 'catalog', 7),
  ('c0447', 'd12', 'EMK53006', 'تقنيات التسويق الرقمي', '3', 'تخصص', 2, 'catalog', 8),
  ('c0448', 'd12', 'EMK52004', 'بحوث التسويق', '2', 'تخصص', 2, 'catalog', 9),
  ('c0449', 'd12', 'BUS12000', 'مهارات الطباعة', '2', 'تخصص', 2, 'catalog', 10),
  ('c0450', 'd12', 'EMK53002', 'اللغة الانجليزية للأعمال', '2', 'تخصص', 2, 'catalog', 11),
  ('c0451', 'd12', 'CAMP430', 'تصميم وتطوير مواقع الويب للمسوقين', '3', 'تخصص', 2, 'catalog', 12),
  ('c0452', 'd12', 'ACD03002', 'دراسات في الفكر العربي الإسلامي', '3', 'كلية', 3, 'catalog', 13),
  ('c0453', 'd12', 'BUS01144', 'ريادة الأعمال I', '1', 'كلية', 3, 'catalog', 14),
  ('c0454', 'd12', 'EMK53107', 'التصوير ومعالجة الصور الرقمية', '3', 'تخصص', 3, 'catalog', 15),
  ('c0455', 'd12', 'EMK53100', 'التجارة الالكترونية', '3', 'تخصص', 3, 'catalog', 16),
  ('c0456', 'd12', 'BUS01146', 'أخلاقيات منظمات الأعمال', '1', 'تخصص', 3, 'catalog', 17),
  ('c0457', 'd12', 'EMK51110', 'قضايا تسويقية معاصرة', '1', 'تخصص', 3, 'catalog', 18),
  ('c0458', 'd12', 'EMK53105', 'إدارة العلاقات مع الزبائن', '3', 'تخصص', 3, 'catalog', 19),
  ('c0459', 'd12', 'EMK53103', 'استراتيجيات التسويق الرقمي', '3', 'تخصص', 3, 'catalog', 20),
  ('c0460', 'd12', 'ACD03120', 'تاريخ القدس', '3', 'كلية', 4, 'catalog', 21),
  ('c0461', 'd12', 'BUS02245', 'ريادة الأعمال II', '2', 'كلية', 4, 'catalog', 22),
  ('c0462', 'd12', 'EMK53111', 'تسويق الخدمات', '3', 'تخصص', 4, 'catalog', 23),
  ('c0463', 'd12', 'EMK53108', 'معالجة الصوت والفيديو والمونتاج الرقمي', '3', 'تخصص', 4, 'catalog', 24),
  ('c0464', 'd12', 'EMK53112', 'سلوك المستهلك', '3', 'تخصص', 4, 'catalog', 25),
  ('c0465', 'd12', 'EMK51215', 'بحث التخرج', '1', 'تخصص', 4, 'catalog', 26),
  ('c0466', 'd12', 'EMK50214', 'تدريب ميداني', '0', 'تخصص', 4, 'catalog', 27),
  ('c0467', 'd12', 'EMK53213', 'مهارات العمل الحر', '3', 'تخصص', 4, 'catalog', 28),
  ('c0468', 'd13', 'BUS53351', 'التجارة الإلكترونية', '3', 'برنامج', 0, 'catalog', 0),
  ('c0469', 'd13', 'CMP53016', 'استراتيجيات العمل الحر', '3', 'برنامج', 0, 'catalog', 1),
  ('c0470', 'd13', 'WIS13469', 'تقنيات الويب وتطبيقاتها', '3', 'تخصص', 0, 'catalog', 2),
  ('c0471', 'd13', 'WIS53488', 'الأمن السيبراني والاختراق الأخلاقي', '3', 'تخصص', 0, 'catalog', 3),
  ('c0472', 'd13', 'WIS53489', 'أمن السحابة', '3', 'تخصص', 0, 'catalog', 4),
  ('c0473', 'd13', 'WIS03457', 'نظم إدارة المحتوى', '3', 'تخصص', 0, 'catalog', 5),
  ('c0474', 'd13', 'WIS53490', 'التحقيق الجنائي الرقمي', '3', 'تخصص', 0, 'catalog', 6),
  ('c0475', 'd13', 'WIS33477', 'أنظمة كشف التسلل', '3', 'تخصص', 0, 'catalog', 7),
  ('c0476', 'd13', 'WIS13470', 'مواضيع مختارة في تكنولوجيا الويب', '3', 'تخصص', 0, 'catalog', 8),
  ('c0477', 'd13', 'WIS03458', 'التسويق الرقمي', '3', 'تخصص', 0, 'catalog', 9),
  ('c0478', 'd13', 'WIS13471', 'تطوير التطبيقات السحابية', '3', 'تخصص', 0, 'catalog', 10),
  ('c0479', 'd13', 'WIS13367', 'تطوير تطبيقات الهواتف الذكية المتقدمة', '3', 'تخصص', 0, 'catalog', 11),
  ('c0480', 'd13', 'WIS53385', 'أمن قواعد البيانات', '3', 'تخصص', 0, 'catalog', 12),
  ('c0481', 'd13', 'WIS54487', 'أمن الشبكات اللاسلكية', '3', 'تخصص', 0, 'catalog', 13),
  ('c0482', 'd13', 'WIS13265', 'نماذج تصميم البرمجيات', '3', 'تخصص', 0, 'catalog', 14),
  ('c0483', 'd13', 'EMK53001', 'مهارات الاتصال والتفاوض الرقمي', '3', 'برنامج', 0, 'catalog', 15),
  ('c0484', 'd13', 'WIS43490', 'انترنت الأشياء', '3', 'تخصص', 0, 'catalog', 16),
  ('c0485', 'd13', 'ACD03159', 'لغة إنجليزية I', '3', 'كلية', 1, 'catalog', 17),
  ('c0486', 'd13', 'ACD03158', 'لغة عربية', '3', 'كلية', 1, 'catalog', 18),
  ('c0487', 'd13', 'WIS14160', 'مقدمة في البرمجة', '4', 'تخصص', 1, 'catalog', 19),
  ('c0488', 'd13', 'ACD03175', 'رياضيات عامة', '3', 'برنامج', 1, 'catalog', 20),
  ('c0489', 'd13', 'COMP03150', 'المهارات الرقمية', '3', 'كلية', 1, 'catalog', 21),
  ('c0490', 'd13', 'ACD03157', 'اللغة الإنجليزية II', '3', 'كلية', 2, 'catalog', 22),
  ('c0491', 'd13', 'ACD03282', 'رياضيات منفصلة', '3', 'برنامج', 2, 'catalog', 23),
  ('c0492', 'd13', 'WIS14161', 'البرمجة الشيئية الموجهة', '4', 'تخصص', 2, 'catalog', 24),
  ('c0493', 'd13', 'WIS53180', 'أمن الحاسوب الشخصي', '3', 'تخصص', 2, 'catalog', 25),
  ('c0494', 'd13', 'WIS43178', 'تصميم مواقع ويب', '3', 'كلية', 2, 'catalog', 26),
  ('c0495', 'd13', 'ACD03262', 'الثقافة الإسلامية', '3', 'كلية', 3, 'catalog', 27),
  ('c0496', 'd13', 'ACD03370', 'قضية فلسطين', '3', 'كلية', 3, 'catalog', 28),
  ('c0497', 'd13', 'WIS13262', 'تركيب البيانات وتحليل الخوارزميات', '3', 'تخصص', 3, 'catalog', 29),
  ('c0498', 'd13', 'WIS43179', 'تصميم واجهة المستخدم وتجربة المستخدم', '3', 'تخصص', 3, 'catalog', 30),
  ('c0499', 'd13', 'ACD03281', 'مقدمة في نظرية الأعداد وتطبيقاتها', '3', 'برنامج', 3, 'catalog', 31),
  ('c0500', 'd13', 'WIS23270', 'نظم قواعد البيانات', '3', 'تخصص', 3, 'catalog', 32),
  ('c0501', 'd13', 'BUS13000', 'مبادئ الإدارة', '3', 'كلية', 4, 'catalog', 33),
  ('c0502', 'd13', 'ACD03286', 'الاحصاء والاحتمالات', '3', 'برنامج', 4, 'catalog', 34),
  ('c0503', 'd13', 'WIS23271', 'نظم قواعد بيانات متقدمة', '3', 'تخصص', 4, 'catalog', 35),
  ('c0504', 'd13', 'WIS13263', 'تطوير مواقع الويب', '3', 'تخصص', 4, 'catalog', 36),
  ('c0505', 'd13', 'WIS53251', 'مقدمة في التشفير', '3', 'تخصص', 4, 'catalog', 37),
  ('c0506', 'd13', 'WIS03251', 'نظم التشغيل', '3', 'تخصص', 4, 'catalog', 38),
  ('c0507', 'd13', 'ACD03384', 'بحوث العمليات', '3', 'برنامج', 5, 'catalog', 39),
  ('c0508', 'd13', 'WIS01454', 'أخلاقيات تكنولوجيا المعلومات', '1', 'برنامج', 5, 'catalog', 40),
  ('c0509', 'd13', 'WIS53382', 'أمن المعلومات', '3', 'تخصص', 5, 'catalog', 41),
  ('c0510', 'd13', 'WIS34275', 'شبكات الحاسوب', '4', 'تخصص', 5, 'catalog', 42),
  ('c0511', 'd13', 'WIS13366', 'تطوير تطبيقات الهواتف الذكية', '3', 'تخصص', 5, 'catalog', 43),
  ('c0512', 'd13', 'WIS13264', 'تطوير مواقع الويب المتقدم', '3', 'تخصص', 5, 'catalog', 44),
  ('c0513', 'd13', 'WIS13368', 'هندسة البرمجيات', '3', 'تخصص', 6, 'catalog', 45),
  ('c0514', 'd13', 'WIS02352', 'مناهج البحث العلمي', '2', 'برنامج', 6, 'catalog', 46),
  ('c0515', 'd13', 'WIS53384', 'أمن الويب', '3', 'تخصص', 6, 'catalog', 47),
  ('c0516', 'd13', 'WIS53383', 'أمن الشبكات', '3', 'تخصص', 6, 'catalog', 48),
  ('c0517', 'd13', 'WIS03353', 'التكنولوجيا والمجتمع', '3', 'كلية', 6, 'catalog', 49),
  ('c0518', 'd13', 'ELE00001', 'مساق اختياري 1', '3', 'تخصص', 6, 'catalog', 50),
  ('c0519', 'd13', 'ACD03351', 'قضايا فقهية معاصرة', '3', 'كلية', 7, 'catalog', 51),
  ('c0520', 'd13', 'WIS53288', 'تقييم و ادارة المخاطر', '3', 'تخصص', 7, 'catalog', 52),
  ('c0521', 'd13', 'WIS01455', 'مقدمة في مشروع التخرج', '1', 'تخصص', 7, 'catalog', 53),
  ('c0522', 'd13', 'WIS03452', 'تدريب ميداني', '3', 'برنامج', 7, 'catalog', 54),
  ('c0523', 'd13', 'WIS53386', 'أمن نظم التشغيل', '3', 'تخصص', 7, 'catalog', 55),
  ('c0524', 'd13', 'ELE00002', 'مساق اختياري 2', '3', 'تخصص', 7, 'catalog', 56),
  ('c0525', 'd13', 'WIS01456', 'مشروع التخرج', '3', 'تخصص', 8, 'catalog', 57),
  ('c0526', 'd13', 'WIS33476', 'ادارة خوادم الويب', '3', 'تخصص', 8, 'catalog', 58),
  ('c0527', 'd13', '000000', 'مساق حر', '3', 'تخصص', 8, 'catalog', 59),
  ('c0528', 'd13', 'ELE00003', 'مساق اختياري 3', '3', 'تخصص', 8, 'catalog', 60),
  ('c0529', 'd14', 'ACD03001', 'اللغة الإنجليزية', '3', 'كلية', 1, 'catalog', 0),
  ('c0530', 'd14', 'ACD03002', 'دراسات في الفكر العربي الإسلامي', '3', 'كلية', 1, 'catalog', 1),
  ('c0531', 'd14', 'MED02104', 'الرسم الحر', '2', 'برنامج', 1, 'catalog', 2),
  ('c0532', 'd14', 'CMP42104', 'معالجة الصور الرقمية', '2', 'تخصص', 1, 'catalog', 3),
  ('c0533', 'd14', 'CMP03103', 'تكنولوجيا المعلومات والوسائط المتعددة', '3', 'تخصص', 1, 'catalog', 4),
  ('c0534', 'd14', 'CMP42108', 'تطوير العناصر ثلاثية الأبعاد البسيطة', '2', 'تخصص', 1, 'catalog', 5),
  ('c0535', 'd14', 'COMP03150', 'المهارات الرقمية', '3', 'كلية', 1, 'catalog', 6),
  ('c0536', 'd14', 'ACD03003', 'اللغة الإنجليزية الفنية', '3', 'برنامج', 2, 'catalog', 7),
  ('c0537', 'd14', 'CMP13211', 'الخوارزميات ومبادئ البرمجة', '3', 'برنامج', 2, 'catalog', 8),
  ('c0538', 'd14', 'CMP42105', 'معالجة الصوت و الفيديو', '2', 'تخصص', 2, 'catalog', 9),
  ('c0539', 'd14', 'MED02105', 'التصوير وصناعة الأفلام', '2', 'تخصص', 2, 'catalog', 10),
  ('c0540', 'd14', 'CMP43107', 'تحريك العناصر ثنائية الأبعاد', '3', 'تخصص', 2, 'catalog', 11),
  ('c0541', 'd14', 'CMP43208', 'تصميم المطبوعات الدعائية', '3', 'تخصص', 2, 'catalog', 12),
  ('c0542', 'd14', 'BUS01144', 'ريادة الأعمال I', '1', 'كلية', 2, 'catalog', 13),
  ('c0543', 'd14', 'ACD03000', 'اللغة العربية', '3', 'كلية', 3, 'catalog', 14),
  ('c0544', 'd14', 'CMP43207', 'تصميم وبرمجة الالعاب', '3', 'تخصص', 3, 'catalog', 15),
  ('c0545', 'd14', 'CMP03204', 'تصميم المواقع ورسومات الويب', '3', 'تخصص', 3, 'catalog', 16),
  ('c0546', 'd14', 'ACD02216', 'مهارات الإتصال', '2', 'برنامج', 3, 'catalog', 17),
  ('c0547', 'd14', 'CMP43209', 'تحريك العناصر ثلاثية الابعاد', '3', 'تخصص', 3, 'catalog', 18),
  ('c0548', 'd14', 'BUS02245', 'ريادة الأعمال II', '2', 'كلية', 3, 'catalog', 19),
  ('c0549', 'd14', 'CMP52200', 'تدريب ميداني', '3', 'تخصص', 4, 'catalog', 20),
  ('c0550', 'd14', 'ACD03120', 'تاريخ القدس', '3', 'كلية', 4, 'catalog', 21),
  ('c0551', 'd14', 'CMP43207', 'انتاج الخدع السينمائية والمؤثرات البصرية', '3', 'تخصص', 4, 'catalog', 22),
  ('c0552', 'd14', 'CMP43200', 'استراتيجيات التسويق عبر مواقع التواصل الاجتماعي', '3', 'برنامج', 4, 'catalog', 23),
  ('c0553', 'd14', 'CMP43210', 'تطوير تطبيقات الهواتف الذكية', '3', 'تخصص', 4, 'catalog', 24),
  ('c0554', 'd14', 'CMP53207', 'مشروع تخرج', '3', 'تخصص', 4, 'catalog', 25),
  ('c0555', 'd14', 'CMP42203', 'مواضيع مختارة', '2', 'تخصص', 4, 'catalog', 26),
  ('c0556', 'd15', 'REM00000', 'أساسيات علوم الصحة *', '3', 'برنامج', 0, 'catalog', 0),
  ('c0557', 'd15', 'REM00001', 'أساسيات علوم البيئة*', '2', 'برنامج', 0, 'catalog', 1),
  ('c0558', 'd15', 'NPH43464', 'مكافحة الآفات الصحية', '3', 'تخصص', 0, 'catalog', 2),
  ('c0559', 'd15', 'REM00002', 'أساسيات العلوم العامة*', '2', 'برنامج', 0, 'catalog', 3),
  ('c0560', 'd15', 'REM00003', 'أساسيات علم الاغذية*', '2', 'برنامج', 0, 'catalog', 4),
  ('c0561', 'd15', 'ELN42363', 'أساسيات علم الأدوية والسموم', '2', 'تخصص', 0, 'catalog', 5),
  ('c0562', 'd15', 'ELN32356', 'سوء التغذية وأمراضه', '2', 'تخصص', 0, 'catalog', 6),
  ('c0563', 'd15', 'ELN32461', 'التربية التغذوية', '2', 'تخصص', 0, 'catalog', 7),
  ('c0564', 'd15', 'ELN42358', 'اسعافات اولية', '2', 'تخصص', 0, 'catalog', 8),
  ('c0565', 'd15', 'REM00004', 'مخلفات صلبة*', '2', 'برنامج', 0, 'catalog', 9),
  ('c0566', 'd15', 'REM00005', 'صحة المياه*', '2', 'برنامج', 0, 'catalog', 10),
  ('c0567', 'd15', 'NUT22487', 'التغذية الجينية', '2', 'تخصص', 0, 'catalog', 11),
  ('c0568', 'd15', 'NUT22493', 'الأمن الغذائي', '2', 'برنامج', 0, 'catalog', 12),
  ('c0569', 'd15', 'NUT22495', 'الأعشاب الطبية والطب البديل', '2', 'تخصص', 0, 'catalog', 13),
  ('c0570', 'd15', 'ACD03159', 'لغة إنجليزية I', '3', 'كلية', 1, 'catalog', 14),
  ('c0571', 'd15', 'BUS03451', 'مبادئ الإدارة', '3', 'كلية', 1, 'catalog', 15),
  ('c0572', 'd15', 'NPH23150', 'كيمياء عامة', '3', 'برنامج', 1, 'catalog', 16),
  ('c0573', 'd15', 'NPH33251', 'أساسيات علم التغذية', '3', 'تخصص', 1, 'catalog', 17),
  ('c0574', 'd15', 'COMP03150', 'المهارات الرقمية', '3', 'كلية', 1, 'catalog', 18),
  ('c0575', 'd15', 'NBHG11151', 'مصطلحات طبية', '1', 'برنامج', 1, 'catalog', 19),
  ('c0576', 'd15', 'ACD03160', 'لغة انجليزية II', '3', 'كلية', 2, 'catalog', 20),
  ('c0577', 'd15', 'NPH43151', 'أساسيات الإدارة الصحية', '2', 'تخصص', 2, 'catalog', 21),
  ('c0578', 'd15', 'NPH23154', 'كيمياء عضوية', '3', 'برنامج', 2, 'catalog', 22),
  ('c0579', 'd15', 'NPH43253', 'أساسيات الصحة العامة', '3', 'برنامج', 2, 'catalog', 23),
  ('c0580', 'd15', 'NPH23255', 'أساسيات الكيمياء الحيوية', '3', 'برنامج', 2, 'catalog', 24),
  ('c0581', 'd15', 'PHS33156', 'علم التشريح ووظائف الأعضاء', '3', 'برنامج', 2, 'catalog', 25),
  ('c0582', 'd15', 'ACD03158', 'لغة عربية', '3', 'كلية', 3, 'catalog', 26),
  ('c0583', 'd15', 'NPH43254', 'علم الأمراض', '3', 'تخصص', 3, 'catalog', 27),
  ('c0584', 'd15', 'NPH33250', 'أساسيات الكيمياء التحليلية', '3', 'تخصص', 3, 'catalog', 28),
  ('c0585', 'd15', 'NPH33352', 'كيمياء حيوية تغذوية', '3', 'تخصص', 3, 'catalog', 29),
  ('c0586', 'd15', 'NUT23261', 'التغذية عبر مراحل العمر (1)', '3', 'تخصص', 3, 'catalog', 30),
  ('c0587', 'd15', 'NUT22263', 'التقييم التغذوي', '2', 'تخصص', 3, 'catalog', 31),
  ('c0588', 'd15', 'EEE03352', 'التكنولوجيا والمجتمع', '3', 'كلية', 4, 'catalog', 32),
  ('c0589', 'd15', 'NPH43255', 'صحة الأم والطفل', '3', 'تخصص', 4, 'catalog', 33),
  ('c0590', 'd15', 'NPH43357', 'علم الأمراض المعدية والأوبئة', '3', 'تخصص', 4, 'catalog', 34),
  ('c0591', 'd15', 'NUT23267', 'التغذية عبر مراحل العمر (2)', '3', 'تخصص', 4, 'catalog', 35),
  ('c0592', 'd15', 'PHS33264', 'صحة بيئية', '3', 'تخصص', 4, 'catalog', 36),
  ('c0593', 'd15', 'ACD03262', 'الثقافة الإسلامية', '3', 'كلية', 5, 'catalog', 37),
  ('c0594', 'd15', 'ACD03370', 'قضية فلسطين', '3', 'كلية', 5, 'catalog', 38),
  ('c0595', 'd15', 'NPH33354', 'كيمياء وتحليل الأغذية', '3', 'تخصص', 5, 'catalog', 39),
  ('c0596', 'd15', 'ELN00001', 'مساق اختياري 1', '2', 'تخصص', 5, 'catalog', 40),
  ('c0597', 'd15', 'NUT23370', 'تخطيط الوجبات الغذائية', '3', 'تخصص', 5, 'catalog', 41),
  ('c0598', 'd15', 'NUT23368', 'تغذية علاجية (1)', '3', 'تخصص', 5, 'catalog', 42),
  ('c0599', 'd15', 'NPH23256', 'مناهج البحث العلمي', '3', 'برنامج', 6, 'catalog', 43),
  ('c0600', 'd15', 'NPH23357', 'الإحصاء الحيوي', '3', 'برنامج', 6, 'catalog', 44),
  ('c0601', 'd15', 'NPH33357', 'مراقبة جودة الأغذية', '3', 'تخصص', 6, 'catalog', 45),
  ('c0602', 'd15', 'NUT24373', 'ميكروبولوجيا الأغذية', '4', 'تخصص', 6, 'catalog', 46),
  ('c0603', 'd15', 'NUT23374', 'تغذية علاجية (2)', '3', 'تخصص', 6, 'catalog', 47),
  ('c0604', 'd15', 'PHS23375', 'صحة المجتمع', '3', 'تخصص', 6, 'catalog', 48),
  ('c0605', 'd15', 'ACD03351', 'قضايا فقهية معاصرة', '3', 'كلية', 7, 'catalog', 49),
  ('c0606', 'd15', 'NPH43361', 'أساسيات علم المناعة', '2', 'تخصص', 7, 'catalog', 50),
  ('c0607', 'd15', 'NPH42463', 'تدريب ميداني I', '2', 'تخصص', 7, 'catalog', 51),
  ('c0608', 'd15', 'NPH33460', 'تكنولوجيا التصنيع الغذائي', '3', 'تخصص', 7, 'catalog', 52),
  ('c0609', 'd15', 'ELN32462', 'التغذية الرياضية', '2', 'تخصص', 7, 'catalog', 53),
  ('c0610', 'd15', 'ELN00002', 'مساق اختياري 2', '2', 'تخصص', 7, 'catalog', 54),
  ('c0611', 'd15', 'NPH11484', 'مقدمة في مشروع التخرج', '1', 'تخصص', 7, 'catalog', 55),
  ('c0612', 'd15', 'NUT23481', 'حفظ ومعالجة الأغذية', '3', 'تخصص', 7, 'catalog', 56),
  ('c0613', 'd15', 'NPH33464', 'تفتيش غذائي وحجر صحي', '3', 'تخصص', 8, 'catalog', 57),
  ('c0614', 'd15', 'NPH32467', 'تدريب ميداني II', '2', 'تخصص', 8, 'catalog', 58),
  ('c0615', 'd15', 'NPH23458', 'مشروع التخرج', '3', 'برنامج', 8, 'catalog', 59),
  ('c0616', 'd15', 'ELN00003', 'مساق اختياري 3', '2', 'تخصص', 8, 'catalog', 60),
  ('c0617', 'd15', 'PHS31483', 'أخلاقيات المهنة والصحة المهنية', '1', 'برنامج', 8, 'catalog', 61),
  ('c0618', 'd15', 'PHS32489', 'الصحة النفسية المجتمعية', '2', 'تخصص', 8, 'catalog', 62),
  ('c0619', 'd15', 'NUT22491', 'الأغذية الوظيفية', '2', 'تخصص', 8, 'catalog', 63),
  ('c0620', 'd16', 'EEE23596', 'معالجة الصور ورئية الحاسوب', '3', 'تخصص', 0, 'catalog', 0),
  ('c0621', 'd16', 'EEE43594', 'موضوعات مختارة في هندسة نظم الحاسوب', '3', 'تخصص', 0, 'catalog', 1),
  ('c0622', 'd16', 'EEE43579', 'تقنيات الأنظمة الموزعة', '3', 'تخصص', 0, 'catalog', 2),
  ('c0623', 'd16', 'EEE63588', 'الشبكات العصبية', '3', 'تخصص', 0, 'catalog', 3),
  ('c0624', 'd16', 'EEE43583', 'موضوع متقدم في لغات البرمجة ومترجماتها', '3', 'تخصص', 0, 'catalog', 4),
  ('c0625', 'd16', 'EEE43582', 'خوارزميات وتراكيب بيانات متقدمة', '3', 'تخصص', 0, 'catalog', 5),
  ('c0626', 'd16', 'EEE63576', 'مقدمة في علم الروبوت', '3', 'تخصص', 0, 'catalog', 6),
  ('c0627', 'd16', 'EEP13151', 'مقدمة في الدوائر الكهربائية*', '3', 'برنامج', 0, 'catalog', 7),
  ('c0628', 'd16', 'EEP13152', 'مقدمة في الإلكترونيات*', '3', 'برنامج', 0, 'catalog', 8),
  ('c0629', 'd16', 'EEP13150', 'مقدمة في القياسات الكهربائية*', '3', 'برنامج', 0, 'catalog', 9),
  ('c0630', 'd16', 'WIS13264', 'تطوير مواقع الويب المتقدم', '3', 'تخصص', 0, 'catalog', 10),
  ('c0631', 'd16', 'EEE43471', 'تطوير مواقع الإنترنت المتقدمة', '3', 'تخصص', 0, 'catalog', 11),
  ('c0632', 'd16', 'EEE43473', 'تطبيقات الهواتف الذكية المتقدمة', '3', 'تخصص', 0, 'catalog', 12),
  ('c0633', 'd16', 'EEE63586', 'أنظمة التحكم الرقمية', '3', 'تخصص', 0, 'catalog', 13),
  ('c0634', 'd16', 'EEE43574', 'تقنيات الربط المتقدمة', '3', 'تخصص', 0, 'catalog', 14),
  ('c0635', 'd16', 'EEE63589', 'الأتمتة الصناعية', '3', 'تخصص', 0, 'catalog', 15),
  ('c0636', 'd16', 'EEE43599', 'تعلم الآلة', '3', 'تخصص', 0, 'catalog', 16),
  ('c0637', 'd16', 'EEE63587', 'الأنظمة المنطقية المحيرة', '3', 'تخصص', 0, 'catalog', 17),
  ('c0638', 'd16', 'EEE43591', 'الرسم الحاسوبي', '3', 'تخصص', 0, 'catalog', 18),
  ('c0639', 'd16', 'EEE23580', 'تمييز النماذج', '3', 'تخصص', 0, 'catalog', 19),
  ('c0640', 'd16', 'EEE33597', 'نظرية المعلومات والترميز', '3', 'تخصص', 0, 'catalog', 20),
  ('c0641', 'd16', 'EEE43577', 'التشفير وأمن أنظمة الحاسوب', '3', 'تخصص', 0, 'catalog', 21),
  ('c0642', 'd16', 'EEE43593', 'شبكات الحاسوب المتقدمة', '3', 'تخصص', 0, 'catalog', 22),
  ('c0643', 'd16', 'EEE43586', 'الحوسبة السحابية', '3', 'تخصص', 0, 'catalog', 23),
  ('c0644', 'd16', 'EEE43573', 'تصميم المترجمات', '3', 'تخصص', 0, 'catalog', 24),
  ('c0645', 'd16', 'EEE43590', 'نظم التشغيل المتقدمة', '3', 'تخصص', 0, 'catalog', 25),
  ('c0646', 'd16', 'EEE03150', 'مقدمة في الحاسوب', '3', 'كلية', 1, 'catalog', 26),
  ('c0647', 'd16', 'ACD03150', 'تفاضل وتكامل I', '3', 'برنامج', 1, 'catalog', 27),
  ('c0648', 'd16', 'ACD03159', 'لغة إنجليزية I', '3', 'كلية', 1, 'catalog', 28),
  ('c0649', 'd16', 'ACD04159', 'فيزياء عامة', '4', 'برنامج', 1, 'catalog', 29),
  ('c0650', 'd16', 'MEE02150', 'الرسم الهندسي', '2', 'برنامج', 1, 'catalog', 30),
  ('c0651', 'd16', 'MEE02151', 'المشغل الهندسي والامن الصناعي', '2', 'برنامج', 1, 'catalog', 31),
  ('c0652', 'd16', 'ACD03158', 'لغة عربية', '3', 'كلية', 2, 'catalog', 32),
  ('c0653', 'd16', 'EEE01151', 'مقدمة في الهندسة', '1', 'برنامج', 2, 'catalog', 33),
  ('c0654', 'd16', 'EEE44150', 'برمجة الحاسوب', '4', 'تخصص', 2, 'catalog', 34),
  ('c0655', 'd16', 'ACD03151', 'تفاضل وتكامل II', '3', 'برنامج', 2, 'catalog', 35),
  ('c0656', 'd16', 'ACD03157', 'اللغة الإنجليزية II', '3', 'كلية', 2, 'catalog', 36),
  ('c0657', 'd16', 'EEE13250', 'دوائر كهربائية I', '3', 'تخصص', 2, 'catalog', 37),
  ('c0658', 'd16', 'ACD03262', 'الثقافة الإسلامية', '3', 'كلية', 3, 'catalog', 38),
  ('c0659', 'd16', 'EEE13251', 'إلكترونيات I', '3', 'تخصص', 3, 'catalog', 39),
  ('c0660', 'd16', 'ACD03264', 'الجبر الخطي', '3', 'برنامج', 3, 'catalog', 40),
  ('c0661', 'd16', 'EEE43253', 'لغات برمجة', '3', 'تخصص', 3, 'catalog', 41),
  ('c0662', 'd16', 'EEE13252', 'دوائر كهربائية II', '3', 'تخصص', 3, 'catalog', 42),
  ('c0663', 'd16', 'EEE11253', 'مختبر دوائر كهربائية', '1', 'تخصص', 3, 'catalog', 43),
  ('c0664', 'd16', 'EEE13254', 'إلكترونيات II', '3', 'تخصص', 4, 'catalog', 44),
  ('c0665', 'd16', 'EEE11255', 'مختبر إلكترونيات', '1', 'تخصص', 4, 'catalog', 45),
  ('c0666', 'd16', 'ACD03265', 'معادلات تفاضلية', '3', 'برنامج', 4, 'catalog', 46),
  ('c0667', 'd16', 'EEE43354', 'البرمجة الشيئية الموجهة', '3', 'تخصص', 4, 'catalog', 47),
  ('c0668', 'd16', 'BUS03451', 'مبادئ الإدارة', '3', 'تخصص', 4, 'catalog', 48),
  ('c0669', 'd16', 'EEE11151', 'التصميم الإلكتروني بمساعدة الحاسوب', '1', 'تخصص', 4, 'catalog', 49),
  ('c0670', 'd16', 'EEE43360', 'نظم قواعد البيانات', '3', 'تخصص', 4, 'catalog', 50),
  ('c0671', 'd16', 'EEE33350', 'الأشارات وتواصل البيانات', '3', 'تخصص', 5, 'catalog', 51),
  ('c0672', 'd16', 'ACD03370', 'قضية فلسطين', '3', 'كلية', 5, 'catalog', 52),
  ('c0673', 'd16', 'EEE43254', 'الخوارزميات وتركيب البيانات', '3', 'تخصص', 5, 'catalog', 53),
  ('c0674', 'd16', 'EEE14356', 'أساسيات المنطق الرقمي', '4', 'تخصص', 5, 'catalog', 54),
  ('c0675', 'd16', 'EEE43595', 'برمجة الإنترنت وتطبيقاته I', '3', 'تخصص', 5, 'catalog', 55),
  ('c0676', 'd16', 'EEE43461', 'نظم قواعد البيانات المتقدمة', '3', 'تخصص', 5, 'catalog', 56),
  ('c0677', 'd16', 'ACD03266', 'نظرية الاحتمالات والإحصاء', '3', 'برنامج', 6, 'catalog', 57),
  ('c0678', 'd16', 'EEE43355', 'هندسة البرمجيات', '3', 'تخصص', 6, 'catalog', 58),
  ('c0679', 'd16', 'EEE43356', 'نظم التشغيل', '3', 'تخصص', 6, 'catalog', 59),
  ('c0680', 'd16', 'EEE14357', 'تصميم الأنظمة الرقمية', '4', 'تخصص', 6, 'catalog', 60),
  ('c0681', 'd16', 'EEE43358', 'معمارية الحاسوب', '3', 'تخصص', 6, 'catalog', 61),
  ('c0682', 'd16', 'EEE43596', 'برمجة الإنترنت وتطبيقاته II', '3', 'تخصص', 6, 'catalog', 62),
  ('c0683', 'd16', 'ACD03267', 'التحليل العددي', '3', 'برنامج', 7, 'catalog', 63),
  ('c0684', 'd16', 'EEE43465', 'تقنيات الربط بالحاسوب', '3', 'تخصص', 7, 'catalog', 64),
  ('c0685', 'd16', 'EEE03352', 'التكنولوجيا والمجتمع', '3', 'كلية', 7, 'catalog', 65),
  ('c0686', 'd16', 'EEE43584', 'تطبيقات الهواتف الذكية', '3', 'تخصص', 7, 'catalog', 66),
  ('c0687', 'd16', 'EEE43469', 'شبكات الحاسوب', '3', 'تخصص', 7, 'catalog', 67),
  ('c0688', 'd16', 'EEE00001', 'مساق اختياري 1', '3', 'تخصص', 7, 'catalog', 68),
  ('c0689', 'd16', 'EEE33498', 'أنظمة الاتصالات', '3', 'تخصص', 8, 'catalog', 69),
  ('c0690', 'd16', 'ACD03351', 'قضايا فقهية معاصرة', '3', 'كلية', 8, 'catalog', 70),
  ('c0691', 'd16', 'EEE43491', 'الذكاء الإصطناعي', '3', 'تخصص', 8, 'catalog', 71),
  ('c0692', 'd16', 'EEE43576', 'أمن المعلومات والشبكات', '3', 'تخصص', 8, 'catalog', 72),
  ('c0693', 'd16', 'EEE43468', 'إدارة الشبكات', '3', 'تخصص', 8, 'catalog', 73),
  ('c0694', 'd16', 'EEE00002', 'مساق اختياري 2', '3', 'تخصص', 8, 'catalog', 74),
  ('c0695', 'd16', 'EEE01554', 'مقدمة في مشروع التخرج', '1', 'برنامج', 9, 'catalog', 75),
  ('c0696', 'd16', 'EEE23595', 'معالجة الإشارات الرقمية', '3', 'تخصص', 9, 'catalog', 76),
  ('c0697', 'd16', 'EEE03200', 'أساليب البحث العلمي', '3', 'برنامج', 9, 'catalog', 77),
  ('c0698', 'd16', 'EEE43490', 'إنترنت الأشياء', '3', 'تخصص', 9, 'catalog', 78),
  ('c0699', 'd16', 'EEE63584', 'الأنظمة المتكاملة ومعالجة الزمن الحقيقي', '3', 'تخصص', 9, 'catalog', 79),
  ('c0700', 'd16', 'EEE00003', 'مساق اختياري 3', '3', 'تخصص', 9, 'catalog', 80),
  ('c0701', 'd16', 'EEE03555', 'مشروع التخرج', '3', 'برنامج', 10, 'catalog', 81),
  ('c0702', 'd16', 'EEE02580', 'ريادة الأعمال العمل الحر عبر الإنترنت', '3', 'برنامج', 10, 'catalog', 82),
  ('c0703', 'd16', 'EEE00004', 'مساق اختياري 4', '3', 'تخصص', 10, 'catalog', 83),
  ('c0704', 'd16', 'EEE00005', 'مساق اختياري 5', '3', 'تخصص', 10, 'catalog', 84),
  ('c0705', 'd17', 'EEE23596', 'معالجة الصور ورئية الحاسوب', '3', 'تخصص', 0, 'catalog', 0),
  ('c0706', 'd17', 'EEE43594', 'موضوعات مختارة في هندسة نظم الحاسوب', '3', 'تخصص', 0, 'catalog', 1),
  ('c0707', 'd17', 'EEE43579', 'تقنيات الأنظمة الموزعة', '3', 'تخصص', 0, 'catalog', 2),
  ('c0708', 'd17', 'EEE63588', 'الشبكات العصبية', '3', 'تخصص', 0, 'catalog', 3),
  ('c0709', 'd17', 'EEE43583', 'موضوع متقدم في لغات البرمجة ومترجماتها', '3', 'تخصص', 0, 'catalog', 4),
  ('c0710', 'd17', 'EEE43582', 'خوارزميات وتراكيب بيانات متقدمة', '3', 'تخصص', 0, 'catalog', 5),
  ('c0711', 'd17', 'EEE63576', 'مقدمة في علم الروبوت', '3', 'تخصص', 0, 'catalog', 6),
  ('c0712', 'd17', 'EEP13151', 'مقدمة في الدوائر الكهربائية*', '3', 'برنامج', 0, 'catalog', 7),
  ('c0713', 'd17', 'EEP13152', 'مقدمة في الإلكترونيات*', '3', 'برنامج', 0, 'catalog', 8),
  ('c0714', 'd17', 'EEP13150', 'مقدمة في القياسات الكهربائية*', '3', 'برنامج', 0, 'catalog', 9),
  ('c0715', 'd17', 'EEE43471', 'تطوير مواقع الإنترنت المتقدمة', '3', 'تخصص', 0, 'catalog', 10),
  ('c0716', 'd17', 'EEE43473', 'تطبيقات الهواتف الذكية المتقدمة', '3', 'تخصص', 0, 'catalog', 11),
  ('c0717', 'd17', 'EEE63586', 'أنظمة التحكم الرقمية', '3', 'تخصص', 0, 'catalog', 12),
  ('c0718', 'd17', 'EEE43574', 'تقنيات الربط المتقدمة', '3', 'تخصص', 0, 'catalog', 13),
  ('c0719', 'd17', 'EEE63589', 'الأتمتة الصناعية', '3', 'تخصص', 0, 'catalog', 14),
  ('c0720', 'd17', 'EEE43599', 'تعلم الآلة', '3', 'تخصص', 0, 'catalog', 15),
  ('c0721', 'd17', 'EEE63587', 'الأنظمة المنطقية المحيرة', '3', 'تخصص', 0, 'catalog', 16),
  ('c0722', 'd17', 'EEE43591', 'الرسم الحاسوبي', '3', 'تخصص', 0, 'catalog', 17),
  ('c0723', 'd17', 'EEE23580', 'تمييز النماذج', '3', 'تخصص', 0, 'catalog', 18),
  ('c0724', 'd17', 'EEE33597', 'نظرية المعلومات والترميز', '3', 'تخصص', 0, 'catalog', 19),
  ('c0725', 'd17', 'EEE43577', 'التشفير وأمن أنظمة الحاسوب', '3', 'تخصص', 0, 'catalog', 20),
  ('c0726', 'd17', 'EEE43593', 'شبكات الحاسوب المتقدمة', '3', 'تخصص', 0, 'catalog', 21),
  ('c0727', 'd17', 'EEE43586', 'الحوسبة السحابية', '3', 'تخصص', 0, 'catalog', 22),
  ('c0728', 'd17', 'EEE43573', 'تصميم المترجمات', '3', 'تخصص', 0, 'catalog', 23),
  ('c0729', 'd17', 'EEE43590', 'نظم التشغيل المتقدمة', '3', 'تخصص', 0, 'catalog', 24),
  ('c0730', 'd17', 'ACD03150', 'تفاضل وتكامل I', '3', 'برنامج', 1, 'catalog', 25),
  ('c0731', 'd17', 'ACD03159', 'لغة إنجليزية I', '3', 'كلية', 1, 'catalog', 26),
  ('c0732', 'd17', 'ACD03158', 'لغة عربية', '3', 'كلية', 1, 'catalog', 27),
  ('c0733', 'd17', 'EEE01151', 'مقدمة في الهندسة', '1', 'برنامج', 1, 'catalog', 28),
  ('c0734', 'd17', 'ACD04159', 'فيزياء عامة', '4', 'برنامج', 1, 'catalog', 29),
  ('c0735', 'd17', 'COMP03150', 'المهارات الرقمية', '3', 'كلية', 1, 'catalog', 30),
  ('c0736', 'd17', 'MEE01151', 'المشغل الهندسي', '1', 'برنامج', 1, 'catalog', 31),
  ('c0737', 'd17', 'EEE44150', 'برمجة الحاسوب', '4', 'تخصص', 2, 'catalog', 32),
  ('c0738', 'd17', 'ACD03151', 'تفاضل وتكامل II', '3', 'برنامج', 2, 'catalog', 33),
  ('c0739', 'd17', 'ACD03157', 'اللغة الإنجليزية II', '3', 'كلية', 2, 'catalog', 34),
  ('c0740', 'd17', 'ACD03262', 'الثقافة الإسلامية', '3', 'كلية', 2, 'catalog', 35),
  ('c0741', 'd17', 'EEE13259', 'إلكترونيات', '3', 'تخصص', 2, 'catalog', 36),
  ('c0742', 'd17', 'EEE13258', 'دوائر كهربائية', '3', 'تخصص', 2, 'catalog', 37),
  ('c0743', 'd17', 'EEE11253', 'مختبر دوائر كهربائية', '1', 'تخصص', 3, 'catalog', 38),
  ('c0744', 'd17', 'EEE11255', 'مختبر إلكترونيات', '1', 'تخصص', 3, 'catalog', 39),
  ('c0745', 'd17', 'EEE43354', 'البرمجة الشيئية الموجهة', '3', 'تخصص', 3, 'catalog', 40),
  ('c0746', 'd17', 'BUS03451', 'مبادئ الإدارة', '3', 'كلية', 3, 'catalog', 41),
  ('c0747', 'd17', 'EEE03352', 'التكنولوجيا والمجتمع', '3', 'كلية', 3, 'catalog', 42),
  ('c0748', 'd17', 'EEE14356', 'أساسيات المنطق الرقمي', '4', 'تخصص', 3, 'catalog', 43),
  ('c0749', 'd17', 'EEE11151', 'التصميم الإلكتروني بمساعدة الحاسوب', '1', 'تخصص', 3, 'catalog', 44),
  ('c0750', 'd17', 'ACD04264', 'المعادلات التفاضلية والجبر الخطي', '3', 'برنامج', 3, 'catalog', 45),
  ('c0751', 'd17', 'ACD03266', 'نظرية الاحتمالات والإحصاء', '3', 'برنامج', 4, 'catalog', 46),
  ('c0752', 'd17', 'ACD03267', 'التحليل العددي', '3', 'برنامج', 4, 'catalog', 47),
  ('c0753', 'd17', 'ACD03370', 'قضية فلسطين', '3', 'كلية', 4, 'catalog', 48),
  ('c0754', 'd17', 'EEE43254', 'الخوارزميات وتركيب البيانات', '3', 'تخصص', 4, 'catalog', 49),
  ('c0755', 'd17', 'EEE43247', 'لغات برمجة حديثة', '3', 'تخصص', 4, 'catalog', 50),
  ('c0756', 'd17', 'EEE33359', 'الأنظمة والاشارات', '3', 'تخصص', 4, 'catalog', 51),
  ('c0757', 'd17', 'EEE43355', 'هندسة البرمجيات', '3', 'تخصص', 5, 'catalog', 52),
  ('c0758', 'd17', 'EEE43465', 'تقنيات الربط بالحاسوب', '3', 'تخصص', 5, 'catalog', 53),
  ('c0759', 'd17', 'EEE33498', 'أنظمة الاتصالات', '3', 'تخصص', 5, 'catalog', 54),
  ('c0760', 'd17', 'EEE43358', 'معمارية الحاسوب', '3', 'تخصص', 5, 'catalog', 55),
  ('c0761', 'd17', 'EEE43360', 'نظم قواعد البيانات', '3', 'تخصص', 5, 'catalog', 56),
  ('c0762', 'd17', 'EEE43597', 'تطوير تطبيقات الويب', '3', 'تخصص', 5, 'catalog', 57),
  ('c0763', 'd17', 'EEE43356', 'نظم التشغيل', '3', 'تخصص', 6, 'catalog', 58),
  ('c0764', 'd17', 'EEE43584', 'تطبيقات الهواتف الذكية', '3', 'تخصص', 6, 'catalog', 59),
  ('c0765', 'd17', 'EEE03200', 'أساليب البحث العلمي', '3', 'برنامج', 6, 'catalog', 60),
  ('c0766', 'd17', 'EEE43461', 'نظم قواعد البيانات المتقدمة', '3', 'تخصص', 6, 'catalog', 61),
  ('c0767', 'd17', 'EEE00001', 'مساق اختياري 1', '3', 'تخصص', 6, 'catalog', 62),
  ('c0768', 'd17', 'EEE43566', 'تطوير تطبيقات الويب المتقدمة', '3', 'تخصص', 6, 'catalog', 63),
  ('c0769', 'd17', 'EEE01554', 'مقدمة في مشروع التخرج', '1', 'تخصص', 7, 'catalog', 64),
  ('c0770', 'd17', 'EEE63209', 'أنظمة مضمنة', '3', 'تخصص', 7, 'catalog', 65),
  ('c0771', 'd17', 'EEE43469', 'شبكات الحاسوب', '3', 'تخصص', 7, 'catalog', 66),
  ('c0772', 'd17', 'EEE43502', 'مساق اختياري تخصص 3', '3', 'تخصص', 7, 'catalog', 67),
  ('c0773', 'd17', 'EEE43491', 'الذكاء الإصطناعي', '3', 'تخصص', 7, 'catalog', 68),
  ('c0774', 'd17', 'EEE00002', 'مساق اختياري 2', '3', 'تخصص', 7, 'catalog', 69),
  ('c0775', 'd17', 'EEE03555', 'مشروع التخرج', '3', 'تخصص', 8, 'catalog', 70),
  ('c0776', 'd17', 'EEE43503', 'مساق اختياري تخصص 4', '3', 'تخصص', 8, 'catalog', 71),
  ('c0777', 'd17', 'EEE43504', 'مساق اختياري تخصص 5', '3', 'تخصص', 8, 'catalog', 72),
  ('c0778', 'd17', 'EEE43576', 'أمن المعلومات والشبكات', '3', 'تخصص', 8, 'catalog', 73),
  ('c0779', 'd17', 'EEE43490', 'إنترنت الأشياء', '3', 'تخصص', 8, 'catalog', 74)
),
ins as (
  insert into public.courses (id, dept_id, code, name, credit, req_type, semester, source, sort_order)
  select v.id, v.dept_id, v.code, v.name, v.credit, v.req_type, v.semester, v.source, v.sort_order
  from v
  where not exists (select 1 from public.courses c where c.dept_id = v.dept_id and c.code = v.code)
  on conflict (id) do nothing
  returning 1
),
upd as (
  update public.courses c set semester = v.semester
  from v
  where c.dept_id = v.dept_id and c.code = v.code
    and c.semester is distinct from v.semester
  returning 1
)
select (select count(*) from ins) as courses_inserted, (select count(*) from upd) as courses_semester_backfilled;
