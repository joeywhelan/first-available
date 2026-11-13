# The notebook sets these from .env as TF_VAR_* environment variables
# (for example GCP_PROJECT_ID becomes TF_VAR_gcp_project_id).

variable "gcp_project_id" {
  description = "Google Cloud project for the demo."
  type        = string
}

variable "gcp_region" {
  description = "Region for the AlloyDB cluster. Must offer the 1 vCPU C4A shape (c4a-highmem-1)."
  type        = string
}

variable "alloydb_cluster_id" {
  description = "AlloyDB cluster ID."
  type        = string
}

variable "alloydb_instance_id" {
  description = "AlloyDB primary instance ID."
  type        = string
}

variable "db_admin_user" {
  description = "Built-in admin user the notebook connects as."
  type        = string
}

# Ephemeral + write-only: the passwords are sent to AlloyDB but never stored in
# the Terraform state or plan files.
variable "db_admin_password" {
  description = "Password for the admin user."
  type        = string
  sensitive   = true
  ephemeral   = true
}

variable "mcp_db_password" {
  description = "Password for mcp_search, the MCP server's limited database user."
  type        = string
  sensitive   = true
  ephemeral   = true
}

variable "network_name" {
  description = "VPC network created for this demo (deleted again by terraform destroy)."
  type        = string
  default     = "summit-demo-net"
}
