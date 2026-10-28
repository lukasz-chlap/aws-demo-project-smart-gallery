locals {
  name       = var.project_name
  api_origin = "https://${aws_apigatewayv2_api.gallery.id}.execute-api.${var.aws_region}.${data.aws_partition.current.dns_suffix}"
}
resource "random_id" "suffix" { byte_length = 4 }
resource "aws_s3_bucket" "site" {
  bucket        = "${local.name}-site-${random_id.suffix.hex}"
  force_destroy = var.force_destroy_buckets
}
resource "aws_s3_bucket" "images" {
  bucket        = "${local.name}-images-${random_id.suffix.hex}"
  force_destroy = var.force_destroy_buckets
}
resource "aws_s3_bucket_public_access_block" "site" {
  bucket                  = aws_s3_bucket.site.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_public_access_block" "images" {
  bucket                  = aws_s3_bucket.images.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_server_side_encryption_configuration" "site" {
  bucket = aws_s3_bucket.site.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
resource "aws_s3_bucket_server_side_encryption_configuration" "images" {
  bucket = aws_s3_bucket.images.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
resource "aws_s3_bucket_cors_configuration" "images" {
  bucket = aws_s3_bucket.images.id
  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "HEAD", "PUT"]
    allowed_origins = ["*"] # demo; restrict to CloudFront origin in production
    max_age_seconds = 300
  }
}
resource "aws_dynamodb_table" "images" {
  name         = "${local.name}-images-${random_id.suffix.hex}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"
  attribute {
    name = "id"
    type = "S"
  }
}
resource "aws_iam_role" "api" {
  name               = "${local.name}-api-${random_id.suffix.hex}"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }] })
}
resource "aws_iam_role" "processor" {
  name               = "${local.name}-processor-${random_id.suffix.hex}"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }] })
}
resource "aws_iam_role_policy_attachment" "api_logs" {
  role       = aws_iam_role.api.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
resource "aws_iam_role_policy_attachment" "processor_logs" {
  role       = aws_iam_role.processor.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
resource "aws_iam_role_policy" "api" {
  role = aws_iam_role.api.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["s3:PutObject"], Resource = ["${aws_s3_bucket.images.arn}/originals/*"] },
    { Effect = "Allow", Action = ["s3:GetObject"], Resource = ["${aws_s3_bucket.images.arn}/originals/*", "${aws_s3_bucket.images.arn}/thumbnails/*"] },
    { Effect = "Allow", Action = ["dynamodb:Scan"], Resource = [aws_dynamodb_table.images.arn] }
  ] })
}
resource "aws_iam_role_policy" "processor" {
  role = aws_iam_role.processor.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["s3:GetObject"], Resource = ["${aws_s3_bucket.images.arn}/originals/*", "${aws_s3_bucket.images.arn}/thumbnails/*"] },
    { Effect = "Allow", Action = ["s3:PutObject"], Resource = ["${aws_s3_bucket.images.arn}/thumbnails/*"] },
    { Effect = "Allow", Action = ["rekognition:DetectLabels"], Resource = ["*"] },
    { Effect = "Allow", Action = ["bedrock:InvokeModel"], Resource = ["*"] },
    { Effect = "Allow", Action = ["dynamodb:PutItem"], Resource = [aws_dynamodb_table.images.arn] }
  ] })
}
data "archive_file" "api" {
  type        = "zip"
  source_file = "${path.module}/../api/app.py"
  output_path = "${path.module}/../.build/api.zip"
}
resource "null_resource" "processor_build" {
  triggers = {
    requirements = filemd5("${path.module}/../processor/requirements.txt")
    app          = filemd5("${path.module}/../processor/app.py")
  }
  provisioner "local-exec" {
    command = <<-EOT
      mkdir -p ${path.module}/../.build/processor
      python3 -m pip install -q --upgrade --target ${path.module}/../.build/processor \
        --platform manylinux2014_x86_64 --python-version 3.12 \
        --implementation cp --only-binary=:all: \
        -r ${path.module}/../processor/requirements.txt
      cp ${path.module}/../processor/app.py ${path.module}/../.build/processor/app.py
    EOT
  }
}
data "archive_file" "processor" {
  type        = "zip"
  source_dir  = "${path.module}/../.build/processor"
  output_path = "${path.module}/../.build/processor.zip"
  depends_on  = [null_resource.processor_build]
}
resource "aws_lambda_function" "api" {
  function_name    = "${local.name}-api-${random_id.suffix.hex}"
  role             = aws_iam_role.api.arn
  filename         = data.archive_file.api.output_path
  source_code_hash = data.archive_file.api.output_base64sha256
  handler          = "app.handler"
  runtime          = "python3.12"
  timeout          = 15
  environment { variables = { IMAGES_TABLE = aws_dynamodb_table.images.name, IMAGES_BUCKET = aws_s3_bucket.images.id, UPLOAD_TOKEN = var.upload_token } }
}
resource "aws_lambda_function" "processor" {
  function_name    = "${local.name}-processor-${random_id.suffix.hex}"
  role             = aws_iam_role.processor.arn
  filename         = data.archive_file.processor.output_path
  source_code_hash = data.archive_file.processor.output_base64sha256
  handler          = "app.handler"
  runtime          = "python3.12"
  architectures    = ["x86_64"]
  memory_size      = 512
  timeout          = 90
  environment { variables = { IMAGES_TABLE = aws_dynamodb_table.images.name, IMAGES_BUCKET = aws_s3_bucket.images.id, CAPTION_MODEL_ID = var.caption_model_id } }
}
resource "aws_lambda_permission" "allow_s3" {
  statement_id   = "AllowS3Invoke"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.processor.function_name
  principal      = "s3.amazonaws.com"
  source_arn     = aws_s3_bucket.images.arn
  source_account = data.aws_caller_identity.current.account_id
}
resource "aws_s3_bucket_notification" "images" {
  bucket = aws_s3_bucket.images.id
  lambda_function {
    lambda_function_arn = aws_lambda_function.processor.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "originals/"
  }
  depends_on = [aws_lambda_permission.allow_s3]
}
resource "aws_apigatewayv2_api" "gallery" {
  name          = "${local.name}-${random_id.suffix.hex}"
  protocol_type = "HTTP"
  cors_configuration {
    allow_origins = ["*"] # demo only; restrict origin in production
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["content-type", "x-upload-token"]
    max_age       = 300
  }
}
resource "aws_apigatewayv2_integration" "api" {
  api_id                 = aws_apigatewayv2_api.gallery.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api.invoke_arn
  payload_format_version = "2.0"
}
resource "aws_apigatewayv2_route" "images" {
  api_id    = aws_apigatewayv2_api.gallery.id
  route_key = "GET /images"
  target    = "integrations/${aws_apigatewayv2_integration.api.id}"
}
resource "aws_apigatewayv2_route" "upload" {
  api_id    = aws_apigatewayv2_api.gallery.id
  route_key = "POST /upload-url"
  target    = "integrations/${aws_apigatewayv2_integration.api.id}"
}
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.gallery.id
  name        = "$default"
  auto_deploy = true
}
resource "aws_lambda_permission" "allow_api" {
  statement_id  = "AllowApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.gallery.execution_arn}/*/*"
}
resource "aws_cloudfront_origin_access_control" "site" {
  name                              = "${local.name}-${random_id.suffix.hex}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}
resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  default_root_object = "index.html"
  is_ipv6_enabled     = true
  price_class         = "PriceClass_100"
  origin {
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_id                = "site"
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }
  default_cache_behavior {
    target_origin_id       = "site"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
    min_ttl     = 0
    default_ttl = 60
    max_ttl     = 300
  }
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
  viewer_certificate { cloudfront_default_certificate = true }
}
data "aws_iam_policy_document" "cloudfront" {
  statement {
    sid       = "CloudFrontReadOnly"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.site.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.site.arn]
    }
  }
}
resource "aws_s3_bucket_policy" "site" {
  bucket     = aws_s3_bucket.site.id
  policy     = data.aws_iam_policy_document.cloudfront.json
  depends_on = [aws_s3_bucket_public_access_block.site]
}
resource "aws_s3_object" "index" {
  bucket        = aws_s3_bucket.site.id
  key           = "index.html"
  source        = "${path.module}/../site/index.html"
  etag          = filemd5("${path.module}/../site/index.html")
  content_type  = "text/html; charset=utf-8"
  cache_control = "no-cache"
}
resource "aws_s3_object" "config" {
  bucket        = aws_s3_bucket.site.id
  key           = "config.js"
  content       = "window.GALLERY_API_URL = ${jsonencode(local.api_origin)};\n"
  content_type  = "application/javascript; charset=utf-8"
  cache_control = "no-cache"
}
