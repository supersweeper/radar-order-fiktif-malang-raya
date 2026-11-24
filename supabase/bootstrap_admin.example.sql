-- CONTOH. Bukan migrasi (sengaja di luar supabase/migrations/).
-- Menunjuk Admin Utama PERTAMA. Jalankan SEKALI oleh pemilik proyek di Supabase SQL Editor
-- (peran postgres) setelah akun tersebut mendaftar dan memverifikasi emailnya.
-- Ganti UUID dengan id akun di Authentication > Users. Jangan menyimpan UUID asli di repo.
-- Setelah ini, penunjukan peran lain dilakukan Admin Utama lewat public.admin_set_role().
insert into public.user_roles (user_id, role, reason)
values ('00000000-0000-0000-0000-000000000000', 'admin_utama', 'bootstrap oleh pemilik proyek');
-- Penunjukan ini otomatis tercatat di audit_logs (aktor: system).
