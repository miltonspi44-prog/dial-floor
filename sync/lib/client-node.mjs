// Node's half of the client handshake: the PC entrypoints import this for its
// side effect before anything touches the database. The edge function makes its
// own client (from npm:) and hands it to initSupa the same way.
import { createClient } from '@supabase/supabase-js'
import { initSupa } from './supa.mjs'
import { env } from './env.mjs'

if (!env('SUPABASE_SERVICE_KEY')) throw new Error('SUPABASE_SERVICE_KEY missing (.env or environment)')
initSupa(createClient(
  env('SUPABASE_URL') ?? 'https://fevjrcxmktjwbaozbngo.supabase.co',
  env('SUPABASE_SERVICE_KEY'),
  { auth: { persistSession: false } },
))
