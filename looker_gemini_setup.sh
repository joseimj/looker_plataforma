#!/bin/bash
# =============================================================================
# setup_looker_gemini_enterprise.sh
# Automatiza: MCP Toolbox en Cloud Run + ADK Agent en Agent Engine + Gemini Enterprise
# El agente genera links SSO firmados a dashboards/looks que se renderizan
# como links clickeables en Gemini Enterprise.
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

# Embed Secret de Looker (Looker Admin > Embed > Embed Secret)
# IMPORTANTE: También debes agregar el dominio de Gemini Enterprise en
# Looker Admin > Embed > Embed Domain Allowlist
LOOKER_EMBED_SECRET="YOUR_LOOKER_EMBED_SECRET"

# Modelos LookML permitidos para el embed (ajusta según tu instancia)
LOOKER_MODELS='["thelook"]'

# Gemini Enterprise
AS_APP="YOUR_GEMINI_ENTERPRISE_AGENT_ID"
ENGINE_LOCATION="us"                           # "us", "eu", o "global"
AGENT_DISPLAY_NAME="Looker Agent"
AGENT_DESCRIPTION="Looker MCP Capability with interactive dashboards."
TOOL_DESCRIPTION="Use this tool to answer questions about Looker data, generate dashboard/chart links, and visualize ecommerce metrics."
# =============================================================================

# -----------------------------------------------------------------------------
# Helper: valida que una variable no esté vacía ni con valor placeholder
# -----------------------------------------------------------------------------
validate_var() {
  local var_name="$1"
  local var_value="$2"
  if [[ -z "$var_value" || "$var_value" == YOUR_* ]]; then
    echo "ERROR: La variable '$var_name' no está configurada correctamente."
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
validate_var "LOOKER_EMBED_SECRET" "$LOOKER_EMBED_SECRET"
validate_var "AS_APP" "$AS_APP"
echo "OK: Todas las variables están configuradas."

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
  echo "ERROR: No se pudo obtener la URL del Cloud Run"
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
LOOKER_EMBED_SECRET=${LOOKER_EMBED_SECRET}
LOOKER_MODELS=${LOOKER_MODELS}
EOF

cat > looker_app/requirements.txt <<EOF
google-adk
toolbox-core
looker_sdk
google-auth
requests
EOF

# Usar single-quote heredoc ('PYEOF') para evitar problemas con backslashes y $
# Solo reemplazamos MCP_SERVER_URL al final con sed
cat > looker_app/agent.py <<'PYEOF'
import os
import time
import hmac
import hashlib
import json
import base64
import binascii
from urllib.parse import quote_plus

import looker_sdk
from looker_sdk import models40

from google.adk.agents import LlmAgent
from google.adk.planners.built_in_planner import BuiltInPlanner
from google.adk.tools.mcp_tool.mcp_toolset import MCPToolset
from google.adk.tools.mcp_tool.mcp_session_manager import StreamableHTTPConnectionParams
from google.genai.types import ThinkingConfig
import google.auth.transport.requests
import google.oauth2.id_token

# -----------------------------------------------------------------------------
# Configuracion desde variables de entorno
# -----------------------------------------------------------------------------
MCP_SERVER_URL = "__MCP_SERVER_URL__"
LOOKER_HOST = (
    os.environ.get("LOOKERSDK_BASE_URL", "")
    .replace("https://", "")
    .replace("http://", "")
    .rstrip("/")
)
EMBED_SECRET = os.environ.get("LOOKER_EMBED_SECRET", "")
LOOKER_MODELS_ENV = os.environ.get("LOOKER_MODELS", '["thelook"]')


def get_id_token():
    """Obtiene un ID token para autenticarse con el MCP server en Cloud Run."""
    audience = MCP_SERVER_URL.split('/mcp')[0]
    auth_req = google.auth.transport.requests.Request()
    return google.oauth2.id_token.fetch_id_token(auth_req, audience)


# -----------------------------------------------------------------------------
# SSO Embed URL signing (metodo oficial de Looker)
# Doc: https://cloud.google.com/looker/docs/single-sign-on-embedding
# -----------------------------------------------------------------------------
def _generate_signed_embed_url(target_path: str, user_email: str = "gemini-enterprise-user@company.com") -> str:
    """Genera una URL SSO firmada para embed de Looker sin requerir login."""
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
        "see_lookml_dashboards", "explore", "save_content",
        "embed_browse_spaces"
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
        LOOKER_HOST,
        target_path,
        nonce,
        str(current_time),
        str(session_length),
        external_user_id,
        permissions,
        models,
        group_ids,
        user_attributes,
        access_filters,
    ])

    signature = base64.b64encode(
        hmac.new(
            EMBED_SECRET.encode('utf-8'),
            string_to_sign.encode('utf-8'),
            hashlib.sha1
        ).digest()
    ).decode().strip()

    params = {
        "nonce": nonce,
        "time": current_time,
        "session_length": session_length,
        "external_user_id": external_user_id,
        "permissions": permissions,
        "models": models,
        "group_ids": group_ids,
        "external_group_id": external_group_id,
        "user_attributes": user_attributes,
        "access_filters": access_filters,
        "first_name": first_name,
        "last_name": last_name,
        "user_timezone": user_timezone,
        "force_logout_login": force_logout_login,
        "signature": signature,
    }

    query = "&".join(f"{k}={quote_plus(str(v))}" for k, v in params.items())
    return f"https://{LOOKER_HOST}{target_path}?{query}"


# -----------------------------------------------------------------------------
# Tools: generacion de links interactivos para Gemini Enterprise
# -----------------------------------------------------------------------------
def get_dashboard_link(dashboard_id: str, title: str = "") -> dict:
    """Genera un link clickeable a un Dashboard de Looker (SSO firmado).

    Usar cuando el usuario quiere VER, MOSTRAR o VISUALIZAR un dashboard.
    Devuelve un markdown que Gemini Enterprise renderiza como link clickeable.

    Args:
        dashboard_id: ID numerico del dashboard (ej: "42").
        title: Titulo opcional para mostrar en el link.
    Returns:
        Dict con markdown listo para mostrar en chat.
    """
    url = _generate_signed_embed_url(f"/embed/dashboards/{dashboard_id}")
    label = title if title else f"Dashboard {dashboard_id}"
    return {
        "dashboard_id": dashboard_id,
        "url": url,
        "markdown": f"[Ver {label} en Looker]({url})\n\nClick para abrir el dashboard interactivo en una nueva pestana.",
    }


def get_look_link(look_id: str, title: str = "") -> dict:
    """Genera un link clickeable a un Look (grafico) de Looker.

    Args:
        look_id: ID numerico del Look.
        title: Titulo opcional para mostrar en el link.
    Returns:
        Dict con markdown listo para mostrar en chat.
    """
    url = _generate_signed_embed_url(f"/embed/looks/{look_id}")
    label = title if title else f"Look {look_id}"
    return {
        "look_id": look_id,
        "url": url,
        "markdown": f"[Ver {label} en Looker]({url})\n\nClick para abrir el grafico interactivo.",
    }


def list_available_dashboards(search_term: str = "") -> dict:
    """Lista los dashboards disponibles en Looker con links SSO firmados.

    Usar cuando el usuario pregunte que dashboards existen o quiere explorar.

    Args:
        search_term: Filtro opcional para buscar dashboards por nombre.
    Returns:
        Dict con lista de dashboards y markdown listo para mostrar.
    """
    sdk = looker_sdk.init40()
    if search_term:
        dashboards = sdk.search_dashboards(title=f"%{search_term}%", limit=20)
    else:
        dashboards = sdk.search_dashboards(limit=20)

    items = []
    md_lines = ["## Dashboards disponibles:\n"]
    for d in dashboards:
        url = _generate_signed_embed_url(f"/embed/dashboards/{d.id}")
        items.append({"id": str(d.id), "title": d.title, "url": url})
        md_lines.append(f"- [{d.title}]({url}) (ID: {d.id})")

    if not items:
        return {
            "dashboards": [],
            "markdown": "No encontre dashboards con ese criterio."
        }

    return {"dashboards": items, "markdown": "\n".join(md_lines)}


def list_available_looks(search_term: str = "") -> dict:
    """Lista los Looks disponibles en Looker con links SSO firmados.

    Args:
        search_term: Filtro opcional para buscar Looks por titulo.
    Returns:
        Dict con lista de looks y markdown para mostrar en chat.
    """
    sdk = looker_sdk.init40()
    if search_term:
        looks = sdk.search_looks(title=f"%{search_term}%", limit=20)
    else:
        looks = sdk.search_looks(limit=20)

    items = []
    md_lines = ["## Looks disponibles:\n"]
    for l in looks:
        url = _generate_signed_embed_url(f"/embed/looks/{l.id}")
        items.append({"id": str(l.id), "title": l.title, "url": url})
        md_lines.append(f"- [{l.title}]({url}) (ID: {l.id})")

    if not items:
        return {"looks": [], "markdown": "No encontre Looks con ese criterio."}

    return {"looks": items, "markdown": "\n".join(md_lines)}


def generate_query_link(model: str, explore: str, fields: list) -> dict:
    """Crea una query ad-hoc en Looker y devuelve un link SSO al explore.

    Usar cuando el usuario quiere ver datos visualmente pero no hay Look/Dashboard
    existente. Construye la query y genera link al Explore con esos campos.

    Args:
        model: Nombre del modelo LookML (ej: "thelook").
        explore: Nombre del explore (ej: "order_items").
        fields: Lista de campos (ej: ["orders.count", "orders.status"]).
    Returns:
        Dict con link al explore con la query pre-cargada.
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
    target_path = f"/embed/explore/{model}/{explore}?qid={query.client_id}"
    url = _generate_signed_embed_url(target_path)
    return {
        "model": model,
        "explore": explore,
        "fields": fields,
        "url": url,
        "markdown": f"[Ver visualizacion interactiva en Looker]({url})\n\nExplorando {explore} del modelo {model}.",
    }


# -----------------------------------------------------------------------------
# Agente ADK principal
# -----------------------------------------------------------------------------
root_agent = LlmAgent(
    model='gemini-2.5-flash',
    name='looker_agent',
    description='Looker data agent that returns interactive dashboard/look links for Gemini Enterprise.',
    instruction=(
        'You are a Looker data agent operating inside Gemini Enterprise. '
        'Your primary responsibility is to help users answer questions about their '
        'Looker data AND give them interactive access to dashboards and charts. '
        '\n\n'
        'CRITICAL RULES for visualization requests: '
        '\n- When users ask to SEE, SHOW, VIEW, VISUALIZE, or OPEN a dashboard or chart: '
        '  you MUST call get_dashboard_link or get_look_link and return the "markdown" '
        '  field VERBATIM in your response. This produces a clickable SSO link. '
        '\n- When users ask "what dashboards exist" or "show me my dashboards": '
        '  call list_available_dashboards and return its markdown. '
        '\n- When users want to visualize ad-hoc data (no existing dashboard): '
        '  call generate_query_link with appropriate model/explore/fields. '
        '\n- NEVER describe a dashboard in text when you could give them the live link. '
        '\n\n'
        'For raw data questions (totals, counts, aggregations without visualization): '
        'use the MCP tools (get_models, get_explores, run_query, etc.) to return numbers. '
        '\n\n'
        'Default assumptions when unsure: '
        '\n- Model: "thelook" '
        '\n- Explore: "order_items" '
        '\n\n'
        'Always prefer giving users an interactive Looker link over a text-only answer '
        'when they show any interest in seeing data visually.'
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
        get_dashboard_link,
        get_look_link,
        list_available_dashboards,
        list_available_looks,
        generate_query_link,
    ],
)
PYEOF

# Reemplazar el placeholder de MCP_SERVER_URL con la URL real
sed -i "s|__MCP_SERVER_URL__|${MCP_SERVER_URL}|g" looker_app/agent.py

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
echo "  (puede tardar 15-20 min - mostrando progreso)"
echo "=================================================="

DEPLOY_LOG="/tmp/adk_deploy_$$.log"
> "$DEPLOY_LOG"

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
  LAST_LINE=$(tail -1 "$DEPLOY_LOG" 2>/dev/null || echo "(sin output aun)")
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
  echo "ERROR: Deploy fallo con codigo $DEPLOY_EXIT"
  exit 1
fi

# Extraer el Reasoning Engine resource name
REASONING_ENGINE=$(grep -oE 'projects/[^/]+/locations/[^/]+/reasoningEngines/[0-9]+' "$DEPLOY_LOG" | head -1 || true)

# Fallback: buscar el mas reciente en Vertex AI
if [ -z "$REASONING_ENGINE" ]; then
  echo "WARN: No se pudo extraer del log. Buscando el mas reciente en Vertex AI..."
  REASONING_ENGINE=$(gcloud ai reasoning-engines list \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --filter="displayName=looker-agent1" \
    --sort-by="~createTime" \
    --format="value(name)" \
    --limit=1)
fi

if [ -z "$REASONING_ENGINE" ]; then
  echo "ERROR: No se pudo obtener el Reasoning Engine ID. Aborta."
  exit 1
fi

echo "OK: Reasoning Engine: $REASONING_ENGINE"

# Otorgar rol de Cloud Run Invoker al SA de Agent Engine
AGENT_ENGINE_SA="service-${PROJECT_NUMBER}@gcp-sa-aiplatform-re.iam.gserviceaccount.com"
echo "Otorgando Cloud Run Invoker a: $AGENT_ENGINE_SA"
gcloud run services add-iam-policy-binding toolbox \
  --region="$REGION" \
  --member="serviceAccount:${AGENT_ENGINE_SA}" \
  --role="roles/run.invoker" \
  --project="$PROJECT_ID" &>/dev/null || {
    echo "WARN: no se pudo otorgar roles/run.invoker (quizas ya existe)"
}

cd ..

echo ""
echo "=================================================="
echo " PASO 9: Registrar agente en Gemini Enterprise"
echo "=================================================="
ACCESS_TOKEN=$(gcloud auth print-access-token)

# Endpoint correcto segun region
if [ "$ENGINE_LOCATION" = "global" ]; then
  API_ENDPOINT="discoveryengine.googleapis.com"
else
  API_ENDPOINT="${ENGINE_LOCATION}-discoveryengine.googleapis.com"
fi

AGENT_API_URL="https://${API_ENDPOINT}/v1alpha/projects/${PROJECT_NUMBER}/locations/${ENGINE_LOCATION}/collections/default_collection/engines/${AS_APP}/assistants/default_assistant/agents"

echo "POST a: $AGENT_API_URL"
echo ""

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
  echo "OK: Agente registrado exitosamente en Gemini Enterprise"
else
  echo ""
  echo "ERROR: El registro fallo con HTTP $HTTP_STATUS"
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
echo " SETUP COMPLETO"
echo "=================================================="
echo ""
echo "  Cloud Run URL   : $CLOUD_RUN_URL"
echo "  MCP Server URL  : $MCP_SERVER_URL"
echo "  Reasoning Engine: $REASONING_ENGINE"
echo ""
echo "Tu agente Looker esta listo en Gemini Enterprise!"
echo ""
echo "Prueba con prompts como:"
echo "  - Que dashboards tengo disponibles?"
echo "  - Muestrame el dashboard de ventas"
echo "  - Abre el Look 42"
echo "  - Visualiza la cantidad de ordenes por estado"
echo ""
echo "IMPORTANTE: Verifica en Looker Admin > Embed que:"
echo "  1. Embed SSO Authentication este ACTIVADO"
echo "  2. El dominio de Gemini Enterprise este en Embed Domain Allowlist"
echo "  3. El Embed Secret configurado coincida con tu instancia"
