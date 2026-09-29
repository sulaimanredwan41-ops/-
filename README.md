# تطبيق أوامر التشغيل — المرحلة 1 من الواجهة

## التشغيل
1. شغّل ملف قاعدة البيانات (Phase 1) في Supabase SQL Editor، مع الإصلاحات الأمنية.
2. أنشئ مستخدمًا من Supabase Auth → ثم اجعله مديرًا:
   `update public.profiles set role_id = (select id from public.roles where key='manager') where id = '<USER_UUID>';`
3. انسخ `.env.local.example` إلى `.env.local` وضع رابط المشروع و anon key.
4. `npm install` ثم `npm run dev` ثم افتح http://localhost:3000

## المتضمن
دخول، لوحة تحكم، قائمة أوامر مع بحث وتصفية، إنشاء أمر، تفاصيل الأمر مع السجل وتغيير الحالة، والمالية (تظهر لمن يملك finance.view فقط).

## ملاحظة
لتثبيته كتطبيق على الجوال أضف أيقونات 192 و512 في public/ واذكرها في manifest.json.
