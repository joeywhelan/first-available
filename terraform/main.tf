# Everything the demo needs in Google Cloud. `terraform apply` builds it (notebook
# Section 1) and `terraform destroy` removes it (Section 12). APIs stay enabled.

# --- APIs -----------------------------------------------------------------------
# disable_on_destroy = false: destroy leaves the APIs on.

locals {
  apis = [
    "alloydb.googleapis.com",           # the database
    "aiplatform.googleapis.com",        # Vertex AI, for embeddings
    "compute.googleapis.com",           # the VPC network
    "servicenetworking.googleapis.com", # private services access
  ]
}

resource "google_project_service" "api" {
  for_each           = toset(local.apis)
  service            = each.value
  disable_on_destroy = false
}

# --- Network: a dedicated VPC with private services access ----------------------
# An AlloyDB cluster lives on a VPC. We reserve a private IP range on our own
# network and peer it with Google's services network.

resource "google_compute_network" "demo" {
  name       = var.network_name
  depends_on = [google_project_service.api]
}

resource "google_compute_global_address" "psa_range" {
  name          = "alloydb-psa-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.demo.id
}

resource "google_service_networking_connection" "psa" {
  network                 = google_compute_network.demo.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.psa_range.name]

  # On destroy, AlloyDB may still hold the connection for a while after the
  # cluster is gone. REMOVE_PEERING then drops the peering so the network can be
  # deleted; the provider documents it for tearing down short-lived networks.
  deletion_policy = "REMOVE_PEERING"
}

# --- AlloyDB --------------------------------------------------------------------

resource "google_alloydb_cluster" "demo" {
  cluster_id       = var.alloydb_cluster_id
  location         = var.gcp_region
  database_version = "POSTGRES_18"

  network_config {
    network            = google_compute_network.demo.id
    allocated_ip_range = google_compute_global_address.psa_range.name
  }

  initial_user {
    user                = var.db_admin_user
    password_wo         = var.db_admin_password # write-only: not stored in state
    password_wo_version = 1
  }

  deletion_policy     = "FORCE" # destroy deletes the cluster together with its instance
  deletion_protection = false

  depends_on = [google_service_networking_connection.psa]
}

resource "google_alloydb_instance" "primary" {
  cluster           = google_alloydb_cluster.demo.name
  instance_id       = var.alloydb_instance_id
  instance_type     = "PRIMARY"
  availability_type = "ZONAL" # one node; the default, REGIONAL, doubles the cost

  machine_config {
    machine_type = "c4a-highmem-1" # 1 vCPU, the smallest AlloyDB shape
  }

  # Public IP lets the notebook connect through the AlloyDB Python Connector.
  # No authorized networks: the connector authenticates with your Google login.
  network_config {
    enable_public_ip = true
  }

  # AlloyDB requires password complexity checks on any instance with a public IP.
  database_flags = {
    "password.enforce_complexity" = "on"
  }
}

# The MCP server's limited database user. No database roles: mcp_grants.sql gives
# it EXECUTE on the three tool functions and nothing else.
resource "google_alloydb_user" "mcp_search" {
  cluster             = google_alloydb_cluster.demo.name
  user_id             = "mcp_search"
  user_type           = "ALLOYDB_BUILT_IN"
  password_wo         = var.mcp_db_password # write-only: not stored in state
  password_wo_version = 1

  # mcp_grants.sql grants this role privileges, and Postgres won't drop a role that
  # holds any, so deleting the user alone fails. ABANDON makes destroy just forget it;
  # the cluster's FORCE deletion then removes it along with everything else.
  deletion_policy = "ABANDON"

  depends_on = [google_alloydb_instance.primary]
}

# --- Vertex AI access -------------------------------------------------------------
# AlloyDB calls Vertex AI as its Google-managed service agent, which needs the
# Vertex AI User role. The identity resource makes sure the agent exists.

resource "google_project_service_identity" "alloydb" {
  provider   = google-beta
  service    = "alloydb.googleapis.com"
  depends_on = [google_project_service.api]
}

resource "google_project_iam_member" "alloydb_vertex_user" {
  project = var.gcp_project_id
  role    = "roles/aiplatform.user"
  member  = google_project_service_identity.alloydb.member
}
