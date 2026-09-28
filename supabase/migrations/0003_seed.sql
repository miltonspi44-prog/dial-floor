-- Dial Floor · 0003 seeds

-- state defaults (IANA). Split states get area-code overrides below.
insert into public.state_tz (state, tz) values
('FL','America/New_York'),('GA','America/New_York'),('NC','America/New_York'),('SC','America/New_York'),
('VA','America/New_York'),('PA','America/New_York'),('OH','America/New_York'),('NY','America/New_York'),
('NJ','America/New_York'),('MA','America/New_York'),('MD','America/New_York'),('CT','America/New_York'),
('NH','America/New_York'),('ME','America/New_York'),('RI','America/New_York'),('DE','America/New_York'),
('MI','America/New_York'),('IN','America/New_York'),('KY','America/New_York'),('VT','America/New_York'),
('WV','America/New_York'),
('TN','America/Chicago'),('AL','America/Chicago'),('WI','America/Chicago'),('IL','America/Chicago'),
('TX','America/Chicago'),('MO','America/Chicago'),('AR','America/Chicago'),('LA','America/Chicago'),
('MS','America/Chicago'),('IA','America/Chicago'),('MN','America/Chicago'),('OK','America/Chicago'),
('KS','America/Chicago'),('NE','America/Chicago'),('SD','America/Chicago'),('ND','America/Chicago'),
('AZ','America/Phoenix'),('CO','America/Denver'),('NM','America/Denver'),('UT','America/Denver'),
('WY','America/Denver'),('MT','America/Denver'),('ID','America/Denver'),
('CA','America/Los_Angeles'),('WA','America/Los_Angeles'),('OR','America/Los_Angeles'),('NV','America/Los_Angeles'),
('AK','America/Anchorage'),('HI','Pacific/Honolulu')
on conflict (state) do nothing;

-- split-state overrides by phone area code (the guard uses the phone's zone)
insert into public.area_code_tz (area_code, tz) values
('850','America/Chicago'),   -- FL panhandle
('915','America/Denver'),    -- TX El Paso
('432','America/Denver'),    -- TX Midland/Odessa (partial)
('423','America/New_York'),  -- TN Chattanooga/Tri-Cities
('865','America/New_York'),  -- TN Knoxville
('270','America/Chicago'),   -- KY west
('364','America/Chicago'),   -- KY west overlay
('219','America/Chicago'),   -- IN northwest
('812','America/Chicago')    -- IN Evansville (majority)
on conflict (area_code) do nothing;

-- intent catalog (C1 — priority orders the display)
insert into public.intents_catalog (key, label, description, priority) values
('no_website',      'No website',              'Nothing to send customers to — hottest list; build-it-first pitch', 10),
('social_only',     'Facebook/Instagram only', 'Believes in online presence, has not graduated', 20),
('free_subdomain',  'Free-subdomain site',     'godaddysites/wixsite/canva… fingerprinted by the scraper', 30),
('cheap_builder',   'Cheap builder site',      'Wix/GoDaddy/Weebly single-pager — upgrade pitch', 40),
('broken_site',     'Broken/unreachable site', 'Expired domain, SSL error, under construction', 25),
('fresh_listing',   'Fresh listing',           'First seen under 30 days — no agency has called yet', 15),
('review_rich',     'Review-rich, site-poor',  '20–150 good reviews and nowhere to send people', 12),
('reputation_risk', 'Reputation risk',         'Rating under 3.8 with volume — reputation/SEO angle', 50),
('owner_mobile',    'Owner mobile listed',     'Mobile line — the owner answers; skip gatekeeper talk', 18),
('multi_trade',     'Multi-trade operator',    '3+ categories — bigger site, more service pages', 60),
('ad_spend',        'Paying for ads',          'Sponsored listing + weak site — already buys leads', 35),
('badge_holder',    'Badge holder',            'Google Guaranteed / verified — invests in marketing', 55),
('never_answers',   'Never answers phone',     '4+ attempts, zero pickups — AI receptionist pitch with proof', 22),
('seasonal_window', 'Seasonal window open',    'Trade season opening (radar-assigned)', 45),
('storm_response',  'Storm response',          'Weather event in metro (radar-assigned)', 44),
('competitor_gap',  'Competitor gap',          'Top-rated peers all have sites (radar-assigned)', 65),
('voicemail_missing','Voicemail full/missing', 'Losing calls today — receptionist angle', 42),
('callback_due',    'Callback due',            'A promise to keep, not a cold call', 5)
on conflict (key) do nothing;

-- battlecards (D1) — starter set, manager-editable in the app
insert into public.battlecards (objection, counters, sort) values
('Too expensive', '["Compare it to one missed job: one roof off a website pays for years of it.","We build it first — you pay nothing until you have seen it and want it.","What does one new customer bring you? This costs less than losing one a month."]', 10),
('My nephew/friend does it', '["How is that going — is it live and bringing calls?","Free help usually means it never gets finished. We finish this week.","Keep the nephew — we handle the part that brings customers."]', 20),
('Too busy right now', '["That is exactly why — busy season is when a site pays for itself fastest.","Takes zero time from you: we build it first, you just look at it.","30 seconds: what is stopping customers finding you today?"]', 30),
('Send me something', '["Happy to — what is the best email? And while I have you: [one qualifying question]","I will do better — we will build the actual homepage and send that.","Sure. If it looks good, is a website something you would actually invest in this season?"]', 40),
('I get enough work from word of mouth', '["Word of mouth sends them to Google to check you — what do they find?","Your competitors with sites are catching the overflow you never hear about.","Great sign — reviews plus a site turns word of mouth into twice the calls."]', 50),
('Already have a website', '["I see it — it is on a free builder / not mobile friendly; that is costing calls.","When did it last bring you a customer you can name?","Fair — how about the phone side: who answers when you are on a roof?"]', 60)
on conflict do nothing;

-- settings
insert into public.app_settings (key, value) values
('call_window',           '{"start":"08:00","end":"20:30"}'),
('max_attempts_per_day',  '2'),
('rest_soft_days',        '10'),
('rest_hard_days',        '20'),
('reclaim_minutes',       '30'),
('allow_general_pool',    'true'),
('ai_summaries_enabled',  'false'),
('spam_alert_drop_pts',   '10')
on conflict (key) do nothing;

-- pace targets (F4) — placeholders, edit in app/SQL
insert into public.kpi_targets (metric, target, scope) values
('dials_per_day',    400, 'agent_day'),
('connects_per_day',  45, 'agent_day'),
('handoffs_per_day',   3, 'agent_day')
on conflict (metric) do nothing;
