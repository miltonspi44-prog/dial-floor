-- Dial Floor · 0049 registry leads wait two weeks in the console
-- The owner wants a lead from a state business registry to reach the floor only
-- once the scraper has had it for two weeks; every other source (Google Maps,
-- Angi, Yelp, Thumbtack, Facebook) still comes in as soon as it is scraped.
-- The pull does the waiting (sync/pull-leads.mjs, in the PC loop and the hosted
-- sync-console function alike): a registry row the scraper first saw less than
-- the hold ago is left alone, so it is not marked contacted and the console keeps
-- offering it, and the first pull after its day takes it like any other lead.
-- The hold is a setting, on the Settings page under Lead sync: 14 days unless
-- changed, 0 turns it off. This adds it to the settings registry (0043's, with
-- one more entry); the sync reads app_settings and assumes 14 when no row exists.
-- Applies through the management API as it is.

create or replace function public.settings_registry()
returns jsonb language sql immutable set search_path = public as $$
select jsonb_build_array(
  jsonb_build_object('key','call_window','kind','window','grp','Calling window','label','Calling hours (lead''s local time)','help','No lead is served or dialed outside these hours on its own clock.','def','{"start":"08:00","end":"20:30"}'::jsonb),
  jsonb_build_object('key','business_hours','kind','window_days','grp','Calling window','label','Business hours (for never-answers proof)','help','The hours and days that count as "they should have picked up".','def','{"start":"08:00","end":"17:00","days":[1,2,3,4,5]}'::jsonb),
  jsonb_build_object('key','business_tz','kind','tz','grp','Calling window','label','Business timezone','help','The clock the floor''s day, streaks and reports run on.','def',to_jsonb('America/Los_Angeles'::text)),
  jsonb_build_object('key','max_attempts_per_day','kind','int','grp','Queue','label','Calls per business per day','min',1,'max',6,'def',to_jsonb(2)),
  jsonb_build_object('key','min_redial_minutes','kind','int','grp','Queue','label','Redial gap (minutes)','min',15,'max',720,'def',to_jsonb(120)),
  jsonb_build_object('key','reserve_minutes','kind','int','grp','Queue','label','Lead held on screen (minutes)','min',3,'max',60,'def',to_jsonb(10)),
  jsonb_build_object('key','reclaim_minutes','kind','int','grp','Queue','label','Abandoned call reclaimed after (minutes)','min',10,'max',120,'def',to_jsonb(30)),
  jsonb_build_object('key','skip_rest_minutes','kind','int','grp','Queue','label','Rest after a skip (minutes)','min',10,'max',480,'def',to_jsonb(60)),
  jsonb_build_object('key','reclaim_sweep_max','kind','int','grp','Queue','label','Stranded calls finished per check','min',5,'max',100,'def',to_jsonb(25)),
  jsonb_build_object('key','allow_general_pool','kind','bool','grp','Queue','label','Serve from the general pool','help','Off = agents only dial callbacks and lists.','def',to_jsonb(true)),
  jsonb_build_object('key','callback_retry_minutes','kind','int','grp','Callbacks','label','Unanswered callback retried after (minutes)','min',10,'max',480,'def',to_jsonb(60)),
  jsonb_build_object('key','callback_max_tries','kind','int','grp','Callbacks','label','Tries before a callback is unreached','min',1,'max',6,'def',to_jsonb(3)),
  jsonb_build_object('key','callback_missed_hours','kind','int','grp','Callbacks','label','Overdue hours before a callback is missed','min',4,'max',72,'def',to_jsonb(24)),
  jsonb_build_object('key','rest_soft_days','kind','int','grp','Rests','label','"Not interested — soft" rest (days)','min',1,'max',60,'def',to_jsonb(10)),
  jsonb_build_object('key','rest_hard_days','kind','int','grp','Rests','label','"Not interested — hard" rest (days)','min',1,'max',120,'def',to_jsonb(20)),
  jsonb_build_object('key','recycle_provider_days','kind','int','grp','Rests','label','"Has provider" auto-return (days, 0 = off)','min',0,'max',365,'def',to_jsonb(0)),
  jsonb_build_object('key','shift_hours','kind','num','grp','Pace','label','Shift length (hours)','min',1,'max',16,'def',to_jsonb(8)),
  jsonb_build_object('key','wrapup_seconds','kind','int','grp','Pace','label','Wrap-up countdown (seconds, 0 = off)','min',0,'max',300,'def',to_jsonb(20)),
  jsonb_build_object('key','alerts','kind','json','grp','Alerts','label','Alert thresholds','help','idle_minutes, long_call_minutes, pace_pct, callback_overdue_minutes, celebrate, spam, sync_quiet_minutes, console_quiet_days, outside_calls, radar_approvals.','def','{}'::jsonb),
  jsonb_build_object('key','spam_alert_drop_pts','kind','num','grp','Alerts','label','Spam alert: connect-rate drop (points)','min',1,'max',50,'def',to_jsonb(10)),
  jsonb_build_object('key','radar_deal_per_agent','kind','int','grp','Radar','label','Radar leads per proposed list','help','The radar proposes one list per agent and waits for a manager to approve it; the next is proposed once that one is dialed through. 0 turns the radar lists off.','min',0,'max',500,'def',to_jsonb(100)),
  jsonb_build_object('key','missed_call_threshold','kind','int','grp','Radar','label','Missed tries before "never answers"','min',2,'max',10,'def',to_jsonb(4)),
  jsonb_build_object('key','seasons','kind','json','grp','Radar','label','Seasonal windows','help','A list of {label, keys, months, states}.','def','[]'::jsonb),
  jsonb_build_object('key','best_time','kind','json','grp','Model','label','Best-time-to-call model','help','use_in_queue, days, min_dials, min_total, prior.','def','{}'::jsonb),
  jsonb_build_object('key','ai_summaries_enabled','kind','bool','grp','Model','label','Fetch Zoom AI call summaries','def',to_jsonb(false)),
  jsonb_build_object('key','ai','kind','json','grp','AI','label','AI floor analysis','help','model: the Gemini model to use (blank = the newest Gemini Flash your key can reach); match: true deals radar lists by who is likeliest to convert each lead, false deals them round-robin.','def','{"model":"","match":true}'::jsonb),
  jsonb_build_object('key','pull_hold_registry_days','kind','int','grp','Lead sync','label','Registry leads held after scraping (days, 0 = off)','help','A new registry lead waits in the console until the scraper has had it this many days, then comes in with the next pull. Every other source comes in as soon as it is scraped.','min',0,'max',60,'def',to_jsonb(14))
)
$$;
