output "website_url" { value = "https://${aws_cloudfront_distribution.site.domain_name}" }
output "api_url" { value = local.api_origin }
output "images_bucket" { value = aws_s3_bucket.images.id }
output "website_bucket" { value = aws_s3_bucket.site.id }
output "cloudfront_distribution_id" { value = aws_cloudfront_distribution.site.id }
output "processor_lambda" { value = aws_lambda_function.processor.function_name }
