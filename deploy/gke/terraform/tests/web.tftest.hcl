mock_provider "google" {}

run "protected_edge_bootstrap" {
  command = plan

  assert {
    condition     = length(google_iap_web_backend_service_iam_binding.web_owner) == 0
    error_message = "Bootstrap must not guess or grant access to a backend."
  }

  assert {
    condition = (
      google_certificate_manager_certificate_map_entry.web.hostname == "symphony.iliazlobin.com" &&
      google_certificate_manager_certificate_map_entry.web.matcher == null &&
      google_compute_ssl_policy.web.profile == "MODERN" &&
      google_compute_ssl_policy.web.min_tls_version == "TLS_1_2"
    )
    error_message = "TLS must select the exact Symphony hostname with the reviewed protocol policy."
  }
}

run "backend_scoped_single_operator" {
  command = plan
  variables {
    symphony_iap_backend_service_name = "gkegw1-verified-symphony-symphony-application"
  }

  assert {
    condition = (
      length(google_iap_web_backend_service_iam_binding.web_owner) == 1 &&
      google_iap_web_backend_service_iam_binding.web_owner[0].project == "iz27-platform-dev" &&
      google_iap_web_backend_service_iam_binding.web_owner[0].web_backend_service == var.symphony_iap_backend_service_name &&
      google_iap_web_backend_service_iam_binding.web_owner[0].role == "roles/iap.httpsResourceAccessor" &&
      google_iap_web_backend_service_iam_binding.web_owner[0].members == toset(["user:iliazlobin91@gmail.com"])
    )
    error_message = "Grant only the approved user on the verified Symphony backend."
  }
}

run "reject_another_application_backend" {
  command = plan
  variables {
    symphony_iap_backend_service_name = "gkegw1-other-application"
  }
  expect_failures = [var.symphony_iap_backend_service_name]
}
