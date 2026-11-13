output "instance_public_ip" {
  description = "Public IP of the AlloyDB primary instance (reached through the AlloyDB Python Connector)."
  value       = google_alloydb_instance.primary.public_ip_address
}

output "alloydb_service_agent" {
  description = "AlloyDB's service agent, which calls Vertex AI for embeddings."
  value       = google_project_service_identity.alloydb.email
}

output "network" {
  description = "The demo's VPC network."
  value       = google_compute_network.demo.name
}
