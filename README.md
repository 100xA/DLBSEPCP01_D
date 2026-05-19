# Automatische E-Mail-Kategorisierung 

Finale Phase 3DLBSEPCP01_D

## Architektur

Der PoC läuft auf AWS in `eu-central-1` [hier](https://d21ojfb0of1n3j.cloudfront.net):

1. Amazon SES oder ein manueller `.eml`-Upload legt Raw-E-Mails in Amazon S3 ab
2. Ein S3-Event startet die Classifier-Lambda
3. Die Lambda parst die E-Mail, nutzt Amazon Comprehend und ergaenzt regelbasierte Kategorie/Dringlichkeit
4. DynamoDB speichert Metadaten, Vorschau und S3-Referenz
5. API Gateway und eine API-Lambda stellen Lesen und Löschen bereit
6. CloudFront liefert ein statisches Dashboard aus S3 per HTTPS aus

## Projektstruktur

```text
terraform/               AWS-Infrastruktur als Terraform
src/lambdas/classifier/  S3-getriggerte Klassifizierungs-Lambda
src/lambdas/api/         API-Lambda für Lesen und Löschen
dashboard/               Statisches Dashboard
examples/                Test-E-Mails für S3-Upload
docs/                    C4-Diagramm
```

## Deployment

Voraussetzungen:

- AWS CLI mit passenden Berechtigungen
- Terraform >= 1.5

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
```

Outputs:

```bash
terraform output
```

## Testablauf

Nach dem Deployment kann eine Beispiel-E-Mail manuell hochgeladen werden:

```bash
aws s3 cp examples/test-email.eml "s3://<raw_email_bucket>/<raw_email_prefix>test-email.eml"
```

Mehrere Test-E-Mails können gesammelt hochgeladen werden:

```bash
aws s3 cp examples/ "s3://<raw_email_bucket>/<raw_email_prefix>" --recursive --exclude "*" --include "*.eml"
```

API prüfen:

```bash
curl "<api_base_url>/health"
curl "<api_base_url>/emails?limit=5"
```

Das Dashboard ist über den Terraform-Output `dashboard_url` erreichbar.
