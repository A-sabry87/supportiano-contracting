-- Real Estate Developer ERP: PostgreSQL 15+ reference schema
-- Designed for project-led development, construction costing, sales and installment collections.
-- Reference DDL, not a complete production migration. Access control, posting,
-- stock valuation, balanced-journal checks and all transitions must be implemented transactionally.
-- All amounts are in document currency; exchange rates are captured for accounting conversions.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE SCHEMA IF NOT EXISTS erp;
SET search_path = erp, public;

CREATE TYPE doc_status AS ENUM ('draft','submitted','approved','posted','cancelled');
CREATE TYPE project_status AS ENUM ('planning','active','on_hold','completed','closed');
CREATE TYPE unit_status AS ENUM ('available','held','reserved','contracted','delivered','blocked');
CREATE TYPE movement_kind AS ENUM ('receipt','issue','return_in','return_out','transfer_in','transfer_out','adjustment_in','adjustment_out');
CREATE TYPE account_type AS ENUM ('asset','liability','equity','revenue','expense');
CREATE TYPE counterparty_kind AS ENUM ('customer','supplier','contractor','worker','other');
CREATE TYPE labor_calc_mode AS ENUM ('daily','hourly','unit','lump_sum');

-- 01. Company, access control, approval and documents
CREATE TABLE companies (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), code text NOT NULL UNIQUE,
  legal_name text NOT NULL, trade_name text, tax_number text,
  base_currency char(3) NOT NULL DEFAULT 'EGP', fiscal_year_start_month int NOT NULL DEFAULT 1
    CHECK (fiscal_year_start_month BETWEEN 1 AND 12),
  active boolean NOT NULL DEFAULT true, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE app_users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), full_name text NOT NULL,
  email text NOT NULL UNIQUE, password_hash text, is_active boolean NOT NULL DEFAULT true,
  mfa_enabled boolean NOT NULL DEFAULT false, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE roles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), company_id uuid NOT NULL REFERENCES companies(id),
  code text NOT NULL, name_ar text NOT NULL, UNIQUE(company_id,code), UNIQUE(id,company_id)
);
CREATE TABLE permissions (code text PRIMARY KEY, description text NOT NULL);
CREATE TABLE role_permissions (
  role_id uuid NOT NULL REFERENCES roles(id), permission_code text NOT NULL REFERENCES permissions(code),
  PRIMARY KEY (role_id,permission_code)
);
CREATE TABLE user_company_roles (
  user_id uuid NOT NULL REFERENCES app_users(id), company_id uuid NOT NULL REFERENCES companies(id),
  role_id uuid NOT NULL, PRIMARY KEY(user_id,company_id,role_id),
  FOREIGN KEY(role_id,company_id) REFERENCES roles(id,company_id)
);
CREATE TABLE file_attachments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), company_id uuid NOT NULL REFERENCES companies(id),
  object_type text NOT NULL, object_id uuid NOT NULL, original_name text NOT NULL,
  storage_key text NOT NULL UNIQUE, mime_type text NOT NULL, size_bytes bigint NOT NULL CHECK(size_bytes>=0),
  sha256 text, uploaded_by uuid REFERENCES app_users(id), uploaded_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE approval_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), company_id uuid NOT NULL REFERENCES companies(id),
  object_type text NOT NULL, object_id uuid NOT NULL, stage_number int NOT NULL DEFAULT 1,
  requested_by uuid REFERENCES app_users(id), decided_by uuid REFERENCES app_users(id),
  decision text NOT NULL DEFAULT 'pending' CHECK(decision IN ('pending','approved','rejected')),
  reason text, requested_at timestamptz NOT NULL DEFAULT now(), decided_at timestamptz
);
CREATE TABLE audit_events (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, company_id uuid NOT NULL REFERENCES companies(id),
  actor_id uuid REFERENCES app_users(id), entity_type text NOT NULL, entity_id uuid,
  action text NOT NULL, before_data jsonb, after_data jsonb, request_id text,
  occurred_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX audit_by_entity ON audit_events(company_id,entity_type,entity_id,occurred_at DESC);

-- 02. Projects, real estate geometry, WBS and budgets
CREATE TABLE projects (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), company_id uuid NOT NULL REFERENCES companies(id),
  project_code text NOT NULL, name text NOT NULL, address text, city text,
  planned_start date, planned_finish date, actual_start date, actual_finish date,
  status project_status NOT NULL DEFAULT 'planning', manager_user_id uuid REFERENCES app_users(id),
  target_budget numeric(18,2) CHECK(target_budget>=0), created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(company_id,project_code), UNIQUE(id,company_id)
);
CREATE TABLE land_parcels (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), project_id uuid NOT NULL REFERENCES projects(id),
  parcel_number text, area_sqm numeric(18,3) CHECK(area_sqm>0),
  purchase_date date, contract_price numeric(18,2) CHECK(contract_price>=0),
  registration_ref text, notes text
);
CREATE TABLE project_phases (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), project_id uuid NOT NULL REFERENCES projects(id),
  phase_code text NOT NULL, name text NOT NULL, sort_order int NOT NULL DEFAULT 0,
  planned_start date, planned_finish date, actual_start date, actual_finish date,
  progress_percent numeric(5,2) NOT NULL DEFAULT 0 CHECK(progress_percent BETWEEN 0 AND 100),
  UNIQUE(project_id,phase_code)
);
CREATE TABLE buildings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), project_id uuid NOT NULL REFERENCES projects(id),
  building_code text NOT NULL, name text, UNIQUE(project_id,building_code)
);
CREATE TABLE floors (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), building_id uuid NOT NULL REFERENCES buildings(id),
  floor_no int NOT NULL, label text, UNIQUE(building_id,floor_no)
);
CREATE TABLE units (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), project_id uuid NOT NULL REFERENCES projects(id),
  floor_id uuid REFERENCES floors(id), unit_code text NOT NULL, unit_type text NOT NULL DEFAULT 'apartment',
  gross_area_sqm numeric(18,3) CHECK(gross_area_sqm>0), net_area_sqm numeric(18,3) CHECK(net_area_sqm>0),
  list_price numeric(18,2) CHECK(list_price>=0), status unit_status NOT NULL DEFAULT 'available',
  delivery_due date, UNIQUE(project_id,unit_code)
);
CREATE TABLE cost_codes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), company_id uuid NOT NULL REFERENCES companies(id),
  code text NOT NULL, name_ar text NOT NULL, category text NOT NULL,
  is_direct boolean NOT NULL DEFAULT true, UNIQUE(company_id,code)
);
CREATE TABLE work_packages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), project_id uuid NOT NULL REFERENCES projects(id),
  phase_id uuid NOT NULL REFERENCES project_phases(id), cost_code_id uuid NOT NULL REFERENCES cost_codes(id),
  building_id uuid REFERENCES buildings(id), unit_id uuid REFERENCES units(id),
  parent_id uuid REFERENCES work_packages(id), title text NOT NULL, unit_of_measure text,
  planned_quantity numeric(18,4) CHECK(planned_quantity>=0),
  actual_quantity numeric(18,4) NOT NULL DEFAULT 0 CHECK(actual_quantity>=0),
  progress_percent numeric(5,2) NOT NULL DEFAULT 0 CHECK(progress_percent BETWEEN 0 AND 100),
  UNIQUE(id,project_id)
);
CREATE TABLE budget_versions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), project_id uuid NOT NULL REFERENCES projects(id),
  revision_no int NOT NULL, status doc_status NOT NULL DEFAULT 'draft',
  approved_by uuid REFERENCES app_users(id), approved_at timestamptz,
  UNIQUE(project_id,revision_no)
);
CREATE TABLE budget_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), budget_version_id uuid NOT NULL REFERENCES budget_versions(id),
  work_package_id uuid REFERENCES work_packages(id), cost_code_id uuid NOT NULL REFERENCES cost_codes(id),
  description text, quantity numeric(18,4) NOT NULL DEFAULT 1 CHECK(quantity>=0),
  unit_cost numeric(18,4) NOT NULL DEFAULT 0 CHECK(unit_cost>=0),
  budget_amount numeric(18,2) GENERATED ALWAYS AS (round(quantity * unit_cost,2)) STORED
);

-- 03. Parties and labor
CREATE TABLE counterparties (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), company_id uuid NOT NULL REFERENCES companies(id),
  party_code text NOT NULL, display_name text NOT NULL, phone text, email text,
  tax_number text, national_id_reference text, address text, active boolean NOT NULL DEFAULT true,
  UNIQUE(company_id,party_code), UNIQUE(id,company_id)
);
CREATE TABLE counterparty_types (
  party_id uuid NOT NULL REFERENCES counterparties(id), kind counterparty_kind NOT NULL,
  PRIMARY KEY(party_id,kind)
);
CREATE TABLE labor_agreements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), project_id uuid NOT NULL REFERENCES projects(id),
  worker_id uuid NOT NULL REFERENCES counterparties(id), work_package_id uuid REFERENCES work_packages(id),
  calc_mode labor_calc_mode NOT NULL, rate numeric(18,2) NOT NULL CHECK(rate>=0),
  currency char(3) NOT NULL DEFAULT 'EGP', valid_from date NOT NULL, valid_to date,
  CHECK(valid_to IS NULL OR valid_to>=valid_from)
);
CREATE TABLE labor_timesheets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), agreement_id uuid NOT NULL REFERENCES labor_agreements(id),
  work_date date NOT NULL, quantity numeric(12,3) NOT NULL CHECK(quantity>0),
  quantity_unit text NOT NULL, calculated_amount numeric(18,2) NOT NULL CHECK(calculated_amount>=0),
  work_package_id uuid REFERENCES work_packages(id), status doc_status NOT NULL DEFAULT 'draft',
  approved_by uuid REFERENCES app_users(id), approved_at timestamptz,
  UNIQUE NULLS NOT DISTINCT (agreement_id,work_date,work_package_id)
);
CREATE TABLE labor_advances (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), agreement_id uuid NOT NULL REFERENCES labor_agreements(id),
  amount numeric(18,2) NOT NULL CHECK(amount>0), voucher_id uuid,
  advanced_at date NOT NULL, reason text
);
CREATE TABLE labor_settlements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), agreement_id uuid NOT NULL REFERENCES labor_agreements(id),
  period_from date NOT NULL, period_to date NOT NULL, gross_earned numeric(18,2) NOT NULL CHECK(gross_earned>=0),
  deductions numeric(18,2) NOT NULL DEFAULT 0 CHECK(deductions>=0),
  advances_applied numeric(18,2) NOT NULL DEFAULT 0 CHECK(advances_applied>=0),
  net_due numeric(18,2) NOT NULL, status doc_status NOT NULL DEFAULT 'draft',
  CHECK(period_to>=period_from), CHECK(net_due = gross_earned-deductions-advances_applied)
);

-- 04. Materials procurement and perpetual stock ledger
CREATE TABLE materials (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), company_id uuid NOT NULL REFERENCES companies(id),
  sku text NOT NULL, name_ar text NOT NULL, base_uom text NOT NULL,
  reorder_level numeric(18,4) NOT NULL DEFAULT 0 CHECK(reorder_level>=0),
  is_active boolean NOT NULL DEFAULT true, UNIQUE(company_id,sku)
);
CREATE TABLE material_uom_conversions (
  material_id uuid NOT NULL REFERENCES materials(id), from_uom text NOT NULL,
  factor_to_base numeric(18,8) NOT NULL CHECK(factor_to_base>0),
  PRIMARY KEY(material_id,from_uom)
);
CREATE TABLE warehouses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), company_id uuid NOT NULL REFERENCES companies(id),
  project_id uuid REFERENCES projects(id), code text NOT NULL, name text NOT NULL,
  manager_user_id uuid REFERENCES app_users(id), UNIQUE(company_id,code)
);
CREATE TABLE purchase_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), company_id uuid NOT NULL REFERENCES companies(id),
  project_id uuid REFERENCES projects(id), work_package_id uuid REFERENCES work_packages(id),
  request_no text NOT NULL, requester_id uuid REFERENCES app_users(id),
  status doc_status NOT NULL DEFAULT 'draft', requested_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(company_id,request_no)
);
CREATE TABLE purchase_request_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), request_id uuid NOT NULL REFERENCES purchase_requests(id),
  material_id uuid NOT NULL REFERENCES materials(id), quantity numeric(18,4) NOT NULL CHECK(quantity>0),
  required_by date, notes text
);
CREATE TABLE purchase_orders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), company_id uuid NOT NULL REFERENCES companies(id),
  project_id uuid REFERENCES projects(id), supplier_id uuid NOT NULL REFERENCES counterparties(id),
  request_id uuid REFERENCES purchase_requests(id), po_no text NOT NULL,
  ordered_at date NOT NULL, currency char(3) NOT NULL DEFAULT 'EGP',
  status doc_status NOT NULL DEFAULT 'draft', UNIQUE(company_id,po_no)
);
CREATE TABLE purchase_order_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), po_id uuid NOT NULL REFERENCES purchase_orders(id),
  material_id uuid NOT NULL REFERENCES materials(id), work_package_id uuid REFERENCES work_packages(id),
  quantity numeric(18,4) NOT NULL CHECK(quantity>0),
  unit_price numeric(18,4) NOT NULL CHECK(unit_price>=0),
  discount_amount numeric(18,2) NOT NULL DEFAULT 0 CHECK(discount_amount>=0),
  tax_amount numeric(18,2) NOT NULL DEFAULT 0 CHECK(tax_amount>=0)
);
CREATE TABLE goods_receipts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), company_id uuid NOT NULL REFERENCES companies(id),
  po_id uuid REFERENCES purchase_orders(id), warehouse_id uuid NOT NULL REFERENCES warehouses(id),
  grn_no text NOT NULL, received_at timestamptz NOT NULL DEFAULT now(),
  status doc_status NOT NULL DEFAULT 'draft', UNIQUE(company_id,grn_no)
);
CREATE TABLE goods_receipt_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), receipt_id uuid NOT NULL REFERENCES goods_receipts(id),
  po_line_id uuid REFERENCES purchase_order_lines(id), material_id uuid NOT NULL REFERENCES materials(id),
  accepted_qty numeric(18,4) NOT NULL CHECK(accepted_qty>0),
  rejected_qty numeric(18,4) NOT NULL DEFAULT 0 CHECK(rejected_qty>=0),
  unit_cost numeric(18,4) NOT NULL CHECK(unit_cost>=0)
);
CREATE TABLE supplier_invoices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), company_id uuid NOT NULL REFERENCES companies(id),
  supplier_id uuid NOT NULL REFERENCES counterparties(id), po_id uuid REFERENCES purchase_orders(id),
  receipt_id uuid REFERENCES goods_receipts(id), supplier_invoice_no text NOT NULL,
  invoice_date date NOT NULL, due_date date, currency char(3) NOT NULL DEFAULT 'EGP',
  total_net numeric(18,2) NOT NULL CHECK(total_net>=0),
  total_tax numeric(18,2) NOT NULL DEFAULT 0 CHECK(total_tax>=0),
  status doc_status NOT NULL DEFAULT 'draft',
  UNIQUE(company_id,supplier_id,supplier_invoice_no)
);
CREATE TABLE stock_movements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), company_id uuid NOT NULL REFERENCES companies(id),
  warehouse_id uuid NOT NULL REFERENCES warehouses(id), material_id uuid NOT NULL REFERENCES materials(id),
  project_id uuid REFERENCES projects(id), work_package_id uuid REFERENCES work_packages(id),
  recipient_party_id uuid REFERENCES counterparties(id), kind movement_kind NOT NULL,
  document_type text NOT NULL, document_id uuid NOT NULL, document_line_id uuid,
  moved_at timestamptz NOT NULL DEFAULT now(),
  quantity_base numeric(18,4) NOT NULL CHECK(quantity_base>0),
  unit_cost_base numeric(18,6) NOT NULL CHECK(unit_cost_base>=0),
  posted_by uuid REFERENCES app_users(id),
  UNIQUE NULLS NOT DISTINCT (document_type,document_id,document_line_id,kind)
);
CREATE INDEX stock_by_item ON stock_movements(company_id,warehouse_id,material_id,moved_at);

-- 05. Contractor contracts, certified quantities and retained amounts
CREATE TABLE contractor_contracts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), company_id uuid NOT NULL REFERENCES companies(id),
  project_id uuid NOT NULL REFERENCES projects(id), contractor_id uuid NOT NULL REFERENCES counterparties(id),
  contract_no text NOT NULL, signed_at date, work_package_id uuid REFERENCES work_packages(id),
  contract_amount numeric(18,2) NOT NULL CHECK(contract_amount>=0),
  advance_amount numeric(18,2) NOT NULL DEFAULT 0 CHECK(advance_amount>=0),
  retention_percent numeric(5,2) NOT NULL DEFAULT 0 CHECK(retention_percent BETWEEN 0 AND 100),
  status doc_status NOT NULL DEFAULT 'draft', UNIQUE(company_id,contract_no)
);
CREATE TABLE contractor_contract_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), contract_id uuid NOT NULL REFERENCES contractor_contracts(id),
  work_package_id uuid REFERENCES work_packages(id), description text NOT NULL, uom text,
  contracted_qty numeric(18,4) CHECK(contracted_qty>0),
  unit_rate numeric(18,4) NOT NULL CHECK(unit_rate>=0)
);
CREATE TABLE contractor_certificates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), contract_id uuid NOT NULL REFERENCES contractor_contracts(id),
  certificate_no text NOT NULL, period_from date, period_to date,
  gross_amount numeric(18,2) NOT NULL CHECK(gross_amount>=0),
  retention_amount numeric(18,2) NOT NULL DEFAULT 0 CHECK(retention_amount>=0),
  advance_recovery numeric(18,2) NOT NULL DEFAULT 0 CHECK(advance_recovery>=0),
  other_deductions numeric(18,2) NOT NULL DEFAULT 0 CHECK(other_deductions>=0),
  payable_amount numeric(18,2) NOT NULL,
  status doc_status NOT NULL DEFAULT 'draft',
  CHECK(payable_amount>=0),
  CHECK(payable_amount=gross_amount-retention_amount-advance_recovery-other_deductions),
  UNIQUE(contract_id,certificate_no)
);
CREATE TABLE contractor_certificate_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), certificate_id uuid NOT NULL REFERENCES contractor_certificates(id),
  contract_line_id uuid REFERENCES contractor_contract_lines(id),
  current_quantity numeric(18,4) NOT NULL CHECK(current_quantity>=0),
  unit_rate numeric(18,4) NOT NULL CHECK(unit_rate>=0)
);

-- 06. Buyers, reservations, contracts, installments and delivery
CREATE TABLE unit_reservations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), company_id uuid NOT NULL REFERENCES companies(id),
  unit_id uuid NOT NULL REFERENCES units(id), customer_id uuid NOT NULL REFERENCES counterparties(id),
  reserved_at timestamptz NOT NULL DEFAULT now(), expires_at timestamptz,
  deposit_amount numeric(18,2) NOT NULL DEFAULT 0 CHECK(deposit_amount>=0),
  status text NOT NULL DEFAULT 'active' CHECK(status IN ('active','converted','expired','cancelled'))
);
-- Prevent multiple currently active reservations for one unit.
CREATE UNIQUE INDEX uq_active_reservation_per_unit ON unit_reservations(unit_id) WHERE status='active';
CREATE TABLE sales_contracts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), company_id uuid NOT NULL REFERENCES companies(id),
  project_id uuid NOT NULL REFERENCES projects(id), unit_id uuid NOT NULL REFERENCES units(id),
  customer_id uuid NOT NULL REFERENCES counterparties(id), reservation_id uuid REFERENCES unit_reservations(id),
  contract_no text NOT NULL, signed_on date NOT NULL,
  sale_price numeric(18,2) NOT NULL CHECK(sale_price>0),
  discount_amount numeric(18,2) NOT NULL DEFAULT 0 CHECK(discount_amount>=0),
  currency char(3) NOT NULL DEFAULT 'EGP', status text NOT NULL DEFAULT 'draft'
    CHECK(status IN ('draft','active','cancelled','completed')),
  recognition_policy text NOT NULL DEFAULT 'review_required',
  UNIQUE(company_id,contract_no), CHECK(discount_amount<=sale_price)
);
CREATE UNIQUE INDEX uq_active_sale_per_unit ON sales_contracts(unit_id)
  WHERE status IN ('draft','active','completed');
CREATE TABLE installment_schedules (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), contract_id uuid NOT NULL REFERENCES sales_contracts(id),
  installment_no int NOT NULL CHECK(installment_no>0), due_on date NOT NULL,
  principal_amount numeric(18,2) NOT NULL CHECK(principal_amount>=0),
  fee_amount numeric(18,2) NOT NULL DEFAULT 0 CHECK(fee_amount>=0),
  status text NOT NULL DEFAULT 'unpaid' CHECK(status IN ('unpaid','partial','paid','waived')),
  UNIQUE(contract_id,installment_no)
);
CREATE TABLE customer_receipts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), company_id uuid NOT NULL REFERENCES companies(id),
  customer_id uuid NOT NULL REFERENCES counterparties(id), contract_id uuid REFERENCES sales_contracts(id),
  receipt_no text NOT NULL, received_at timestamptz NOT NULL DEFAULT now(),
  amount numeric(18,2) NOT NULL CHECK(amount>0), currency char(3) NOT NULL DEFAULT 'EGP',
  payment_method text NOT NULL, status doc_status NOT NULL DEFAULT 'draft',
  UNIQUE(company_id,receipt_no)
);
CREATE TABLE receipt_allocations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), receipt_id uuid NOT NULL REFERENCES customer_receipts(id),
  installment_id uuid NOT NULL REFERENCES installment_schedules(id),
  allocated_amount numeric(18,2) NOT NULL CHECK(allocated_amount>0),
  UNIQUE(receipt_id,installment_id)
);
CREATE TABLE unit_handovers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), unit_id uuid NOT NULL REFERENCES units(id),
  contract_id uuid NOT NULL REFERENCES sales_contracts(id), handed_over_on date NOT NULL,
  approved_by uuid REFERENCES app_users(id), handover_notes text
);

-- 07. General ledger, money documents, cash and banks
CREATE TABLE gl_accounts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), company_id uuid NOT NULL REFERENCES companies(id),
  account_code text NOT NULL, name_ar text NOT NULL, type account_type NOT NULL,
  parent_id uuid REFERENCES gl_accounts(id), is_postable boolean NOT NULL DEFAULT true,
  is_active boolean NOT NULL DEFAULT true, UNIQUE(company_id,account_code)
);
CREATE TABLE fiscal_periods (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), company_id uuid NOT NULL REFERENCES companies(id),
  period_code text NOT NULL, starts_on date NOT NULL, ends_on date NOT NULL,
  is_closed boolean NOT NULL DEFAULT false, closed_at timestamptz,
  CHECK(ends_on>=starts_on), UNIQUE(company_id,period_code)
);
CREATE TABLE money_accounts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), company_id uuid NOT NULL REFERENCES companies(id),
  name text NOT NULL, kind text NOT NULL CHECK(kind IN ('cash','bank','mobile_wallet')),
  gl_account_id uuid NOT NULL REFERENCES gl_accounts(id), currency char(3) NOT NULL DEFAULT 'EGP',
  bank_name text, masked_account_number text, is_active boolean NOT NULL DEFAULT true
);
CREATE TABLE cash_vouchers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), company_id uuid NOT NULL REFERENCES companies(id),
  voucher_no text NOT NULL, direction text NOT NULL CHECK(direction IN ('in','out','transfer')),
  money_account_id uuid NOT NULL REFERENCES money_accounts(id), destination_money_account_id uuid REFERENCES money_accounts(id),
  counterparty_id uuid REFERENCES counterparties(id), project_id uuid REFERENCES projects(id),
  work_package_id uuid REFERENCES work_packages(id), source_type text, source_id uuid,
  voucher_date date NOT NULL, amount numeric(18,2) NOT NULL CHECK(amount>0),
  description text, status doc_status NOT NULL DEFAULT 'draft',
  idempotency_key text UNIQUE, UNIQUE(company_id,voucher_no),
  CHECK(direction<>'transfer' OR destination_money_account_id IS NOT NULL)
);
ALTER TABLE labor_advances ADD CONSTRAINT fk_labor_advance_voucher
  FOREIGN KEY (voucher_id) REFERENCES cash_vouchers(id);
CREATE TABLE journal_entries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), company_id uuid NOT NULL REFERENCES companies(id),
  period_id uuid NOT NULL REFERENCES fiscal_periods(id), journal_no text NOT NULL,
  posting_date date NOT NULL, currency char(3) NOT NULL DEFAULT 'EGP',
  exchange_rate numeric(20,8) NOT NULL DEFAULT 1 CHECK(exchange_rate>0),
  source_type text NOT NULL, source_id uuid, memo text,
  status doc_status NOT NULL DEFAULT 'draft', posted_by uuid REFERENCES app_users(id),
  posted_at timestamptz, reversal_of uuid REFERENCES journal_entries(id),
  idempotency_key text UNIQUE, UNIQUE(company_id,journal_no)
);
CREATE TABLE journal_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), journal_id uuid NOT NULL REFERENCES journal_entries(id),
  account_id uuid NOT NULL REFERENCES gl_accounts(id), line_no int NOT NULL,
  debit numeric(18,2) NOT NULL DEFAULT 0 CHECK(debit>=0),
  credit numeric(18,2) NOT NULL DEFAULT 0 CHECK(credit>=0),
  project_id uuid REFERENCES projects(id), phase_id uuid REFERENCES project_phases(id),
  work_package_id uuid REFERENCES work_packages(id), unit_id uuid REFERENCES units(id),
  counterparty_id uuid REFERENCES counterparties(id), narration text,
  CHECK ((debit>0 AND credit=0) OR (credit>0 AND debit=0)),
  UNIQUE(journal_id,line_no)
);
CREATE INDEX journal_by_account ON journal_lines(account_id,journal_id);
CREATE TABLE cost_allocations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), company_id uuid NOT NULL REFERENCES companies(id),
  source_journal_line_id uuid NOT NULL REFERENCES journal_lines(id),
  project_id uuid NOT NULL REFERENCES projects(id), work_package_id uuid REFERENCES work_packages(id),
  unit_id uuid REFERENCES units(id), allocation_percent numeric(9,6) CHECK(allocation_percent>0 AND allocation_percent<=100),
  allocated_amount numeric(18,2) NOT NULL CHECK(allocated_amount>=0)
);
CREATE TABLE inventory_cost_layers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), company_id uuid NOT NULL REFERENCES companies(id),
  material_id uuid NOT NULL REFERENCES materials(id), warehouse_id uuid NOT NULL REFERENCES warehouses(id),
  receipt_movement_id uuid NOT NULL REFERENCES stock_movements(id),
  original_qty numeric(18,4) NOT NULL CHECK(original_qty>0),
  remaining_qty numeric(18,4) NOT NULL CHECK(remaining_qty>=0),
  unit_cost numeric(18,6) NOT NULL CHECK(unit_cost>=0),
  CHECK(remaining_qty<=original_qty)
);

-- Derived, read-only views. Do not edit their balances directly.
CREATE VIEW vw_stock_on_hand AS
SELECT company_id,warehouse_id,material_id,
       sum(CASE WHEN kind IN ('receipt','return_in','transfer_in','adjustment_in')
           THEN quantity_base ELSE -quantity_base END) AS on_hand_base_qty
FROM stock_movements GROUP BY company_id,warehouse_id,material_id;
CREATE VIEW vw_gl_balance AS
SELECT j.company_id,l.account_id,sum(l.debit) AS total_debit,sum(l.credit) AS total_credit,
       sum(l.debit-l.credit) AS net_debit
FROM journal_lines l JOIN journal_entries j ON j.id=l.journal_id
WHERE j.status='posted'
GROUP BY j.company_id,l.account_id;
CREATE VIEW vw_installment_collections AS
SELECT i.id AS installment_id, i.contract_id, i.principal_amount+i.fee_amount AS due_amount,
       coalesce(sum(CASE WHEN r.status='posted' THEN a.allocated_amount ELSE 0 END),0) AS collected_amount,
       i.principal_amount+i.fee_amount - coalesce(sum(CASE WHEN r.status='posted' THEN a.allocated_amount ELSE 0 END),0) AS outstanding_amount
FROM installment_schedules i
LEFT JOIN receipt_allocations a ON a.installment_id=i.id
LEFT JOIN customer_receipts r ON r.id=a.receipt_id
GROUP BY i.id,i.contract_id,i.principal_amount,i.fee_amount;

-- Important cross-row/cross-company invariants (enforce via application services or
-- database constraint triggers):
-- 1. All referenced project/phase/work-package/unit belongs to same company/project.
-- 2. POST only when journal_lines sum(debit)=sum(credit), >=2 lines, period open.
-- 3. Posted journal/source documents immutable; corrections via reversal documents.
-- 4. No negative stock after any posted issue; lot/layer consumption allocated atomically.
-- 5. No double posting via source_type/source_id and idempotency key; unique numbers atomically.
-- 6. Sum receipt allocations <= posted receipt amount and <= installment balances.
-- 7. Total installment principal = contract net price (unless documented schedule differences).
-- 8. No simultaneous active reservation + active contract for the same unit.
-- 9. Cannot oversettle labor advances, duplicate progress quantities, or release retained amounts twice.
-- 10. Apply company/project row-level authorization to every query, including reports and attachments.
-- 11. Only journal lines from qualifying costs contribute to WIP/project cost; avoid counting PO + goods receipt + issued stock twice.
-- 12. Closing an accounting period blocks late backdated posting except with authorized reopening.
COMMIT;