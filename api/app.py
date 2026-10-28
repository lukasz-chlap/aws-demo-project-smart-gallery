import base64
import hmac
import json
import os
import uuid
from decimal import Decimal

import boto3
from botocore.config import Config

# Always sign against the bucket's own regional endpoint. The global
# s3.amazonaws.com endpoint can return 307 on CORS preflight requests.
REGION = os.environ.get('AWS_REGION', 'eu-west-1')
s3 = boto3.client(
    's3',
    region_name=REGION,
    endpoint_url=f'https://s3.{REGION}.amazonaws.com',
    config=Config(signature_version='s3v4', s3={'addressing_style': 'virtual'}),
)
table = boto3.resource('dynamodb').Table(os.environ['IMAGES_TABLE'])
BUCKET = os.environ['IMAGES_BUCKET']


def response(status, data):
    return {'statusCode': status, 'headers': {'content-type': 'application/json', 'cache-control': 'no-store'},
            'body': json.dumps(data)}


def handler(event, context):
    route = event.get('routeKey', '')
    if route == 'POST /upload-url':
        provided = event.get('headers', {}).get('x-upload-token', '')
        if not hmac.compare_digest(provided, os.environ['UPLOAD_TOKEN']):
            return response(403, {'error': 'Incorrect upload passphrase'})
        try:
            body = json.loads(event.get('body') or '{}')
        except (ValueError, TypeError):
            return response(400, {'error': 'Invalid JSON'})
        mime = body.get('contentType', '')
        if mime not in ('image/jpeg', 'image/png', 'image/webp'):
            return response(400, {'error': 'Upload JPG, PNG or WebP only'})
        image_id = str(uuid.uuid4())
        ext = {'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp'}[mime]
        key = f'originals/{image_id}.{ext}'
        url = s3.generate_presigned_url('put_object', Params={
            'Bucket': BUCKET, 'Key': key, 'ContentType': mime,
        }, ExpiresIn=300)
        return response(200, {'uploadUrl': url, 'id': image_id, 'key': key})
    if route == 'GET /images':
        # Full table scan is intentionally limited to a small workshop/demo gallery.
        results = []
        params = {'Limit': 100}
        while len(results) < 100:
            page = table.scan(**params)
            results.extend(page.get('Items', []))
            if 'LastEvaluatedKey' not in page:
                break
            params['ExclusiveStartKey'] = page['LastEvaluatedKey']
        results.sort(key=lambda item: item.get('createdAt', ''), reverse=True)
        items = []
        for item in results[:100]:
            if item.get('status') != 'ready':
                continue
            thumb = s3.generate_presigned_url('get_object', Params={
                'Bucket': BUCKET, 'Key': item['thumbnailKey']
            }, ExpiresIn=900)
            original = s3.generate_presigned_url('get_object', Params={
                'Bucket': BUCKET, 'Key': item['originalKey']
            }, ExpiresIn=900)
            items.append({'id': item['id'], 'description': item.get('description', ''),
                          'labels': item.get('labels', []), 'createdAt': item['createdAt'],
                          'thumbnailUrl': thumb, 'originalUrl': original})
        return response(200, {'items': items})
    return response(404, {'error': 'Not found'})
