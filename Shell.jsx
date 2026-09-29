'use client';
import { useEffect, useState } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { supabase } from '@/lib/supabase';

export default function Shell({ children }) {
  const router = useRouter();
  const [me, setMe] = useState(null);
  useEffect(() => {
    supabase.auth.getSession().then(async ({ data }) => {
      if (!data.session) return router.replace('/login');
      const { data: p } = await supabase.from('profiles').select('full_name, roles(name_ar)').eq('id', data.session.user.id).single();
      setMe(p || {});
    });
  }, [router]);
  if (!me) return <p className="p-8 text-sm">جارٍ التحميل…</p>;
  return (
    <div className="mx-auto max-w-5xl p-4">
      <header className="mb-6 flex items-center justify-between border-b border-line pb-3">
        <nav className="flex gap-5 text-sm font-medium">
          <Link href="/">لوحة التحكم</Link>
          <Link href="/orders">الأوامر</Link>
        </nav>
        <div className="flex items-center gap-3 text-sm">
          <span>{me.full_name} <span className="text-zinc-500">({me.roles?.name_ar || 'بدون دور'})</span></span>
          <button className="btn btn-ghost" onClick={async () => { await supabase.auth.signOut(); router.replace('/login'); }}>خروج</button>
        </div>
      </header>
      {children}
    </div>
  );
}
