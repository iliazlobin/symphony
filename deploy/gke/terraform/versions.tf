terraform {
  required_version = "= 1.16.1"
  required_providers {
    google = { source = "hashicorp/google", version = "7.40.0" }
  }
}

provider "google" {
  project = "iz27-platform-dev"
  region  = "us-west1"
  zone    = "us-west1-a"
}
