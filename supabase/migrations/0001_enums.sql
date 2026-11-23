-- 0001: tipe enum dasar sesuai SRS v0.1. Aman dijalankan ulang.
-- Belum membuat tabel; tabel dibuat per fase (lihat ANALISIS_GAP_SRS_v0.1.md).

do $$ begin
  create type public.app_role as enum ('user','verifier','moderator','admin_utama');
exception when duplicate_object then null; end $$;

do $$ begin
  -- SRS 4.2
  create type public.report_status as enum
    ('draft','pending','under_review','needs_revision','verified','rejected','cancelled');
exception when duplicate_object then null; end $$;

do $$ begin
  -- SRS 4.1 (BR-62)
  create type public.evidence_type as enum
    ('EV-01','EV-02','EV-03','EV-04','EV-05','EV-06');
exception when duplicate_object then null; end $$;

do $$ begin
  -- FR-29
  create type public.sanction_type as enum
    ('warning','feature_restriction','temporary_suspension','permanent_ban');
exception when duplicate_object then null; end $$;
