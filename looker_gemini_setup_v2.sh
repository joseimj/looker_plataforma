#!/bin/bash
# =============================================================================
# setup_looker_gemini_enterprise.sh (v2 - con SA custom para firmar URLs)
# Cambios clave vs version anterior:
#   1. Crea una SA dedicada (looker-agent-sa) con TODOS los permisos
#   2. Usa --service_account en adk deploy para que Agent Engine use esa SA
#   3. Da permisos de firma (signBlob) ANTES del deploy (la SA ya existe)
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURA ESTAS VARIABLES ANTES DE EJECUTAR
# =============================================================================
PROJECT_ID="YOUR_GOOGLE_CLOUD_PROJECT_ID"
PROJECT_NUMBER="YOUR_PROJECT_NUMBER"
REGION="us-central1"
BUCKET_NAME="YOUR_GCS_BUCKET_NAME"
BUCKET_LOCATION="US"

IMAGES_BUCKET="YOUR_LOOKER_IMAGES_BUCKET"

LOOKER_URL="https://your-instance.looker.com"
LOOKER_CLIENT_ID="YOUR_LOOKER_CLIENT_ID"
LOOKER_CLIENT_SECRET="YOUR_LOOKER_CLIENT_SECRET"
LOOKER_EMBED_SECRET="YOUR_LOOKER_EMBED_SECRET"
LOOKER_MODELS='["thelook"]'

AS_APP="YOUR_GEMINI_ENTERPRISE_AGENT_ID"
ENGINE_LOCATION="us"
AGENT_DISPLAY_NAME="Looker Agent"
AGENT_DESCRIPTION="Looker agent with inline dashboard images."
TOOL_DESCRIPTION="Use this tool to answer questions about Looker data and display dashboards/charts as inline images."
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
validate_var "PROJECT_NUMBER" "$PROJECT_NUMBER"
validate_var "BUCKET_NAME" "$BUCKET_NAME"
validate_var "IMAGES_BUCKET" "$IMAGES_BUCKET"
validate_var "LOOKER_URL" "$LOOKER_URL"
validate_var "LOOKER_CLIENT_ID" "$LOOKER_CLIENT_ID"
validate_var "LOOKER_CLIENT_SECRET" "$LOOKER_CLIENT_SECRET"
validate_var "LOOKER_EMBED_SECRET" "$LOOKER_EMBED_SECRET"
validate_var "AS_APP" "$AS_APP"
echo "OK: Variables configuradas."

echo ""
echo "=================================================="
echo " PASO 0: Autenticacion"
echo "=================================================="
gcloud auth list
gcloud config set project "$PROJECT_ID"

echo ""
echo "=================================================="
echo " PASO 1: Habilitar APIs"
echo "=================================================="
gcloud services enable \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  iam.googleapis.com \
  secretmanager.googleapis.com \
  aiplatform.googleapis.com \
  discoveryengine.googleapis.com \
  looker.googleapis.com \
  storage.googleapis.com \
  iamcredentials.googleapis.com \
  cloudresourcemanager.googleapis.com \
  --project="$PROJECT_ID"

echo ""
echo "=================================================="
echo " PASO 2: Crear service accounts y TODOS los permisos"
echo "=================================================="

# SA del Toolbox (Cloud Run)
SA_NAME="toolbox-identity"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

if ! gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID" &>/dev/null; then
  gcloud iam service-accounts create "$SA_NAME" \
    --project="$PROJECT_ID" \
    --display-name="MCP Toolbox SA"
fi
echo "SA Toolbox: $SA_EMAIL"

# ***NUEVO: SA dedicada para el Agente***
AGENT_SA_NAME="looker-agent-sa"
AGENT_SA="${AGENT_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

if ! gcloud iam service-accounts describe "$AGENT_SA" --project="$PROJECT_ID" &>/dev/null; then
  gcloud iam service-accounts create "$AGENT_SA_NAME" \
    --project="$PROJECT_ID" \
    --display-name="Looker Agent Engine SA"
fi
echo "SA Agente: $AGENT_SA"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/secretmanager.secretAccessor" \
  --condition=None &>/dev/null

echo ""
echo "Asignando permisos al SA del Agente..."

# 1. Correr como Agent Engine
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${AGENT_SA}" \
  --role="roles/aiplatform.user" \
  --condition=None &>/dev/null
echo "  [OK] aiplatform.user"

# 2. FIRMAR URLs (sobre si mismo) - ESTE ES EL CLAVE
gcloud iam service-accounts add-iam-policy-binding "$AGENT_SA" \
  --member="serviceAccount:${AGENT_SA}" \
  --role="roles/iam.serviceAccountTokenCreator" \
  --project="$PROJECT_ID" &>/dev/null
echo "  [OK] iam.serviceAccountTokenCreator (FIRMAR URLs)"

# 3. Storage admin en todo el proyecto
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${AGENT_SA}" \
  --role="roles/storage.objectAdmin" \
  --condition=None &>/dev/null
echo "  [OK] storage.objectAdmin"

# 4. Logs
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${AGENT_SA}" \
  --role="roles/logging.logWriter" \
  --condition=None &>/dev/null
echo "  [OK] logging.logWriter"

echo "Permisos del SA del agente asignados completamente."

echo ""
echo "=================================================="
echo " PASO 3: Crear buckets GCS"
echo "=================================================="
if ! gcloud storage buckets describe "gs://${BUCKET_NAME}" &>/dev/null; then
  gcloud storage buckets create "gs://${BUCKET_NAME}" --location="$BUCKET_LOCATION"
fi

if ! gcloud storage buckets describe "gs://${IMAGES_BUCKET}" &>/dev/null; then
  gcloud storage buckets create "gs://${IMAGES_BUCKET}" \
    --location="$BUCKET_LOCATION" \
    --uniform-bucket-level-access
fi

cat > /tmp/lifecycle.json <<EOF
{"lifecycle": {"rule": [{"action": {"type": "Delete"}, "condition": {"age": 1}}]}}
EOF
gcloud storage buckets update "gs://${IMAGES_BUCKET}" --lifecycle-file=/tmp/lifecycle.json
echo "Lifecycle policy aplicada (1 dia)"

# Admin explicito del bucket de imagenes
gcloud storage buckets add-iam-policy-binding "gs://${IMAGES_BUCKET}" \
  --member="serviceAccount:${AGENT_SA}" \
  --role="roles/storage.objectAdmin" &>/dev/null
echo "Admin bucket imagenes asignado al SA del agente"

echo ""
echo "=================================================="
echo " PASO 4: Desplegar MCP Toolbox en Cloud Run"
echo "=================================================="
mkdir -p mcp-toolbox && cd mcp-toolbox

IMAGE="us-central1-docker.pkg.dev/database-toolbox/toolbox/toolbox:1.1.0"

gcloud run deploy toolbox \
  --image="$IMAGE" \
  --service-account="$SA_EMAIL" \
  --region="$REGION" \
  --set-env-vars="LOOKER_BASE_URL=${LOOKER_URL},LOOKER_CLIENT_ID=${LOOKER_CLIENT_ID},LOOKER_CLIENT_SECRET=${LOOKER_CLIENT_SECRET},LOOKER_VERIFY_SSL=true" \
  --args="--prebuilt=looker","--address=0.0.0.0","--port=8080" \
  --no-allow-unauthenticated \
  --project="$PROJECT_ID"

CLOUD_RUN_URL=$(gcloud run services describe toolbox \
  --region="$REGION" --project="$PROJECT_ID" --format="value(status.url)")

echo "Cloud Run URL: $CLOUD_RUN_URL"
MCP_SERVER_URL="${CLOUD_RUN_URL}/mcp"

# SA del agente puede invocar Cloud Run
gcloud run services add-iam-policy-binding toolbox \
  --region="$REGION" \
  --member="serviceAccount:${AGENT_SA}" \
  --role="roles/run.invoker" \
  --project="$PROJECT_ID" &>/dev/null
echo "SA del agente puede invocar el Cloud Run"

cd ..

echo ""
echo "=================================================="
echo " PASO 5: Entorno Python del agente"
echo "=================================================="
mkdir -p my-agents && cd my-agents
python3 -m venv .venv
source .venv/bin/activate
pip install --quiet --upgrade pip
pip install --quiet google-adk toolbox-core looker-sdk google-cloud-storage

echo ""
echo "=================================================="
echo " PASO 6: Crear aplicacion del agente"
echo "=================================================="
mkdir -p looker_app

cat > looker_app/__init__.py <<'EOF'
from . import agent
EOF

cat > looker_app/.env <<EOF
GOOGLE_GENAI_USE_VERTEXAI=1
GOOGLE_CLOUD_PROJECT=${PROJECT_ID}
GOOGLE_CLOUD_LOCATION=${REGION}
LOOKERSDK_BASE_URL=${LOOKER_URL}
LOOKERSDK_CLIENT_ID=${LOOKER_CLIENT_ID}
LOOKERSDK_CLIENT_SECRET=${LOOKER_CLIENT_SECRET}
LOOKERSDK_VERIFY_SSL=true
LOOKER_EMBED_SECRET=${LOOKER_EMBED_SECRET}
LOOKER_MODELS=${LOOKER_MODELS}
LOOKER_IMAGES_BUCKET=${IMAGES_BUCKET}
EOF

cat > looker_app/requirements.txt <<EOF
google-adk
toolbox-core
looker_sdk
google-cloud-storage
google-auth
requests
EOF

cat > looker_app/agent.py <<'PYEOF'
import os
import time
import hmac
import hashlib
import json
import base64
import binascii
import uuid
from datetime import timedelta
from urllib.parse import quote_plus

import looker_sdk
from looker_sdk import models40

from google.cloud import storage
import google.auth
from google.auth.transport import requests as gauth_requests
from google.auth import impersonated_credentials

from google.adk.agents import LlmAgent
from google.adk.planners.built_in_planner import BuiltInPlanner
from google.adk.tools.mcp_tool.mcp_toolset import MCPToolset
from google.adk.tools.mcp_tool.mcp_session_manager import StreamableHTTPConnectionParams
from google.genai.types import ThinkingConfig
import google.auth.transport.requests
import google.oauth2.id_token

MCP_SERVER_URL = "__MCP_SERVER_URL__"
LOOKER_HOST = (
    os.environ.get("LOOKERSDK_BASE_URL", "")
    .replace("https://", "").replace("http://", "").rstrip("/")
)
EMBED_SECRET = os.environ.get("LOOKER_EMBED_SECRET", "")
LOOKER_MODELS_ENV = os.environ.get("LOOKER_MODELS", '["thelook"]')
IMAGES_BUCKET = os.environ.get("LOOKER_IMAGES_BUCKET", "")


def get_id_token():
    audience = MCP_SERVER_URL.split('/mcp')[0]
    auth_req = google.auth.transport.requests.Request()
    return google.oauth2.id_token.fetch_id_token(auth_req, audience)


def _upload_png_to_gcs(png_bytes: bytes, prefix: str = "render") -> str:
    """Sube PNG al bucket y firma URL con IAM signBlob API."""
    client = storage.Client()
    bucket = client.bucket(IMAGES_BUCKET)

    blob_name = f"{prefix}/{int(time.time())}-{uuid.uuid4().hex[:8]}.png"
    blob = bucket.blob(blob_name)
    blob.upload_from_string(png_bytes, content_type="image/png")

    credentials, project = google.auth.default()
    auth_req = gauth_requests.Request()
    credentials.refresh(auth_req)

    sa_email = getattr(credentials, "service_account_email", None)

    if sa_email and sa_email != "default":
        signing_credentials = impersonated_credentials.Credentials(
            source_credentials=credentials,
            target_principal=sa_email,
            target_scopes=["https://www.googleapis.com/auth/devstorage.read_only"],
            lifetime=500,
        )
        return blob.generate_signed_url(
            version="v4",
            expiration=timedelta(hours=1),
            method="GET",
            credentials=signing_credentials,
        )
    return f"https://storage.googleapis.com/{IMAGES_BUCKET}/{blob_name}"


def _generate_signed_embed_url(target_path: str, user_email: str = "gemini-enterprise-user@company.com") -> str:
    if not EMBED_SECRET:
        sdk = looker_sdk.init40()
        result = sdk.create_sso_embed_url(
            body=models40.EmbedSsoParams(
                target_url=f"https://{LOOKER_HOST}{target_path}",
                session_length=3600,
                force_logout_login=False,
            )
        )
        return result.url

    nonce = binascii.hexlify(os.urandom(8)).decode()
    current_time = int(time.time())
    session_length = 3600
    external_user_id = json.dumps(user_email)
    permissions = json.dumps([
        "access_data", "see_looks", "see_user_dashboards",
        "see_lookml_dashboards", "explore", "save_content", "embed_browse_spaces"
    ])
    models = LOOKER_MODELS_ENV
    group_ids = json.dumps([])
    external_group_id = json.dumps("")
    user_attributes = json.dumps({})
    access_filters = json.dumps({})
    first_name = json.dumps("Gemini")
    last_name = json.dumps("User")
    user_timezone = json.dumps("America/Mexico_City")
    force_logout_login = json.dumps(True)

    string_to_sign = "\n".join([
        LOOKER_HOST, target_path, nonce, str(current_time),
        str(session_length), external_user_id, permissions, models,
        group_ids, user_attributes, access_filters,
    ])

    signature = base64.b64encode(
        hmac.new(EMBED_SECRET.encode('utf-8'),
                 string_to_sign.encode('utf-8'),
                 hashlib.sha1).digest()
    ).decode().strip()

    params = {
        "nonce": nonce, "time": current_time, "session_length": session_length,
        "external_user_id": external_user_id, "permissions": permissions,
        "models": models, "group_ids": group_ids,
        "external_group_id": external_group_id, "user_attributes": user_attributes,
        "access_filters": access_filters, "first_name": first_name,
        "last_name": last_name, "user_timezone": user_timezone,
        "force_logout_login": force_logout_login, "signature": signature,
    }
    query = "&".join(f"{k}={quote_plus(str(v))}" for k, v in params.items())
    return f"https://{LOOKER_HOST}{target_path}?{query}"


def show_dashboard_inline(dashboard_id: str) -> dict:
    """Renderiza un dashboard como PNG inline en el chat.

    Args:
        dashboard_id: ID del dashboard.
    Returns:
        Dict con markdown que incluye la imagen.
    """
    sdk = looker_sdk.init40()
    task = sdk.create_dashboard_render_task(
        dashboard_id=dashboard_id, result_format="png",
        body=models40.CreateDashboardRenderTask(dashboard_style="tiled", dashboard_filters=""),
        width=1400, height=900,
    )

    max_wait = 60
    waited = 0
    while waited < max_wait:
        status = sdk.render_task(task.id)
        if status.status == "success":
            break
        if status.status == "failure":
            return {"error": "Render failed", "markdown": f"Error renderizando dashboard {dashboard_id}"}
        time.sleep(2)
        waited += 2

    if waited >= max_wait:
        return {"error": "timeout", "markdown": f"Timeout renderizando dashboard {dashboard_id}"}

    png_bytes = sdk.render_task_results(task.id)

    try:
        signed_url = _upload_png_to_gcs(png_bytes, prefix=f"dashboard-{dashboard_id}")
    except Exception as e:
        return {"error": str(e), "markdown": f"Error al subir imagen: {e}"}

    interactive_url = _generate_signed_embed_url(f"/embed/dashboards/{dashboard_id}")

    return {
        "dashboard_id": dashboard_id,
        "image_url": signed_url,
        "interactive_url": interactive_url,
        "markdown": f"![Dashboard {dashboard_id}]({signed_url})\n\n[Abrir version interactiva]({interactive_url})",
    }


def show_look_inline(look_id: str) -> dict:
    """Renderiza un Look como PNG inline.

    Args:
        look_id: ID del Look.
    Returns:
        Dict con markdown.
    """
    sdk = looker_sdk.init40()
    try:
        png_bytes = sdk.run_look(look_id=look_id, result_format="png",
                                 image_width=1200, image_height=700)
    except Exception as e:
        return {"error": str(e), "markdown": f"Error al renderizar Look {look_id}: {e}"}

    try:
        signed_url = _upload_png_to_gcs(png_bytes, prefix=f"look-{look_id}")
    except Exception as e:
        return {"error": str(e), "markdown": f"Error al subir imagen: {e}"}

    interactive_url = _generate_signed_embed_url(f"/embed/looks/{look_id}")

    return {
        "look_id": look_id,
        "image_url": signed_url,
        "interactive_url": interactive_url,
        "markdown": f"![Look {look_id}]({signed_url})\n\n[Abrir Look interactivo]({interactive_url})",
    }


def show_query_inline(model: str, explore: str, fields: list, vis_type: str = "looker_column") -> dict:
    """Query ad-hoc como PNG inline.

    Args:
        model: modelo LookML.
        explore: explore.
        fields: campos.
        vis_type: tipo de visualizacion.
    Returns:
        Dict con markdown.
    """
    sdk = looker_sdk.init40()
    try:
        query = sdk.create_query(
            body=models40.WriteQuery(
                model=model, view=explore, fields=fields,
                limit="500", vis_config={"type": vis_type},
            )
        )
        png_bytes = sdk.run_query(
            query_id=str(query.id), result_format="png",
            image_width=1200, image_height=700,
        )
    except Exception as e:
        return {"error": str(e), "markdown": f"Error al ejecutar query: {e}"}

    try:
        signed_url = _upload_png_to_gcs(png_bytes, prefix=f"query-{model}-{explore}")
    except Exception as e:
        return {"error": str(e), "markdown": f"Error al subir imagen: {e}"}

    interactive_url = _generate_signed_embed_url(
        f"/embed/explore/{model}/{explore}?qid={query.client_id}"
    )

    return {
        "model": model, "explore": explore, "fields": fields,
        "image_url": signed_url, "interactive_url": interactive_url,
        "markdown": f"![{explore}]({signed_url})\n\n*{explore} ({model})*\n\n[Explorar]({interactive_url})",
    }


def list_available_dashboards(search_term: str = "") -> dict:
    """Lista dashboards."""
    sdk = looker_sdk.init40()
    if search_term:
        dashboards = sdk.search_dashboards(title=f"%{search_term}%", limit=20)
    else:
        dashboards = sdk.search_dashboards(limit=20)

    if not dashboards:
        return {"dashboards": [], "markdown": "No encontre dashboards."}

    items = []
    md_lines = ["## Dashboards disponibles:\n"]
    for d in dashboards:
        items.append({"id": str(d.id), "title": d.title})
        md_lines.append(f"- **{d.title}** (ID: {d.id})")
    return {"dashboards": items, "markdown": "\n".join(md_lines)}


root_agent = LlmAgent(
    model='gemini-2.5-flash',
    name='looker_agent',
    description='Looker agent rendering dashboards as inline images.',
    instruction=(
        'You are a Looker agent inside Gemini Enterprise. '
        'Render dashboards/charts as INLINE IMAGES.\n\n'
        'RULES:\n'
        '- SEE/SHOW/VIEW a dashboard: call show_dashboard_inline, return markdown verbatim.\n'
        '- Look by ID: call show_look_inline.\n'
        '- Ad-hoc viz: call show_query_inline with model/explore/fields/vis_type.\n'
        '- What dashboards exist: call list_available_dashboards.\n'
        '- Raw numbers: use MCP tools.\n\n'
        'Defaults: model="thelook", explore="order_items".\n'
        'vis_type: looker_column, looker_bar, looker_line, looker_pie, looker_scatter.'
    ),
    planner=BuiltInPlanner(
        thinking_config=ThinkingConfig(include_thoughts=False, thinking_budget=0)
    ),
    tools=[
        MCPToolset(
            connection_params=StreamableHTTPConnectionParams(
                url=MCP_SERVER_URL,
                headers={"Authorization": f"Bearer {get_id_token()}"},
            ),
            errlog=None, tool_filter=None,
        ),
        show_dashboard_inline,
        show_look_inline,
        show_query_inline,
        list_available_dashboards,
    ],
)
PYEOF

sed -i "s|__MCP_SERVER_URL__|${MCP_SERVER_URL}|g" looker_app/agent.py
echo "Agente creado."

echo ""
echo "=================================================="
echo " PASO 7: Desplegar con Python SDK (soporta SA custom)"
echo "  (tarda 15-20 min, usara: $AGENT_SA)"
echo "=================================================="

# Instalar Vertex AI SDK con agent_engines
pip install --quiet --upgrade "google-cloud-aiplatform[agent_engines,adk]"

# Crear deploy.py que usa el Python SDK
cat > deploy.py <<'DEPLOYEOF'
import os
import sys
import vertexai
from vertexai.preview import reasoning_engines
from vertexai import agent_engines

# Importar el agente
from looker_app.agent import root_agent

PROJECT_ID = os.environ["PROJECT_ID"]
REGION = os.environ["REGION"]
STAGING_BUCKET = f"gs://{os.environ['BUCKET_NAME']}"
AGENT_SA = os.environ["AGENT_SA"]

vertexai.init(
    project=PROJECT_ID,
    location=REGION,
    staging_bucket=STAGING_BUCKET,
)

print(f"Desplegando agente con SA: {AGENT_SA}", flush=True)
print(f"Staging bucket: {STAGING_BUCKET}", flush=True)

app = reasoning_engines.AdkApp(agent=root_agent, enable_tracing=True)

env_vars = {
    "LOOKERSDK_BASE_URL": os.environ["LOOKER_URL"],
    "LOOKERSDK_CLIENT_ID": os.environ["LOOKER_CLIENT_ID"],
    "LOOKERSDK_CLIENT_SECRET": os.environ["LOOKER_CLIENT_SECRET"],
    "LOOKERSDK_VERIFY_SSL": "true",
    "LOOKER_EMBED_SECRET": os.environ["LOOKER_EMBED_SECRET"],
    "LOOKER_MODELS": os.environ.get("LOOKER_MODELS", '["thelook"]'),
    "LOOKER_IMAGES_BUCKET": os.environ["IMAGES_BUCKET"],
    "GOOGLE_GENAI_USE_VERTEXAI": "1",
    "GOOGLE_CLOUD_PROJECT": PROJECT_ID,
    "GOOGLE_CLOUD_LOCATION": REGION,
}

try:
    remote_app = agent_engines.create(
        agent_engine=app,
        display_name="looker-agent1",
        requirements=[
            "google-adk",
            "toolbox-core",
            "looker_sdk",
            "google-cloud-storage",
            "google-auth",
            "google-cloud-aiplatform[agent_engines,adk]",
            "requests",
        ],
        extra_packages=["./looker_app"],
        service_account=AGENT_SA,
        env_vars=env_vars,
    )
    print(f"AGENT_ENGINE_RESOURCE_NAME={remote_app.resource_name}", flush=True)
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr, flush=True)
    sys.exit(1)
DEPLOYEOF

# Exportar variables para el deploy.py
export PROJECT_ID REGION BUCKET_NAME AGENT_SA IMAGES_BUCKET
export LOOKER_URL LOOKER_CLIENT_ID LOOKER_CLIENT_SECRET
export LOOKER_EMBED_SECRET LOOKER_MODELS

DEPLOY_LOG="/tmp/adk_deploy_$$.log"
> "$DEPLOY_LOG"

# Correr deploy en background
python deploy.py > "$DEPLOY_LOG" 2>&1 &
DEPLOY_PID=$!
echo "Deploy en background (PID: $DEPLOY_PID)"

ELAPSED=0
while kill -0 $DEPLOY_PID 2>/dev/null; do
  sleep 15
  ELAPSED=$((ELAPSED + 15))
  MINS=$((ELAPSED / 60))
  SECS=$((ELAPSED % 60))
  LAST_LINE=$(tail -1 "$DEPLOY_LOG" 2>/dev/null || echo "...")
  echo "[${MINS}m${SECS}s] $LAST_LINE"
done

wait $DEPLOY_PID
DEPLOY_EXIT=$?

echo ""
echo "=== OUTPUT DEL DEPLOY ==="
cat "$DEPLOY_LOG"
echo "========================="

if [ $DEPLOY_EXIT -ne 0 ]; then
  echo "ERROR: Deploy fallo"
  exit 1
fi

# Extraer el Reasoning Engine del output del Python SDK
REASONING_ENGINE=$(grep "AGENT_ENGINE_RESOURCE_NAME=" "$DEPLOY_LOG" | tail -1 | cut -d= -f2- || true)

# Fallback al patron estandar
if [ -z "$REASONING_ENGINE" ]; then
  REASONING_ENGINE=$(grep -oE 'projects/[^/]+/locations/[^/]+/reasoningEngines/[0-9]+' "$DEPLOY_LOG" | head -1 || true)
fi

# Fallback ultimo via API REST
if [ -z "$REASONING_ENGINE" ]; then
  REASONING_ENGINE=$(curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
    "https://${REGION}-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines" \
    | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    engines = [e for e in d.get('reasoningEngines', []) if e.get('displayName') == 'looker-agent1']
    if engines: print(engines[-1]['name'])
except: pass
")
fi

if [ -z "$REASONING_ENGINE" ]; then
  echo "ERROR: No se pudo obtener Reasoning Engine"
  exit 1
fi

echo "Reasoning Engine: $REASONING_ENGINE"

cd ..

echo ""
echo "=================================================="
echo " PASO 8: Registrar en Gemini Enterprise"
echo "=================================================="
ACCESS_TOKEN=$(gcloud auth print-access-token)

if [ "$ENGINE_LOCATION" = "global" ]; then
  API_ENDPOINT="discoveryengine.googleapis.com"
else
  API_ENDPOINT="${ENGINE_LOCATION}-discoveryengine.googleapis.com"
fi

AGENT_API_URL="https://${API_ENDPOINT}/v1alpha/projects/${PROJECT_NUMBER}/locations/${ENGINE_LOCATION}/collections/default_collection/engines/${AS_APP}/assistants/default_assistant/agents"

REQUEST_BODY=$(cat <<EOF
{
  "displayName": "${AGENT_DISPLAY_NAME}",
  "description": "${AGENT_DESCRIPTION}",
  "adk_agent_definition": {
    "tool_settings": {"tool_description": "${TOOL_DESCRIPTION}"},
    "provisioned_reasoning_engine": {"reasoning_engine": "${REASONING_ENGINE}"}
  }
}
EOF
)

HTTP_RESPONSE=$(curl -sS -w "\n__HTTP_STATUS__:%{http_code}" -X POST \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -H "X-Goog-User-Project: ${PROJECT_NUMBER}" \
  "$AGENT_API_URL" -d "$REQUEST_BODY")

HTTP_STATUS=$(echo "$HTTP_RESPONSE" | grep "__HTTP_STATUS__" | cut -d: -f2)
RESPONSE_BODY=$(echo "$HTTP_RESPONSE" | sed '/__HTTP_STATUS__/d')

echo "HTTP Status: $HTTP_STATUS"
echo "$RESPONSE_BODY" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE_BODY"

if [[ "$HTTP_STATUS" =~ ^2[0-9][0-9]$ ]]; then
  echo "OK: Agente registrado"
else
  echo "ERROR HTTP $HTTP_STATUS"
  exit 1
fi

echo ""
echo "=================================================="
echo " SETUP COMPLETO"
echo "=================================================="
echo ""
echo "  Cloud Run URL    : $CLOUD_RUN_URL"
echo "  MCP Server URL   : $MCP_SERVER_URL"
echo "  Reasoning Engine : $REASONING_ENGINE"
echo "  Agent SA         : $AGENT_SA"
echo "  Images Bucket    : gs://${IMAGES_BUCKET}"
echo ""
echo "Prueba con: 'Muestrame el dashboard 1'"
