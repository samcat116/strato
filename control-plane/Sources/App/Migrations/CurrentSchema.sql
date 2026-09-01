--
-- PostgreSQL database dump
--

-- Dumped from database version 16.14 (Debian 16.14-1.pgdg13+1)
-- Dumped by pg_dump version 16.14 (Debian 16.14-1.pgdg13+1)


--
-- Name: agent_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.agent_status AS ENUM (
    'online',
    'offline',
    'connecting',
    'error'
);


--
-- Name: org_trust_domain_phase; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.org_trust_domain_phase AS ENUM (
    'pending',
    'provisioning',
    'active',
    'failed',
    'deleting'
);


--
-- Name: workload_registration_kind; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.workload_registration_kind AS ENUM (
    'agent',
    'service_account',
    'workload'
);


--
-- Name: resource_events_reject_row_change(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.resource_events_reject_row_change() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    RAISE EXCEPTION 'resource_events is append-only; % is not permitted', TG_OP;
END;
$$;


--
-- Name: release_mac_address_allocation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.release_mac_address_allocation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    DELETE FROM public.mac_address_allocations
    WHERE mac_address = lower(OLD.mac_address)
      AND owner_kind = TG_ARGV[0]
      AND owner_id = OLD.id;
    RETURN OLD;
END;
$$;




--
-- Name: _fluent_enums; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public._fluent_enums (
    id uuid NOT NULL,
    name text NOT NULL,
    "case" text NOT NULL
);


--
-- Name: _fluent_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public._fluent_sessions (
    id uuid NOT NULL,
    key text NOT NULL,
    data jsonb NOT NULL
);


--
-- Name: account_claim_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.account_claim_tokens (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    token_hash text NOT NULL,
    token_prefix text NOT NULL,
    expires_at timestamp with time zone,
    claimed_at timestamp with time zone,
    created_by_id uuid,
    created_at timestamp with time zone
);


--
-- Name: agent_enrollments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_enrollments (
    id uuid NOT NULL,
    agent_name text NOT NULL,
    spiffe_id text NOT NULL,
    is_used boolean NOT NULL,
    site_id uuid,
    organization_id uuid,
    organizational_unit_id uuid,
    expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone,
    used_at timestamp with time zone,
    trust_domain text NOT NULL
);


--
-- Name: agent_workload_claims; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_workload_claims (
    id uuid NOT NULL,
    agent_id text NOT NULL,
    resource_kind text NOT NULL,
    resource_id uuid NOT NULL,
    disposition text NOT NULL,
    tombstone_generation bigint,
    reason text,
    observed_generation bigint DEFAULT 0 NOT NULL,
    observed_status text,
    first_seen_at timestamp with time zone,
    last_seen_at timestamp with time zone,
    CONSTRAINT ck_agent_workload_claims_disposition_enum CHECK ((disposition = ANY (ARRAY['tombstoned'::text, 'held'::text]))),
    CONSTRAINT ck_agent_workload_claims_resource_kind_enum CHECK ((resource_kind = ANY (ARRAY['virtual_machine'::text, 'sandbox'::text, 'volume'::text, 'volume_snapshot'::text, 'vm_checkpoint'::text, 'sandbox_snapshot'::text])))
);


--
-- Name: agents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agents (
    id uuid NOT NULL,
    name text NOT NULL,
    hostname text NOT NULL,
    version text NOT NULL,
    status public.agent_status NOT NULL,
    total_cpu bigint NOT NULL,
    total_memory bigint NOT NULL,
    total_disk bigint NOT NULL,
    available_cpu bigint NOT NULL,
    available_memory bigint NOT NULL,
    available_disk bigint NOT NULL,
    last_heartbeat timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    architecture text,
    hypervisors jsonb[] DEFAULT '{}'::jsonb[] NOT NULL,
    network_capability text,
    site_id uuid NOT NULL,
    wire_protocol_version bigint,
    organization_id uuid,
    organizational_unit_id uuid,
    operating_system text,
    sandbox_capable boolean DEFAULT false NOT NULL,
    auto_update boolean DEFAULT false NOT NULL,
    update_desired_version text,
    update_attempted_at timestamp with time zone,
    update_blocked_reason text,
    update_failure_reason text,
    host_info jsonb,
    tpm_capable boolean DEFAULT false NOT NULL,
    trust_domain text NOT NULL,
    teardown_refusal_reason text,
    teardown_refused_at timestamp with time zone,
    update_assignment_source text,
    update_artifact_override jsonb,
    manifest_status_reason text,
    manifest_status_at timestamp with time zone,
    manifest_inventory_complete boolean,
    sandbox_networking_capable boolean DEFAULT false NOT NULL,
    resolver_capable boolean DEFAULT false NOT NULL
);


--
-- Name: api_keys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.api_keys (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    name text NOT NULL,
    key_hash text NOT NULL,
    key_prefix text NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    expires_at timestamp with time zone,
    last_used_at timestamp with time zone,
    last_used_ip text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    restriction_actions text[] NOT NULL,
    restriction_node_type text,
    restriction_node_id uuid
);


--
-- Name: app_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.app_settings (
    id uuid NOT NULL,
    key text NOT NULL,
    value text NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: audit_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_events (
    id uuid NOT NULL,
    event_type text NOT NULL,
    user_id uuid,
    username text,
    api_key_id uuid,
    organization_id uuid,
    method text,
    path text,
    status bigint,
    resource_type text,
    resource_id text,
    action text,
    source_ip text,
    admin_bypass boolean DEFAULT false NOT NULL,
    metadata text,
    created_at timestamp with time zone
);


--
-- Name: authentication_challenges; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.authentication_challenges (
    id uuid NOT NULL,
    challenge text NOT NULL,
    user_id uuid,
    operation text NOT NULL,
    created_at timestamp with time zone,
    expires_at timestamp with time zone
);


--
-- Name: cli_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cli_sessions (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    client_name text NOT NULL,
    access_token_hash text NOT NULL,
    access_token_prefix text NOT NULL,
    access_token_expires_at timestamp with time zone NOT NULL,
    refresh_token_hash text NOT NULL,
    previous_refresh_token_hash text,
    refresh_token_expires_at timestamp with time zone NOT NULL,
    revoked_at timestamp with time zone,
    last_used_at timestamp with time zone,
    last_used_ip text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    restriction_actions text[] NOT NULL,
    restriction_node_type text,
    restriction_node_id uuid
);


--
-- Name: dns_records; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.dns_records (
    id uuid NOT NULL,
    zone_id uuid NOT NULL,
    name text NOT NULL,
    type text NOT NULL,
    value text NOT NULL,
    ttl bigint NOT NULL,
    view text DEFAULT 'both'::text NOT NULL,
    created_by_id uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    CONSTRAINT ck_dns_records_name_length CHECK ((char_length(name) <= 253)),
    CONSTRAINT ck_dns_records_type_enum CHECK ((type = ANY (ARRAY['A'::text, 'AAAA'::text, 'CNAME'::text, 'TXT'::text, 'SRV'::text, 'PTR'::text]))),
    CONSTRAINT ck_dns_records_value_length CHECK ((char_length(value) <= 4096)),
    CONSTRAINT ck_dns_records_view_enum CHECK ((view = ANY (ARRAY['internal'::text, 'external'::text, 'both'::text])))
);


--
-- Name: dns_zone_networks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.dns_zone_networks (
    id uuid NOT NULL,
    zone_id uuid NOT NULL,
    logical_network_id uuid NOT NULL,
    created_at timestamp with time zone
);


--
-- Name: dns_zones; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.dns_zones (
    id uuid NOT NULL,
    name text NOT NULL,
    description text,
    project_id uuid NOT NULL,
    created_by_id uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    CONSTRAINT ck_dns_zones_description_length CHECK ((char_length(description) <= 4096)),
    CONSTRAINT ck_dns_zones_name_length CHECK ((char_length(name) <= 253))
);


--
-- Name: floating_ip_pools; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.floating_ip_pools (
    id uuid NOT NULL,
    name text NOT NULL,
    cidr text NOT NULL,
    gateway text,
    site_id uuid NOT NULL,
    organization_id uuid,
    organizational_unit_id uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: floating_ips; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.floating_ips (
    id uuid NOT NULL,
    pool_id uuid NOT NULL,
    address text NOT NULL,
    project_id uuid NOT NULL,
    interface_id uuid,
    created_by_id uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: groups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.groups (
    id uuid NOT NULL,
    name text NOT NULL,
    description text NOT NULL,
    organization_id uuid NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    scim_provisioned boolean DEFAULT false NOT NULL,
    CONSTRAINT ck_groups_description_length CHECK ((char_length(description) <= 4096)),
    CONSTRAINT ck_groups_name_length CHECK ((char_length(name) <= 128))
);


--
-- Name: iam_decision_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.iam_decision_logs (
    id uuid NOT NULL,
    request_id text,
    path text,
    method text,
    subject text NOT NULL,
    action text,
    node_type text,
    node_id uuid,
    organization_id uuid,
    decision text NOT NULL,
    determining_policies text,
    tier text,
    cedar_errors text,
    policy_version bigint,
    skipped_conditioned_bindings bigint,
    created_at timestamp with time zone,
    credential_type text,
    credential_id uuid
);


--
-- Name: iam_guardrails; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.iam_guardrails (
    id uuid NOT NULL,
    name text NOT NULL,
    description text,
    node_type text NOT NULL,
    node_id uuid NOT NULL,
    effect text NOT NULL,
    actions text[] NOT NULL,
    principal_match_kind text NOT NULL,
    principal_match_id uuid,
    resource_match_kind text NOT NULL,
    resource_match_value text,
    enabled boolean NOT NULL,
    created_by uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    cedar_text text,
    authored boolean DEFAULT false NOT NULL,
    CONSTRAINT ck_iam_guardrails_description_length CHECK ((char_length(description) <= 4096)),
    CONSTRAINT ck_iam_guardrails_name_length CHECK ((char_length(name) <= 128)),
    CONSTRAINT iam_guardrails_forbid_only CHECK ((effect = 'forbid'::text))
);


--
-- Name: iam_policies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.iam_policies (
    id uuid NOT NULL,
    name text NOT NULL,
    description text,
    owner_type text NOT NULL,
    owner_id uuid NOT NULL,
    cedar_text text NOT NULL,
    effect text NOT NULL,
    enabled boolean NOT NULL,
    created_by uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    CONSTRAINT ck_iam_policies_description_length CHECK ((char_length(description) <= 4096)),
    CONSTRAINT ck_iam_policies_name_length CHECK ((char_length(name) <= 128)),
    CONSTRAINT iam_policies_effect_check CHECK ((effect = ANY (ARRAY['permit'::text, 'forbid'::text])))
);


--
-- Name: iam_policy_set_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.iam_policy_set_versions (
    id uuid NOT NULL,
    version bigint NOT NULL,
    reason text NOT NULL,
    changed_by uuid,
    created_at timestamp with time zone
);


--
-- Name: iam_roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.iam_roles (
    id uuid NOT NULL,
    name text NOT NULL,
    description text,
    owner_type text NOT NULL,
    owner_id uuid NOT NULL,
    cedar_text text NOT NULL,
    actions text[] NOT NULL,
    managed boolean NOT NULL,
    created_by uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    CONSTRAINT ck_iam_roles_description_length CHECK ((char_length(description) <= 4096)),
    CONSTRAINT ck_iam_roles_name_length CHECK ((char_length(name) <= 128))
);


--
-- Name: image_artifacts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.image_artifacts (
    id uuid NOT NULL,
    image_id uuid NOT NULL,
    kind text NOT NULL,
    format text,
    architecture text NOT NULL,
    filename text NOT NULL,
    size bigint DEFAULT '0'::bigint NOT NULL,
    checksum text NOT NULL,
    storage_path text NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    status text DEFAULT 'ready'::text NOT NULL,
    source_url text,
    download_progress bigint,
    error_message text,
    expected_checksum text,
    CONSTRAINT ck_image_artifacts_architecture_enum CHECK ((architecture = ANY (ARRAY['x86_64'::text, 'arm64'::text]))),
    CONSTRAINT ck_image_artifacts_format_enum CHECK ((format = ANY (ARRAY['qcow2'::text, 'raw'::text, 'vmdk'::text, 'vhd'::text, 'vhdx'::text]))),
    CONSTRAINT ck_image_artifacts_kind_enum CHECK ((kind = ANY (ARRAY['disk-image'::text, 'kernel'::text, 'initramfs'::text, 'rootfs'::text]))),
    CONSTRAINT ck_image_artifacts_status_enum CHECK ((status = ANY (ARRAY['pending'::text, 'downloading'::text, 'ready'::text, 'error'::text])))
);


--
-- Name: images; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.images (
    id uuid NOT NULL,
    name text NOT NULL,
    description text NOT NULL,
    project_id uuid NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    default_cpu bigint,
    default_memory bigint,
    default_disk bigint,
    default_cmdline text,
    uploaded_by_id uuid NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    architecture text DEFAULT 'x86_64'::text NOT NULL,
    CONSTRAINT ck_images_architecture_enum CHECK ((architecture = ANY (ARRAY['x86_64'::text, 'arm64'::text]))),
    CONSTRAINT ck_images_description_length CHECK ((char_length(description) <= 4096)),
    CONSTRAINT ck_images_name_length CHECK ((char_length(name) <= 128)),
    CONSTRAINT ck_images_status_enum CHECK ((status = ANY (ARRAY['pending'::text, 'uploading'::text, 'downloading'::text, 'validating'::text, 'ready'::text, 'error'::text])))
);


--
-- Name: logical_networks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.logical_networks (
    id uuid NOT NULL,
    name text NOT NULL,
    subnet text NOT NULL,
    gateway text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    project_id uuid NOT NULL,
    created_by_id uuid,
    dhcp_enabled boolean DEFAULT true NOT NULL,
    dns_servers text,
    domain_name text,
    lease_time bigint,
    external_access boolean DEFAULT true NOT NULL,
    generation bigint DEFAULT 1 NOT NULL,
    site_id uuid NOT NULL,
    subnet6 text,
    gateway6 text,
    primary_dns_zone_id uuid,
    metadata_enabled boolean DEFAULT true NOT NULL,
    resolver_enabled boolean DEFAULT true NOT NULL,
    resolver_index bigint,
    CONSTRAINT ck_logical_networks_name_length CHECK ((char_length(name) <= 128))
);


--
-- Name: mac_address_allocations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.mac_address_allocations (
    mac_address text NOT NULL,
    owner_kind text NOT NULL,
    owner_id uuid NOT NULL,
    created_at timestamp with time zone,
    CONSTRAINT ck_mac_address_allocations_owner_kind CHECK ((owner_kind = ANY (ARRAY['vm'::text, 'sandbox'::text])))
);


--
-- Name: oauth_device_authorizations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.oauth_device_authorizations (
    id uuid NOT NULL,
    device_code_hash text NOT NULL,
    user_code text NOT NULL,
    client_name text NOT NULL,
    status text NOT NULL,
    user_id uuid,
    request_ip text,
    expires_at timestamp with time zone NOT NULL,
    last_polled_at timestamp with time zone,
    poll_interval bigint NOT NULL,
    created_at timestamp with time zone,
    restriction_actions text[] NOT NULL,
    restriction_node_type text,
    restriction_node_id uuid
);


--
-- Name: oidc_providers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.oidc_providers (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    name text NOT NULL,
    client_id text NOT NULL,
    client_secret text NOT NULL,
    discovery_url text,
    authorization_endpoint text,
    token_endpoint text,
    userinfo_endpoint text,
    jwks_uri text,
    scopes text NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    groups_claim text,
    group_mappings text DEFAULT '[]'::text NOT NULL,
    admin_claim_values text DEFAULT '[]'::text NOT NULL,
    issuer text,
    end_session_endpoint text,
    use_nonce boolean DEFAULT true NOT NULL,
    discovered_hosts text DEFAULT '[]'::text NOT NULL,
    role_mappings text DEFAULT '[]'::text NOT NULL,
    default_role_id uuid
);


--
-- Name: org_trust_domains; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.org_trust_domains (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    trust_domain text NOT NULL,
    phase public.org_trust_domain_phase DEFAULT 'pending'::public.org_trust_domain_phase NOT NULL,
    generation bigint DEFAULT 1 NOT NULL,
    observed_generation bigint DEFAULT 0 NOT NULL,
    server_address text,
    bundle_endpoint_url text,
    node_address text,
    org_bundle_pem text,
    platform_federation_at timestamp with time zone,
    org_federation_at timestamp with time zone,
    last_error text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone
);


--
-- Name: organizational_units; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organizational_units (
    id uuid NOT NULL,
    name text NOT NULL,
    description text NOT NULL,
    organization_id uuid NOT NULL,
    parent_ou_id uuid,
    path text NOT NULL,
    depth bigint NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    CONSTRAINT ck_organizational_units_description_length CHECK ((char_length(description) <= 4096)),
    CONSTRAINT ck_organizational_units_name_length CHECK ((char_length(name) <= 128))
);


--
-- Name: organizations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organizations (
    id uuid NOT NULL,
    name text NOT NULL,
    description text NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    CONSTRAINT ck_organizations_description_length CHECK ((char_length(description) <= 4096)),
    CONSTRAINT ck_organizations_name_length CHECK ((char_length(name) <= 128))
);


--
-- Name: projects; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.projects (
    id uuid NOT NULL,
    name text NOT NULL,
    description text NOT NULL,
    organization_id uuid,
    organizational_unit_id uuid,
    path text NOT NULL,
    default_environment text NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    environments text[] NOT NULL,
    CONSTRAINT ck_projects_description_length CHECK ((char_length(description) <= 4096)),
    CONSTRAINT ck_projects_name_length CHECK ((char_length(name) <= 128))
);


--
-- Name: registry_pull_secrets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.registry_pull_secrets (
    id uuid NOT NULL,
    project_id uuid NOT NULL,
    registry text NOT NULL,
    username text NOT NULL,
    secret text NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: resource_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.resource_events (
    id uuid NOT NULL,
    actor_type text NOT NULL,
    actor_id uuid,
    resource_kind text NOT NULL,
    resource_id uuid NOT NULL,
    resource_name text,
    mutation text NOT NULL,
    target_generation bigint,
    organization_id uuid,
    project_id uuid,
    created_at timestamp with time zone NOT NULL,
    phase text DEFAULT 'requested'::text NOT NULL,
    CONSTRAINT ck_resource_events_actor_type_enum CHECK ((actor_type = ANY (ARRAY['user'::text, 'service_account'::text, 'workload'::text, 'system'::text]))),
    CONSTRAINT ck_resource_events_mutation_enum CHECK ((mutation = ANY (ARRAY['create'::text, 'boot'::text, 'shutdown'::text, 'reboot'::text, 'pause'::text, 'resume'::text, 'delete'::text, 'resize'::text, 'snapshot'::text, 'snapshot_delete'::text, 'restore'::text, 'snapshot_export'::text, 'attach'::text, 'detach'::text, 'throttle'::text]))),
    CONSTRAINT ck_resource_events_phase_enum CHECK ((phase = ANY (ARRAY['requested'::text, 'completed'::text, 'failed'::text]))),
    CONSTRAINT ck_resource_events_resource_kind_enum CHECK ((resource_kind = ANY (ARRAY['virtual_machine'::text, 'sandbox'::text, 'volume'::text, 'volume_snapshot'::text, 'vm_checkpoint'::text, 'sandbox_snapshot'::text])))
);


--
-- Name: resource_quotas; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.resource_quotas (
    id uuid NOT NULL,
    name text NOT NULL,
    organization_id uuid,
    organizational_unit_id uuid,
    project_id uuid,
    max_vcpus bigint NOT NULL,
    reserved_vcpus bigint DEFAULT 0 NOT NULL,
    max_memory bigint NOT NULL,
    reserved_memory bigint DEFAULT 0 NOT NULL,
    max_storage bigint NOT NULL,
    reserved_storage bigint DEFAULT 0 NOT NULL,
    max_vms bigint NOT NULL,
    vm_count bigint DEFAULT 0 NOT NULL,
    max_networks bigint DEFAULT 10 NOT NULL,
    network_count bigint DEFAULT 0 NOT NULL,
    is_enabled boolean DEFAULT true NOT NULL,
    environment text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    max_sandboxes bigint DEFAULT 0 NOT NULL,
    sandbox_count bigint DEFAULT 0 NOT NULL,
    max_volumes bigint,
    volume_count bigint DEFAULT 0 NOT NULL,
    CONSTRAINT ck_resource_quotas_name_length CHECK ((char_length(name) <= 128))
);


--
-- Name: role_bindings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.role_bindings (
    id uuid NOT NULL,
    principal_type text NOT NULL,
    principal_id uuid NOT NULL,
    node_type text NOT NULL,
    node_id uuid NOT NULL,
    condition text,
    expires_at timestamp with time zone,
    created_by uuid,
    created_at timestamp with time zone,
    role_id uuid NOT NULL,
    CONSTRAINT ck_role_bindings_condition_unsupported CHECK ((condition IS NULL))
);


--
-- Name: sandbox_interface_addresses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sandbox_interface_addresses (
    id uuid NOT NULL,
    interface_id uuid NOT NULL,
    family text NOT NULL,
    address text NOT NULL,
    prefix_length bigint NOT NULL,
    gateway text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    logical_network_id uuid NOT NULL
);


--
-- Name: sandbox_interface_security_groups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sandbox_interface_security_groups (
    id uuid NOT NULL,
    interface_id uuid NOT NULL,
    security_group_id uuid NOT NULL,
    created_at timestamp with time zone
);


--
-- Name: sandbox_network_interfaces; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sandbox_network_interfaces (
    id uuid NOT NULL,
    sandbox_id uuid NOT NULL,
    mac_address text NOT NULL,
    mtu bigint,
    device_name text NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    logical_network_id uuid NOT NULL
);


--
-- Name: sandbox_snapshots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sandbox_snapshots (
    id uuid NOT NULL,
    name text NOT NULL,
    sandbox_id uuid NOT NULL,
    project_id uuid NOT NULL,
    environment text NOT NULL,
    status text NOT NULL,
    size bigint,
    agent_id text,
    storage_path text,
    firecracker_version text,
    architecture text,
    error_message text,
    created_by_id uuid NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    guest_control_protocol_version bigint,
    fork_layout_version bigint,
    exported_at timestamp with time zone,
    exported_artifacts jsonb[],
    cpu_template text,
    source_cpu_model text,
    desired_status text DEFAULT 'Present'::text NOT NULL,
    generation bigint DEFAULT 0 NOT NULL,
    observed_generation bigint DEFAULT 0 NOT NULL,
    convergence_phase text,
    failed_generation bigint,
    convergence_deadline timestamp with time zone,
    finalizers text[] DEFAULT '{}'::text[] NOT NULL,
    expires_at timestamp with time zone,
    export_desired boolean DEFAULT false NOT NULL,
    capture_mode text DEFAULT 'resume'::text NOT NULL,
    CONSTRAINT ck_sandbox_snapshots_capture_mode_enum CHECK ((capture_mode = ANY (ARRAY['resume'::text, 'stop'::text]))),
    CONSTRAINT ck_sandbox_snapshots_desired_status_enum CHECK ((desired_status = ANY (ARRAY['Present'::text, 'Absent'::text]))),
    CONSTRAINT ck_sandbox_snapshots_name_length CHECK ((char_length(name) <= 128)),
    CONSTRAINT ck_sandbox_snapshots_status_enum CHECK ((status = ANY (ARRAY['creating'::text, 'ready'::text, 'deleting'::text, 'error'::text])))
);


--
-- Name: sandboxes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sandboxes (
    id uuid NOT NULL,
    name text NOT NULL,
    project_id uuid NOT NULL,
    environment text NOT NULL,
    image text NOT NULL,
    image_digest text,
    vcpus bigint NOT NULL,
    memory bigint NOT NULL,
    entrypoint text[],
    cmd text[],
    env jsonb NOT NULL,
    working_dir text,
    ttl_seconds bigint,
    hypervisor_id text,
    status text NOT NULL,
    status_changed_at timestamp with time zone,
    exit_code bigint,
    desired_status text NOT NULL,
    generation bigint NOT NULL,
    observed_generation bigint NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    restored_from_snapshot_id uuid,
    cpu_template text,
    finalizers text[] DEFAULT '{}'::text[] NOT NULL,
    convergence_phase text,
    last_error text,
    failed_generation bigint,
    convergence_deadline timestamp with time zone,
    restore_generation bigint DEFAULT 0 NOT NULL,
    restore_snapshot_id uuid,
    last_error_at timestamp with time zone,
    divergence_detected_at timestamp with time zone,
    CONSTRAINT ck_sandboxes_desired_status_enum CHECK ((desired_status = ANY (ARRAY['Running'::text, 'Stopped'::text, 'Absent'::text]))),
    CONSTRAINT ck_sandboxes_name_length CHECK ((char_length(name) <= 128)),
    CONSTRAINT ck_sandboxes_status_enum CHECK ((status = ANY (ARRAY['Stopped'::text, 'Running'::text, 'Exited'::text, 'Starting'::text, 'Stopping'::text, 'Error'::text, 'Unknown'::text])))
);


--
-- Name: scim_external_ids; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.scim_external_ids (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    resource_type text NOT NULL,
    external_id text NOT NULL,
    internal_id uuid NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: scim_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.scim_tokens (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    name text NOT NULL,
    token_hash text NOT NULL,
    token_prefix text NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    expires_at timestamp with time zone,
    last_used_at timestamp with time zone,
    last_used_ip text,
    created_by_id uuid NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: security_group_rules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.security_group_rules (
    id uuid NOT NULL,
    security_group_id uuid NOT NULL,
    direction text NOT NULL,
    ethertype text NOT NULL,
    protocol text,
    port_range_min bigint,
    port_range_max bigint,
    remote_cidr text,
    remote_group_id uuid,
    description text,
    created_at timestamp with time zone,
    log boolean DEFAULT false NOT NULL
);


--
-- Name: security_groups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.security_groups (
    id uuid NOT NULL,
    project_id uuid NOT NULL,
    name text NOT NULL,
    description text,
    is_default boolean NOT NULL,
    generation bigint NOT NULL,
    created_by_id uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    CONSTRAINT ck_security_groups_description_length CHECK ((char_length(description) <= 4096)),
    CONSTRAINT ck_security_groups_name_length CHECK ((char_length(name) <= 128))
);


--
-- Name: service_accounts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.service_accounts (
    id uuid NOT NULL,
    name text NOT NULL,
    description text NOT NULL,
    project_id uuid NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: sites; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sites (
    id uuid NOT NULL,
    name text NOT NULL,
    description text,
    network_controller_agent_id uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    organization_id uuid,
    organizational_unit_id uuid,
    status text DEFAULT 'active'::text NOT NULL,
    latitude double precision,
    longitude double precision,
    location_label text,
    region_code text,
    labels jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT ck_sites_status_enum CHECK ((status = ANY (ARRAY['active'::text, 'draining'::text, 'maintenance'::text, 'decommissioned'::text])))
);


--
-- Name: ssf_streams; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ssf_streams (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    name text NOT NULL,
    description text,
    transmitter_url text NOT NULL,
    auth_token text,
    expected_issuer text,
    expected_audience text DEFAULT '[]'::text NOT NULL,
    delivery_method text NOT NULL,
    events_requested text DEFAULT '[]'::text NOT NULL,
    remote_stream_id text,
    poll_endpoint text,
    push_token_hash text,
    push_token_prefix text,
    enabled boolean DEFAULT true NOT NULL,
    verified_at timestamp with time zone,
    last_event_at timestamp with time zone,
    last_error text,
    created_by_id uuid NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: stored_secrets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stored_secrets (
    id uuid PRIMARY KEY,
    purpose text NOT NULL,
    encrypted_value text NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    CONSTRAINT ck_stored_secrets_purpose CHECK ((purpose = ANY (ARRAY['ceph_cluster_observer_keyring'::text, 'ceph_project_keyring'::text])))
);


--
-- Name: ceph_clusters; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ceph_clusters (
    id uuid PRIMARY KEY,
    site_id uuid NOT NULL,
    fsid text NOT NULL,
    managed boolean NOT NULL,
    mon_endpoints text[] NOT NULL,
    client_name text NOT NULL,
    keyring_secret_ref uuid NOT NULL,
    health text NOT NULL,
    capacity_bytes bigint,
    used_bytes bigint,
    observed_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    CONSTRAINT ck_ceph_clusters_external CHECK ((managed = false)),
    CONSTRAINT ck_ceph_clusters_health CHECK ((health = ANY (ARRAY['unknown'::text, 'ok'::text, 'warning'::text, 'error'::text]))),
    CONSTRAINT ck_ceph_clusters_mon_endpoints CHECK ((cardinality(mon_endpoints) > 0)),
    CONSTRAINT ck_ceph_clusters_capacity CHECK ((((capacity_bytes IS NULL) OR (capacity_bytes >= 0)) AND ((used_bytes IS NULL) OR (used_bytes >= 0)) AND ((capacity_bytes IS NULL) OR (used_bytes IS NULL) OR (used_bytes <= capacity_bytes))))
);


--
-- Name: ceph_project_accesses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ceph_project_accesses (
    id uuid PRIMARY KEY,
    cluster_id uuid NOT NULL,
    project_id uuid NOT NULL,
    client_name text NOT NULL,
    keyring_secret_ref uuid NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: ceph_credential_revocations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ceph_credential_revocations (
    id uuid PRIMARY KEY,
    site_id uuid NOT NULL,
    cluster_id uuid NOT NULL,
    credential_id uuid NOT NULL,
    created_at timestamp with time zone
);


-- Name: storage_pools; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.storage_pools (
    id uuid NOT NULL,
    name text NOT NULL,
    mode text NOT NULL,
    replication_factor bigint NOT NULL,
    member_agent_ids text[] NOT NULL,
    backing text NOT NULL,
    site_id uuid,
    ceph_cluster_id uuid,
    ceph_project_access_id uuid,
    ceph_pool_name text,
    ceph_namespace text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    CONSTRAINT ck_storage_pools_backing_enum CHECK ((backing = ANY (ARRAY['filesystem'::text, 'zfs'::text]))),
    CONSTRAINT ck_storage_pools_mode_enum CHECK ((mode = ANY (ARRAY['local'::text, 'replicated'::text, 'ceph'::text]))),
    CONSTRAINT ck_storage_pools_ceph_shape CHECK ((((mode = 'ceph'::text) AND (site_id IS NOT NULL) AND (ceph_cluster_id IS NOT NULL) AND (ceph_project_access_id IS NOT NULL) AND (ceph_pool_name IS NOT NULL) AND (ceph_namespace IS NOT NULL)) OR ((mode <> 'ceph'::text) AND (site_id IS NULL) AND (ceph_cluster_id IS NULL) AND (ceph_project_access_id IS NULL) AND (ceph_pool_name IS NULL) AND (ceph_namespace IS NULL))))
);


--
-- Name: user_credentials; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_credentials (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    credential_id bytea NOT NULL,
    public_key bytea NOT NULL,
    sign_count integer NOT NULL,
    transports text NOT NULL,
    backup_eligible boolean NOT NULL,
    backup_state boolean NOT NULL,
    device_type text NOT NULL,
    name text,
    created_at timestamp with time zone,
    last_used_at timestamp with time zone
);


--
-- Name: user_groups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_groups (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    group_id uuid NOT NULL,
    created_at timestamp with time zone
);


--
-- Name: user_organizations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_organizations (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    organization_id uuid NOT NULL,
    created_at timestamp with time zone,
    role_id uuid
);


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id uuid NOT NULL,
    username text NOT NULL,
    email text NOT NULL,
    display_name text NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    current_organization_id uuid,
    is_system_admin boolean DEFAULT false NOT NULL,
    session_epoch bigint DEFAULT 0 NOT NULL,
    disabled_at timestamp with time zone,
    oidc_provider_id uuid,
    oidc_subject text,
    scim_provisioned boolean DEFAULT false NOT NULL,
    scim_active boolean DEFAULT true NOT NULL,
    source text DEFAULT 'local'::text NOT NULL
);


--
-- Name: vm_interface_addresses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vm_interface_addresses (
    id uuid NOT NULL,
    interface_id uuid NOT NULL,
    family text NOT NULL,
    address text NOT NULL,
    prefix_length bigint NOT NULL,
    gateway text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    logical_network_id uuid NOT NULL
);


--
-- Name: vm_interface_observed_addresses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vm_interface_observed_addresses (
    id uuid NOT NULL,
    interface_id uuid NOT NULL,
    family text NOT NULL,
    address text NOT NULL,
    prefix_length bigint,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: vm_interface_security_groups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vm_interface_security_groups (
    id uuid NOT NULL,
    interface_id uuid NOT NULL,
    security_group_id uuid NOT NULL,
    created_at timestamp with time zone
);


--
-- Name: vm_network_interfaces; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vm_network_interfaces (
    id uuid NOT NULL,
    vm_id uuid NOT NULL,
    mac_address text NOT NULL,
    mtu bigint,
    device_name text NOT NULL,
    order_index bigint NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    logical_network_id uuid NOT NULL,
    attach_generation bigint,
    detach_generation bigint
);


--
-- Name: vm_snapshots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vm_snapshots (
    id uuid NOT NULL,
    name text NOT NULL,
    description text NOT NULL,
    vm_id uuid NOT NULL,
    project_id uuid NOT NULL,
    environment text NOT NULL,
    status text NOT NULL,
    size bigint,
    agent_id text,
    qemu_version text,
    architecture text,
    error_message text,
    created_by_id uuid NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    desired_status text DEFAULT 'Present'::text NOT NULL,
    generation bigint DEFAULT 0 NOT NULL,
    observed_generation bigint DEFAULT 0 NOT NULL,
    convergence_phase text,
    failed_generation bigint,
    convergence_deadline timestamp with time zone,
    finalizers text[] DEFAULT '{}'::text[] NOT NULL,
    expires_at timestamp with time zone,
    CONSTRAINT ck_vm_snapshots_description_length CHECK ((char_length(description) <= 4096)),
    CONSTRAINT ck_vm_snapshots_desired_status_enum CHECK ((desired_status = ANY (ARRAY['Present'::text, 'Absent'::text]))),
    CONSTRAINT ck_vm_snapshots_name_length CHECK ((char_length(name) <= 128))
);


--
-- Name: vms; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vms (
    id uuid NOT NULL,
    name text,
    description text,
    image text,
    cpu bigint,
    memory bigint,
    disk bigint,
    status text DEFAULT 'Created'::text NOT NULL,
    hypervisor_id text,
    max_cpu bigint DEFAULT '1'::bigint NOT NULL,
    memory_new bigint DEFAULT '536870912'::bigint NOT NULL,
    hugepages boolean DEFAULT false NOT NULL,
    shared_memory boolean DEFAULT false NOT NULL,
    disk_new bigint DEFAULT '1073741824'::bigint NOT NULL,
    kernel_path text,
    initramfs_path text,
    cmdline text,
    firmware_path text,
    console_mode text DEFAULT 'Pty'::text NOT NULL,
    serial_mode text DEFAULT 'Pty'::text NOT NULL,
    console_socket text,
    serial_socket text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    project_id uuid,
    environment text DEFAULT '''development'''::text,
    image_id uuid,
    hypervisor_type text DEFAULT 'qemu'::text NOT NULL,
    status_changed_at timestamp with time zone,
    desired_status text DEFAULT 'Shutdown'::text NOT NULL,
    generation bigint DEFAULT 0 NOT NULL,
    observed_generation bigint DEFAULT 0 NOT NULL,
    ssh_public_key text,
    user_data text,
    qga_available boolean,
    observed_hostname text,
    guest_memory_total_bytes bigint,
    guest_memory_available_bytes bigint,
    guest_memory_stats_at timestamp with time zone,
    max_memory bigint DEFAULT 0 NOT NULL,
    balloon_target bigint,
    guest_memory_balloon_actual_bytes bigint,
    secure_boot boolean DEFAULT false NOT NULL,
    tpm_enabled boolean DEFAULT false NOT NULL,
    guest_agent_enabled boolean DEFAULT false NOT NULL,
    hostname text,
    graphics_console boolean DEFAULT false NOT NULL,
    finalizers text[] DEFAULT '{}'::text[] NOT NULL,
    convergence_phase text,
    last_error text,
    failed_generation bigint,
    convergence_deadline timestamp with time zone,
    reboot_generation bigint DEFAULT 0 NOT NULL,
    restore_generation bigint DEFAULT 0 NOT NULL,
    restore_snapshot_id uuid,
    metadata_enabled boolean DEFAULT true NOT NULL,
    last_error_at timestamp with time zone,
    divergence_detected_at timestamp with time zone,
    desired_state_assembly_error text,
    desired_state_assembly_error_generation bigint,
    desired_state_assembly_error_at timestamp with time zone,
    CONSTRAINT ck_vms_console_mode_enum CHECK ((console_mode = ANY (ARRAY['Off'::text, 'Pty'::text, 'Tty'::text, 'File'::text, 'Socket'::text, 'Null'::text]))),
    CONSTRAINT ck_vms_description_length CHECK ((char_length(description) <= 4096)),
    CONSTRAINT ck_vms_desired_status_enum CHECK ((desired_status = ANY (ARRAY['Running'::text, 'Shutdown'::text, 'Paused'::text, 'Absent'::text]))),
    CONSTRAINT ck_vms_hypervisor_type_enum CHECK ((hypervisor_type = ANY (ARRAY['qemu'::text, 'firecracker'::text]))),
    CONSTRAINT ck_vms_name_length CHECK ((char_length(name) <= 128)),
    CONSTRAINT ck_vms_serial_mode_enum CHECK ((serial_mode = ANY (ARRAY['Off'::text, 'Pty'::text, 'Tty'::text, 'File'::text, 'Socket'::text, 'Null'::text]))),
    CONSTRAINT ck_vms_ssh_public_key_length CHECK ((char_length(ssh_public_key) <= 4096)),
    CONSTRAINT ck_vms_status_enum CHECK ((status = ANY (ARRAY['Created'::text, 'Running'::text, 'Shutdown'::text, 'Paused'::text, 'Starting'::text, 'Stopping'::text, 'Error'::text, 'Unknown'::text])))
);


--
-- Name: volume_replicas; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.volume_replicas (
    id uuid NOT NULL,
    volume_id uuid NOT NULL,
    agent_id text NOT NULL,
    disk_attachment jsonb,
    state text NOT NULL,
    generation bigint NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    CONSTRAINT ck_volume_replicas_state_enum CHECK ((state = ANY (ARRAY['provisioning'::text, 'healthy'::text, 'degraded'::text, 'resyncing'::text, 'faulted'::text])))
);


--
-- Name: volume_snapshots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.volume_snapshots (
    id uuid NOT NULL,
    name text NOT NULL,
    description text NOT NULL,
    volume_id uuid NOT NULL,
    project_id uuid NOT NULL,
    size bigint NOT NULL,
    status text DEFAULT 'creating'::text NOT NULL,
    error_message text,
    storage_path text,
    created_by_id uuid NOT NULL,
    created_at timestamp with time zone,
    desired_status text DEFAULT 'Present'::text NOT NULL,
    generation bigint DEFAULT 0 NOT NULL,
    observed_generation bigint DEFAULT 0 NOT NULL,
    convergence_phase text,
    failed_generation bigint,
    convergence_deadline timestamp with time zone,
    finalizers text[] DEFAULT '{}'::text[] NOT NULL,
    expires_at timestamp with time zone,
    agent_id text,
    environment text DEFAULT 'development'::text NOT NULL,
    observed_size_bytes bigint,
    CONSTRAINT ck_volume_snapshots_description_length CHECK ((char_length(description) <= 4096)),
    CONSTRAINT ck_volume_snapshots_desired_status_enum CHECK ((desired_status = ANY (ARRAY['Present'::text, 'Absent'::text]))),
    CONSTRAINT ck_volume_snapshots_name_length CHECK ((char_length(name) <= 128)),
    CONSTRAINT ck_volume_snapshots_status_enum CHECK ((status = ANY (ARRAY['creating'::text, 'available'::text, 'deleting'::text, 'error'::text])))
);


--
-- Name: volumes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.volumes (
    id uuid NOT NULL,
    name text NOT NULL,
    description text NOT NULL,
    project_id uuid NOT NULL,
    size bigint NOT NULL,
    format text DEFAULT 'qcow2'::text NOT NULL,
    type text DEFAULT 'data'::text NOT NULL,
    status text DEFAULT 'creating'::text NOT NULL,
    error_message text,
    vm_id uuid,
    device_name text,
    boot_order bigint,
    source_image_id uuid,
    source_volume_id uuid,
    created_by_id uuid NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    pool_id uuid,
    attached_agent_id text,
    disk_attachment jsonb,
    reconciler_agent_id text,
    desired_status text DEFAULT 'Present'::text NOT NULL,
    generation bigint DEFAULT 0 NOT NULL,
    observed_generation bigint DEFAULT 0 NOT NULL,
    convergence_phase text,
    failed_generation bigint,
    convergence_deadline timestamp with time zone,
    finalizers text[] DEFAULT '{}'::text[] NOT NULL,
    readonly boolean DEFAULT false NOT NULL,
    iops_total bigint,
    bps_total bigint,
    applied_iops_total bigint,
    applied_bps_total bigint,
    observed_size_bytes bigint,
    environment text DEFAULT 'development'::text NOT NULL,
    CONSTRAINT chk_volumes_attached_names_device CHECK (((vm_id IS NULL) OR (device_name IS NOT NULL))),
    CONSTRAINT ck_volumes_description_length CHECK ((char_length(description) <= 4096)),
    CONSTRAINT ck_volumes_desired_status_enum CHECK ((desired_status = ANY (ARRAY['Present'::text, 'Absent'::text]))),
    CONSTRAINT ck_volumes_format_enum CHECK ((format = ANY (ARRAY['qcow2'::text, 'raw'::text]))),
    CONSTRAINT ck_volumes_name_length CHECK ((char_length(name) <= 128)),
    CONSTRAINT ck_volumes_status_enum CHECK ((status = ANY (ARRAY['creating'::text, 'available'::text, 'attaching'::text, 'attached'::text, 'detaching'::text, 'resizing'::text, 'snapshotting'::text, 'cloning'::text, 'deleting'::text, 'error'::text]))),
    CONSTRAINT ck_volumes_type_enum CHECK ((type = ANY (ARRAY['boot'::text, 'data'::text]))),
    CONSTRAINT volumes_canonical_boot CHECK (((type <> 'boot'::text) OR ((vm_id IS NOT NULL) AND (device_name = 'disk0'::text) AND (boot_order = 0) AND (NOT readonly))))
);


--
-- Name: webhook_deliveries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.webhook_deliveries (
    id uuid NOT NULL,
    subscription_id uuid NOT NULL,
    event_id uuid NOT NULL,
    event_type text NOT NULL,
    payload text NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    attempts bigint DEFAULT 0 NOT NULL,
    next_attempt_at timestamp with time zone NOT NULL,
    claimed_until timestamp with time zone,
    last_attempt_at timestamp with time zone,
    response_status bigint,
    last_error text,
    delivered_at timestamp with time zone,
    enqueued_at timestamp with time zone DEFAULT now(),
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: webhook_subscriptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.webhook_subscriptions (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    project_id uuid,
    name text NOT NULL,
    url text NOT NULL,
    event_types text DEFAULT '[]'::text NOT NULL,
    signing_secret text NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    disabled_reason text,
    failing_since timestamp with time zone,
    created_by_id uuid NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: workload_registrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.workload_registrations (
    id uuid NOT NULL,
    spiffe_id text NOT NULL,
    kind public.workload_registration_kind NOT NULL,
    agent_name text,
    service_account_id uuid,
    organization_id uuid,
    display_name text,
    created_by uuid,
    created_at timestamp with time zone,
    vm_id uuid
);


--
-- Name: _fluent_enums _fluent_enums_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public._fluent_enums
    ADD CONSTRAINT _fluent_enums_pkey PRIMARY KEY (id);


--
-- Name: _fluent_sessions _fluent_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public._fluent_sessions
    ADD CONSTRAINT _fluent_sessions_pkey PRIMARY KEY (id);


--
-- Name: account_claim_tokens account_claim_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_claim_tokens
    ADD CONSTRAINT account_claim_tokens_pkey PRIMARY KEY (id);


--
-- Name: agent_enrollments agent_enrollments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_enrollments
    ADD CONSTRAINT agent_enrollments_pkey PRIMARY KEY (id);


--
-- Name: agent_workload_claims agent_workload_claims_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_workload_claims
    ADD CONSTRAINT agent_workload_claims_pkey PRIMARY KEY (id);


--
-- Name: agents agents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agents
    ADD CONSTRAINT agents_pkey PRIMARY KEY (id);


--
-- Name: api_keys api_keys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_keys
    ADD CONSTRAINT api_keys_pkey PRIMARY KEY (id);


--
-- Name: app_settings app_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_settings
    ADD CONSTRAINT app_settings_pkey PRIMARY KEY (id);


--
-- Name: audit_events audit_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT audit_events_pkey PRIMARY KEY (id);


--
-- Name: authentication_challenges authentication_challenges_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.authentication_challenges
    ADD CONSTRAINT authentication_challenges_pkey PRIMARY KEY (id);


--
-- Name: cli_sessions cli_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cli_sessions
    ADD CONSTRAINT cli_sessions_pkey PRIMARY KEY (id);


--
-- Name: dns_records dns_records_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dns_records
    ADD CONSTRAINT dns_records_pkey PRIMARY KEY (id);


--
-- Name: dns_zone_networks dns_zone_networks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dns_zone_networks
    ADD CONSTRAINT dns_zone_networks_pkey PRIMARY KEY (id);


--
-- Name: dns_zones dns_zones_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dns_zones
    ADD CONSTRAINT dns_zones_pkey PRIMARY KEY (id);


--
-- Name: floating_ip_pools floating_ip_pools_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.floating_ip_pools
    ADD CONSTRAINT floating_ip_pools_pkey PRIMARY KEY (id);


--
-- Name: floating_ips floating_ips_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.floating_ips
    ADD CONSTRAINT floating_ips_pkey PRIMARY KEY (id);


--
-- Name: groups groups_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.groups
    ADD CONSTRAINT groups_pkey PRIMARY KEY (id);


--
-- Name: iam_decision_logs iam_decision_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.iam_decision_logs
    ADD CONSTRAINT iam_decision_logs_pkey PRIMARY KEY (id);


--
-- Name: iam_guardrails iam_guardrails_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.iam_guardrails
    ADD CONSTRAINT iam_guardrails_pkey PRIMARY KEY (id);


--
-- Name: iam_policies iam_policies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.iam_policies
    ADD CONSTRAINT iam_policies_pkey PRIMARY KEY (id);


--
-- Name: iam_policy_set_versions iam_policy_set_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.iam_policy_set_versions
    ADD CONSTRAINT iam_policy_set_versions_pkey PRIMARY KEY (id);


--
-- Name: iam_roles iam_roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.iam_roles
    ADD CONSTRAINT iam_roles_pkey PRIMARY KEY (id);


--
-- Name: image_artifacts image_artifacts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.image_artifacts
    ADD CONSTRAINT image_artifacts_pkey PRIMARY KEY (id);


--
-- Name: images images_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.images
    ADD CONSTRAINT images_pkey PRIMARY KEY (id);


--
-- Name: logical_networks logical_networks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.logical_networks
    ADD CONSTRAINT logical_networks_pkey PRIMARY KEY (id);


--
-- Name: mac_address_allocations mac_address_allocations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mac_address_allocations
    ADD CONSTRAINT mac_address_allocations_pkey PRIMARY KEY (mac_address);


--
-- Name: mac_address_allocations uq_mac_address_allocations_owner; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mac_address_allocations
    ADD CONSTRAINT uq_mac_address_allocations_owner UNIQUE (owner_kind, owner_id);


--
-- Name: oauth_device_authorizations oauth_device_authorizations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oauth_device_authorizations
    ADD CONSTRAINT oauth_device_authorizations_pkey PRIMARY KEY (id);


--
-- Name: oidc_providers oidc_providers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oidc_providers
    ADD CONSTRAINT oidc_providers_pkey PRIMARY KEY (id);


--
-- Name: org_trust_domains org_trust_domains_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.org_trust_domains
    ADD CONSTRAINT org_trust_domains_pkey PRIMARY KEY (id);


--
-- Name: organizational_units organizational_units_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organizational_units
    ADD CONSTRAINT organizational_units_pkey PRIMARY KEY (id);


--
-- Name: organizations organizations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organizations
    ADD CONSTRAINT organizations_pkey PRIMARY KEY (id);


--
-- Name: projects projects_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.projects
    ADD CONSTRAINT projects_pkey PRIMARY KEY (id);


--
-- Name: registry_pull_secrets registry_pull_secrets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.registry_pull_secrets
    ADD CONSTRAINT registry_pull_secrets_pkey PRIMARY KEY (id);


--
-- Name: resource_events resource_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_events
    ADD CONSTRAINT resource_events_pkey PRIMARY KEY (id);


--
-- Name: resource_quotas resource_quotas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_quotas
    ADD CONSTRAINT resource_quotas_pkey PRIMARY KEY (id);


--
-- Name: role_bindings role_bindings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role_bindings
    ADD CONSTRAINT role_bindings_pkey PRIMARY KEY (id);


--
-- Name: sandbox_interface_addresses sandbox_interface_addresses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sandbox_interface_addresses
    ADD CONSTRAINT sandbox_interface_addresses_pkey PRIMARY KEY (id);


--
-- Name: sandbox_interface_security_groups sandbox_interface_security_groups_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sandbox_interface_security_groups
    ADD CONSTRAINT sandbox_interface_security_groups_pkey PRIMARY KEY (id);


--
-- Name: sandbox_network_interfaces sandbox_network_interfaces_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sandbox_network_interfaces
    ADD CONSTRAINT sandbox_network_interfaces_pkey PRIMARY KEY (id);


--
-- Name: sandbox_snapshots sandbox_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sandbox_snapshots
    ADD CONSTRAINT sandbox_snapshots_pkey PRIMARY KEY (id);


--
-- Name: sandboxes sandboxes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sandboxes
    ADD CONSTRAINT sandboxes_pkey PRIMARY KEY (id);


--
-- Name: scim_external_ids scim_external_ids_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scim_external_ids
    ADD CONSTRAINT scim_external_ids_pkey PRIMARY KEY (id);


--
-- Name: scim_tokens scim_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scim_tokens
    ADD CONSTRAINT scim_tokens_pkey PRIMARY KEY (id);


--
-- Name: security_group_rules security_group_rules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.security_group_rules
    ADD CONSTRAINT security_group_rules_pkey PRIMARY KEY (id);


--
-- Name: security_groups security_groups_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.security_groups
    ADD CONSTRAINT security_groups_pkey PRIMARY KEY (id);


--
-- Name: service_accounts service_accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_accounts
    ADD CONSTRAINT service_accounts_pkey PRIMARY KEY (id);


--
-- Name: sites sites_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sites
    ADD CONSTRAINT sites_pkey PRIMARY KEY (id);


--
-- Name: ssf_streams ssf_streams_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ssf_streams
    ADD CONSTRAINT ssf_streams_pkey PRIMARY KEY (id);


--
-- Name: storage_pools storage_pools_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.storage_pools
    ADD CONSTRAINT storage_pools_pkey PRIMARY KEY (id);


--
-- Name: _fluent_enums uq:_fluent_enums.name+_fluent_enums.case; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public._fluent_enums
    ADD CONSTRAINT "uq:_fluent_enums.name+_fluent_enums.case" UNIQUE (name, "case");


--
-- Name: _fluent_sessions uq:_fluent_sessions.key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public._fluent_sessions
    ADD CONSTRAINT "uq:_fluent_sessions.key" UNIQUE (key);


--
-- Name: account_claim_tokens uq:account_claim_tokens.token_hash; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_claim_tokens
    ADD CONSTRAINT "uq:account_claim_tokens.token_hash" UNIQUE (token_hash);


--
-- Name: agent_enrollments uq:agent_enrollments.trust_domain+agent_enrollments.agent_name; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_enrollments
    ADD CONSTRAINT "uq:agent_enrollments.trust_domain+agent_enrollments.agent_name" UNIQUE (trust_domain, agent_name);


--
-- Name: agent_workload_claims uq:agent_workload_claims.agent_id+agent_workload_claims.resourc; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_workload_claims
    ADD CONSTRAINT "uq:agent_workload_claims.agent_id+agent_workload_claims.resourc" UNIQUE (agent_id, resource_kind, resource_id);


--
-- Name: agents uq:agents.trust_domain+agents.name; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agents
    ADD CONSTRAINT "uq:agents.trust_domain+agents.name" UNIQUE (trust_domain, name);


--
-- Name: api_keys uq:api_keys.key_hash; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_keys
    ADD CONSTRAINT "uq:api_keys.key_hash" UNIQUE (key_hash);


--
-- Name: app_settings uq:app_settings.key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_settings
    ADD CONSTRAINT "uq:app_settings.key" UNIQUE (key);


--
-- Name: cli_sessions uq:cli_sessions.access_token_hash; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cli_sessions
    ADD CONSTRAINT "uq:cli_sessions.access_token_hash" UNIQUE (access_token_hash);


--
-- Name: cli_sessions uq:cli_sessions.refresh_token_hash; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cli_sessions
    ADD CONSTRAINT "uq:cli_sessions.refresh_token_hash" UNIQUE (refresh_token_hash);


--
-- Name: dns_records uq:dns_records.zone_id+dns_records.name+dns_records.type+dns_re; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dns_records
    ADD CONSTRAINT "uq:dns_records.zone_id+dns_records.name+dns_records.type+dns_re" UNIQUE (zone_id, name, type, value);


--
-- Name: dns_zone_networks uq:dns_zone_networks.zone_id+dns_zone_networks.logical_network_; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dns_zone_networks
    ADD CONSTRAINT "uq:dns_zone_networks.zone_id+dns_zone_networks.logical_network_" UNIQUE (zone_id, logical_network_id);


--
-- Name: dns_zones uq:dns_zones.project_id+dns_zones.name; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dns_zones
    ADD CONSTRAINT "uq:dns_zones.project_id+dns_zones.name" UNIQUE (project_id, name);


--
-- Name: floating_ips uq:floating_ips.pool_id+floating_ips.address; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.floating_ips
    ADD CONSTRAINT "uq:floating_ips.pool_id+floating_ips.address" UNIQUE (pool_id, address);


--
-- Name: groups uq:groups.name+groups.organization_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.groups
    ADD CONSTRAINT "uq:groups.name+groups.organization_id" UNIQUE (name, organization_id);


--
-- Name: iam_guardrails uq:iam_guardrails.node_type+iam_guardrails.node_id+iam_guardrai; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.iam_guardrails
    ADD CONSTRAINT "uq:iam_guardrails.node_type+iam_guardrails.node_id+iam_guardrai" UNIQUE (node_type, node_id, name);


--
-- Name: iam_policies uq:iam_policies.owner_type+iam_policies.owner_id+iam_policies.n; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.iam_policies
    ADD CONSTRAINT "uq:iam_policies.owner_type+iam_policies.owner_id+iam_policies.n" UNIQUE (owner_type, owner_id, name);


--
-- Name: iam_policy_set_versions uq:iam_policy_set_versions.version; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.iam_policy_set_versions
    ADD CONSTRAINT "uq:iam_policy_set_versions.version" UNIQUE (version);


--
-- Name: iam_roles uq:iam_roles.owner_type+iam_roles.owner_id+iam_roles.name; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.iam_roles
    ADD CONSTRAINT "uq:iam_roles.owner_type+iam_roles.owner_id+iam_roles.name" UNIQUE (owner_type, owner_id, name);


--
-- Name: image_artifacts uq:image_artifacts.image_id+image_artifacts.kind; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.image_artifacts
    ADD CONSTRAINT "uq:image_artifacts.image_id+image_artifacts.kind" UNIQUE (image_id, kind);


--
-- Name: images uq:images.project_id+images.name; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.images
    ADD CONSTRAINT "uq:images.project_id+images.name" UNIQUE (project_id, name);


--
-- Name: logical_networks uq:logical_networks.project_id+logical_networks.name; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.logical_networks
    ADD CONSTRAINT "uq:logical_networks.project_id+logical_networks.name" UNIQUE (project_id, name);


--
-- Name: oauth_device_authorizations uq:oauth_device_authorizations.device_code_hash; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oauth_device_authorizations
    ADD CONSTRAINT "uq:oauth_device_authorizations.device_code_hash" UNIQUE (device_code_hash);


--
-- Name: oauth_device_authorizations uq:oauth_device_authorizations.user_code; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oauth_device_authorizations
    ADD CONSTRAINT "uq:oauth_device_authorizations.user_code" UNIQUE (user_code);


--
-- Name: org_trust_domains uq:org_trust_domains.organization_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.org_trust_domains
    ADD CONSTRAINT "uq:org_trust_domains.organization_id" UNIQUE (organization_id);


--
-- Name: org_trust_domains uq:org_trust_domains.trust_domain; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.org_trust_domains
    ADD CONSTRAINT "uq:org_trust_domains.trust_domain" UNIQUE (trust_domain);


--
-- Name: organizational_units uq:organizational_units.organization_id+organizational_units.pa; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organizational_units
    ADD CONSTRAINT "uq:organizational_units.organization_id+organizational_units.pa" UNIQUE (organization_id, parent_ou_id, name);


--
-- Name: organizations uq:organizations.name; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organizations
    ADD CONSTRAINT "uq:organizations.name" UNIQUE (name);


--
-- Name: projects uq:projects.organization_id+projects.name; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.projects
    ADD CONSTRAINT "uq:projects.organization_id+projects.name" UNIQUE (organization_id, name);


--
-- Name: projects uq:projects.organizational_unit_id+projects.name; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.projects
    ADD CONSTRAINT "uq:projects.organizational_unit_id+projects.name" UNIQUE (organizational_unit_id, name);


--
-- Name: registry_pull_secrets uq:registry_pull_secrets.project_id+registry_pull_secrets.regis; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.registry_pull_secrets
    ADD CONSTRAINT "uq:registry_pull_secrets.project_id+registry_pull_secrets.regis" UNIQUE (project_id, registry);


--
-- Name: resource_quotas uq:resource_quotas.organization_id+resource_quotas.name+resourc; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_quotas
    ADD CONSTRAINT "uq:resource_quotas.organization_id+resource_quotas.name+resourc" UNIQUE (organization_id, name, environment);


--
-- Name: resource_quotas uq:resource_quotas.organizational_unit_id+resource_quotas.name+; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_quotas
    ADD CONSTRAINT "uq:resource_quotas.organizational_unit_id+resource_quotas.name+" UNIQUE (organizational_unit_id, name, environment);


--
-- Name: resource_quotas uq:resource_quotas.project_id+resource_quotas.name+resource_quo; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_quotas
    ADD CONSTRAINT "uq:resource_quotas.project_id+resource_quotas.name+resource_quo" UNIQUE (project_id, name, environment);


--
-- Name: sandbox_interface_security_groups uq:sandbox_interface_security_groups.interface_id+sandbox_inter; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sandbox_interface_security_groups
    ADD CONSTRAINT "uq:sandbox_interface_security_groups.interface_id+sandbox_inter" UNIQUE (interface_id, security_group_id);


--
-- Name: sandbox_network_interfaces uq:sandbox_network_interfaces.sandbox_id+sandbox_network_interf; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sandbox_network_interfaces
    ADD CONSTRAINT "uq:sandbox_network_interfaces.sandbox_id+sandbox_network_interf" UNIQUE (sandbox_id, device_name);


--
-- Name: sandbox_network_interfaces uq_sandbox_network_interfaces_mac_address; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sandbox_network_interfaces
    ADD CONSTRAINT uq_sandbox_network_interfaces_mac_address UNIQUE (mac_address);


--
-- Name: scim_external_ids uq:scim_external_ids.organization_id+scim_external_ids.resource; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scim_external_ids
    ADD CONSTRAINT "uq:scim_external_ids.organization_id+scim_external_ids.resource" UNIQUE (organization_id, resource_type, external_id);


--
-- Name: scim_tokens uq:scim_tokens.token_hash; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scim_tokens
    ADD CONSTRAINT "uq:scim_tokens.token_hash" UNIQUE (token_hash);


--
-- Name: security_groups uq:security_groups.project_id+security_groups.name; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.security_groups
    ADD CONSTRAINT "uq:security_groups.project_id+security_groups.name" UNIQUE (project_id, name);


--
-- Name: service_accounts uq:service_accounts.project_id+service_accounts.name; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_accounts
    ADD CONSTRAINT "uq:service_accounts.project_id+service_accounts.name" UNIQUE (project_id, name);


--
-- Name: sites uq:sites.name; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sites
    ADD CONSTRAINT "uq:sites.name" UNIQUE (name);


--
-- Name: storage_pools uq:storage_pools.name; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.storage_pools
    ADD CONSTRAINT "uq:storage_pools.name" UNIQUE (name);


--
-- Name: user_credentials uq:user_credentials.credential_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_credentials
    ADD CONSTRAINT "uq:user_credentials.credential_id" UNIQUE (credential_id);


--
-- Name: user_groups uq:user_groups.user_id+user_groups.group_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_groups
    ADD CONSTRAINT "uq:user_groups.user_id+user_groups.group_id" UNIQUE (user_id, group_id);


--
-- Name: user_organizations uq:user_organizations.user_id+user_organizations.organization_i; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_organizations
    ADD CONSTRAINT "uq:user_organizations.user_id+user_organizations.organization_i" UNIQUE (user_id, organization_id);


--
-- Name: users uq:users.email; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT "uq:users.email" UNIQUE (email);


--
-- Name: users uq:users.username; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT "uq:users.username" UNIQUE (username);


--
-- Name: vm_interface_security_groups uq:vm_interface_security_groups.interface_id+vm_interface_secur; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vm_interface_security_groups
    ADD CONSTRAINT "uq:vm_interface_security_groups.interface_id+vm_interface_secur" UNIQUE (interface_id, security_group_id);


--
-- Name: vm_network_interfaces uq:vm_network_interfaces.vm_id+vm_network_interfaces.device_nam; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vm_network_interfaces
    ADD CONSTRAINT "uq:vm_network_interfaces.vm_id+vm_network_interfaces.device_nam" UNIQUE (vm_id, device_name);


--
-- Name: vm_network_interfaces uq_vm_network_interfaces_mac_address; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vm_network_interfaces
    ADD CONSTRAINT uq_vm_network_interfaces_mac_address UNIQUE (mac_address);


--
-- Name: volume_replicas uq:volume_replicas.volume_id+volume_replicas.agent_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.volume_replicas
    ADD CONSTRAINT "uq:volume_replicas.volume_id+volume_replicas.agent_id" UNIQUE (volume_id, agent_id);


--
-- Name: volume_snapshots uq:volume_snapshots.volume_id+volume_snapshots.name; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.volume_snapshots
    ADD CONSTRAINT "uq:volume_snapshots.volume_id+volume_snapshots.name" UNIQUE (volume_id, name);


--
-- Name: volumes uq:volumes.project_id+volumes.name; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.volumes
    ADD CONSTRAINT "uq:volumes.project_id+volumes.name" UNIQUE (project_id, name);


--
-- Name: workload_registrations uq:workload_registrations.spiffe_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workload_registrations
    ADD CONSTRAINT "uq:workload_registrations.spiffe_id" UNIQUE (spiffe_id);


--
-- Name: role_bindings uq_role_bindings_principal_role_node; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role_bindings
    ADD CONSTRAINT uq_role_bindings_principal_role_node UNIQUE (principal_type, principal_id, role_id, node_type, node_id);


--
-- Name: user_credentials user_credentials_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_credentials
    ADD CONSTRAINT user_credentials_pkey PRIMARY KEY (id);


--
-- Name: user_groups user_groups_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_groups
    ADD CONSTRAINT user_groups_pkey PRIMARY KEY (id);


--
-- Name: user_organizations user_organizations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_organizations
    ADD CONSTRAINT user_organizations_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: vm_interface_addresses vm_interface_addresses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vm_interface_addresses
    ADD CONSTRAINT vm_interface_addresses_pkey PRIMARY KEY (id);


--
-- Name: vm_interface_observed_addresses vm_interface_observed_addresses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vm_interface_observed_addresses
    ADD CONSTRAINT vm_interface_observed_addresses_pkey PRIMARY KEY (id);


--
-- Name: vm_interface_security_groups vm_interface_security_groups_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vm_interface_security_groups
    ADD CONSTRAINT vm_interface_security_groups_pkey PRIMARY KEY (id);


--
-- Name: vm_network_interfaces vm_network_interfaces_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vm_network_interfaces
    ADD CONSTRAINT vm_network_interfaces_pkey PRIMARY KEY (id);


--
-- Name: vm_snapshots vm_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vm_snapshots
    ADD CONSTRAINT vm_snapshots_pkey PRIMARY KEY (id);


--
-- Name: vms vms_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vms
    ADD CONSTRAINT vms_pkey PRIMARY KEY (id);


--
-- Name: volume_replicas volume_replicas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.volume_replicas
    ADD CONSTRAINT volume_replicas_pkey PRIMARY KEY (id);


--
-- Name: volume_snapshots volume_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.volume_snapshots
    ADD CONSTRAINT volume_snapshots_pkey PRIMARY KEY (id);


--
-- Name: volumes volumes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.volumes
    ADD CONSTRAINT volumes_pkey PRIMARY KEY (id);


--
-- Name: webhook_deliveries webhook_deliveries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.webhook_deliveries
    ADD CONSTRAINT webhook_deliveries_pkey PRIMARY KEY (id);


--
-- Name: webhook_subscriptions webhook_subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.webhook_subscriptions
    ADD CONSTRAINT webhook_subscriptions_pkey PRIMARY KEY (id);


--
-- Name: workload_registrations workload_registrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workload_registrations
    ADD CONSTRAINT workload_registrations_pkey PRIMARY KEY (id);


--
-- Name: idx_audit_events_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_events_created ON public.audit_events USING btree (created_at);


--
-- Name: idx_audit_events_org_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_events_org_created ON public.audit_events USING btree (organization_id, created_at);


--
-- Name: idx_audit_events_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_events_user_id ON public.audit_events USING btree (user_id);


--
-- Name: idx_floating_ips_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_floating_ips_project_id ON public.floating_ips USING btree (project_id);


--
-- Name: idx_iam_decision_logs_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_iam_decision_logs_created ON public.iam_decision_logs USING btree (created_at);


--
-- Name: idx_iam_decision_logs_credential; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_iam_decision_logs_credential ON public.iam_decision_logs USING btree (credential_id, created_at);


--
-- Name: idx_iam_guardrails_node; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_iam_guardrails_node ON public.iam_guardrails USING btree (node_type, node_id);


--
-- Name: idx_iam_policies_owner; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_iam_policies_owner ON public.iam_policies USING btree (owner_type, owner_id);


--
-- Name: idx_iam_policy_set_versions_version; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_iam_policy_set_versions_version ON public.iam_policy_set_versions USING btree (version DESC);


--
-- Name: idx_iam_roles_owner; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_iam_roles_owner ON public.iam_roles USING btree (owner_type, owner_id);


--
-- Name: idx_organizational_units_parent_ou_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_organizational_units_parent_ou_id ON public.organizational_units USING btree (parent_ou_id);


--
-- Name: idx_organizational_units_path_prefix; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_organizational_units_path_prefix ON public.organizational_units USING btree (path varchar_pattern_ops);


--
-- Name: idx_resource_events_actor; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_resource_events_actor ON public.resource_events USING btree (actor_type, actor_id, created_at DESC);


--
-- Name: idx_resource_events_org_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_resource_events_org_created ON public.resource_events USING btree (organization_id, created_at DESC);


--
-- Name: idx_resource_events_resource; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_resource_events_resource ON public.resource_events USING btree (resource_kind, resource_id, created_at DESC);


--
-- Name: idx_resource_events_terminal; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_resource_events_terminal ON public.resource_events USING btree (resource_kind, resource_id, created_at DESC) WHERE (phase <> 'requested'::text);


--
-- Name: idx_role_bindings_node; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_role_bindings_node ON public.role_bindings USING btree (node_type, node_id);


--
-- Name: idx_role_bindings_principal; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_role_bindings_principal ON public.role_bindings USING btree (principal_type, principal_id);


--
-- Name: idx_role_bindings_role_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_role_bindings_role_id ON public.role_bindings USING btree (role_id);


--
-- Name: idx_sandbox_interface_addresses_interface; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sandbox_interface_addresses_interface ON public.sandbox_interface_addresses USING btree (interface_id);


--
-- Name: idx_sandbox_network_interfaces_logical_network_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sandbox_network_interfaces_logical_network_id ON public.sandbox_network_interfaces USING btree (logical_network_id);


--
-- Name: idx_sandbox_network_interfaces_sandbox_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sandbox_network_interfaces_sandbox_id ON public.sandbox_network_interfaces USING btree (sandbox_id);


--
-- Name: idx_sandbox_snapshots_agent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sandbox_snapshots_agent_id ON public.sandbox_snapshots USING btree (agent_id);


--
-- Name: idx_sandbox_snapshots_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sandbox_snapshots_project_id ON public.sandbox_snapshots USING btree (project_id);


--
-- Name: idx_sandbox_snapshots_sandbox_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sandbox_snapshots_sandbox_id ON public.sandbox_snapshots USING btree (sandbox_id);


--
-- Name: idx_sandboxes_hypervisor_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sandboxes_hypervisor_id ON public.sandboxes USING btree (hypervisor_id);


--
-- Name: idx_sandboxes_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sandboxes_project_id ON public.sandboxes USING btree (project_id);


--
-- Name: idx_sandboxes_restored_from_snapshot_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sandboxes_restored_from_snapshot_id ON public.sandboxes USING btree (restored_from_snapshot_id);


--
-- Name: idx_sandboxes_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sandboxes_status ON public.sandboxes USING btree (status);


--
-- Name: idx_scim_external_ids_internal; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_scim_external_ids_internal ON public.scim_external_ids USING btree (organization_id, resource_type, internal_id);


--
-- Name: idx_user_groups_group_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_groups_group_id ON public.user_groups USING btree (group_id);


--
-- Name: idx_users_oidc_subject; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_users_oidc_subject ON public.users USING btree (oidc_subject) WHERE (oidc_subject IS NOT NULL);


--
-- Name: idx_vm_interface_addresses_interface; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_vm_interface_addresses_interface ON public.vm_interface_addresses USING btree (interface_id);


--
-- Name: idx_vm_interface_observed_addresses_iface_address; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_vm_interface_observed_addresses_iface_address ON public.vm_interface_observed_addresses USING btree (interface_id, address);


--
-- Name: idx_vm_interface_observed_addresses_interface; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_vm_interface_observed_addresses_interface ON public.vm_interface_observed_addresses USING btree (interface_id);


--
-- Name: idx_vm_network_interfaces_logical_network_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_vm_network_interfaces_logical_network_id ON public.vm_network_interfaces USING btree (logical_network_id);


--
-- Name: idx_vm_network_interfaces_vm_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_vm_network_interfaces_vm_id ON public.vm_network_interfaces USING btree (vm_id);


--
-- Name: idx_vm_snapshots_agent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_vm_snapshots_agent_id ON public.vm_snapshots USING btree (agent_id);


--
-- Name: idx_vm_snapshots_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_vm_snapshots_project_id ON public.vm_snapshots USING btree (project_id);


--
-- Name: idx_vm_snapshots_vm_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_vm_snapshots_vm_id ON public.vm_snapshots USING btree (vm_id);


--
-- Name: idx_vms_hypervisor_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_vms_hypervisor_id ON public.vms USING btree (hypervisor_id);


--
-- Name: idx_vms_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_vms_project_id ON public.vms USING btree (project_id);


--
-- Name: idx_vms_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_vms_status ON public.vms USING btree (status);


--
-- Name: idx_volume_replicas_agent_state; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_volume_replicas_agent_state ON public.volume_replicas USING btree (agent_id, state);


--
-- Name: idx_volume_snapshots_agent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_volume_snapshots_agent_id ON public.volume_snapshots USING btree (agent_id);


--
-- Name: idx_volume_snapshots_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_volume_snapshots_project_id ON public.volume_snapshots USING btree (project_id);


CREATE UNIQUE INDEX uq_ceph_clusters_site ON public.ceph_clusters USING btree (site_id);


CREATE UNIQUE INDEX uq_ceph_clusters_fsid ON public.ceph_clusters USING btree (fsid);


CREATE UNIQUE INDEX uq_ceph_clusters_secret ON public.ceph_clusters USING btree (keyring_secret_ref);


CREATE UNIQUE INDEX uq_ceph_project_accesses_cluster_project ON public.ceph_project_accesses USING btree (cluster_id, project_id);


CREATE UNIQUE INDEX uq_ceph_project_accesses_secret ON public.ceph_project_accesses USING btree (keyring_secret_ref);


CREATE UNIQUE INDEX uq_ceph_project_accesses_cluster_client ON public.ceph_project_accesses USING btree (cluster_id, client_name);


CREATE UNIQUE INDEX uq_ceph_credential_revocations_identity ON public.ceph_credential_revocations USING btree (cluster_id, credential_id);


CREATE INDEX idx_ceph_credential_revocations_site ON public.ceph_credential_revocations USING btree (site_id, created_at, id);


CREATE UNIQUE INDEX uq_storage_pools_ceph_project_access ON public.storage_pools USING btree (ceph_project_access_id) WHERE (ceph_project_access_id IS NOT NULL);


CREATE UNIQUE INDEX uq_storage_pools_ceph_namespace ON public.storage_pools USING btree (ceph_cluster_id, ceph_namespace) WHERE (mode = 'ceph'::text);


CREATE INDEX idx_volumes_reconciler_agent_id ON public.volumes USING btree (reconciler_agent_id) WHERE (reconciler_agent_id IS NOT NULL);


--
-- Name: idx_volumes_transitional; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_volumes_transitional ON public.volumes USING btree (status) WHERE (status = ANY (ARRAY['creating'::text, 'attaching'::text, 'detaching'::text, 'resizing'::text, 'snapshotting'::text, 'cloning'::text]));


--
-- Name: idx_volumes_vm_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_volumes_vm_id ON public.volumes USING btree (vm_id);


--
-- Name: idx_webhook_deliveries_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_webhook_deliveries_created_at ON public.webhook_deliveries USING btree (created_at);


--
-- Name: idx_webhook_deliveries_due; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_webhook_deliveries_due ON public.webhook_deliveries USING btree (status, next_attempt_at);


--
-- Name: idx_webhook_deliveries_pending_subscription_due; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_webhook_deliveries_pending_subscription_due ON public.webhook_deliveries USING btree (subscription_id, next_attempt_at, created_at, id) WHERE (status = 'pending'::text);


--
-- Name: idx_webhook_deliveries_pending_subscription_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_webhook_deliveries_pending_subscription_created ON public.webhook_deliveries USING btree (subscription_id, created_at, id) WHERE (status = 'pending'::text);


--
-- Name: idx_webhook_deliveries_subscription; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_webhook_deliveries_subscription ON public.webhook_deliveries USING btree (subscription_id, created_at);


--
-- Name: idx_webhook_deliveries_subscription_updated; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_webhook_deliveries_subscription_updated ON public.webhook_deliveries USING btree (subscription_id, updated_at DESC, created_at DESC);


--
-- Name: idx_webhook_deliveries_terminal_updated; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_webhook_deliveries_terminal_updated ON public.webhook_deliveries USING btree (updated_at) WHERE (status <> 'pending'::text);


--
-- Name: idx_webhook_subscriptions_org_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_webhook_subscriptions_org_active ON public.webhook_subscriptions USING btree (organization_id, is_active);


--
-- Name: idx_workload_registrations_vm_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_workload_registrations_vm_id ON public.workload_registrations USING btree (vm_id) WHERE (vm_id IS NOT NULL);


--
-- Name: ix_agent_workload_claims_tombstoned; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_agent_workload_claims_tombstoned ON public.agent_workload_claims USING btree (agent_id) WHERE (disposition = 'tombstoned'::text);


--
-- Name: ix_dns_records_zone; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_dns_records_zone ON public.dns_records USING btree (zone_id);


--
-- Name: ix_dns_zone_networks_network; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_dns_zone_networks_network ON public.dns_zone_networks USING btree (logical_network_id);


--
-- Name: ix_logical_networks_primary_dns_zone; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_logical_networks_primary_dns_zone ON public.logical_networks USING btree (primary_dns_zone_id);


--
-- Name: ix_sandbox_interface_security_groups_group; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_sandbox_interface_security_groups_group ON public.sandbox_interface_security_groups USING btree (security_group_id);


--
-- Name: ix_security_group_rules_group; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_security_group_rules_group ON public.security_group_rules USING btree (security_group_id);


--
-- Name: ix_security_group_rules_remote_group; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_security_group_rules_remote_group ON public.security_group_rules USING btree (remote_group_id);


--
-- Name: ix_vm_interface_security_groups_group; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_vm_interface_security_groups_group ON public.vm_interface_security_groups USING btree (security_group_id);


--
-- Name: logical_networks_resolver_index_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX logical_networks_resolver_index_key ON public.logical_networks USING btree (resolver_index) WHERE (resolver_index IS NOT NULL);


--
-- Name: uniq_vm_network_interfaces_vm_id_order_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uniq_vm_network_interfaces_vm_id_order_index ON public.vm_network_interfaces USING btree (vm_id, order_index);


--
-- Name: uniq_volumes_vm_canonical_boot; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uniq_volumes_vm_canonical_boot ON public.volumes USING btree (vm_id) WHERE ((vm_id IS NOT NULL) AND (type = 'boot'::text));


--
-- Name: uniq_volumes_vm_id_boot_order; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uniq_volumes_vm_id_boot_order ON public.volumes USING btree (vm_id, boot_order) WHERE ((vm_id IS NOT NULL) AND (boot_order IS NOT NULL));


--
-- Name: uniq_volumes_vm_id_device_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uniq_volumes_vm_id_device_name ON public.volumes USING btree (vm_id, device_name) WHERE (vm_id IS NOT NULL);


--
-- Name: uq_floating_ip_pools_org_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_floating_ip_pools_org_name ON public.floating_ip_pools USING btree (organization_id, name) WHERE (organization_id IS NOT NULL);


--
-- Name: uq_floating_ip_pools_ou_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_floating_ip_pools_ou_name ON public.floating_ip_pools USING btree (organizational_unit_id, name) WHERE (organizational_unit_id IS NOT NULL);


--
-- Name: uq_floating_ips_interface; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_floating_ips_interface ON public.floating_ips USING btree (interface_id) WHERE (interface_id IS NOT NULL);


--
-- Name: uq_sandbox_interface_addresses_network_address; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_sandbox_interface_addresses_network_address ON public.sandbox_interface_addresses USING btree (logical_network_id, address);


--
-- Name: uq_security_groups_default; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_security_groups_default ON public.security_groups USING btree (project_id) WHERE is_default;


--
-- Name: uq_vm_interface_addresses_network_address; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_vm_interface_addresses_network_address ON public.vm_interface_addresses USING btree (logical_network_id, address);


--
-- Name: resource_events trg_resource_events_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_resource_events_append_only BEFORE DELETE OR UPDATE ON public.resource_events FOR EACH ROW EXECUTE FUNCTION public.resource_events_reject_row_change();


--
-- Name: sandbox_network_interfaces trg_sandbox_network_interfaces_release_mac; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_sandbox_network_interfaces_release_mac AFTER DELETE ON public.sandbox_network_interfaces FOR EACH ROW EXECUTE FUNCTION public.release_mac_address_allocation('sandbox');


--
-- Name: vm_network_interfaces trg_vm_network_interfaces_release_mac; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_vm_network_interfaces_release_mac AFTER DELETE ON public.vm_network_interfaces FOR EACH ROW EXECUTE FUNCTION public.release_mac_address_allocation('vm');


--
-- Name: account_claim_tokens account_claim_tokens_created_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_claim_tokens
    ADD CONSTRAINT account_claim_tokens_created_by_id_fkey FOREIGN KEY (created_by_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: account_claim_tokens account_claim_tokens_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_claim_tokens
    ADD CONSTRAINT account_claim_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: agent_enrollments agent_enrollments_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_enrollments
    ADD CONSTRAINT agent_enrollments_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: agent_enrollments agent_enrollments_organizational_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_enrollments
    ADD CONSTRAINT agent_enrollments_organizational_unit_id_fkey FOREIGN KEY (organizational_unit_id) REFERENCES public.organizational_units(id) ON DELETE RESTRICT;


--
-- Name: agent_enrollments agent_enrollments_site_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_enrollments
    ADD CONSTRAINT agent_enrollments_site_id_fkey FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE SET NULL;


--
-- Name: agents agents_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agents
    ADD CONSTRAINT agents_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: agents agents_organizational_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agents
    ADD CONSTRAINT agents_organizational_unit_id_fkey FOREIGN KEY (organizational_unit_id) REFERENCES public.organizational_units(id) ON DELETE RESTRICT;


--
-- Name: agents agents_site_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agents
    ADD CONSTRAINT agents_site_id_fkey FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE SET NULL;


--
-- Name: api_keys api_keys_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_keys
    ADD CONSTRAINT api_keys_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: cli_sessions cli_sessions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cli_sessions
    ADD CONSTRAINT cli_sessions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: dns_records dns_records_created_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dns_records
    ADD CONSTRAINT dns_records_created_by_id_fkey FOREIGN KEY (created_by_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: dns_records dns_records_zone_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dns_records
    ADD CONSTRAINT dns_records_zone_id_fkey FOREIGN KEY (zone_id) REFERENCES public.dns_zones(id) ON DELETE CASCADE;


--
-- Name: dns_zone_networks dns_zone_networks_logical_network_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dns_zone_networks
    ADD CONSTRAINT dns_zone_networks_logical_network_id_fkey FOREIGN KEY (logical_network_id) REFERENCES public.logical_networks(id) ON DELETE CASCADE;


--
-- Name: dns_zone_networks dns_zone_networks_zone_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dns_zone_networks
    ADD CONSTRAINT dns_zone_networks_zone_id_fkey FOREIGN KEY (zone_id) REFERENCES public.dns_zones(id) ON DELETE CASCADE;


--
-- Name: dns_zones dns_zones_created_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dns_zones
    ADD CONSTRAINT dns_zones_created_by_id_fkey FOREIGN KEY (created_by_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: dns_zones dns_zones_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dns_zones
    ADD CONSTRAINT dns_zones_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: vms fk_vms_project_id_restrict; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vms
    ADD CONSTRAINT fk_vms_project_id_restrict FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE RESTRICT;


--
-- Name: volumes fk_volumes_vm_id_restrict; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.volumes
    ADD CONSTRAINT fk_volumes_vm_id_restrict FOREIGN KEY (vm_id) REFERENCES public.vms(id) ON DELETE RESTRICT;


--
-- Name: floating_ip_pools floating_ip_pools_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.floating_ip_pools
    ADD CONSTRAINT floating_ip_pools_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE SET NULL;


--
-- Name: floating_ip_pools floating_ip_pools_organizational_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.floating_ip_pools
    ADD CONSTRAINT floating_ip_pools_organizational_unit_id_fkey FOREIGN KEY (organizational_unit_id) REFERENCES public.organizational_units(id) ON DELETE SET NULL;


--
-- Name: floating_ip_pools floating_ip_pools_site_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.floating_ip_pools
    ADD CONSTRAINT floating_ip_pools_site_id_fkey FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE SET NULL;


--
-- Name: floating_ips floating_ips_created_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.floating_ips
    ADD CONSTRAINT floating_ips_created_by_id_fkey FOREIGN KEY (created_by_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: floating_ips floating_ips_interface_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.floating_ips
    ADD CONSTRAINT floating_ips_interface_id_fkey FOREIGN KEY (interface_id) REFERENCES public.vm_network_interfaces(id) ON DELETE SET NULL;


--
-- Name: floating_ips floating_ips_pool_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.floating_ips
    ADD CONSTRAINT floating_ips_pool_id_fkey FOREIGN KEY (pool_id) REFERENCES public.floating_ip_pools(id);


--
-- Name: floating_ips floating_ips_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.floating_ips
    ADD CONSTRAINT floating_ips_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: groups groups_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.groups
    ADD CONSTRAINT groups_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: image_artifacts image_artifacts_image_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.image_artifacts
    ADD CONSTRAINT image_artifacts_image_id_fkey FOREIGN KEY (image_id) REFERENCES public.images(id) ON DELETE CASCADE;


--
-- Name: images images_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.images
    ADD CONSTRAINT images_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: images images_uploaded_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.images
    ADD CONSTRAINT images_uploaded_by_id_fkey FOREIGN KEY (uploaded_by_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: logical_networks logical_networks_created_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.logical_networks
    ADD CONSTRAINT logical_networks_created_by_id_fkey FOREIGN KEY (created_by_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: logical_networks logical_networks_primary_dns_zone_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.logical_networks
    ADD CONSTRAINT logical_networks_primary_dns_zone_id_fkey FOREIGN KEY (primary_dns_zone_id) REFERENCES public.dns_zones(id) ON DELETE SET NULL;


--
-- Name: logical_networks logical_networks_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.logical_networks
    ADD CONSTRAINT logical_networks_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: logical_networks logical_networks_site_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.logical_networks
    ADD CONSTRAINT logical_networks_site_id_fkey FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE SET NULL;


--
-- Name: oauth_device_authorizations oauth_device_authorizations_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oauth_device_authorizations
    ADD CONSTRAINT oauth_device_authorizations_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: oidc_providers oidc_providers_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oidc_providers
    ADD CONSTRAINT oidc_providers_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: organizational_units organizational_units_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organizational_units
    ADD CONSTRAINT organizational_units_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: organizational_units organizational_units_parent_ou_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organizational_units
    ADD CONSTRAINT organizational_units_parent_ou_id_fkey FOREIGN KEY (parent_ou_id) REFERENCES public.organizational_units(id) ON DELETE CASCADE;


--
-- Name: projects projects_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.projects
    ADD CONSTRAINT projects_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: projects projects_organizational_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.projects
    ADD CONSTRAINT projects_organizational_unit_id_fkey FOREIGN KEY (organizational_unit_id) REFERENCES public.organizational_units(id) ON DELETE CASCADE;


--
-- Name: registry_pull_secrets registry_pull_secrets_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.registry_pull_secrets
    ADD CONSTRAINT registry_pull_secrets_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: resource_quotas resource_quotas_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_quotas
    ADD CONSTRAINT resource_quotas_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: resource_quotas resource_quotas_organizational_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_quotas
    ADD CONSTRAINT resource_quotas_organizational_unit_id_fkey FOREIGN KEY (organizational_unit_id) REFERENCES public.organizational_units(id) ON DELETE CASCADE;


--
-- Name: resource_quotas resource_quotas_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_quotas
    ADD CONSTRAINT resource_quotas_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: sandbox_interface_addresses sandbox_interface_addresses_interface_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sandbox_interface_addresses
    ADD CONSTRAINT sandbox_interface_addresses_interface_id_fkey FOREIGN KEY (interface_id) REFERENCES public.sandbox_network_interfaces(id) ON DELETE CASCADE;


--
-- Name: sandbox_interface_addresses sandbox_interface_addresses_logical_network_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sandbox_interface_addresses
    ADD CONSTRAINT sandbox_interface_addresses_logical_network_id_fkey FOREIGN KEY (logical_network_id) REFERENCES public.logical_networks(id) ON DELETE RESTRICT;


--
-- Name: sandbox_interface_security_groups sandbox_interface_security_groups_interface_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sandbox_interface_security_groups
    ADD CONSTRAINT sandbox_interface_security_groups_interface_id_fkey FOREIGN KEY (interface_id) REFERENCES public.sandbox_network_interfaces(id) ON DELETE CASCADE;


--
-- Name: sandbox_interface_security_groups sandbox_interface_security_groups_security_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sandbox_interface_security_groups
    ADD CONSTRAINT sandbox_interface_security_groups_security_group_id_fkey FOREIGN KEY (security_group_id) REFERENCES public.security_groups(id);


--
-- Name: sandbox_network_interfaces sandbox_network_interfaces_logical_network_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sandbox_network_interfaces
    ADD CONSTRAINT sandbox_network_interfaces_logical_network_id_fkey FOREIGN KEY (logical_network_id) REFERENCES public.logical_networks(id) ON DELETE RESTRICT;


--
-- Name: sandbox_network_interfaces sandbox_network_interfaces_sandbox_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sandbox_network_interfaces
    ADD CONSTRAINT sandbox_network_interfaces_sandbox_id_fkey FOREIGN KEY (sandbox_id) REFERENCES public.sandboxes(id) ON DELETE CASCADE;


--
-- Name: sandbox_snapshots sandbox_snapshots_created_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sandbox_snapshots
    ADD CONSTRAINT sandbox_snapshots_created_by_id_fkey FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- Name: sandbox_snapshots sandbox_snapshots_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sandbox_snapshots
    ADD CONSTRAINT sandbox_snapshots_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id);


--
-- Name: sandbox_snapshots sandbox_snapshots_sandbox_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sandbox_snapshots
    ADD CONSTRAINT sandbox_snapshots_sandbox_id_fkey FOREIGN KEY (sandbox_id) REFERENCES public.sandboxes(id) ON DELETE CASCADE;


--
-- Name: sandboxes sandboxes_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sandboxes
    ADD CONSTRAINT sandboxes_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id);


--
-- Name: scim_external_ids scim_external_ids_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scim_external_ids
    ADD CONSTRAINT scim_external_ids_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: scim_tokens scim_tokens_created_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scim_tokens
    ADD CONSTRAINT scim_tokens_created_by_id_fkey FOREIGN KEY (created_by_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: scim_tokens scim_tokens_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scim_tokens
    ADD CONSTRAINT scim_tokens_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: security_group_rules security_group_rules_remote_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.security_group_rules
    ADD CONSTRAINT security_group_rules_remote_group_id_fkey FOREIGN KEY (remote_group_id) REFERENCES public.security_groups(id);


--
-- Name: security_group_rules security_group_rules_security_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.security_group_rules
    ADD CONSTRAINT security_group_rules_security_group_id_fkey FOREIGN KEY (security_group_id) REFERENCES public.security_groups(id) ON DELETE CASCADE;


--
-- Name: security_groups security_groups_created_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.security_groups
    ADD CONSTRAINT security_groups_created_by_id_fkey FOREIGN KEY (created_by_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: security_groups security_groups_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.security_groups
    ADD CONSTRAINT security_groups_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: service_accounts service_accounts_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_accounts
    ADD CONSTRAINT service_accounts_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: sites sites_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sites
    ADD CONSTRAINT sites_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: sites sites_organizational_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sites
    ADD CONSTRAINT sites_organizational_unit_id_fkey FOREIGN KEY (organizational_unit_id) REFERENCES public.organizational_units(id) ON DELETE RESTRICT;


--
-- Name: ssf_streams ssf_streams_created_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ssf_streams
    ADD CONSTRAINT ssf_streams_created_by_id_fkey FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- Name: ssf_streams ssf_streams_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ssf_streams
    ADD CONSTRAINT ssf_streams_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: user_credentials user_credentials_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_credentials
    ADD CONSTRAINT user_credentials_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: user_groups user_groups_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_groups
    ADD CONSTRAINT user_groups_group_id_fkey FOREIGN KEY (group_id) REFERENCES public.groups(id) ON DELETE CASCADE;


--
-- Name: user_groups user_groups_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_groups
    ADD CONSTRAINT user_groups_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: user_organizations user_organizations_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_organizations
    ADD CONSTRAINT user_organizations_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: user_organizations user_organizations_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_organizations
    ADD CONSTRAINT user_organizations_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: users users_current_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_current_organization_id_fkey FOREIGN KEY (current_organization_id) REFERENCES public.organizations(id) ON DELETE SET NULL;


--
-- Name: users users_oidc_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_oidc_provider_id_fkey FOREIGN KEY (oidc_provider_id) REFERENCES public.oidc_providers(id) ON DELETE SET NULL;


--
-- Name: vm_interface_addresses vm_interface_addresses_interface_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vm_interface_addresses
    ADD CONSTRAINT vm_interface_addresses_interface_id_fkey FOREIGN KEY (interface_id) REFERENCES public.vm_network_interfaces(id) ON DELETE CASCADE;


--
-- Name: vm_interface_addresses vm_interface_addresses_logical_network_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vm_interface_addresses
    ADD CONSTRAINT vm_interface_addresses_logical_network_id_fkey FOREIGN KEY (logical_network_id) REFERENCES public.logical_networks(id) ON DELETE RESTRICT;


--
-- Name: vm_interface_observed_addresses vm_interface_observed_addresses_interface_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vm_interface_observed_addresses
    ADD CONSTRAINT vm_interface_observed_addresses_interface_id_fkey FOREIGN KEY (interface_id) REFERENCES public.vm_network_interfaces(id) ON DELETE CASCADE;


--
-- Name: vm_interface_security_groups vm_interface_security_groups_interface_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vm_interface_security_groups
    ADD CONSTRAINT vm_interface_security_groups_interface_id_fkey FOREIGN KEY (interface_id) REFERENCES public.vm_network_interfaces(id) ON DELETE CASCADE;


--
-- Name: vm_interface_security_groups vm_interface_security_groups_security_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vm_interface_security_groups
    ADD CONSTRAINT vm_interface_security_groups_security_group_id_fkey FOREIGN KEY (security_group_id) REFERENCES public.security_groups(id);


--
-- Name: vm_network_interfaces vm_network_interfaces_logical_network_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vm_network_interfaces
    ADD CONSTRAINT vm_network_interfaces_logical_network_id_fkey FOREIGN KEY (logical_network_id) REFERENCES public.logical_networks(id) ON DELETE RESTRICT;


--
-- Name: vm_network_interfaces vm_network_interfaces_vm_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vm_network_interfaces
    ADD CONSTRAINT vm_network_interfaces_vm_id_fkey FOREIGN KEY (vm_id) REFERENCES public.vms(id) ON DELETE CASCADE;


--
-- Name: vm_snapshots vm_snapshots_created_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vm_snapshots
    ADD CONSTRAINT vm_snapshots_created_by_id_fkey FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- Name: vm_snapshots vm_snapshots_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vm_snapshots
    ADD CONSTRAINT vm_snapshots_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id);


--
-- Name: vm_snapshots vm_snapshots_vm_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vm_snapshots
    ADD CONSTRAINT vm_snapshots_vm_id_fkey FOREIGN KEY (vm_id) REFERENCES public.vms(id) ON DELETE CASCADE;


--
-- Name: vms vms_image_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vms
    ADD CONSTRAINT vms_image_id_fkey FOREIGN KEY (image_id) REFERENCES public.images(id) ON DELETE SET NULL;


--
-- Name: volume_replicas volume_replicas_volume_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.volume_replicas
    ADD CONSTRAINT volume_replicas_volume_id_fkey FOREIGN KEY (volume_id) REFERENCES public.volumes(id) ON DELETE CASCADE;


--
-- Name: volume_snapshots volume_snapshots_created_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.volume_snapshots
    ADD CONSTRAINT volume_snapshots_created_by_id_fkey FOREIGN KEY (created_by_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: volume_snapshots volume_snapshots_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.volume_snapshots
    ADD CONSTRAINT volume_snapshots_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: volume_snapshots volume_snapshots_volume_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.volume_snapshots
    ADD CONSTRAINT volume_snapshots_volume_id_fkey FOREIGN KEY (volume_id) REFERENCES public.volumes(id) ON DELETE CASCADE;


--
-- Name: volumes volumes_created_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.storage_pools
    ADD CONSTRAINT storage_pools_site_id_fkey FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE RESTRICT;


ALTER TABLE ONLY public.storage_pools
    ADD CONSTRAINT storage_pools_ceph_cluster_id_fkey FOREIGN KEY (ceph_cluster_id) REFERENCES public.ceph_clusters(id) ON DELETE RESTRICT;


ALTER TABLE ONLY public.storage_pools
    ADD CONSTRAINT storage_pools_ceph_project_access_id_fkey FOREIGN KEY (ceph_project_access_id) REFERENCES public.ceph_project_accesses(id) ON DELETE RESTRICT;


--
-- Name: ceph_clusters ceph_clusters_site_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ceph_clusters
    ADD CONSTRAINT ceph_clusters_site_id_fkey FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE RESTRICT;


--
-- Name: ceph_clusters ceph_clusters_keyring_secret_ref_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ceph_clusters
    ADD CONSTRAINT ceph_clusters_keyring_secret_ref_fkey FOREIGN KEY (keyring_secret_ref) REFERENCES public.stored_secrets(id) ON DELETE RESTRICT;


--
-- Name: ceph_project_accesses ceph_project_accesses_cluster_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ceph_project_accesses
    ADD CONSTRAINT ceph_project_accesses_cluster_id_fkey FOREIGN KEY (cluster_id) REFERENCES public.ceph_clusters(id) ON DELETE RESTRICT;


--
-- Name: ceph_project_accesses ceph_project_accesses_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ceph_project_accesses
    ADD CONSTRAINT ceph_project_accesses_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE RESTRICT;


--
-- Name: ceph_project_accesses ceph_project_accesses_keyring_secret_ref_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ceph_project_accesses
    ADD CONSTRAINT ceph_project_accesses_keyring_secret_ref_fkey FOREIGN KEY (keyring_secret_ref) REFERENCES public.stored_secrets(id) ON DELETE RESTRICT;


--
-- Name: ceph_credential_revocations ceph_credential_revocations_site_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ceph_credential_revocations
    ADD CONSTRAINT ceph_credential_revocations_site_id_fkey FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE CASCADE;


-- Name: volumes volumes_created_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.volumes
    ADD CONSTRAINT volumes_created_by_id_fkey FOREIGN KEY (created_by_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: volumes volumes_pool_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.volumes
    ADD CONSTRAINT volumes_pool_id_fkey FOREIGN KEY (pool_id) REFERENCES public.storage_pools(id);


--
-- Name: volumes volumes_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.volumes
    ADD CONSTRAINT volumes_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: volumes volumes_source_image_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.volumes
    ADD CONSTRAINT volumes_source_image_id_fkey FOREIGN KEY (source_image_id) REFERENCES public.images(id) ON DELETE SET NULL;


--
-- Name: volumes volumes_source_volume_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.volumes
    ADD CONSTRAINT volumes_source_volume_id_fkey FOREIGN KEY (source_volume_id) REFERENCES public.volumes(id) ON DELETE SET NULL;


--
-- Name: webhook_deliveries webhook_deliveries_subscription_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.webhook_deliveries
    ADD CONSTRAINT webhook_deliveries_subscription_id_fkey FOREIGN KEY (subscription_id) REFERENCES public.webhook_subscriptions(id) ON DELETE CASCADE;


--
-- Name: webhook_subscriptions webhook_subscriptions_created_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.webhook_subscriptions
    ADD CONSTRAINT webhook_subscriptions_created_by_id_fkey FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- Name: webhook_subscriptions webhook_subscriptions_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.webhook_subscriptions
    ADD CONSTRAINT webhook_subscriptions_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: webhook_subscriptions webhook_subscriptions_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.webhook_subscriptions
    ADD CONSTRAINT webhook_subscriptions_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: workload_registrations workload_registrations_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workload_registrations
    ADD CONSTRAINT workload_registrations_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: workload_registrations workload_registrations_service_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workload_registrations
    ADD CONSTRAINT workload_registrations_service_account_id_fkey FOREIGN KEY (service_account_id) REFERENCES public.service_accounts(id) ON DELETE CASCADE;


--
-- Name: workload_registrations workload_registrations_vm_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workload_registrations
    ADD CONSTRAINT workload_registrations_vm_id_fkey FOREIGN KEY (vm_id) REFERENCES public.vms(id) ON DELETE CASCADE;


--
-- Seed data required by a fresh installation. Curated IAM roles, policy-set
-- versions, and application secrets are synchronized by configure() after the
-- migration; the default storage pool and Fluent enum bookkeeping originate in
-- the schema phase itself.
--

INSERT INTO public._fluent_enums (id, name, "case")
SELECT gen_random_uuid(), seed.name, seed."case"
FROM (VALUES
    ('agent_status', 'online'),
    ('agent_status', 'offline'),
    ('agent_status', 'connecting'),
    ('agent_status', 'error'),
    ('org_trust_domain_phase', 'pending'),
    ('org_trust_domain_phase', 'provisioning'),
    ('org_trust_domain_phase', 'active'),
    ('org_trust_domain_phase', 'failed'),
    ('org_trust_domain_phase', 'deleting'),
    ('workload_registration_kind', 'agent'),
    ('workload_registration_kind', 'service_account'),
    ('workload_registration_kind', 'workload')
) AS seed(name, "case");

INSERT INTO public.storage_pools (
    id, name, mode, replication_factor, member_agent_ids, backing, created_at, updated_at
) VALUES (
    gen_random_uuid(), 'default', 'local', 1, ARRAY[]::text[], 'filesystem', now(), now()
);


--
-- PostgreSQL database dump complete
--
