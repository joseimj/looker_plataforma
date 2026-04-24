#!/bin/bash
# =============================================================================
# setup_looker_gemini_enterprise.sh
# Automatiza: MCP Toolbox en Cloud Run + ADK Agent en Agent Engine + Gemini Enterprise
# Basado en: https://medium.com/google-cloud/connect-looker-to-agentspace-in-minutes-with-mcp-toolbox-and-the-adk-8e37ae096f49 de Rob Carr
# Modificado por Jose Maldonado (joseim@google.com) Abril de 2026
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURA ESTAS VARIABLES ANTES DE EJECUTAR
# =============================================================================
PROJECT_ID="YOUR_GOOGLE_CLOUD_PROJECT_ID"
PROJECT_NUMBER="YOUR_PROJECT_NUMBER"           # gcloud projects describe $PROJECT_ID --format='value(projectNumber)'
REGION="us-central1"
BUCKET_NAME="YOUR_GCS_BUCKET_NAME"             # debe ser globalmente único
BUCKET_LOCATION="US"

# Credenciales de Looker (obtener en Looker Admin > API Keys)
LOOKER_URL="https://your-instance.looker.com"
LOOKER_CLIENT_ID="YOUR_LOOKER_CLIENT_ID"
LOOKER_CLIENT_SECRET="YOUR_LOOKER_CLIENT_SECRET"

# Gemini Enterprise
AS_APP="YOUR_GEMINI_ENTERPRISE_AGENT_ID"
ENGINE_LOCATION="us"                           # "us", "eu", o "global"
AGENT_DISPLAY_NAME="Looker Agent"
AGENT_DESCRIPTION="Looker MCP Capability."
TOOL_DESCRIPTION="Looker's Query Engine is used to answer Ecommerce questions."
# =============================================================================

# -----------------------------------------------------------------------------
# Helper: valida que una variable no esté vacía ni con valor placeholder
# -----------------------------------------------------------------------------
validate_var() {
  local var_name="$1"
  local var_value="$2"
  if [[ -z "$var_value" || "$var_value" == YOUR_* ]]; then
    echo " ERROR: La variable '$var_name' no está configurada correctamente."
    echo "   Valor actual: '$var_value'"
    echo "   Edita el script y configura esa variable antes de correrlo."
    exit 1
  fi
}

echo ""
echo "=================================================="
echo " PASO -1: Validar variables de configuración"
echo "=================================================="
validate_var "PROJECT_ID" "$PROJECT_ID"
validate_var "PROJECT_NUMBER" "$PROJECT_NUMBER"
validate_var "BUCKET_NAME" "$BUCKET_NAME"
validate_var "LOOKER_URL" "$LOOKER_URL"
validate_var "LOOKER_CLIENT_ID" "$LOOKER_CLIENT_ID"
validate_var "LOOKER_CLIENT_SECRET" "$LOOKER_CLIENT_SECRET"
validate_var "AS_APP" "$AS_APP"
echo " Todas las variables están configuradas."

echo ""
echo "=================================================="
echo " PASO 0: Verificar autenticación y proyecto"
echo "=================================================="
gcloud auth list
gcloud config set project "$PROJECT_ID"

echo ""
echo "=================================================="
echo " PASO 1: Habilitar APIs necesarias"
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
  bigquery.googleapis.com \
  bigquerystorage.googleapis.com \
  cloudresourcemanager.googleapis.com \
  cloudaicompanion.googleapis.com \
  --project="$PROJECT_ID"

echo ""
echo "=================================================="
echo " PASO 2: Crear cuenta de servicio y roles"
echo "=================================================="
SA_NAME="toolbox-identity"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

if ! gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID" &>/dev/null; then
  gcloud iam service-accounts create "$SA_NAME" --project="$PROJECT_ID"
  echo "Service account creada: $SA_EMAIL"
else
  echo "Service account ya existe: $SA_EMAIL"
fi

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/secretmanager.secretAccessor" \
  --condition=None &>/dev/null

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/cloudsql.client" \
  --condition=None &>/dev/null

echo "Roles IAM asignados."

echo ""
echo "=================================================="
echo " PASO 3: Preparar directorio de trabajo"
echo "=================================================="
mkdir -p mcp-toolbox && cd mcp-toolbox

echo ""
echo "=================================================="
echo " PASO 4: Desplegar MCP Toolbox en Cloud Run (prebuilt=looker)"
echo "=================================================="
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
  --region="$REGION" \
  --project="$PROJECT_ID" \
  --format="value(status.url)")

if [ -z "$CLOUD_RUN_URL" ]; then
  echo " ERROR: No se pudo obtener la URL del Cloud Run"
  exit 1
fi

echo "Cloud Run URL: $CLOUD_RUN_URL"
MCP_SERVER_URL="${CLOUD_RUN_URL}/mcp"

cd ..

echo ""
echo "=================================================="
echo " PASO 5: Configurar entorno Python para el agente ADK"
echo "=================================================="
mkdir -p my-agents && cd my-agents

python3 -m venv .venv
source .venv/bin/activate

pip install --quiet --upgrade pip
pip install --quiet google-adk toolbox-core looker-sdk

echo ""
echo "=================================================="
echo " PASO 6: Crear la aplicación del agente ADK"
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
EOF

cat > looker_app/requirements.txt <<EOF
google-adk
toolbox-core
looker_sdk
google-auth
requests
EOF

cat > looker_app/agent.py <<EOF
import os
import base64
import time
import looker_sdk
from looker_sdk import models40
from google.adk.agents import LlmAgent
from google.adk.planners.built_in_planner import BuiltInPlanner
from google.adk.tools.mcp_tool.mcp_toolset import MCPToolset
from google.adk.tools.mcp_tool.mcp_session_manager import StreamableHTTPConnectionParams
from google.genai.types import ThinkingConfig
import google.auth.transport.requests
import google.oauth2.id_token

MCP_SERVER_URL = "${MCP_SERVER_URL}"

def get_id_token():
    """Obtiene un ID token para autenticarse con el MCP server en Cloud Run."""
    audience = MCP_SERVER_URL.split('/mcp')[0]
    auth_req = google.auth.transport.requests.Request()
    return google.oauth2.id_token.fetch_id_token(auth_req, audience)

def get_look_png(look_id: str) -> dict:
    """Exporta un Look de Looker como imagen PNG en base64.

    Args:
        look_id: El ID numérico del Look en Looker.
    Returns:
        Diccionario con la imagen en base64 y el mime type.
    """
    sdk = looker_sdk.init40()
    png_bytes = sdk.run_look(look_id=look_id, result_format="png")
    encoded = base64.b64encode(png_bytes).decode("utf-8")
    return {"mime_type": "image/png", "data": encoded, "look_id": look_id}

def get_look_url(look_id: str) -> dict:
    """Genera una URL de embed SSO para un Look de Looker.

    Args:
        look_id: El ID numérico del Look en Looker.
    Returns:
        Diccionario con la URL del gráfico embebido.
    """
    sdk = looker_sdk.init40()
    embed = sdk.create_sso_embed_url(
        body=models40.EmbedSsoParams(
            target_url=f"/embed/looks/{look_id}",
            session_length=3600,
            force_logout_login=True,
        )
    )
    return {"look_id": look_id, "embed_url": embed.url}

def get_dashboard_url(dashboard_id: str) -> dict:
    """Genera una URL de embed SSO para un Dashboard de Looker.

    Args:
        dashboard_id: El ID numérico del Dashboard en Looker.
    Returns:
        Diccionario con la URL del dashboard embebido.
    """
    sdk = looker_sdk.init40()
    embed = sdk.create_sso_embed_url(
        body=models40.EmbedSsoParams(
            target_url=f"/embed/dashboards/{dashboard_id}",
            session_length=3600,
            force_logout_login=True,
        )
    )
    return {"dashboard_id": dashboard_id, "embed_url": embed.url}

def run_query_as_png(model: str, explore: str, fields: list[str]) -> dict:
    """Ejecuta una query en Looker y devuelve el resultado como imagen PNG en base64.

    Args:
        model: El nombre del modelo LookML (ej: thelook).
        explore: El nombre del explore (ej: order_items).
        fields: Lista de campos a incluir (ej: ['orders.count', 'orders.status']).
    Returns:
        Diccionario con la imagen en base64 y el mime type.
    """
    sdk = looker_sdk.init40()
    query = sdk.create_query(
        body=models40.WriteQuery(
            model=model,
            view=explore,
            fields=fields,
            limit="500",
        )
    )
    png_bytes = sdk.run_query(query_id=str(query.id), result_format="png")
    encoded = base64.b64encode(png_bytes).decode("utf-8")
    return {
        "mime_type": "image/png",
        "data": encoded,
        "model": model,
        "explore": explore,
        "fields": fields,
    }

root_agent = LlmAgent(
    model='gemini-2.5-flash',
    name='looker_agent',
    description='Agent to answer questions about Looker data and generate charts/dashboards.',
    instruction=(
        'You are a helpful agent who can answer user questions about Looker data. '
        'You have access to MCP tools (from the toolbox) for querying Looker models, '
        'explores, and running queries, plus local tools for generating visualizations. '
        'When a user asks for a dashboard, use get_dashboard_url. '
        'When a user asks for a Look or chart by ID, use get_look_url or get_look_png. '
        'When a user asks to see data visually from a query, use run_query_as_png. '
        'Otherwise use the MCP tools (get_models, get_explores, run_query, etc). '
        'If unsure what model to use, try thelook. If unsure on explore, try order_items.'
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
            errlog=None,
            tool_filter=None,
        ),
        get_look_png,
        get_look_url,
        get_dashboard_url,
        run_query_as_png,
    ],
)
EOF
echo "Archivos del agente creados."

echo ""
echo "=================================================="
echo " PASO 7: Crear bucket GCS si no existe"
echo "=================================================="
if ! gcloud storage buckets describe "gs://${BUCKET_NAME}" &>/dev/null; then
  gcloud storage buckets create "gs://${BUCKET_NAME}" --location="$BUCKET_LOCATION"
  echo "Bucket creado: gs://${BUCKET_NAME}"
else
  echo "Bucket ya existe: gs://${BUCKET_NAME}"
fi

echo ""
echo "=================================================="
echo " PASO 8: Desplegar agente en Vertex AI Agent Engine"
echo "  (puede tardar 15-20 min — mostrando progreso)"
echo "=================================================="

DEPLOY_LOG="/tmp/adk_deploy_$$.log"
> "$DEPLOY_LOG"

# Correr el deploy en background y mostrar progreso
adk deploy agent_engine \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --staging_bucket="gs://${BUCKET_NAME}" \
  --display_name="looker-agent1" \
  looker_app > "$DEPLOY_LOG" 2>&1 &

DEPLOY_PID=$!
echo "Deploy corriendo en background (PID: $DEPLOY_PID)"
echo "Log: $DEPLOY_LOG"
echo ""

ELAPSED=0
while kill -0 $DEPLOY_PID 2>/dev/null; do
  sleep 15
  ELAPSED=$((ELAPSED + 15))
  MINS=$((ELAPSED / 60))
  SECS=$((ELAPSED % 60))
  LAST_LINE=$(tail -1 "$DEPLOY_LOG" 2>/dev/null || echo "(sin output aún)")
  echo "[${MINS}m${SECS}s] $LAST_LINE"

  if (( ELAPSED > 0 && ELAPSED % 120 == 0 )); then
    echo "  --- Reasoning Engines en Vertex AI ---"
    gcloud ai reasoning-engines list \
      --region="$REGION" \
      --project="$PROJECT_ID" \
      --format="table(name.segment(-1):label=ID,displayName,createTime)" 2>/dev/null || true
    echo "  --------------------------------------"
  fi
done

wait $DEPLOY_PID
DEPLOY_EXIT=$?

echo ""
echo "=== OUTPUT COMPLETO DEL DEPLOY ==="
cat "$DEPLOY_LOG"
echo "=================================="

if [ $DEPLOY_EXIT -ne 0 ]; then
  echo " Deploy falló con código $DEPLOY_EXIT"
  exit 1
fi

# Extraer el Reasoning Engine resource name (múltiples patrones por si cambia el formato)
REASONING_ENGINE=$(grep -oE 'projects/[^/]+/locations/[^/]+/reasoningEngines/[0-9]+' "$DEPLOY_LOG" | head -1 || true)

# Fallback: buscar el más reciente en Vertex AI
if [ -z "$REASONING_ENGINE" ]; then
  echo "  No se pudo extraer del log. Buscando el más reciente en Vertex AI..."
  REASONING_ENGINE=$(gcloud ai reasoning-engines list \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --filter="displayName=looker-agent1" \
    --sort-by="~createTime" \
    --format="value(name)" \
    --limit=1)
fi

if [ -z "$REASONING_ENGINE" ]; then
  echo " ERROR: No se pudo obtener el Reasoning Engine ID. Aborta."
  exit 1
fi

echo " Reasoning Engine: $REASONING_ENGINE"

# Otorgar rol de Cloud Run Invoker al SA de Agent Engine
AGENT_ENGINE_SA="service-${PROJECT_NUMBER}@gcp-sa-aiplatform-re.iam.gserviceaccount.com"
echo "Otorgando Cloud Run Invoker a: $AGENT_ENGINE_SA"
gcloud run services add-iam-policy-binding toolbox \
  --region="$REGION" \
  --member="serviceAccount:${AGENT_ENGINE_SA}" \
  --role="roles/run.invoker" \
  --project="$PROJECT_ID" &>/dev/null || {
    echo "  Advertencia: no se pudo otorgar roles/run.invoker (quizás ya existe)"
}

cd ..

echo ""
echo "=================================================="
echo " PASO 9: Registrar agente en Gemini Enterprise"
echo "=================================================="
ACCESS_TOKEN=$(gcloud auth print-access-token)

# Endpoint correcto según región (sin duplicar .googleapis.com)
if [ "$ENGINE_LOCATION" = "global" ]; then
  API_ENDPOINT="discoveryengine.googleapis.com"
else
  API_ENDPOINT="${ENGINE_LOCATION}-discoveryengine.googleapis.com"
fi

AGENT_API_URL="https://${API_ENDPOINT}/v1alpha/projects/${PROJECT_NUMBER}/locations/${ENGINE_LOCATION}/collections/default_collection/engines/${AS_APP}/assistants/default_assistant/agents"

echo "POST a: $AGENT_API_URL"
echo ""

# Construir payload con jq-friendly format
REQUEST_BODY=$(cat <<EOF
{
  "displayName": "${AGENT_DISPLAY_NAME}",
  "description": "${AGENT_DESCRIPTION}",
  "adk_agent_definition": {
    "tool_settings": {
      "tool_description": "${TOOL_DESCRIPTION}"
    },
    "provisioned_reasoning_engine": {
      "reasoning_engine": "${REASONING_ENGINE}"
    }
  }
}
EOF
)

echo "Payload:"
echo "$REQUEST_BODY"
echo ""

# Hacer la llamada capturando status HTTP
HTTP_RESPONSE=$(curl -sS -w "\n__HTTP_STATUS__:%{http_code}" -X POST \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -H "X-Goog-User-Project: ${PROJECT_NUMBER}" \
  "$AGENT_API_URL" \
  -d "$REQUEST_BODY")

HTTP_STATUS=$(echo "$HTTP_RESPONSE" | grep "__HTTP_STATUS__" | cut -d: -f2)
RESPONSE_BODY=$(echo "$HTTP_RESPONSE" | sed '/__HTTP_STATUS__/d')

echo "HTTP Status: $HTTP_STATUS"
echo "Respuesta:"
echo "$RESPONSE_BODY" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE_BODY"

if [[ "$HTTP_STATUS" =~ ^2[0-9][0-9]$ ]]; then
  echo ""
  echo " Agente registrado exitosamente en Gemini Enterprise"
else
  echo ""
  echo " ERROR: El registro falló con HTTP $HTTP_STATUS"
  echo ""
  echo "Causas comunes:"
  echo "  - AS_APP ID incorrecto (verifica el ID de tu app en Gemini Enterprise)"
  echo "  - ENGINE_LOCATION incorrecto (prueba 'us', 'eu', o 'global')"
  echo "  - PROJECT_NUMBER no coincide con el proyecto de la app"
  echo "  - Falta permiso 'Discovery Engine Admin' en tu usuario"
  echo "  - El agente ya existe con ese displayName"
  echo ""
  echo "Para listar agentes existentes:"
  echo "  curl -H \"Authorization: Bearer \$(gcloud auth print-access-token)\" \\"
  echo "       -H \"X-Goog-User-Project: ${PROJECT_NUMBER}\" \\"
  echo "       \"${AGENT_API_URL}\""
  exit 1
fi

echo ""
echo "=================================================="
echo "  SETUP COMPLETO"
echo "=================================================="
echo ""
echo "  Cloud Run URL   : $CLOUD_RUN_URL"
echo "  MCP Server URL  : $MCP_SERVER_URL"
echo "  Reasoning Engine: $REASONING_ENGINE"
echo ""
echo "Looker está ahora disponible en tu Gemini Enterprise app!"
