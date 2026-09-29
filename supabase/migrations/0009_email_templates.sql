-- Dial Floor · 0009 email templates (G5: capture → template → mark sent)
--   The queue already captured the address and tracked sent/skipped. Managers now
--   keep templates here; the Emails tab fills one in for each queued lead and hands
--   it to the manager's own mail client. Nothing is sent from the system.
--   email_queue.template records which template went out.

create table if not exists public.email_templates (
  id bigint generated always as identity primary key,
  name text not null unique check (length(btrim(name)) > 0),
  subject text not null default '',
  body text not null default '',
  active boolean not null default true,
  sort int not null default 0,
  updated_at timestamptz not null default now()
);
alter table public.email_templates enable row level security;
create policy email_templates_read on public.email_templates
  for select to authenticated using (true);
create policy email_templates_manager on public.email_templates
  for all to authenticated using (public.is_manager()) with check (public.is_manager());

-- Starter drafts, meant to be edited in the Emails tab before they go out.
-- Placeholders: {business} {city} {state} {category} {website} {agent} {my_name}
insert into public.email_templates (name, subject, body, sort) values
('Website — more info', 'A website for {business}',
$t$Hi,

Thanks for speaking with {agent} today. As promised, here's a short note about what we can do for {business}.

We build clean, mobile-friendly websites for local businesses, set up so the people who find you on Google can see your services, your reviews and the area you cover, and call you in one tap.

If you'd like, I can show you an example of what a site for {business} could look like. Just reply to this email.

Best regards,
{my_name}$t$, 1),
('Google visibility (SEO)', 'Getting {business} found on Google',
$t$Hi,

Thanks for speaking with {agent} today. Here's the information you asked for.

When someone in {city} searches for what you do, the businesses at the top of Google get most of the calls. We help local businesses move up those results: a complete Google Business Profile, consistent local listings, and a website Google can read.

If you'd like, I can send you a quick look at where {business} shows up today and what would move it up. Just reply to this email.

Best regards,
{my_name}$t$, 2),
('AI receptionist', 'Never miss a call at {business}',
$t$Hi,

Thanks for speaking with {agent} today. As promised, here's a bit more about our AI receptionist.

It picks up your business line when you can't (after hours, on a job, or when the line is busy), takes the caller's details and what they need, and passes it straight to you, so a missed call doesn't turn into a lost job.

If you'd like to hear how it would sound for {business}, just reply to this email and I'll set up a short demo.

Best regards,
{my_name}$t$, 3)
on conflict (name) do nothing;
