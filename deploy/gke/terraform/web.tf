# Symphony owns its public edge; the shared Gateway controller remains platform-owned.
# OAuth client secrets are delivered privately to Kubernetes, never to Terraform.
locals {
  web_hostname = "symphony.iliazlobin.com"
}

resource "google_compute_global_address" "web" {
  project      = local.project
  name         = "symphony-web-ip"
  address_type = "EXTERNAL"
  ip_version   = "IPV4"
  labels       = local.labels
  lifecycle { prevent_destroy = true }
}

resource "google_certificate_manager_dns_authorization" "web" {
  project  = local.project
  name     = "symphony-web-dns"
  location = "global"
  domain   = local.web_hostname
  type     = "PER_PROJECT_RECORD"
  labels   = local.labels
  lifecycle { prevent_destroy = true }
}

resource "google_certificate_manager_certificate" "web" {
  project         = local.project
  name            = "symphony-web-tls"
  location        = "global"
  scope           = "DEFAULT"
  labels          = local.labels
  deletion_policy = "PREVENT"
  managed {
    domains            = [local.web_hostname]
    dns_authorizations = [google_certificate_manager_dns_authorization.web.id]
  }
  lifecycle { prevent_destroy = true }
}

resource "google_certificate_manager_certificate_map" "web" {
  project = local.project
  name    = "symphony-web-cert-map"
  labels  = local.labels
  lifecycle { prevent_destroy = true }
}

resource "google_certificate_manager_certificate_map_entry" "web" {
  project         = local.project
  name            = "symphony-web-host"
  map             = google_certificate_manager_certificate_map.web.name
  hostname        = local.web_hostname
  certificates    = [google_certificate_manager_certificate.web.id]
  labels          = local.labels
  deletion_policy = "PREVENT"
  lifecycle { prevent_destroy = true }
}

resource "google_compute_ssl_policy" "web" {
  project         = local.project
  name            = "symphony-web-tls"
  profile         = "MODERN"
  min_tls_version = "TLS_1_2"
  lifecycle { prevent_destroy = true }
}

# Set only after the bootstrap Gateway creates the exact Symphony backend.
# The application independently verifies its numeric JWT audience and email.
variable "symphony_iap_backend_service_name" {
  type        = string
  default     = null
  description = "Verified global backend name for the symphony/symphony-application Service; null during edge bootstrap."
  validation {
    condition = var.symphony_iap_backend_service_name == null ? true : (
      can(regex("^gkegw1-[a-z0-9-]+$", var.symphony_iap_backend_service_name)) &&
      strcontains(var.symphony_iap_backend_service_name, "symphony") &&
      length(var.symphony_iap_backend_service_name) <= 63
    )
    error_message = "Use the verified GKE Gateway backend name belonging to Symphony."
  }
}

resource "google_iap_web_backend_service_iam_binding" "web_owner" {
  count               = var.symphony_iap_backend_service_name == null ? 0 : 1
  project             = local.project
  web_backend_service = var.symphony_iap_backend_service_name
  role                = "roles/iap.httpsResourceAccessor"
  members             = ["user:iliazlobin91@gmail.com"]
  # Omitting the saved bootstrap input must fail, not silently remove access.
  lifecycle { prevent_destroy = true }
}

output "web_dns_address" {
  value = { name = local.web_hostname, type = "A", data = google_compute_global_address.web.address }
}

output "web_dns_authorization" {
  value = google_certificate_manager_dns_authorization.web.dns_resource_record[0]
}

output "web_certificate_map" {
  value = google_certificate_manager_certificate_map.web.name
}

output "web_ssl_policy" {
  value = google_compute_ssl_policy.web.name
}
