import json
import os
from decimal import Decimal

try:
    import boto3
except ImportError:  # boto3 is available in AWS Lambda.
    boto3 = None


TABLE_NAME = os.environ.get("TABLE_NAME", "")
TENANT_ID = os.environ.get("TENANT_ID", "support-team")
RAW_EMAIL_BUCKET = os.environ.get("RAW_EMAIL_BUCKET", "")
NOT_FOUND = {"message": "Email metadata not found"}
ALLOWED_ORIGINS = [
    origin.strip()
    for origin in os.environ.get("ALLOWED_ORIGINS", "*").split(",")
    if origin.strip()
]
CORS_HEADERS = {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": ALLOWED_ORIGINS[0] if ALLOWED_ORIGINS else "*",
    "Access-Control-Allow-Headers": "content-type,authorization",
    "Access-Control-Allow-Methods": "GET,DELETE,OPTIONS",
}

_table = None
_s3_client = None


def lambda_handler(event, _context):
    method = event.get("requestContext", {}).get("http", {}).get("method", "GET")
    raw_path = event.get("rawPath", "/")
    path_parameters = event.get("pathParameters") or {}

    if method == "OPTIONS":
        return response(204, None)
    if method == "GET" and raw_path == "/health":
        return response(200, {"status": "ok"})
    if method == "GET" and raw_path == "/emails":
        return response(200, list_emails(event.get("queryStringParameters") or {}))

    email_id = path_parameters.get("email_id")
    if email_id:
        handlers = {"GET": get_email, "DELETE": delete_email}
        if method in handlers:
            return handlers[method](email_id)
    return response(404, {"message": "Not found"})


def list_emails(query):
    limit = clamp_int(query.get("limit", "50"), minimum=1, maximum=100)
    result = get_table().query(
        IndexName="tenant-received_at-index",
        KeyConditionExpression="#tenant = :tenant",
        ExpressionAttributeNames={"#tenant": "tenant_id"},
        ExpressionAttributeValues={":tenant": TENANT_ID},
        ScanIndexForward=False,
        Limit=limit,
    )
    return {"items": result.get("Items", []), "count": result.get("Count", 0)}


def get_email(email_id):
    item = fetch_email(email_id)
    if not item:
        return response(404, NOT_FOUND)
    return response(200, item)


def delete_email(email_id):
    table = get_table()
    existing = fetch_email(email_id, table)
    if not existing:
        return response(404, NOT_FOUND)

    delete_raw_email(existing)

    table.delete_item(Key={"email_id": email_id})
    return response(200, {"deleted": email_id})


def fetch_email(email_id, table=None):
    return (table or get_table()).get_item(Key={"email_id": email_id}).get("Item")


def delete_raw_email(item):
    bucket = item.get("s3_bucket") or RAW_EMAIL_BUCKET
    key = item.get("s3_key")
    if bucket and key:
        get_s3_client().delete_object(Bucket=bucket, Key=key)


def response(status_code, payload):
    body = "" if payload is None else json.dumps(payload, default=json_default)
    return {"statusCode": status_code, "headers": CORS_HEADERS, "body": body}


def clamp_int(value, minimum, maximum):
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        parsed = minimum
    return max(minimum, min(maximum, parsed))


def json_default(value):
    if isinstance(value, Decimal):
        if value % 1 == 0:
            return int(value)
        return float(value)
    raise TypeError(f"Object of type {type(value).__name__} is not JSON serializable")


def get_table():
    global _table
    if _table is None:
        ensure_boto3()
        _table = boto3.resource("dynamodb").Table(TABLE_NAME)
    return _table


def get_s3_client():
    global _s3_client
    if _s3_client is None:
        ensure_boto3()
        _s3_client = boto3.client("s3")
    return _s3_client


def ensure_boto3():
    if boto3 is None:
        raise RuntimeError("boto3 is required in AWS Lambda or must be injected for tests")
