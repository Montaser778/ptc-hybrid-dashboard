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
  dept_id        text references public.departments(id) on delete set null,
  residency      text check (residency in ('gaza','outside')),
  status         text not null default 'pending' check (status in ('pending','approved','rejected','suspended')),
  email_verified boolean not null default false,
  review_note    text not null default '',
  reviewed_by    uuid references public.profiles(id) on delete set null,
  reviewed_at    timestamptz,
  created_at     timestamptz not null default now(),
  constraint approved_needs_role check (status <> 'approved' or role is not null),
  constraint head_needs_dept     check (role is distinct from 'head' or dept_id is not null)
);

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

create or replace function app.my_dept() returns text
language sql stable security definer set search_path = public as $$
  select dept_id from public.profiles where id = auth.uid() and status = 'approved'
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
     and (app.is_vp() or (app.my_role() = 'head' and app.my_dept() = p_dept))
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
  v_dept  text  := nullif(meta->>'dept_id', '');
  v_res   text  := nullif(meta->>'residency', '');
  v_name  text  := nullif(trim(meta->>'full_name'), '');
  v_is_vp boolean;
begin
  select * into s from public.app_settings where id = 1;
  if s.id is null then
    raise exception 'APP_SETTINGS_MISSING';
  end if;
  if v_email is null or not (split_part(v_email, '@', 2) = any (select lower(unnest(s.allowed_domains)))) then
    raise exception 'EMAIL_DOMAIN_NOT_ALLOWED';
  end if;

  if v_req not in ('lecturer','head','viewer') or v_req is null then v_req := 'lecturer'; end if;
  if v_dept is not null and not exists (select 1 from public.departments where id = v_dept) then v_dept := null; end if;
  if v_res not in ('gaza','outside') then v_res := null; end if;
  if v_name is null or length(v_name) < 2 then v_name := split_part(v_email, '@', 1); end if;
  v_is_vp := v_email = lower(s.vp_email);

  insert into public.profiles (id, email, full_name, requested_role, role, dept_id, residency, status, email_verified)
  values (new.id, v_email, left(v_name, 120), v_req,
          case when v_is_vp then 'vp' end,
          v_dept, v_res,
          case when v_is_vp then 'approved' else 'pending' end,
          new.email_confirmed_at is not null)
  on conflict (id) do nothing;

  insert into public.audit_log (actor_id, actor_label, dept_id, dept_name, text)
  values (new.id, v_name, v_dept, coalesce((select name from public.departments where id = v_dept), ''),
          case when v_is_vp then 'تفعيل حساب نائب العميد تلقائيًا'
               else format('طلب تسجيل جديد بصفة: %s', app.role_label(v_req)) end);
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
    if (new.id, new.email, new.requested_role, new.role, new.dept_id, new.status,
        new.email_verified, new.review_note, new.reviewed_by, new.reviewed_at, new.created_at)
       is distinct from
       (old.id, old.email, old.requested_role, old.role, old.dept_id, old.status,
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
    if new.role = 'head' and new.dept_id is null then
      raise exception 'يجب تحديد القسم عند اعتماد رئيس قسم';
    end if;
    if (new.status, new.role, new.dept_id) is distinct from (old.status, old.role, old.dept_id) then
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
    perform app.log(new.dept_id, case new.status
      when 'approved'  then format('اعتماد حساب «%s» (%s) بصفة: %s', new.full_name, new.email, app.role_label(new.role))
      when 'rejected'  then format('رفض طلب تسجيل «%s» (%s)%s', new.full_name, new.email,
                                   case when new.review_note <> '' then ' — السبب: ' || new.review_note else '' end)
      when 'suspended' then format('تعليق حساب «%s» (%s)', new.full_name, new.email)
      else format('إعادة حساب «%s» إلى المراجعة', new.full_name) end);
  elsif new.status = 'approved' and (new.role, new.dept_id) is distinct from (old.role, old.dept_id) then
    perform app.log(new.dept_id, format('تعديل صلاحية «%s» إلى: %s%s', new.full_name, app.role_label(new.role),
      coalesce(' — ' || (select name from public.departments where id = new.dept_id), '')));
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

insert into public.courses (id, dept_id, code, name, credit, req_type, source, sort_order) values
  ('c001', 'd1', 'ACD03159', 'لغة إنجليزية I', '3', 'كلية', 'catalog', 0),
  ('c002', 'd1', 'ACD03158', 'لغة عربية', '3', 'كلية', 'catalog', 1),
  ('c003', 'd1', 'BUS23150', 'مبادئ الاقتصاد الجزئي', '3', 'برنامج', 'catalog', 2),
  ('c004', 'd1', 'BUS13150', 'مبادئ إدارة الأعمال', '3', 'برنامج', 'catalog', 3),
  ('c005', 'd1', 'BUS33150', 'مبادئ المحاسبة I', '3', 'برنامج', 'catalog', 4),
  ('c006', 'd1', 'COMP03150', 'المهارات الرقمية', '3', 'كلية', 'catalog', 5),
  ('c007', 'd2', 'ACD03001', 'اللغة الإنجليزية', '3', 'كلية', 'catalog', 0),
  ('c008', 'd2', 'BUS13000', 'مبادئ الإدارة', '3', 'برنامج', 'catalog', 1),
  ('c009', 'd2', 'BUS33000', 'المحاسبة', '3', 'تخصص', 'catalog', 2),
  ('c010', 'd2', 'ACD03002', 'دراسات في الفكر العربي الإسلامي', '3', 'كلية', 'catalog', 3),
  ('c011', 'd2', 'BUS04000', 'طباعة باللغة العربية', '2', 'تخصص', 'catalog', 4),
  ('c012', 'd2', 'COMP03150', 'المهارات الرقمية', '3', 'كلية', 'catalog', 5),
  ('c013', 'd3', 'ACD03158', 'لغة عربية', '3', 'كلية', 'catalog', 0),
  ('c014', 'd3', 'BUS03451', 'مبادئ الإدارة', '3', 'كلية', 'catalog', 1),
  ('c015', 'd3', 'MED03114', 'الإعلام الجديد', '3', 'برنامج', 'catalog', 2),
  ('c016', 'd3', 'MED03115', 'مدخل إلى الإذاعة والتليفزيون', '3', 'برنامج', 'catalog', 3),
  ('c017', 'd3', 'MED02116', 'إعلام الهاتف المحمول', '2', 'برنامج', 'catalog', 4),
  ('c018', 'd3', 'COMP03150', 'المهارات الرقمية', '3', 'كلية', 'catalog', 5),
  ('c019', 'd4', 'ACD03000', 'اللغة العربية', '3', 'كلية', 'catalog', 0),
  ('c020', 'd4', 'DME13101', 'مدخل إلى الإذاعة والتليفزيون', '3', 'برنامج', 'catalog', 1),
  ('c021', 'd4', 'DME13102', 'التصوير الفوتوغرافي', '3', 'برنامج', 'catalog', 2),
  ('c022', 'd4', 'DME13103', 'الهندسة الصوتية', '3', 'برنامج', 'catalog', 3),
  ('c023', 'd4', 'DME13104', 'مدخل إلى الإعلام الإلكتروني', '3', 'برنامج', 'catalog', 4),
  ('c024', 'd4', 'COMP03150', 'المهارات الرقمية', '3', 'كلية', 'catalog', 5),
  ('c025', 'd5', 'ACD03152', 'I فيزياء عامة', '3', 'برنامج', 'catalog', 0),
  ('c026', 'd5', 'ACD03159', 'لغة إنجليزية I', '3', 'كلية', 'catalog', 1),
  ('c027', 'd5', 'ACD03158', 'لغة عربية', '3', 'كلية', 'catalog', 2),
  ('c028', 'd5', 'MEE02152', 'مشغل هندسي', '2', 'تخصص', 'catalog', 3),
  ('c029', 'd5', 'ACD03178', 'I رياضيات عامة', '3', 'برنامج', 'catalog', 4),
  ('c030', 'd5', 'COMP03150', 'المهارات الرقمية', '3', 'كلية', 'catalog', 5),
  ('c031', 'd6', 'ACD03001', 'اللغة الإنجليزية', '3', 'كلية', 'catalog', 0),
  ('c032', 'd6', 'EEE13109', 'إلكترونيات', '3', 'برنامج', 'catalog', 1),
  ('c033', 'd6', 'ACD13263', 'الرياضيات', '3', 'برنامج', 'catalog', 2),
  ('c034', 'd6', 'EEE13106', 'طرق الفحص وأجهزة القياس', '3', 'تخصص', 'catalog', 3),
  ('c035', 'd6', 'EEE13107', 'مبادئ الدوائر الكهربائية', '3', 'برنامج', 'catalog', 4),
  ('c036', 'd6', 'COMP03150', 'المهارات الرقمية', '3', 'كلية', 'catalog', 5),
  ('c037', 'd7', 'ACD03001', 'اللغة الإنجليزية', '3', 'كلية', 'catalog', 0),
  ('c038', 'd7', 'ACD03000', 'اللغة العربية', '3', 'كلية', 'catalog', 1),
  ('c039', 'd7', 'BUS13000', 'مبادئ الإدارة', '3', 'برنامج', 'catalog', 2),
  ('c040', 'd7', 'HOT03100', 'صحة الأغذية', '3', 'تخصص', 'catalog', 3),
  ('c041', 'd7', 'HNP12151', 'I فرنسي', '2', 'برنامج', 'catalog', 4),
  ('c042', 'd7', 'COMP03150', 'المهارات الرقمية', '3', 'كلية', 'catalog', 5),
  ('c043', 'd8', 'ACD03001', 'اللغة الإنجليزية', '3', 'كلية', 'catalog', 0),
  ('c044', 'd8', 'ACD03000', 'اللغة العربية', '3', 'كلية', 'catalog', 1),
  ('c045', 'd8', 'BUS13000', 'مبادئ الإدارة', '3', 'برنامج', 'catalog', 2),
  ('c046', 'd8', 'BUS33100', 'المحاسبة المالية I', '3', 'تخصص', 'catalog', 3),
  ('c047', 'd8', 'BUS93008', 'مبادئ القانون', '3', 'تخصص', 'catalog', 4),
  ('c048', 'd8', 'COMP03150', 'المهارات الرقمية', '3', 'كلية', 'catalog', 5),
  ('c049', 'd9', 'ACD03159', 'لغة إنجليزية I', '3', 'كلية', 'catalog', 0),
  ('c050', 'd9', 'ACD03158', 'لغة عربية', '3', 'كلية', 'catalog', 1),
  ('c051', 'd9', 'BUS23150', 'مبادئ الاقتصاد الجزئي', '3', 'برنامج', 'catalog', 2),
  ('c052', 'd9', 'BUS13150', 'مبادئ إدارة الأعمال', '3', 'كلية', 'catalog', 3),
  ('c053', 'd9', 'BUS33150', 'مبادئ المحاسبة I', '3', 'برنامج', 'catalog', 4),
  ('c054', 'd9', 'COMP03150', 'المهارات الرقمية', '3', 'كلية', 'catalog', 5),
  ('c055', 'd10', 'ACD03159', 'لغة إنجليزية I', '3', 'كلية', 'catalog', 0),
  ('c056', 'd10', 'ACD03158', 'لغة عربية', '3', 'كلية', 'catalog', 1),
  ('c057', 'd10', 'COMP03150', 'المهارات الرقمية', '3', 'كلية', 'catalog', 2),
  ('c058', 'd10', 'MMD42153', 'معالجة الصور الرقمية', '2', 'تخصص', 'catalog', 3),
  ('c059', 'd10', 'MMD03151', 'مقدمة في الوسائط المتعددة', '3', 'برنامج', 'catalog', 4),
  ('c060', 'd10', 'MMD02152', 'الرسم الحر', '2', 'تخصص', 'catalog', 5),
  ('c061', 'd11', 'ACD03001', 'اللغة الإنجليزية', '3', 'كلية', 'catalog', 0),
  ('c062', 'd11', 'BUS13000', 'مبادئ الإدارة', '3', 'برنامج', 'catalog', 1),
  ('c063', 'd11', 'CMP13211', 'الخوارزميات ومبادئ البرمجة', '3', 'تخصص', 'catalog', 2),
  ('c064', 'd11', 'CMP43100', 'مقدمة في الوسائط المتعددة', '3', 'تخصص', 'catalog', 3),
  ('c065', 'd11', 'CMP43103', 'تصميم مواقع الويب', '3', 'تخصص', 'catalog', 4),
  ('c066', 'd11', 'COMP03150', 'المهارات الرقمية', '3', 'كلية', 'catalog', 5),
  ('c067', 'd12', 'ACD03001', 'اللغة الإنجليزية', '3', 'كلية', 'catalog', 0),
  ('c068', 'd12', 'BUS13000', 'مبادئ الإدارة', '3', 'برنامج', 'catalog', 1),
  ('c069', 'd12', 'EMK53000', 'مبادئ التسويق', '3', 'تخصص', 'catalog', 2),
  ('c070', 'd12', 'BUS23101', 'مبادئ الاقتصاد', '3', 'تخصص', 'catalog', 3),
  ('c071', 'd12', 'CMP43022', 'تطبيقات حاسوبية في الإدارة', '3', 'تخصص', 'catalog', 4),
  ('c072', 'd12', 'COMP03150', 'المهارات الرقمية', '3', 'كلية', 'catalog', 5),
  ('c073', 'd13', 'ACD03159', 'لغة إنجليزية I', '3', 'كلية', 'catalog', 0),
  ('c074', 'd13', 'ACD03158', 'لغة عربية', '3', 'كلية', 'catalog', 1),
  ('c075', 'd13', 'WIS14160', 'مقدمة في البرمجة', '4', 'تخصص', 'catalog', 2),
  ('c076', 'd13', 'ACD03175', 'رياضيات عامة', '3', 'برنامج', 'catalog', 3),
  ('c077', 'd13', 'COMP03150', 'المهارات الرقمية', '3', 'كلية', 'catalog', 4),
  ('c078', 'd14', 'ACD03001', 'اللغة الإنجليزية', '3', 'كلية', 'catalog', 0),
  ('c079', 'd14', 'ACD03002', 'دراسات في الفكر العربي الإسلامي', '3', 'كلية', 'catalog', 1),
  ('c080', 'd14', 'MED02104', 'الرسم الحر', '2', 'برنامج', 'catalog', 2),
  ('c081', 'd14', 'CMP42104', 'معالجة الصور الرقمية', '2', 'تخصص', 'catalog', 3),
  ('c082', 'd14', 'CMP03103', 'تكنولوجيا المعلومات والوسائط المتعددة', '3', 'تخصص', 'catalog', 4),
  ('c083', 'd14', 'CMP42108', 'تطوير العناصر ثلاثية الأبعاد البسيطة', '2', 'تخصص', 'catalog', 5),
  ('c084', 'd14', 'COMP03150', 'المهارات الرقمية', '3', 'كلية', 'catalog', 6),
  ('c085', 'd15', 'ACD03159', 'لغة إنجليزية I', '3', 'كلية', 'catalog', 0),
  ('c086', 'd15', 'BUS03451', 'مبادئ الإدارة', '3', 'كلية', 'catalog', 1),
  ('c087', 'd15', 'NPH23150', 'كيمياء عامة', '3', 'برنامج', 'catalog', 2),
  ('c088', 'd15', 'NPH33251', 'أساسيات علم التغذية', '3', 'تخصص', 'catalog', 3),
  ('c089', 'd15', 'COMP03150', 'المهارات الرقمية', '3', 'كلية', 'catalog', 4),
  ('c090', 'd15', 'NBHG11151', 'مصطلحات طبية', '1', 'برنامج', 'catalog', 5),
  ('c091', 'd16', 'EEE03150', 'مقدمة في الحاسوب', '3', 'كلية', 'catalog', 0),
  ('c092', 'd16', 'ACD03150', 'تفاضل وتكامل I', '3', 'برنامج', 'catalog', 1),
  ('c093', 'd16', 'ACD03159', 'لغة إنجليزية I', '3', 'كلية', 'catalog', 2),
  ('c094', 'd16', 'ACD04159', 'فيزياء عامة', '4', 'برنامج', 'catalog', 3),
  ('c095', 'd16', 'MEE02150', 'الرسم الهندسي', '2', 'برنامج', 'catalog', 4),
  ('c096', 'd16', 'MEE02151', 'المشغل الهندسي والامن الصناعي', '2', 'برنامج', 'catalog', 5),
  ('c097', 'd17', 'ACD03150', 'تفاضل وتكامل I', '3', 'برنامج', 'catalog', 0),
  ('c098', 'd17', 'ACD03159', 'لغة إنجليزية I', '3', 'كلية', 'catalog', 1),
  ('c099', 'd17', 'ACD03158', 'لغة عربية', '3', 'كلية', 'catalog', 2),
  ('c100', 'd17', 'EEE01151', 'مقدمة في الهندسة', '1', 'برنامج', 'catalog', 3),
  ('c101', 'd17', 'ACD04159', 'فيزياء عامة', '4', 'برنامج', 'catalog', 4),
  ('c102', 'd17', 'COMP03150', 'المهارات الرقمية', '3', 'كلية', 'catalog', 5),
  ('c103', 'd17', 'MEE01151', 'المشغل الهندسي', '1', 'برنامج', 'catalog', 6)
on conflict (id) do nothing;