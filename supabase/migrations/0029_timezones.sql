-- Dial Floor · 0029 every area code, and no guessing
-- Focus item 21, reproduced first in supabase/tests/groups/40_timezones.sql.
-- derive_tz knew nine area codes and fell back to Eastern when it knew nothing
-- at all, so a lead with no usable state would have been dialable at 5am its
-- time. Three changes:
--   · the area-code table covers the NANP: every US and Canadian geographic
--     code, set to the zone most of that code lives in (the nine split-state
--     overrides 0003 seeded agree with these). Toll-free and premium codes are
--     deliberately absent — they say nothing about where the phone rings, so
--     those leads lean on their state.
--   · unknown means unknown: no state, no known code → tz is null, and
--     local_ok(null) is false, so the queue never serves a lead whose clock
--     nobody knows. It can still be dialed the moment the console sends a
--     usable state or the number is corrected.
--   · every lead's tz is re-derived under the new table.

-- the phone's own area code first, the state second, and nothing third
create or replace function public.derive_tz(p_phone_norm text, p_state text)
returns text language sql stable set search_path = public as $$
  select coalesce(
    (select tz from public.area_code_tz where area_code = substr(p_phone_norm, 1, 3)),
    (select tz from public.state_tz where state = upper(coalesce(p_state, ''))))
$$;

-- Is it a lawful/civil hour at the lead's local time? A lead whose timezone
-- could not be worked out has no lawful hour, so the answer is no.
create or replace function public.local_ok(p_tz text)
returns boolean language plpgsql stable set search_path = public as $$
declare
  w jsonb := coalesce(public.setting('call_window'), '{"start":"08:00","end":"20:30"}'::jsonb);
  lt time;
begin
  if p_tz is null then return false; end if;
  lt := (now() at time zone p_tz)::time;
  return lt >= (w->>'start')::time and lt <= (w->>'end')::time;
end $$;

-- ------------------------------------------------- the NANP, dominant zone --
-- A split code carries the zone most of its numbers live in, same convention as
-- 0003's nine overrides (which these rows agree with and do not overwrite).
insert into public.area_code_tz (area_code, tz) values
-- Eastern
('203','America/New_York'),('475','America/New_York'),('860','America/New_York'),('959','America/New_York'), -- CT
('202','America/New_York'),('771','America/New_York'),                                                       -- DC
('302','America/New_York'),                                                                                   -- DE
('239','America/New_York'),('305','America/New_York'),('321','America/New_York'),('352','America/New_York'), -- FL
('386','America/New_York'),('407','America/New_York'),('561','America/New_York'),('656','America/New_York'),
('689','America/New_York'),('727','America/New_York'),('754','America/New_York'),('772','America/New_York'),
('786','America/New_York'),('813','America/New_York'),('863','America/New_York'),('904','America/New_York'),
('941','America/New_York'),
('229','America/New_York'),('404','America/New_York'),('470','America/New_York'),('478','America/New_York'), -- GA
('678','America/New_York'),('706','America/New_York'),('762','America/New_York'),('770','America/New_York'),
('912','America/New_York'),('943','America/New_York'),
('260','America/New_York'),('317','America/New_York'),('463','America/New_York'),('574','America/New_York'), -- IN (east)
('765','America/New_York'),
('502','America/New_York'),('606','America/New_York'),('859','America/New_York'),                            -- KY (east)
('339','America/New_York'),('351','America/New_York'),('413','America/New_York'),('508','America/New_York'), -- MA
('617','America/New_York'),('774','America/New_York'),('781','America/New_York'),('857','America/New_York'),
('978','America/New_York'),
('240','America/New_York'),('301','America/New_York'),('410','America/New_York'),('443','America/New_York'), -- MD
('667','America/New_York'),
('207','America/New_York'),                                                                                   -- ME
('231','America/New_York'),('248','America/New_York'),('269','America/New_York'),('313','America/New_York'), -- MI
('517','America/New_York'),('586','America/New_York'),('616','America/New_York'),('734','America/New_York'),
('810','America/New_York'),('906','America/New_York'),('947','America/New_York'),('989','America/New_York'),
('252','America/New_York'),('336','America/New_York'),('704','America/New_York'),('743','America/New_York'), -- NC
('828','America/New_York'),('910','America/New_York'),('919','America/New_York'),('980','America/New_York'),
('984','America/New_York'),
('603','America/New_York'),                                                                                   -- NH
('201','America/New_York'),('551','America/New_York'),('609','America/New_York'),('640','America/New_York'), -- NJ
('732','America/New_York'),('848','America/New_York'),('856','America/New_York'),('862','America/New_York'),
('908','America/New_York'),('973','America/New_York'),
('212','America/New_York'),('315','America/New_York'),('332','America/New_York'),('347','America/New_York'), -- NY
('363','America/New_York'),('516','America/New_York'),('518','America/New_York'),('585','America/New_York'),
('607','America/New_York'),('631','America/New_York'),('646','America/New_York'),('680','America/New_York'),
('716','America/New_York'),('718','America/New_York'),('838','America/New_York'),('845','America/New_York'),
('914','America/New_York'),('917','America/New_York'),('929','America/New_York'),('934','America/New_York'),
('216','America/New_York'),('220','America/New_York'),('234','America/New_York'),('326','America/New_York'), -- OH
('330','America/New_York'),('380','America/New_York'),('419','America/New_York'),('440','America/New_York'),
('513','America/New_York'),('567','America/New_York'),('614','America/New_York'),('740','America/New_York'),
('937','America/New_York'),
('215','America/New_York'),('223','America/New_York'),('267','America/New_York'),('272','America/New_York'), -- PA
('412','America/New_York'),('445','America/New_York'),('484','America/New_York'),('570','America/New_York'),
('582','America/New_York'),('610','America/New_York'),('717','America/New_York'),('724','America/New_York'),
('814','America/New_York'),('878','America/New_York'),
('401','America/New_York'),                                                                                   -- RI
('803','America/New_York'),('839','America/New_York'),('843','America/New_York'),('854','America/New_York'), -- SC
('864','America/New_York'),
('276','America/New_York'),('434','America/New_York'),('540','America/New_York'),('571','America/New_York'), -- VA
('703','America/New_York'),('757','America/New_York'),('804','America/New_York'),('826','America/New_York'),
('948','America/New_York'),
('802','America/New_York'),                                                                                   -- VT
('304','America/New_York'),('681','America/New_York'),                                                       -- WV
-- Central
('205','America/Chicago'),('251','America/Chicago'),('256','America/Chicago'),('334','America/Chicago'),     -- AL
('659','America/Chicago'),('938','America/Chicago'),
('479','America/Chicago'),('501','America/Chicago'),('870','America/Chicago'),                                -- AR
('448','America/Chicago'),                                                                                    -- FL panhandle overlay of 850
('319','America/Chicago'),('515','America/Chicago'),('563','America/Chicago'),('641','America/Chicago'),     -- IA
('712','America/Chicago'),
('217','America/Chicago'),('224','America/Chicago'),('309','America/Chicago'),('312','America/Chicago'),     -- IL
('331','America/Chicago'),('447','America/Chicago'),('464','America/Chicago'),('618','America/Chicago'),
('630','America/Chicago'),('708','America/Chicago'),('730','America/Chicago'),('773','America/Chicago'),
('779','America/Chicago'),('815','America/Chicago'),('847','America/Chicago'),('872','America/Chicago'),
('930','America/Chicago'),                                                                                    -- IN (Evansville overlay of 812)
('316','America/Chicago'),('620','America/Chicago'),('785','America/Chicago'),('913','America/Chicago'),     -- KS
('225','America/Chicago'),('318','America/Chicago'),('337','America/Chicago'),('504','America/Chicago'),     -- LA
('985','America/Chicago'),
('218','America/Chicago'),('320','America/Chicago'),('507','America/Chicago'),('612','America/Chicago'),     -- MN
('651','America/Chicago'),('763','America/Chicago'),('952','America/Chicago'),
('314','America/Chicago'),('417','America/Chicago'),('557','America/Chicago'),('573','America/Chicago'),     -- MO
('636','America/Chicago'),('660','America/Chicago'),('816','America/Chicago'),
('228','America/Chicago'),('601','America/Chicago'),('662','America/Chicago'),('769','America/Chicago'),     -- MS
('701','America/Chicago'),                                                                                    -- ND
('308','America/Chicago'),('402','America/Chicago'),('531','America/Chicago'),                                -- NE
('405','America/Chicago'),('539','America/Chicago'),('572','America/Chicago'),('580','America/Chicago'),     -- OK
('918','America/Chicago'),
('605','America/Chicago'),                                                                                    -- SD
('615','America/Chicago'),('629','America/Chicago'),('731','America/Chicago'),('901','America/Chicago'),     -- TN (middle/west)
('931','America/Chicago'),
('210','America/Chicago'),('214','America/Chicago'),('254','America/Chicago'),('281','America/Chicago'),     -- TX
('325','America/Chicago'),('346','America/Chicago'),('361','America/Chicago'),('409','America/Chicago'),
('430','America/Chicago'),('469','America/Chicago'),('512','America/Chicago'),('682','America/Chicago'),
('713','America/Chicago'),('726','America/Chicago'),('737','America/Chicago'),('806','America/Chicago'),
('817','America/Chicago'),('830','America/Chicago'),('903','America/Chicago'),('936','America/Chicago'),
('940','America/Chicago'),('945','America/Chicago'),('956','America/Chicago'),('972','America/Chicago'),
('979','America/Chicago'),
('262','America/Chicago'),('414','America/Chicago'),('534','America/Chicago'),('608','America/Chicago'),     -- WI
('715','America/Chicago'),('920','America/Chicago'),
-- Mountain
('303','America/Denver'),('719','America/Denver'),('720','America/Denver'),('970','America/Denver'),         -- CO
('983','America/Denver'),
('208','America/Denver'),('986','America/Denver'),                                                            -- ID
('406','America/Denver'),                                                                                     -- MT
('505','America/Denver'),('575','America/Denver'),                                                            -- NM
('385','America/Denver'),('435','America/Denver'),('801','America/Denver'),                                   -- UT
('307','America/Denver'),                                                                                     -- WY
-- Arizona (no DST)
('480','America/Phoenix'),('520','America/Phoenix'),('602','America/Phoenix'),('623','America/Phoenix'),     -- AZ
('928','America/Phoenix'),
-- Pacific
('209','America/Los_Angeles'),('213','America/Los_Angeles'),('279','America/Los_Angeles'),('310','America/Los_Angeles'), -- CA
('323','America/Los_Angeles'),('341','America/Los_Angeles'),('350','America/Los_Angeles'),('408','America/Los_Angeles'),
('415','America/Los_Angeles'),('424','America/Los_Angeles'),('442','America/Los_Angeles'),('510','America/Los_Angeles'),
('530','America/Los_Angeles'),('559','America/Los_Angeles'),('562','America/Los_Angeles'),('619','America/Los_Angeles'),
('626','America/Los_Angeles'),('628','America/Los_Angeles'),('650','America/Los_Angeles'),('657','America/Los_Angeles'),
('661','America/Los_Angeles'),('669','America/Los_Angeles'),('707','America/Los_Angeles'),('714','America/Los_Angeles'),
('747','America/Los_Angeles'),('760','America/Los_Angeles'),('805','America/Los_Angeles'),('818','America/Los_Angeles'),
('820','America/Los_Angeles'),('831','America/Los_Angeles'),('840','America/Los_Angeles'),('858','America/Los_Angeles'),
('909','America/Los_Angeles'),('916','America/Los_Angeles'),('925','America/Los_Angeles'),('949','America/Los_Angeles'),
('951','America/Los_Angeles'),
('702','America/Los_Angeles'),('725','America/Los_Angeles'),('775','America/Los_Angeles'),                   -- NV
('458','America/Los_Angeles'),('503','America/Los_Angeles'),('541','America/Los_Angeles'),('971','America/Los_Angeles'), -- OR
('206','America/Los_Angeles'),('253','America/Los_Angeles'),('360','America/Los_Angeles'),('425','America/Los_Angeles'), -- WA
('509','America/Los_Angeles'),('564','America/Los_Angeles'),
-- Alaska, Hawaii, territories
('907','America/Anchorage'),
('808','Pacific/Honolulu'),
('787','America/Puerto_Rico'),('939','America/Puerto_Rico'),('340','America/Puerto_Rico'),
('671','Pacific/Guam'),('670','Pacific/Saipan'),('684','Pacific/Pago_Pago'),
-- Canada
('709','America/St_Johns'),
('902','America/Halifax'),('782','America/Halifax'),('506','America/Halifax'),
('418','America/Toronto'),('438','America/Toronto'),('450','America/Toronto'),('514','America/Toronto'),     -- QC
('579','America/Toronto'),('581','America/Toronto'),('819','America/Toronto'),('873','America/Toronto'),
('263','America/Toronto'),('354','America/Toronto'),('468','America/Toronto'),
('226','America/Toronto'),('249','America/Toronto'),('289','America/Toronto'),('343','America/Toronto'),     -- ON
('365','America/Toronto'),('416','America/Toronto'),('437','America/Toronto'),('519','America/Toronto'),
('548','America/Toronto'),('613','America/Toronto'),('647','America/Toronto'),('705','America/Toronto'),
('742','America/Toronto'),('753','America/Toronto'),('807','America/Toronto'),('905','America/Toronto'),
('204','America/Winnipeg'),('431','America/Winnipeg'),                                                       -- MB
('306','America/Regina'),('639','America/Regina'),('474','America/Regina'),                                  -- SK
('403','America/Edmonton'),('587','America/Edmonton'),('780','America/Edmonton'),('825','America/Edmonton'), -- AB
('368','America/Edmonton'),
('236','America/Vancouver'),('250','America/Vancouver'),('604','America/Vancouver'),('672','America/Vancouver'), -- BC
('778','America/Vancouver'),
('867','America/Edmonton')  -- YT/NT/NU share one code; Yellowknife holds most of it
on conflict (area_code) do nothing;

-- every lead gets its clock re-read under the new table; unknown stays unknown
update public.leads set tz = public.derive_tz(phone_norm, addr_state)
 where tz is distinct from public.derive_tz(phone_norm, addr_state);
