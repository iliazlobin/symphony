locals {
  project = "iz27-platform-dev"
  labels  = { application = "symphony", environment = "development", managed_by = "terraform" }
}

# This root owns only Symphony resources. Shared GKE, networking and pools stay
# in gcp-foundation. Credentials and model-auth payloads never enter Terraform.
resource "google_artifact_registry_repository" "symphony" {
  project       = local.project
  location      = "us-west1"
  repository_id = "symphony"
  description   = "Pinned Symphony controller and worker images"
  format        = "DOCKER"
  labels        = local.labels
  docker_config { immutable_tags = true }
  lifecycle { prevent_destroy = true }
}

# Image pulls run as the node identity, not the application Pod's identity.
# Scope this grant to the new repository; grant no project-wide access.
resource "google_artifact_registry_repository_iam_member" "node_reader" {
  project    = local.project
  location   = google_artifact_registry_repository.symphony.location
  repository = google_artifact_registry_repository.symphony.repository_id
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:platform-dev-node@${local.project}.iam.gserviceaccount.com"
}

resource "google_storage_bucket" "terraform_state" {
  project                     = local.project
  name                        = "${local.project}-symphony-tfstate"
  location                    = "US-WEST1"
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  labels                      = local.labels
  versioning { enabled = true }
  soft_delete_policy { retention_duration_seconds = 604800 }
  lifecycle { prevent_destroy = true }
}

output "controller_image_repository" {
  value = "us-west1-docker.pkg.dev/${local.project}/${google_artifact_registry_repository.symphony.repository_id}/controller"
}

output "terraform_state_bucket" {
  value = google_storage_bucket.terraform_state.name
}
