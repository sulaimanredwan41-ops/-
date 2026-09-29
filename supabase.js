import { createClient } from '@supabase/supabase-js';
export const supabase = createClient(
  process.env.NEXT_PUBLIC_SUPABASE_URL,
  process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY
);
export const dot = { gray: 'bg-zinc-400', blue: 'bg-cyan', purple: 'bg-indigo-500', orange: 'bg-yolk', green: 'bg-emerald-600', red: 'bg-magenta' };
export const fmt = (d) => d ? new Date(d).toLocaleString('ar-SA', { dateStyle: 'medium', timeStyle: 'short' }) : '—';
