terraform {
  cloud {
    hostname = "app.terraform.io"
    # Supply the organization using TF_CLOUD_ORGANIZATION.
    organization = "jasonumiker"
    workspaces {
      name = "aks"
    }
  }
}
