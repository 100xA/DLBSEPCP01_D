import hashlib
import json
import os
import re
import time
from datetime import datetime, timezone
from email import policy
from email.parser import BytesParser
from email.utils import getaddresses, parsedate_to_datetime
from urllib.parse import unquote_plus

try:
    import boto3
except ImportError:
    boto3 = None


_s3_client = None
_comprehend_client = None
_table = None

TABLE_NAME = os.environ.get("TABLE_NAME", "")
TENANT_ID = os.environ.get("TENANT_ID", "support-team")
RAW_EMAIL_RETENTION_DAYS = int(os.environ.get("RAW_EMAIL_RETENTION_DAYS", "30"))
RETENTION_SECONDS = RAW_EMAIL_RETENTION_DAYS * 24 * 60 * 60
DEFAULT_LANGUAGE = "de"
UNKNOWN_SENTIMENT = "UNKNOWN"
TEXT_SAMPLE_LIMIT = 4500
KEY_PHRASE_LIMIT = 8

TOPIC_KEYWORDS = {
    "billing": [
        "rechnung",
        "invoice",
        "zahlung",
        "payment",
        "mahnung",
        "gutschrift",
    ],
    "support_incident": [
        "fehler",
        "error",
        "bug",
        "störung",
        "stoerung",
        "ausfall",
        "incident",
        "problem",
        "system down",
        "down",
        "nicht erreichbar",
    ],
    "sales": ["angebot", "quote", "preis", "demo", "vertrag anfragen", "sales"],
    "legal_privacy": [
        "datenschutz",
        "dsgvo",
        "gdpr",
        "privacy",
        "löschung",
        "loeschung",
    ],
    "contract": ["vertrag", "kündigung", "kuendigung", "frist", "renewal"],
    "hr": ["bewerbung", "application", "lebenslauf", "cv", "interview"],
}

HIGH_URGENCY = [
    "dringend",
    "urgent",
    "sofort",
    "asap",
    "ausfall",
    "notfall",
    "deadline",
    "frist heute",
    "system down",
    "kritisch",
]
MEDIUM_URGENCY = [
    "wichtig",
    "important",
    "bitte prüfen",
    "bitte pruefen",
    "rückmeldung",
    "rueckmeldung",
    "frist",
    "beschwerde",
    "complaint",
]


def lambda_handler(event, _context):
    results = [
        process_s3_record(record)
        for record in event.get("Records", [])
        if record.get("eventSource") == "aws:s3"
    ]
    return {
        "statusCode": 200,
        "body": json.dumps({"processed": len(results), "results": results}),
    }


def process_s3_record(record):
    bucket = record["s3"]["bucket"]["name"]
    key = unquote_plus(record["s3"]["object"]["key"])

    raw_email = get_s3_client().get_object(Bucket=bucket, Key=key)["Body"].read()
    metadata = build_metadata(raw_email, bucket, key)
    get_table().put_item(Item=metadata)

    return {
        "email_id": metadata["email_id"],
        "category": metadata["category"],
        "urgency": metadata["urgency"],
    }


def build_metadata(raw_email, bucket, key):
    parsed = parse_email(raw_email)
    analysis = analyze_email(parsed["subject"], parsed["body"])

    return compact_item(
        {
            "email_id": parsed["email_id"],
            "tenant_id": TENANT_ID,
            "subject": parsed["subject"],
            "sender": parsed["sender"],
            "recipients": parsed["recipients"],
            "received_at": parsed["received_at"],
            **analysis,
            "preview": parsed["body"][:500],
            "s3_bucket": bucket,
            "s3_key": key,
            "expires_at": int(time.time()) + RETENTION_SECONDS,
        }
    )


def parse_email(raw_email):
    message = BytesParser(policy=policy.default).parsebytes(raw_email)
    subject = normalize_space(str(message.get("subject", "")))
    sender = normalize_space(str(message.get("from", "")))
    recipient_headers = message.get_all("to", []) + message.get_all("cc", [])
    recipients = [
        address for _name, address in getaddresses(recipient_headers) if address
    ]
    received_at = parse_message_date(message.get("date"))
    body = normalize_space(extract_text(message))

    message_id = safe_identifier(
        normalize_space(str(message.get("message-id", ""))).strip("<>")
    )
    fallback_id = hashlib.sha256(raw_email).hexdigest()[:32]

    return {
        "email_id": message_id or fallback_id,
        "subject": subject or "(ohne Betreff)",
        "sender": sender or "unbekannt",
        "recipients": recipients,
        "received_at": received_at,
        "body": body,
    }


def extract_text(message):
    if message.is_multipart():
        parts = {"text/plain": [], "text/html": []}
        for part in message.walk():
            content_type = part.get_content_type()
            if (
                part.get_content_disposition() == "attachment"
                or content_type not in parts
            ):
                continue
            content = read_content(part)
            if content is None:
                continue
            if content_type == "text/plain":
                parts[content_type].append(content)
            else:
                parts[content_type].append(strip_html(content))
        return "\n".join(parts["text/plain"] or parts["text/html"])

    content = read_content(message)
    if content is None:
        return ""
    if message.get_content_type() == "text/html":
        return strip_html(content)
    return content


def read_content(message):
    try:
        return str(message.get_content())
    except Exception:
        return None


def analyze_email(subject, body):
    text = normalize_space(f"{subject}\n{body}")
    lower_text = text.lower()
    language = DEFAULT_LANGUAGE
    sentiment = UNKNOWN_SENTIMENT
    key_phrases = []

    comprehend = get_comprehend_client(optional=True)
    if comprehend and text:
        language, sentiment, key_phrases = analyze_with_comprehend(comprehend, text)

    category = classify_topic(lower_text)
    urgency = classify_urgency(lower_text, sentiment, category)

    return {
        "category": category,
        "urgency": urgency,
        "sentiment": sentiment,
        "language": language,
        "key_phrases": key_phrases,
    }


def analyze_with_comprehend(comprehend, text):
    language = DEFAULT_LANGUAGE
    sentiment = UNKNOWN_SENTIMENT
    key_phrases = []

    try:
        sample = text[:TEXT_SAMPLE_LIMIT]
        languages = comprehend.detect_dominant_language(Text=sample).get(
            "Languages", []
        )
        if languages:
            language = languages[0].get("LanguageCode", language)
        sentiment = comprehend.detect_sentiment(Text=sample, LanguageCode=language).get(
            "Sentiment",
            sentiment,
        )
        phrases = comprehend.detect_key_phrases(Text=sample, LanguageCode=language)
        key_phrases = [
            phrase.get("Text", "")
            for phrase in phrases.get("KeyPhrases", [])[:KEY_PHRASE_LIMIT]
            if phrase.get("Text")
        ]
    except Exception:
        sentiment = UNKNOWN_SENTIMENT

    return language, sentiment, key_phrases


def classify_topic(lower_text):
    scores = {
        topic: sum(1 for keyword in keywords if keyword in lower_text)
        for topic, keywords in TOPIC_KEYWORDS.items()
    }
    best_topic, best_score = max(scores.items(), key=lambda item: item[1])
    return best_topic if best_score > 0 else "general"


def classify_urgency(lower_text, sentiment, category):
    if any(keyword in lower_text for keyword in HIGH_URGENCY):
        return "high"
    if category == "support_incident" and sentiment in {"NEGATIVE", "MIXED"}:
        return "high"
    if any(keyword in lower_text for keyword in MEDIUM_URGENCY):
        return "medium"
    if category in {"legal_privacy", "contract"}:
        return "medium"
    return "low"


def parse_message_date(date_header):
    if date_header:
        try:
            parsed = parsedate_to_datetime(date_header)
            if parsed.tzinfo is None:
                parsed = parsed.replace(tzinfo=timezone.utc)
            return parsed.astimezone(timezone.utc).isoformat()
        except Exception:
            pass
    return datetime.now(timezone.utc).isoformat()


def normalize_space(value):
    return re.sub(r"\s+", " ", value or "").strip()


def strip_html(value):
    without_tags = re.sub(r"<[^>]+>", " ", value)
    return re.sub(r"&nbsp;|&amp;|&lt;|&gt;", " ", without_tags)


def safe_identifier(value):
    return re.sub(r"[^A-Za-z0-9._@-]", "-", value or "")[:180].strip("-")


def compact_item(item):
    return {key: value for key, value in item.items() if value not in (None, "", [])}


def get_s3_client():
    global _s3_client
    if _s3_client is None:
        ensure_boto3()
        _s3_client = boto3.client("s3")
    return _s3_client


def get_comprehend_client(optional=False):
    global _comprehend_client
    if _comprehend_client is None:
        if boto3 is None:
            if optional:
                return None
            ensure_boto3()
        _comprehend_client = boto3.client("comprehend")
    return _comprehend_client


def get_table():
    global _table
    if _table is None:
        ensure_boto3()
        _table = boto3.resource("dynamodb").Table(TABLE_NAME)
    return _table


def ensure_boto3():
    if boto3 is None:
        raise RuntimeError(
            "boto3 is required in AWS Lambda or must be injected for tests"
        )
