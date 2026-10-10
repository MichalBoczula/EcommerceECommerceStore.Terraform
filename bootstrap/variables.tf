variable "subscription_id" {
  type = string
  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "Supply an Azure subscription UUID."
  }
}

variable "environment" {
  type    = string
  default = "dev"
  validation {
    condition     = contains(["dev", "portfolio"], var.environment)
    error_message = "Use dev or portfolio."
  }
}

variable "name_suffix" {
  type    = string
  default = "mike2026"
  validation {
    condition     = can(regex("^[a-z0-9]{3,8}$", var.name_suffix))
    error_message = "Use 3-8 lowercase letters/digits."
  }
}

variable "location" {
  type    = string
  default = "northeurope"
  validation {
    condition     = contains(["northeurope", "francecentral"], var.location)
    error_message = "Use northeurope or francecentral for this foundation."
  }
}

variable "resource_group_name" {
  type    = string
  default = null
}

variable "operator_object_id" {
  description = "Optional stable human operator UUID; defaults to the bootstrap caller."
  type        = string
  default     = null
  validation {
    condition     = var.operator_object_id == null ? true : can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.operator_object_id))
    error_message = "Use an Entra object UUID."
  }
}

variable "github_repository" {
  type    = string
  default = "MichalBoczula/EcommerceECommerceStore.Terraform"
  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "Use the GitHub owner/repository name."
  }
}
