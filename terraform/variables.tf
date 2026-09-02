variable "region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-1"
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be dev, staging, or prod."
  }
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "startup-eks"
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster (MAJOR.MINOR)"
  type        = string
  default     = "1.36"

  validation {
    condition     = can(regex("^1\\.[0-9]+$", var.cluster_version))
    error_message = "cluster_version must be in MAJOR.MINOR format, e.g. 1.36."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "single_nat_gateway" {
  description = "Route all private subnets through one NAT gateway. Cuts cost, but makes egress depend on a single AZ. Intended for dev/POC only."
  type        = bool
  default     = false
}

variable "create_spot_service_linked_role" {
  description = "Create the EC2 Spot service-linked role. Set to false if the account already has it, since it is a one-per-account resource."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags applied to all resources"
  type        = map(string)
  default     = {}
}
