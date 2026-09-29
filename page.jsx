'use client';
import { useEffect, useState } from 'react';
import Link from 'next/link';
import Shell from '@/components/Shell';
import { supabase } from '@/lib/supabase';

export default function Dashboard() {
  const [rows, setRows] = useState(null);
  useEffect(() => {
    supabase.from('v_dashboard_counts').select('*').order('sort').then(({ data }) => setRows(data || []));
  }, []);
  const active = (rows || []).filter((r) => r.total > 0);
  const sum = (k) => (rows || []).reduce((a, r) => a + Number(r[k] || 0), 0);
  return (
    <Shell>
      <div className="mb-6 flex gap-8 text-sm">
        <div><div className="text-3xl font-bold">{sum('total')}</div>إجمالي الأوامر</div>
        <div><div className="text-3xl font-bold text-magenta">{sum('urgent')}</div>مستعجل</div>
        <div><div className="text-3xl font-bold text-yolk">{sum('overdue')}</div>متأخر عن التسليم</div>
      </div>
      {rows === null ? <p className="text-sm">جارٍ التحميل…</p> : active.length === 0 ? (
        <p className="text-sm">لا توجد أوامر بعد. <Link className="underline" href="/orders/new">أنشئ أول أمر</Link></p>
      ) : (
        <ul className="divide-y divide-line border-y border-line">
          {active.map((r) => (
            <li key={r.status_key}>
              <Link href={`/orders?status=${r.status_key}`} className="flex items-center justify-between py-3 hover:bg-white">
                <span>{r.name_ar}</span>
                <span className="flex gap-4 text-sm">
                  {r.overdue > 0 && <span className="text-yolk">متأخر {r.overdue}</span>}
                  {r.urgent > 0 && <span className="text-magenta">مستعجل {r.urgent}</span>}
                  <b>{r.total}</b>
                </span>
              </Link>
            </li>
          ))}
        </ul>
      )}
    </Shell>
  );
}
