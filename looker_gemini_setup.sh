#!/bin/bash
# =============================================================================
# setup_looker_gemini_enterprise.sh
# Automatiza: MCP Toolbox en Cloud Run + ADK Agent en Agent Engine + Gemini Enterprise
# Basado en: https://medium.com/google-cloud/connect-looker-to-agentspace-in-minutes-with-mcp-toolbox-and-the-adk-8e37ae096f49 de Rob Carr
# Modificado por Jose Maldonado Abril de 2026
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURA ESTAS VARIABLES ANTES DE EJECUTAR
# =============================================================================
PROJECT_ID="YOUR_GOOGLE_CLOUD_PROJECT_ID"
PROJECT_NUMBER="YOUR_PROJECT_NUMBER"           # gcloud projects describe $PROJECT_ID --format='value(projectNumber)'
REGION="us-central1"
BUCKET_NAME="YOUR_GCS_BUCKET_NAME"            # debe ser globalmente único
BUCKET_LOCATION="US"

# Credenciales de Looker (obtener en Looker Admin > API Keys)
LOOKER_URL="https://your-instance.looker.com"
LOOKER_CLIENT_ID="YOUR_LOOKER_CLIENT_ID"
LOOKER_CLIENT_SECRET="YOUR_LOOKER_CLIENT_SECRET"

# Agentspace
AS_APP="YOUR_GEMINI_ENTERPRISE_AGENT_ID"
AGENT_DISPLAY_NAME="Looker Agent"
AGENT_DESCRIPTION="Looker MCP Capability."
TOOL_DESCRIPTION="Looker's Query Engine is used to answer Ecommerce questions."
# =============================================================================

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
  discoveryengine.googleapis.com

echo ""
echo "=================================================="
echo " PASO 2: Crear cuenta de servicio y roles"
echo "=================================================="
SA_NAME="toolbox-identity"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# Crear SA solo si no existe
if ! gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID" &>/dev/null; then
  gcloud iam service-accounts create "$SA_NAME" --project="$PROJECT_ID"
  echo "Service account creada: $SA_EMAIL"
else
  echo "Service account ya existe: $SA_EMAIL"
fi

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/secretmanager.secretAccessor"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/cloudsql.client"

echo ""
echo "=================================================="
echo " PASO 3: Descargar MCP Toolbox binary"
echo "=================================================="
mkdir -p mcp-toolbox && cd mcp-toolbox

OS="linux/amd64"
TOOLBOX_VERSION="v0.12.0"
if [ ! -f "toolbox" ]; then
  curl -O "https://storage.googleapis.com/genai-toolbox/${TOOLBOX_VERSION}/${OS}/toolbox"
  chmod +x toolbox
  echo "Toolbox descargado."
else
  echo "Toolbox ya existe, omitiendo descarga."
fi

echo ""
echo "=================================================="
echo " PASO 4: Generar tools.yaml para Looker"
echo "=================================================="
cat > tools.yaml <<EOF
sources:
  looker-source:
    kind: looker
    base_url: ${LOOKER_URL}
    client_id: ${LOOKER_CLIENT_ID}
    client_secret: ${LOOKER_CLIENT_SECRET}
    verify_ssl: true
    timeout: 600s

tools:
  get_models:
    kind: looker-get-models
    source: looker-source
    description: |
      Retrieves the list of LookML models in the Looker system. Takes no parameters.

  run_query:
    kind: looker-run-query
    source: looker-source
    description: |
      Runs a query against Looker and returns results.

  get_explores:
    kind: looker-get-explores
    source: looker-source
    description: |
      Gets available explores for a given LookML model.

  get_dimensions_and_measures:
    kind: looker-get-dimensions-and-measures
    source: looker-source
    description: |
      Returns all dimensions and measures for a given model and explore.
EOF
echo "tools.yaml generado."

echo ""
echo "=================================================="
echo " PASO 5: Cargar tools.yaml en Secret Manager"
echo "=================================================="
SECRET_NAME="tools"
if gcloud secrets describe "$SECRET_NAME" --project="$PROJECT_ID" &>/dev/null; then
  gcloud secrets versions add "$SECRET_NAME" --data-file=tools.yaml
  echo "Nueva versión del secret creada."
else
  gcloud secrets create "$SECRET_NAME" --data-file=tools.yaml
  echo "Secret creado."
fi

echo ""
echo "=================================================="
echo " PASO 6: Desplegar MCP Toolbox en Cloud Run"
echo "=================================================="
IMAGE="us-central1-docker.pkg.dev/database-toolbox/toolbox/toolbox:latest"

gcloud run deploy toolbox \
  --image="$IMAGE" \
  --service-account="$SA_EMAIL" \
  --region="$REGION" \
  --set-secrets="/app/tools.yaml=${SECRET_NAME}:latest" \
  --args="--tools_file=/app/tools.yaml,--address=0.0.0.0,--port=8080" \
  --no-allow-unauthenticated \
  --project="$PROJECT_ID"

# Obtener la URL del Cloud Run service
CLOUD_RUN_URL=$(gcloud run services describe toolbox \
  --region="$REGION" \
  --project="$PROJECT_ID" \
  --format="value(status.url)")

echo "Cloud Run URL: $CLOUD_RUN_URL"
MCP_SERVER_URL="${CLOUD_RUN_URL}/mcp"

cd ..

echo ""
echo "=================================================="
echo " PASO 7: Configurar entorno Python para el agente ADK"
echo "=================================================="
mkdir -p my-agents && cd my-agents

python3 -m venv .venv
source .venv/bin/activate

pip install --quiet google-adk toolbox-core

echo ""
echo "=================================================="
echo " PASO 8: Crear la aplicación del agente ADK"
echo "=================================================="
mkdir -p looker_app

cat > looker_app/__init__.py <<'EOF'
from . import agent
EOF

cat > looker_app/.env <<EOF
GOOGLE_GENAI_USE_VERTEXAI=1
GOOGLE_CLOUD_PROJECT=${PROJECT_ID}
GOOGLE_CLOUD_LOCATION=${REGION}
EOF

cat > looker_app/agent.py <<EOF
import os
from google.adk.agents import LlmAgent
from google.adk.planners.built_in_planner import BuiltInPlanner
from google.adk.tools.mcp_tool.mcp_toolset import MCPToolset
from google.adk.tools.mcp_tool.mcp_session_manager import StreamableHTTPConnectionParams
from google.genai.types import ThinkingConfig
import google.auth.transport.requests
import google.oauth2.id_token

MCP_SERVER_URL = "${MCP_SERVER_URL}"

def get_id_token():
    """Obtiene un ID token para autenticarse con el MCP server."""
    audience = MCP_SERVER_URL.split('/mcp')[0]
    auth_req = google.auth.transport.requests.Request()
    id_token = google.oauth2.id_token.fetch_id_token(auth_req, audience)
    return id_token

root_agent = LlmAgent(
    model='gemini-2.5-flash',
    name='looker_agent',
    description='Agent to answer questions about Looker data.',
    instruction=(
        'You are a helpful agent who can answer user questions about Looker data. '
        'Use the tools to answer the question. If unsure what model to use, try '
        'defaulting to thelook. If unsure on explore, try order_items.'
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
        )
    ],
)
EOF
echo "Archivos del agente creados."

echo ""
echo "=================================================="
echo " PASO 9: Crear bucket GCS si no existe"
echo "=================================================="
if ! gcloud storage buckets describe "gs://${BUCKET_NAME}" &>/dev/null; then
  gcloud storage buckets create "gs://${BUCKET_NAME}" --location="$BUCKET_LOCATION"
  echo "Bucket creado: gs://${BUCKET_NAME}"
else
  echo "Bucket ya existe: gs://${BUCKET_NAME}"
fi

echo ""
echo "=================================================="
echo " PASO 10: Desplegar agente en Vertex AI Agent Engine"
echo "=================================================="
DEPLOY_OUTPUT=$(adk deploy agent_engine \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --staging_bucket="gs://${BUCKET_NAME}" \
  --display_name="looker-agent1" \
  looker_app 2>&1)

echo "$DEPLOY_OUTPUT"

# Extraer el Reasoning Engine resource name del output
REASONING_ENGINE=$(echo "$DEPLOY_OUTPUT" | grep -oP 'projects/[^/]+/locations/[^/]+/reasoningEngines/\d+' | head -1)
echo "Reasoning Engine: $REASONING_ENGINE"

# Otorgar rol de Cloud Run Invoker al Agent Engine SA
AGENT_ENGINE_SA="service-${PROJECT_NUMBER}@gcp-sa-aiplatform-re.iam.gserviceaccount.com"
echo "Otorgando Cloud Run Invoker a: $AGENT_ENGINE_SA"
gcloud run services add-iam-policy-binding toolbox \
  --region="$REGION" \
  --member="serviceAccount:${AGENT_ENGINE_SA}" \
  --role="roles/run.invoker"

cd ..

echo ""
echo "=================================================="
echo " PASO 11: Registrar agente en Gemini Enterprise"
echo "=================================================="
ACCESS_TOKEN=$(gcloud auth print-access-token)

curl -s -X POST \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -H "X-Goog-User-Project: ${PROJECT_NUMBER}" \
  "https://discoveryengine.googleapis.com/v1alpha/projects/${PROJECT_NUMBER}/locations/global/collections/default_collection/engines/${AS_APP}/assistants/default_assistant/agents" \
  -d "{
    \"displayName\": \"${AGENT_DISPLAY_NAME}\",
    \"description\": \"${AGENT_DESCRIPTION}\",
    \"adk_agent_definition\": {
      \"tool_settings\": {
        \"tool_description\": \"${TOOL_DESCRIPTION}\"
      },
      \"provisioned_reasoning_engine\": {
        \"reasoning_engine\": \"${REASONING_ENGINE}\"
      }
    }
  }"

echo ""
echo "=================================================="
echo " SETUP COMPLETO"
echo "=================================================="
echo ""
echo "  Cloud Run URL   : $CLOUD_RUN_URL"
echo "  MCP Server URL  : $MCP_SERVER_URL"
echo "  Reasoning Engine: $REASONING_ENGINE"
echo ""
echo "Looker está ahora disponible en tu Gemini Enterprise app!"
