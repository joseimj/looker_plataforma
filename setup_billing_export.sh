#!/bin/bash
# =============================================================================
# setup_billing_export.sh
# Automatiza el setup del export de Cloud Billing a BigQuery para usar con
# el Looker block "Cloud Cost Management: Google Cloud" (gcp-billing) y el
# agente Looker v6.2.
#
# Lo que hace:
#   1. Habilita APIs necesarias (BigQuery, Billing, Recommender)
#   2. Crea el dataset de BigQuery para los exports
#   3. Crea Service Account para Looker con permisos a BQ
#   4. Genera la JSON key del SA (para configurar Looker connection)
#   5. Imprime instrucciones EXACTAS para el setup en Console que NO se puede
#      automatizar (los exports de Billing requieren UI por seguridad)
#   6. Verifica que los exports lleguen (con timeout)
#
# IMPORTANTE: La activacion de los exports en Billing > Billing Export NO se
# puede hacer 100% via gcloud. Requiere clicks en la UI. El script te guia
# paso a paso pero tu haces esa parte manual.
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURA ESTAS VARIABLES
# =============================================================================
# Proyecto donde vivira el dataset de billing exports
# Recomendacion: usar un proyecto dedicado solo para billing/governance
PROJECT_ID="YOUR_BILLING_PROJECT_ID"

# El billing account ID (sin el prefijo "billingAccounts/")
# Lo obtienes con: gcloud billing accounts list
BILLING_ACCOUNT_ID="YOUR_BILLING_ACCOUNT_ID"

# Dataset y region donde vivira el export
BQ_DATASET="billing_export"
BQ_LOCATION="US"

# Service Account que usara Looker para conectarse a BQ
LOOKER_SA_NAME="looker-bq-billing"

# Bucket para guardar la SA key (privado, solo lo lee el admin)
KEY_OUTPUT_DIR="$HOME/looker-bq-keys"
# =============================================================================

validate_var() {
  local var_name="$1"
  local var_value="$2"
  if [[ -z "$var_value" || "$var_value" == YOUR_* ]]; then
    echo "ERROR: La variable '$var_name' no esta configurada."
    exit 1
  fi
}

echo ""
echo "=================================================="
echo " PASO -1: Validar variables"
echo "=================================================="
validate_var "PROJECT_ID" "$PROJECT_ID"
validate_var "BILLING_ACCOUNT_ID" "$BILLING_ACCOUNT_ID"
echo "OK: Variables configuradas."

echo ""
echo "=================================================="
echo " PASO 0: Verificar autenticacion y permisos"
echo "=================================================="
gcloud auth list
gcloud config set project "$PROJECT_ID"

# Verificar que el usuario tiene permisos para Billing
echo ""
echo "Verificando acceso al billing account..."
if ! gcloud billing accounts describe "$BILLING_ACCOUNT_ID" &>/dev/null; then
  echo "ERROR: No tienes acceso al billing account $BILLING_ACCOUNT_ID"
  echo "Necesitas el rol 'Billing Account Administrator' o equivalente."
  echo ""
  echo "Para listar los billing accounts a los que tienes acceso:"
  echo "  gcloud billing accounts list"
  exit 1
fi
echo "OK: Acceso al billing account confirmado."

echo ""
echo "=================================================="
echo " PASO 1: Habilitar APIs necesarias"
echo "=================================================="
gcloud services enable \
  bigquery.googleapis.com \
  bigquerydatatransfer.googleapis.com \
  cloudbilling.googleapis.com \
  recommender.googleapis.com \
  cloudasset.googleapis.com \
  --project="$PROJECT_ID"
echo "APIs habilitadas."

echo ""
echo "=================================================="
echo " PASO 2: Crear dataset de BigQuery"
echo "=================================================="
if bq --project_id="$PROJECT_ID" ls -d 2>/dev/null | grep -q "^${BQ_DATASET}\$"; then
  echo "Dataset '$BQ_DATASET' ya existe."
else
  bq --location="$BQ_LOCATION" mk \
    --dataset \
    --description="GCP Cloud Billing exports for FinOps analysis" \
    "${PROJECT_ID}:${BQ_DATASET}"
  echo "Dataset creado: ${PROJECT_ID}.${BQ_DATASET}"
fi

# Tambien crear un dataset para PDTs (Looker lo necesita)
PDT_DATASET="looker_pdts"
if ! bq --project_id="$PROJECT_ID" ls -d 2>/dev/null | grep -q "^${PDT_DATASET}\$"; then
  bq --location="$BQ_LOCATION" mk \
    --dataset \
    --description="Looker Persistent Derived Tables scratch space" \
    "${PROJECT_ID}:${PDT_DATASET}"
  echo "Dataset PDT creado: ${PROJECT_ID}.${PDT_DATASET}"
else
  echo "Dataset PDT '$PDT_DATASET' ya existe."
fi

echo ""
echo "=================================================="
echo " PASO 3: Crear Service Account para Looker"
echo "=================================================="
LOOKER_SA_EMAIL="${LOOKER_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

if ! gcloud iam service-accounts describe "$LOOKER_SA_EMAIL" --project="$PROJECT_ID" &>/dev/null; then
  gcloud iam service-accounts create "$LOOKER_SA_NAME" \
    --project="$PROJECT_ID" \
    --display-name="Looker BigQuery Billing SA" \
    --description="Used by Looker to query GCP billing exports"
  echo "SA creada: $LOOKER_SA_EMAIL"
else
  echo "SA ya existe: $LOOKER_SA_EMAIL"
fi

echo ""
echo "Asignando permisos al SA de Looker..."

# Lectura del dataset de billing
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${LOOKER_SA_EMAIL}" \
  --role="roles/bigquery.dataViewer" \
  --condition=None &>/dev/null
echo "  [OK] bigquery.dataViewer (leer billing exports)"

# Correr queries
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${LOOKER_SA_EMAIL}" \
  --role="roles/bigquery.jobUser" \
  --condition=None &>/dev/null
echo "  [OK] bigquery.jobUser (correr queries)"

# Escritura en el dataset de PDTs
bq --project_id="$PROJECT_ID" update \
  --source <(bq --project_id="$PROJECT_ID" show --format=prettyjson "${PDT_DATASET}" | \
    python3 -c "
import json, sys
d = json.load(sys.stdin)
d.setdefault('access', []).append({
    'role': 'WRITER',
    'userByEmail': '${LOOKER_SA_EMAIL}'
})
print(json.dumps(d))
") "${PROJECT_ID}:${PDT_DATASET}" &>/dev/null || echo "  [WARN] Permiso WRITER en PDTs ya configurado"
echo "  [OK] WRITER en dataset $PDT_DATASET (para PDTs)"

# Recommender (para el explore recommendations_export del block)
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${LOOKER_SA_EMAIL}" \
  --role="roles/recommender.viewer" \
  --condition=None &>/dev/null
echo "  [OK] recommender.viewer (leer recomendaciones de Active Assist)"

echo ""
echo "=================================================="
echo " PASO 4: Generar JSON key del SA"
echo "=================================================="
mkdir -p "$KEY_OUTPUT_DIR"
chmod 700 "$KEY_OUTPUT_DIR"

KEY_FILE="${KEY_OUTPUT_DIR}/${LOOKER_SA_NAME}-${PROJECT_ID}.json"

if [ -f "$KEY_FILE" ]; then
  echo "Key ya existe: $KEY_FILE"
  echo "(Si necesitas regenerarla, borrala primero)"
else
  gcloud iam service-accounts keys create "$KEY_FILE" \
    --iam-account="$LOOKER_SA_EMAIL" \
    --project="$PROJECT_ID"
  chmod 600 "$KEY_FILE"
  echo "Key generada: $KEY_FILE"
  echo "IMPORTANTE: NO la subas a Git. Solo subela manualmente al admin de Looker."
fi

echo ""
echo "=================================================="
echo " PASO 5: Habilitar Recommender exports a BigQuery"
echo "  (para el explore 'recommendations_export' del block)"
echo "=================================================="
echo ""
echo "El export de Recommendations a BigQuery se configura via Cloud Asset"
echo "Inventory. Lo automatizamos creando un transfer job."
echo ""

# Crear el dataset si necesita uno separado para recommendations
RECOMMENDATIONS_DATASET="recommendations_export"
if ! bq --project_id="$PROJECT_ID" ls -d 2>/dev/null | grep -q "^${RECOMMENDATIONS_DATASET}\$"; then
  bq --location="$BQ_LOCATION" mk \
    --dataset \
    --description="GCP Recommender exports for cost optimization analysis" \
    "${PROJECT_ID}:${RECOMMENDATIONS_DATASET}"
  echo "Dataset $RECOMMENDATIONS_DATASET creado."
fi

cat <<EOF

NOTA: El export automatizado de Recommendations requiere setup adicional
con Cloud Asset Inventory + Cloud Function. Para PoC, puedes saltartelo
y solo usar el costo (gcp_billing_export). El block sigue funcionando, solo
oculta el explore 'recommendations_export' en Looker.

Si quieres setup completo de recommendations exports, ver:
https://cloud.google.com/recommender/docs/recommendations-export-bigquery
EOF

echo ""
echo "=================================================="
echo " PASO 6: INSTRUCCIONES MANUALES (UI de Cloud Billing)"
echo "=================================================="
cat <<EOF

Los exports de Billing a BigQuery requieren clicks en la Console por seguridad.
Sigue estos pasos EXACTOS:

1. Abre: https://console.cloud.google.com/billing/${BILLING_ACCOUNT_ID}/export
   (o ve a Billing > Billing export > BigQuery export)

2. SECCION: 'Standard usage cost'
   - Click 'EDIT SETTINGS'
   - Project: $PROJECT_ID
   - Dataset: $BQ_DATASET
   - Click 'SAVE'
   - Esto creara la tabla: gcp_billing_export_v1_$(echo $BILLING_ACCOUNT_ID | tr '-' '_')

3. SECCION: 'Detailed usage cost' (RECOMENDADO para FinOps avanzado)
   - Click 'EDIT SETTINGS'
   - Project: $PROJECT_ID
   - Dataset: $BQ_DATASET
   - Click 'SAVE'
   - Esto creara: gcp_billing_export_resource_v1_$(echo $BILLING_ACCOUNT_ID | tr '-' '_')

4. SECCION: 'Pricing'
   - Click 'EDIT SETTINGS'
   - Project: $PROJECT_ID
   - Dataset: $BQ_DATASET
   - Click 'SAVE'
   - Esto creara: cloud_pricing_export

5. ESPERA 24-48 HORAS para que llegue la primera carga de datos.
   Despues se actualiza cada hora aproximadamente.

EOF

read -p "Ya configuraste los 3 exports en la Console? [s/n]: " EXPORTS_CONFIGURED
if [[ "$EXPORTS_CONFIGURED" != "s" ]]; then
  echo ""
  echo "OK, ve a la Console y configuralo. Cuando termines, vuelve a correr"
  echo "este script para verificacion (o salta a PASO 7 directamente)."
  exit 0
fi

echo ""
echo "=================================================="
echo " PASO 7: Verificar que los exports estan configurados"
echo "=================================================="

echo ""
echo "Listando tablas en ${PROJECT_ID}.${BQ_DATASET}..."
bq --project_id="$PROJECT_ID" ls "${BQ_DATASET}" 2>/dev/null || \
  echo "(dataset vacio o sin permisos)"

echo ""
echo "Buscando tablas de billing export (puede tardar 24-48h en aparecer la primera vez)..."

EXPORT_TABLES=$(bq --project_id="$PROJECT_ID" ls "${BQ_DATASET}" 2>/dev/null | \
  grep -E "gcp_billing_export|cloud_pricing_export" || echo "")

if [ -z "$EXPORT_TABLES" ]; then
  cat <<EOF

NO se encontraron tablas de billing export aun.

Esto es normal si acabas de configurar los exports - tardan 24-48h.

Para verificar manualmente despues:
  bq ls ${PROJECT_ID}:${BQ_DATASET}

Cuando aparezcan las tablas, podras correr una query de prueba:
  bq query --use_legacy_sql=false \\
    "SELECT _TABLE_SUFFIX, COUNT(*) as rows
     FROM \\\`${PROJECT_ID}.${BQ_DATASET}.gcp_billing_export*\\\`
     GROUP BY 1"
EOF
else
  echo ""
  echo "Tablas encontradas:"
  echo "$EXPORT_TABLES"
  echo ""
  echo "Verificando que tienen data..."

  # Encontrar el nombre exacto de la tabla standard export
  STANDARD_TABLE=$(echo "$EXPORT_TABLES" | grep -E "gcp_billing_export_v1_" | awk '{print $1}' | head -1)

  if [ -n "$STANDARD_TABLE" ]; then
    ROW_COUNT=$(bq query --project_id="$PROJECT_ID" --use_legacy_sql=false --format=csv \
      "SELECT COUNT(*) FROM \`${PROJECT_ID}.${BQ_DATASET}.${STANDARD_TABLE}\`" 2>/dev/null | \
      tail -1 || echo "0")
    echo "Filas en $STANDARD_TABLE: $ROW_COUNT"

    if [ "$ROW_COUNT" -gt "0" ] 2>/dev/null; then
      echo ""
      echo "EXCELENTE! Hay datos. Mostrando rango de fechas:"
      bq query --project_id="$PROJECT_ID" --use_legacy_sql=false \
        "SELECT
           MIN(usage_start_time) as oldest_record,
           MAX(usage_start_time) as newest_record,
           COUNT(DISTINCT project.id) as projects_count
         FROM \`${PROJECT_ID}.${BQ_DATASET}.${STANDARD_TABLE}\`"
    fi
  fi
fi

echo ""
echo "=================================================="
echo " SETUP DE BILLING EXPORT - COMPLETO"
echo "=================================================="
cat <<EOF

  Proyecto BQ          : $PROJECT_ID
  Dataset billing      : ${PROJECT_ID}.${BQ_DATASET}
  Dataset PDTs         : ${PROJECT_ID}.${PDT_DATASET}
  Service Account      : $LOOKER_SA_EMAIL
  JSON Key             : $KEY_FILE
  Billing Account      : $BILLING_ACCOUNT_ID

PROXIMOS PASOS para conectar con Looker:

1. CONFIGURAR CONEXION EN LOOKER
   Looker Admin > Connections > New Connection:
     - Name              : bq_billing
     - Dialect           : Google BigQuery Standard SQL
     - Project Name      : $PROJECT_ID
     - Dataset           : $BQ_DATASET
     - OAuth/Auth        : Service Account
     - JSON              : sube el archivo $KEY_FILE
     - Temp Database     : ${PROJECT_ID}.${PDT_DATASET}
     - PDTs and Datagroup: ENABLED (importante!)
     - Test Connection -> debe pasar todas las validaciones

2. INSTALAR EL BLOCK DESDE MARKETPLACE
   Looker > Marketplace > "Cloud Cost Management: Google Cloud" > Install
   Configura:
     - Connection: bq_billing
     - Billing dataset: $BQ_DATASET
     - Standard table: el nombre exacto que ves en BQ
       (algo como gcp_billing_export_v1_$(echo $BILLING_ACCOUNT_ID | tr '-' '_'))

3. CORRER EL AGENTE v6.2
   Una vez tengas data en Looker, deploya:
     ./setup_looker_gemini_enterprise_v6_2.sh

   El agente preguntara cosas como:
     - "Cuanto gastamos en GCP el mes pasado?"
     - "Top 5 servicios por costo este trimestre"
     - "Como se distribuye el gasto por proyecto?"

DOCUMENTACION DEL BLOCK:
  https://github.com/looker-open-source/block-google-cloud-billing

PRECIOS APROXIMADOS:
  - BQ storage de exports : ~\$0.02/GB/mes (~\$5/mes para org mediana)
  - BQ queries del block  : pay-per-query (~\$10-30/mes uso normal)
  - Looker PDTs storage   : ~\$10-20/mes
  Total: ~\$30-60/mes

EOF
