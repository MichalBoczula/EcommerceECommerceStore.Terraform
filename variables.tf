variable "subscription_id" {
  description = "Azure subscription to deploy into; must match your az login context."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "Supply an Azure subscription UUID."
  }
}

variable "environment" {
  description = "Environment name. Use a separate local directory/state for each environment."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "portfolio"], var.environment)
    error_message = "Use dev or portfolio."
  }
}

variable "name_suffix" {
  description = "Stable suffix for globally unique Storage, SQL, Mongo and Key Vault names."
  type        = string
  default     = "mike2026"

  validation {
    condition     = can(regex("^[a-z0-9]{3,8}$", var.name_suffix))
    error_message = "Use 3-8 lowercase letters/digits; keep the suffix unchanged for this state."
  }
}

variable "resource_group_name" {
  description = "Optional override; must match the persistent bootstrap resource group."
  type        = string
  default     = null
  nullable    = true
}

variable "operator_object_id" {
  description = "Human operator's Entra object UUID; keep identical locally and in CI. Bootstrap exports this value."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.operator_object_id))
    error_message = "Supply the operator's Entra object UUID from bootstrap output."
  }
}

variable "location" {
  description = "Region for ACA, VNet, Storage, Key Vault and the Free DocumentDB cluster."
  type        = string
  default     = "northeurope"

  validation {
    condition     = contains(["northeurope", "francecentral"], var.location)
    error_message = "Use northeurope or francecentral for this foundation."
  }
}

variable "static_web_app_location" {
  description = "Static Web Apps provisioning region, independent of the ACA and database regions. Azure subscription eligibility is checked during apply."
  type        = string
  default     = "eastus2"

  validation {
    condition     = contains(["centralus", "eastus2", "westus2", "westeurope", "eastasia"], var.static_web_app_location)
    error_message = "Use centralus, eastus2, westus2, westeurope or eastasia for Static Web Apps."
  }
}

variable "sql_location" {
  description = "Keep France Central: the subscription's SQL Free offer was admitted there."
  type        = string
  default     = "francecentral"
}

variable "sql_admin_password" {
  description = "SQL administrator password. Supply through TF_VAR_sql_admin_password."
  type        = string
  sensitive   = true

  validation {
    condition = (
      length(var.sql_admin_password) >= 16 && length(var.sql_admin_password) <= 64 &&
      can(regex("[A-Z]", var.sql_admin_password)) && can(regex("[a-z]", var.sql_admin_password)) &&
      can(regex("[0-9]", var.sql_admin_password)) && can(regex("[^A-Za-z0-9]", var.sql_admin_password))
    )
    error_message = "Use 16-64 characters including uppercase, lowercase, a digit and a symbol."
  }
}

variable "mongo_admin_password" {
  description = "DocumentDB administrator password. Supply through TF_VAR_mongo_admin_password."
  type        = string
  sensitive   = true

  validation {
    condition = (
      length(var.mongo_admin_password) >= 16 && length(var.mongo_admin_password) <= 64 &&
      can(regex("[A-Z]", var.mongo_admin_password)) && can(regex("[a-z]", var.mongo_admin_password)) &&
      can(regex("[0-9]", var.mongo_admin_password)) && can(regex("[^A-Za-z0-9]", var.mongo_admin_password))
    )
    error_message = "Use 16-64 characters including uppercase, lowercase, a digit and a symbol."
  }
}

variable "operator_ipv4" {
  description = "Optional single public IPv4 for local database connections. Null creates no firewall rules."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition = var.operator_ipv4 == null ? true : (
      can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$", var.operator_ipv4)) &&
      can(cidrhost("${var.operator_ipv4}/32", 0)) &&
      !contains(["0.0.0.0", "255.255.255.255", "127.0.0.1"], var.operator_ipv4)
    )
    error_message = "Supply one valid public IPv4, without a CIDR suffix; Azure-wide access is not an operator IP."
  }
}
