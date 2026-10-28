variable "aws_region" {
  type    = string
  default = "eu-west-1"
}
variable "project_name" {
  type    = string
  default = "s3-smart-gallery"
}
variable "upload_token" {
  type        = string
  sensitive   = true
  description = "Stored in Terraform state and Lambda configuration."
}
variable "caption_model_id" {
  type        = string
  default     = "NONE"
  description = "Optional vision-capable Bedrock model ID/inference profile; NONE uses Rekognition labels only."
}
variable "force_destroy_buckets" {
  type        = bool
  default     = false
  description = "Set true for easy demo cleanup; destroys ALL images and website files on terraform destroy."
}
