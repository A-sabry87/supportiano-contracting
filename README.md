# Supportiano Contracting • ERP Showcase

عرض تفاعلي أولي لنظام إدارة التطوير العقاري **Supportiano Contracting**، باللغة العربية، يدعم الويب والموبايل.

## 👀 ما الذي يعمل في الديمو؟

- لوحة تحكم والمشروعات والمراحل.
- يوميات ومصنعيات الصنايعية.
- المخازن وإذن صرف المواد الافتراضي.
- المقاولون والمستخلصات.
- الوحدات والحجز والأقساط والتقارير.

> **تنبيه:** مشروع استعراضي فقط: كل البيانات افتراضية، والتغييرات مؤقتة في ذاكرة الصفحة، ولا يوجد Backend أو تسجيل دخول أو قيود محاسبية فعلية.

## تشغيل محلي

لأن الواجهة Static HTML، افتح `index.html` مباشرة أو شغّل خادم محلي:

```bash
python3 -m http.server 8080
```

ثم افتح `http://localhost:8080`.

## GitHub Pages

1. أنشئ مستودعاً باسم `supportiano-contracting`.
2. ارفع الملفات إلى فرع `main` (لا تضع مجلد المشروع نفسه أعلى الملفات: يجب أن يكون `index.html` في الجذر).
3. من Settings → Pages → Build and deployment، اختر **GitHub Actions**.
4. الـworkflow موجود في `.github/workflows/pages.yml`، ويعمل مع كل push إلى `main`.
5. بعد نجاح Actions، ستكون الصفحة عادةً على الرابط:
   `https://A-sabry87.github.io/supportiano-contracting/`.

**ملاحظة:** العنوان أعلاه متوقع، ولا يصبح رابطاً حقيقياً قبل إنشاء المستودع والرفع ونجاح النشر.

## تشغيل على VPS

مع Docker:

```bash
docker compose up -d --build
```

تظهر الواجهة على `http://YOUR_SERVER_IP:8088`. استخدم Reverse Proxy وHTTPS ودومين مخصص قبل مشاركة نسخة إنتاجية عامة. البورت متغير عبر `SHOWCASE_PORT`.

## الملفات

- `index.html`: صفحة الاستقبال للعميل.
- `demo.html`: واجهة ERP تجريبية تفاعلية.
- `database/schema.sql`: مخطط PostgreSQL مرجعي للمشروع المستقبلي، **غير مستخدم في الديمو**.
- `.github/workflows/pages.yml`: نشر تلقائي للموقع الثابت عبر GitHub Pages.
- `Dockerfile` و`compose.yaml`: خادم Nginx اختياري للاستعراض.

## قبل التشغيل الحقيقي

إكمال API وAuth وRBAC وPostgreSQL، المعاملات والقيود المزدوجة، المخازن الدائمة، مراقبة تعارض حجز الوحدات، ملفات المرفقات، والتدقيق والنسخ الاحتياطي واختبارات الأمان. لا تستخدم نسخة Showcase لإدخال بيانات فعلية.