import io
import logging
import os
import uuid
from datetime import datetime, timezone
from urllib.parse import unquote_plus

import boto3
from PIL import Image, ImageOps, UnidentifiedImageError

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)
s3 = boto3.client('s3')
rekognition = boto3.client('rekognition')
bedrock = boto3.client('bedrock-runtime')
table = boto3.resource('dynamodb').Table(os.environ['IMAGES_TABLE'])
BUCKET = os.environ['IMAGES_BUCKET']
MAX_BYTES = 8 * 1024 * 1024


def handler(event, context):
    for record in event.get('Records', []):
        key = unquote_plus(record['s3']['object']['key'])
        if not key.startswith('originals/'):
            continue
        image_id = key.rsplit('/', 1)[-1].split('.')[0]
        try:
            meta = s3.head_object(Bucket=BUCKET, Key=key)
            if meta['ContentLength'] > MAX_BYTES:
                raise ValueError('Image exceeds 8 MB size limit')
            raw = s3.get_object(Bucket=BUCKET, Key=key)['Body'].read()
            with Image.open(io.BytesIO(raw)) as img:
                img = ImageOps.exif_transpose(img)
                if img.width * img.height > 30_000_000:
                    raise ValueError('Image dimensions too large')
                img.thumbnail((400, 300))
                if img.mode != 'RGB':
                    img = img.convert('RGB')
                out = io.BytesIO()
                img.save(out, format='JPEG', quality=82, optimize=True)
            thumb_key = f'thumbnails/{image_id}.jpg'
            s3.put_object(Bucket=BUCKET, Key=thumb_key,
                          Body=out.getvalue(), ContentType='image/jpeg')
            # Rekognition returns object/scene labels, not generative prose captions.
            # Use image bytes so supported formats are handled consistently.
            # Rekognition DetectLabels accepts JPEG/PNG; the JPEG thumbnail is safe to analyze.
            response = rekognition.detect_labels(
                Image={'S3Object': {'Bucket': BUCKET, 'Name': thumb_key}},
                MaxLabels=8, MinConfidence=75)
            labels = [label['Name'] for label in response.get('Labels', [])]
            description = ('Detected: ' + ', '.join(labels[:6]) + '.') if labels else 'No recognizable objects detected.'
            model_id = os.environ.get('CAPTION_MODEL_ID', 'NONE')
            if model_id.upper() != 'NONE':
                try:
                    result = bedrock.converse(
                        modelId=model_id,
                        messages=[{'role': 'user', 'content': [
                            {'text': 'Describe what is visibly present in this image in one concise, factual English sentence. Avoid speculation and do not identify people.'},
                            {'image': {'format': 'jpeg', 'source': {'bytes': out.getvalue()}}}
                        ]}],
                        inferenceConfig={'maxTokens': 120, 'temperature': 0.2})
                    caption = ' '.join(block.get('text', '') for block in result['output']['message']['content']).strip()
                    if caption:
                        description = caption[:500]
                except Exception:
                    logger.exception('Bedrock captioning unavailable; using Rekognition labels')
            table.put_item(Item={
                'id': image_id, 'originalKey': key, 'thumbnailKey': thumb_key,
                'description': description, 'labels': labels,
                'createdAt': datetime.now(timezone.utc).isoformat(), 'status': 'ready'
            })
            logger.info('Processed %s', key)
        except Exception:
            logger.exception('Failed processing %s', key)
            raise
