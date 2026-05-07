#!/bin/bash
# =============================================================================
# setup_looker_gemini_enterprise_v7_a2ui.sh
# Agente A2UI con visualizaciones inline en Gemini Enterprise.
#
# Reemplaza la arquitectura del v6.x:
#   ANTES: Cloud Run (toolbox) -> Reasoning Engine (ADK) -> Gemini Enterprise (markdown)
#   AHORA: Cloud Run (agente A2A+A2UI) -> Gemini Enterprise (UI components nativos)
#
# Caracteristicas:
#   - Agente desplegado directamente en Cloud Run (no en Reasoning Engine)
#   - Soporta protocolo A2A (Agent2Agent) con extension A2UI v0.8
#   - Devuelve componentes UI nativos: Cards, Charts, Lists, Forms
#   - Reutiliza el toolbox MCP del v6.x para queries a Looker
#   - Renderizacion sin restricciones de Model Armor (componentes nativos)
#
# IMPORTANTE - PRE-GA:
#   A2UI v0.8 esta en Pre-GA (anunciado en Cloud Next 2026). Sujeto a cambios.
#   Los TODO_A2UI marcados deben verificarse contra el tutorial oficial:
#   https://docs.cloud.google.com/gemini/enterprise/docs/a2ui-agents/tutorial-host-agent-cloud-run
#
# Edicion requerida: Standard, Plus o Frontline (NO Business)
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURA ESTAS VARIABLES
# =============================================================================
PROJECT_ID="YOUR_GOOGLE_CLOUD_PROJECT_ID"
PROJECT_NUMBER="YOUR_PROJECT_NUMBER"
REGION="us-central1"

# Looker (compartida con el v6.x)
LOOKER_URL="https://your-instance.looker.com"
LOOKER_CLIENT_ID="YOUR_LOOKER_CLIENT_ID"
LOOKER_CLIENT_SECRET="YOUR_LOOKER_CLIENT_SECRET"
LOOKER_EMBED_SECRET="YOUR_LOOKER_EMBED_SECRET"
LOOKER_MODELS='["all"]'

# MCP Toolbox URL (reutilizamos el del v6.x si esta desplegado)
# Si no esta, el script lo crea
MCP_TOOLBOX_URL=""  # opcional, se descubre del Cloud Run "toolbox" si existe

# Gemini Enterprise
AS_APP="YOUR_GEMINI_ENTERPRISE_AGENT_ID"
ENGINE_LOCATION="us"
AGENT_NAME="looker-cost-a2ui"
AGENT_DISPLAY_NAME="GCP Cost Agent (A2UI)"
AGENT_DESCRIPTION="Looker billing agent with native UI components via A2UI protocol."

# Modelo de Gemini para el agente (segun el tutorial soporta gemini-2.5-pro o flash)
AGENT_MODEL="gemini-2.5-flash"
# =============================================================================

unset SA_EMAIL CLOUD_RUN_URL AGENT_URL DEPLOY_LOG DEPLOY_PID
unset ACCESS_TOKEN API_ENDPOINT AGENT_API_URL HTTP_RESPONSE HTTP_STATUS

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
echo " PASO -1: Validar variables y Edicion de GE"
echo "=================================================="
validate_var "PROJECT_ID" "$PROJECT_ID"
validate_var "PROJECT_NUMBER" "$PROJECT_NUMBER"
validate_var "LOOKER_URL" "$LOOKER_URL"
validate_var "LOOKER_CLIENT_ID" "$LOOKER_CLIENT_ID"
validate_var "LOOKER_CLIENT_SECRET" "$LOOKER_CLIENT_SECRET"
validate_var "AS_APP" "$AS_APP"

cat <<EOF

ADVERTENCIAS PRE-GA:
  - A2UI v0.8 esta en Pre-GA. Edicion Standard, Plus o Frontline requerida.
  - Verifica que tu instancia de Gemini Enterprise tiene la edicion correcta.
  - Los TODO_A2UI marcados en el codigo pueden necesitar ajuste.

EOF
read -p "Confirma que tu Gemini Enterprise es Standard/Plus/Frontline [s/n]: " EDITION_OK
[[ "$EDITION_OK" != "s" ]] && { echo "Verifica edicion antes de continuar"; exit 1; }

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
  cloudresourcemanager.googleapis.com \
  --project="$PROJECT_ID"

echo ""
echo "=================================================="
echo " PASO 2: Service Account dedicada para el agente A2UI"
echo "=================================================="
SA_NAME="looker-a2ui-sa"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

if ! gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID" &>/dev/null; then
  gcloud iam service-accounts create "$SA_NAME" \
    --project="$PROJECT_ID" \
    --display-name="Looker A2UI Agent SA"
fi
echo "SA: $SA_EMAIL"

# Permisos para llamar Vertex AI (Gemini API)
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/aiplatform.user" \
  --condition=None &>/dev/null
echo "  [OK] aiplatform.user"

# Permiso para escribir logs
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/logging.logWriter" \
  --condition=None &>/dev/null
echo "  [OK] logging.logWriter"

# Permiso para invocar el toolbox MCP (si existe)
if gcloud run services describe toolbox --region="$REGION" --project="$PROJECT_ID" &>/dev/null; then
  gcloud run services add-iam-policy-binding toolbox \
    --region="$REGION" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/run.invoker" \
    --project="$PROJECT_ID" &>/dev/null
  echo "  [OK] run.invoker en toolbox"

  if [ -z "$MCP_TOOLBOX_URL" ]; then
    MCP_TOOLBOX_URL=$(gcloud run services describe toolbox \
      --region="$REGION" --project="$PROJECT_ID" --format="value(status.url)")"/mcp"
    echo "  Toolbox MCP detectado: $MCP_TOOLBOX_URL"
  fi
else
  echo "  WARN: Cloud Run 'toolbox' no encontrado. Despliega primero el v6.x"
  echo "  o configura MCP_TOOLBOX_URL manualmente en este script."
  exit 1
fi

echo ""
echo "=================================================="
echo " PASO 3: Crear codigo del agente A2UI"
echo "=================================================="
rm -rf my-a2ui-agent
mkdir -p my-a2ui-agent && cd my-a2ui-agent

# -----------------------------------------------------------------------------
# requirements.txt
# TODO_A2UI: verificar nombre exacto del paquete A2UI extension contra
# el tutorial oficial. Probables candidatos:
#   - "a2ui-agent-sdk"
#   - "google-adk-a2ui"
#   - "a2ui[adk]"
# -----------------------------------------------------------------------------
cat > requirements.txt <<'EOF'
# Core ADK
google-adk

# A2UI extension
# TODO_A2UI: verificar nombre exacto del paquete contra tutorial oficial
# https://docs.cloud.google.com/gemini/enterprise/docs/a2ui-agents/tutorial-host-agent-cloud-run
a2ui-agent-sdk

# A2A protocol (para comunicacion con Gemini Enterprise)
# TODO_A2UI: verificar nombre exacto
google-a2a

# MCP client (para llamar al toolbox)
toolbox-core

# Looker SDK (para SSO embed URLs)
looker_sdk

# Servidor web
fastapi
uvicorn[standard]
pydantic

# Auth
google-auth
requests
EOF

# -----------------------------------------------------------------------------
# Dockerfile
# -----------------------------------------------------------------------------
cat > Dockerfile <<'EOF'
FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

ENV PORT=8080
EXPOSE 8080

# TODO_A2UI: el tutorial oficial puede usar un comando diferente para arrancar.
# Patrones comunes:
#   uvicorn main:app --host 0.0.0.0 --port ${PORT}
#   python -m a2ui_agent_sdk.server --agent main:agent
CMD exec uvicorn main:app --host 0.0.0.0 --port ${PORT} --workers 1 --loop uvloop
EOF

# -----------------------------------------------------------------------------
# main.py - el agente A2UI
# TODO_A2UI: gran parte de este codigo es structural. Los imports y nombres
# de clases deben verificarse contra el tutorial oficial.
# -----------------------------------------------------------------------------
cat > main.py <<'PYEOF'
"""
Looker Cost Agent con A2UI v0.8.

Estructura:
1. ADK agent con tools que devuelven componentes A2UI
2. A2A protocol handler para Gemini Enterprise
3. Tools llaman al MCP toolbox para queries Looker
"""
import os
import json
import time
import hmac
import hashlib
import base64
import binascii
from urllib.parse import quote_plus
from typing import Any

# TODO_A2UI: verificar imports exactos contra el tutorial.
# Imports inferidos del patron del tutorial publico:
from google.adk.agents import LlmAgent
from google.adk.tools.mcp_tool.mcp_toolset import MCPToolset
from google.adk.tools.mcp_tool.mcp_session_manager import StreamableHTTPConnectionParams

# A2UI components - TODO_A2UI: verificar imports
# Patron probable basado en a2ui.org documentation:
try:
    from a2ui import components as a2ui_c
    from a2ui.agent_sdk import A2UIAgent, register_a2a_handler
except ImportError:
    # Fallback: si los nombres son distintos, ajustar aqui
    print("WARNING: a2ui imports failed. Check tutorial for correct package names.")
    raise

# Servidor web
from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse, StreamingResponse
import uvicorn

# Auth para llamar al toolbox MCP
import google.auth.transport.requests
import google.oauth2.id_token

# Looker SDK para SSO embed URLs
import looker_sdk
from looker_sdk import models40


# -----------------------------------------------------------------------------
# Config
# -----------------------------------------------------------------------------
MCP_SERVER_URL = os.environ["MCP_TOOLBOX_URL"]
LOOKER_HOST = (
    os.environ.get("LOOKERSDK_BASE_URL", "")
    .replace("https://", "").replace("http://", "").rstrip("/")
)
EMBED_SECRET = os.environ.get("LOOKER_EMBED_SECRET", "")
LOOKER_MODELS_ENV = os.environ.get("LOOKER_MODELS", '["all"]')
AGENT_MODEL = os.environ.get("AGENT_MODEL", "gemini-2.5-flash")


def get_id_token():
    """ID token para autenticar con MCP server en Cloud Run."""
    audience = MCP_SERVER_URL.split('/mcp')[0]
    auth_req = google.auth.transport.requests.Request()
    return google.oauth2.id_token.fetch_id_token(auth_req, audience)


def _generate_signed_embed_url(target_path: str, user_email: str = "ge-user@company.com") -> str:
    """SSO embed URL para Looker (link interactivo)."""
    nonce = binascii.hexlify(os.urandom(8)).decode()
    current_time = int(time.time())
    session_length = 3600
    external_user_id = json.dumps(user_email)
    permissions = json.dumps([
        "access_data", "see_looks", "see_user_dashboards",
        "see_lookml_dashboards", "explore", "save_content"
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


# -----------------------------------------------------------------------------
# A2UI Components (helpers)
# TODO_A2UI: verificar la estructura exacta del schema v0.8 contra
# https://a2ui.org/specification/v0_8/standard_catalog_definition.json
# -----------------------------------------------------------------------------

def make_card(title: str, value: str, subtitle: str = "", trend: str = None) -> dict:
    """Genera un componente Card A2UI con un metric.

    TODO_A2UI: verificar schema exacto de Card en v0.8.
    Puede que el campo se llame 'header' en lugar de 'title', etc.
    """
    component = {
        "type": "Card",  # TODO_A2UI: verificar nombre
        "properties": {
            "title": title,
            "value": value,
            "subtitle": subtitle,
        }
    }
    if trend:
        component["properties"]["trend"] = trend  # e.g. "+12.5%" o "-3.2%"
    return component


def make_list(title: str, items: list[dict]) -> dict:
    """Lista de items (e.g. top 5 servicios).

    items: [{"label": "Compute Engine", "value": "$18,234.56", "subtext": "39%"}]
    """
    return {
        "type": "List",  # TODO_A2UI: verificar
        "properties": {
            "title": title,
            "items": items,
        }
    }


def make_chart(title: str, chart_type: str, data: list[dict]) -> dict:
    """Chart interactivo.

    chart_type: "bar", "line", "pie"
    data: [{"label": "Mar", "value": 45678}, ...]

    TODO_A2UI: el catalogo v0.8 puede no tener Chart, verificar.
    Si no existe, usar List con bars en ASCII como fallback.
    """
    return {
        "type": "Chart",  # TODO_A2UI: verificar - puede llamarse "DataVisualization"
        "properties": {
            "title": title,
            "chartType": chart_type,
            "data": data,
        }
    }


def make_link_card(title: str, description: str, url: str, icon: str = None) -> dict:
    """Card con link a Looker dashboard."""
    component = {
        "type": "LinkCard",  # TODO_A2UI: verificar - puede ser "Card" con propiedad "link"
        "properties": {
            "title": title,
            "description": description,
            "url": url,
        }
    }
    if icon:
        component["properties"]["icon"] = icon
    return component


# -----------------------------------------------------------------------------
# Tools del agente
# Cada tool devuelve un dict con:
#   - "text": breve texto explicativo (markdown)
#   - "ui_components": lista de componentes A2UI a renderizar
# -----------------------------------------------------------------------------

async def get_total_spend(period: str = "last month") -> dict:
    """Total spend para un periodo.

    Args:
        period: "last month", "this month", "30 days", "this quarter", "this year"
    """
    # TODO_A2UI: la tool aqui invocaria via MCP toolbox a get_models, get_explores,
    # get_dimensions_and_measures, run_query (igual que v6.x).
    # Por simplicidad del PoC, asumimos que ya descubrimos los nombres y los hardcodeamos.
    # En produccion, esto requiere el mismo discovery dinamico del v6.x.

    # Placeholder con datos simulados - reemplazar con llamadas reales al MCP
    # MCP call would go here:
    #   mcp_response = await mcp_client.call_tool("run_query", {
    #     "model": "...",
    #     "explore": "...",
    #     "fields": ["billing_export.total_cost"],
    #     "filters": {"billing_export.usage_date": period}
    #   })
    #   total = mcp_response["rows"][0]["billing_export.total_cost"]

    total = 45678.90  # placeholder
    prev_total = 40678.90  # placeholder
    delta_pct = ((total - prev_total) / prev_total) * 100

    return {
        "text": f"El gasto total en GCP en {period} fue ${total:,.2f}",
        "ui_components": [
            make_card(
                title=f"Gasto total ({period})",
                value=f"${total:,.2f}",
                subtitle="USD",
                trend=f"{'+' if delta_pct >= 0 else ''}{delta_pct:.1f}% vs periodo anterior"
            )
        ]
    }


async def get_top_services(period: str = "last month", n: int = 5) -> dict:
    """Top N servicios por gasto."""
    # Placeholder data - reemplazar con MCP calls reales
    services_data = [
        {"label": "Compute Engine", "value": "$18,234.56", "subtext": "39.9%"},
        {"label": "BigQuery", "value": "$12,456.78", "subtext": "27.3%"},
        {"label": "Cloud Storage", "value": "$5,678.90", "subtext": "12.4%"},
        {"label": "AlloyDB", "value": "$3,215.96", "subtext": "7.0%"},
        {"label": "Cloud SQL", "value": "$2,890.12", "subtext": "6.3%"},
    ][:n]

    chart_data = [
        {"label": s["label"], "value": float(s["value"].replace("$", "").replace(",", ""))}
        for s in services_data
    ]

    return {
        "text": f"Top {n} servicios en {period}",
        "ui_components": [
            make_list(title=f"Top {n} servicios por gasto", items=services_data),
            make_chart(title="Distribucion de gasto", chart_type="bar", data=chart_data),
        ]
    }


async def get_service_breakdown(service_name: str, period: str = "last month") -> dict:
    """Detalle de gasto de un servicio especifico.

    Args:
        service_name: nombre del servicio (e.g. "AlloyDB", "BigQuery")
    """
    # Placeholder - en produccion: MCP call con filter LIKE %{service_name}%
    total = 215.96  # placeholder

    embed_url = _generate_signed_embed_url(f"/dashboards/billing-{service_name.lower()}")

    return {
        "text": f"Gasto de {service_name} en {period}",
        "ui_components": [
            make_card(
                title=f"{service_name} - {period}",
                value=f"${total:,.2f}",
                subtitle="USD",
            ),
            make_link_card(
                title=f"Ver dashboard detallado de {service_name}",
                description="Drill-down por SKU, region, dia",
                url=embed_url,
                icon="dashboard",
            )
        ]
    }


# -----------------------------------------------------------------------------
# Construccion del agente ADK + A2UI
# TODO_A2UI: verificar contra tutorial el patron exacto de wiring entre
# ADK LlmAgent y A2UI extension.
# -----------------------------------------------------------------------------

# MCP toolset para queries dinamicas a Looker (reutilizado del v6.x)
mcp_toolset = MCPToolset(
    connection_params=StreamableHTTPConnectionParams(
        url=MCP_SERVER_URL,
        headers={"Authorization": f"Bearer {get_id_token()}"},
    ),
    errlog=None,
    tool_filter=None,
)

# Agent definition
# TODO_A2UI: el tutorial puede requerir un wrapper especifico A2UIAgent
# en lugar de LlmAgent directo. Patron probable:
#   agent = A2UIAgent(
#       base_agent=LlmAgent(...),
#       supported_components=["Card", "List", "Chart", "LinkCard"],
#   )

llm_agent = LlmAgent(
    model=AGENT_MODEL,
    name="looker_cost_agent_a2ui",
    description="GCP cost agent with native UI rendering via A2UI.",
    instruction=(
        'You are a Looker FinOps agent that returns RICH UI COMPONENTS '
        '(not just text) for GCP cost questions.\n\n'
        '*** IMPORTANT ***\n'
        'For each tool result, include the "ui_components" field in your '
        'response. The Gemini Enterprise frontend will render these as '
        'native A2UI components (Cards, Charts, Lists, Forms).\n\n'
        '*** TOOLS AVAILABLE ***\n'
        '- get_total_spend(period): use for "cuanto gastamos en X periodo"\n'
        '- get_top_services(period, n): use for "top servicios por costo"\n'
        '- get_service_breakdown(service, period): use for "cuanto gaste de X"\n'
        '- MCP tools: get_models, get_explores, run_query for ad-hoc queries\n\n'
        '*** RESPONSE FORMAT ***\n'
        'Always respond with both:\n'
        '1. Brief text explanation\n'
        '2. UI components from tool result\n\n'
        '*** TIME FILTERS ***\n'
        '- "este mes" -> "this month"\n'
        '- "mes pasado" -> "last month"\n'
        '- "este trimestre" -> "this quarter"\n'
        '- "este año" -> "this year"\n'
    ),
    tools=[
        mcp_toolset,
        get_total_spend,
        get_top_services,
        get_service_breakdown,
    ],
)

# TODO_A2UI: aqui se envuelve el LlmAgent con la extension A2UI.
# Patron tentativo:
# a2ui_agent = A2UIAgent(
#     llm_agent=llm_agent,
#     catalog_version="v0.8",
#     enabled_components=["Card", "List", "Chart", "LinkCard"],
# )

# -----------------------------------------------------------------------------
# Servidor FastAPI con A2A endpoint
# TODO_A2UI: verificar el path exacto del endpoint A2A. Patrones comunes:
#   - POST /a2a/messages
#   - POST /  (con tipo en el body)
#   - POST /agent/invoke
# -----------------------------------------------------------------------------
app = FastAPI()


@app.get("/")
async def root():
    """Agent card endpoint - lo consulta Gemini Enterprise para descubrir capabilities."""
    return {
        "protocolVersion": "0.3.0",  # TODO_A2UI: verificar
        "name": "looker-cost-a2ui",
        "description": "GCP cost agent with A2UI rendering",
        "url": os.environ.get("AGENT_URL", "http://localhost:8080"),
        "version": "1.0.0",
        "capabilities": {
            "streaming": True,
            "extensions": [
                {
                    "uri": "https://a2ui.org/a2a-extension/a2ui/v0.8",
                    "description": "Ability to render A2UI",
                    "required": False,
                    "params": {
                        "supportedCatalogIds": [
                            "https://a2ui.org/specification/v0_8/standard_catalog_definition.json"
                        ]
                    }
                }
            ]
        },
        "skills": [],
        "defaultInputModes": ["text/plain"],
        "defaultOutputModes": ["text/plain", "application/json"],
    }


@app.post("/")
async def handle_message(request: Request):
    """Endpoint principal A2A - recibe mensajes de Gemini Enterprise."""
    body = await request.json()

    # TODO_A2UI: el handling exacto de mensajes A2A depende del SDK.
    # Patron tentativo - delegar al ADK runner:
    #
    # message_text = extract_message_text(body)
    # async for event in llm_agent.run_async(message_text):
    #     # Convertir cada event a A2A message con UI components
    #     yield format_a2a_response(event)
    #
    # Por ahora respuesta minima para que el endpoint exista:

    return JSONResponse({
        "status": "TODO_A2UI: implement A2A message handling per tutorial",
        "received": body,
    })


@app.get("/health")
async def health():
    return {"status": "ok"}


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("PORT", 8080)))
PYEOF

echo "Codigo del agente A2UI creado en my-a2ui-agent/"

echo ""
echo "=================================================="
echo " PASO 4: Build & Deploy en Cloud Run"
echo "=================================================="

gcloud builds submit \
  --tag="gcr.io/${PROJECT_ID}/${AGENT_NAME}:latest" \
  --project="$PROJECT_ID" \
  --timeout=600s

# Primer deploy para obtener URL
gcloud run deploy "$AGENT_NAME" \
  --image="gcr.io/${PROJECT_ID}/${AGENT_NAME}:latest" \
  --service-account="$SA_EMAIL" \
  --region="$REGION" \
  --set-env-vars="MCP_TOOLBOX_URL=${MCP_TOOLBOX_URL},LOOKERSDK_BASE_URL=${LOOKER_URL},LOOKERSDK_CLIENT_ID=${LOOKER_CLIENT_ID},LOOKERSDK_CLIENT_SECRET=${LOOKER_CLIENT_SECRET},LOOKER_EMBED_SECRET=${LOOKER_EMBED_SECRET},LOOKER_MODELS=${LOOKER_MODELS},AGENT_MODEL=${AGENT_MODEL}" \
  --cpu=2 \
  --memory=2Gi \
  --min-instances=1 \
  --max-instances=10 \
  --no-cpu-throttling \
  --no-allow-unauthenticated \
  --project="$PROJECT_ID"

AGENT_URL=$(gcloud run services describe "$AGENT_NAME" \
  --region="$REGION" --project="$PROJECT_ID" --format="value(status.url)")

# Re-deploy con AGENT_URL en env vars (necesario para el agent card)
gcloud run services update "$AGENT_NAME" \
  --region="$REGION" \
  --update-env-vars="AGENT_URL=${AGENT_URL}" \
  --project="$PROJECT_ID"

echo "Agent URL: $AGENT_URL"

cd ..

echo ""
echo "=================================================="
echo " PASO 5: Registrar en Gemini Enterprise como agente A2A+A2UI"
echo "=================================================="
ACCESS_TOKEN=$(gcloud auth print-access-token)

if [ "$ENGINE_LOCATION" = "global" ]; then
  API_ENDPOINT="discoveryengine.googleapis.com"
else
  API_ENDPOINT="${ENGINE_LOCATION}-discoveryengine.googleapis.com"
fi

AGENT_API_URL="https://${API_ENDPOINT}/v1alpha/projects/${PROJECT_NUMBER}/locations/${ENGINE_LOCATION}/collections/default_collection/engines/${AS_APP}/assistants/default_assistant/agents"

# CLAVE: usar a2aAgentDefinition (no adk_agent_definition como en v6.x)
# JSON Agent Card debe incluir extension A2UI declarada
JSON_AGENT_CARD=$(cat <<EOF
{
  "protocolVersion": "0.3.0",
  "name": "${AGENT_NAME}",
  "description": "${AGENT_DESCRIPTION}",
  "url": "${AGENT_URL}",
  "version": "1.0.0",
  "capabilities": {
    "streaming": true,
    "extensions": [
      {
        "uri": "https://a2ui.org/a2a-extension/a2ui/v0.8",
        "description": "Ability to render A2UI",
        "required": false,
        "params": {
          "supportedCatalogIds": [
            "https://a2ui.org/specification/v0_8/standard_catalog_definition.json"
          ]
        }
      }
    ]
  },
  "skills": [],
  "defaultInputModes": ["text/plain"],
  "defaultOutputModes": ["text/plain", "application/json"]
}
EOF
)

# Escapar el JSON para incluirlo como string
JSON_AGENT_CARD_ESCAPED=$(echo "$JSON_AGENT_CARD" | python3 -c "import sys, json; print(json.dumps(sys.stdin.read()))")

REQUEST_BODY=$(cat <<EOF
{
  "name": "${AGENT_NAME}",
  "displayName": "${AGENT_DISPLAY_NAME}",
  "description": "${AGENT_DESCRIPTION}",
  "a2aAgentDefinition": {
    "jsonAgentCard": ${JSON_AGENT_CARD_ESCAPED}
  }
}
EOF
)

echo "POST a: $AGENT_API_URL"
echo ""
echo "Request body (a2aAgentDefinition):"
echo "$REQUEST_BODY" | python3 -m json.tool

HTTP_RESPONSE=$(curl -sS -w "\n__HTTP_STATUS__:%{http_code}" -X POST \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -H "X-Goog-User-Project: ${PROJECT_NUMBER}" \
  "$AGENT_API_URL" -d "$REQUEST_BODY")

HTTP_STATUS=$(echo "$HTTP_RESPONSE" | grep "__HTTP_STATUS__" | cut -d: -f2)
RESPONSE_BODY=$(echo "$HTTP_RESPONSE" | sed '/__HTTP_STATUS__/d')

echo ""
echo "HTTP Status: $HTTP_STATUS"
echo "$RESPONSE_BODY" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE_BODY"

if [[ "$HTTP_STATUS" =~ ^2[0-9][0-9]$ ]]; then
  echo "OK: Agente A2UI registrado en Gemini Enterprise"
else
  echo "ERROR HTTP $HTTP_STATUS - revisa el body para detalles"
  exit 1
fi

echo ""
echo "=================================================="
echo " SETUP v7.0 A2UI COMPLETO"
echo "=================================================="
cat <<EOF

  Agent name       : $AGENT_NAME
  Agent URL        : $AGENT_URL
  Service Account  : $SA_EMAIL
  MCP Toolbox      : $MCP_TOOLBOX_URL
  Display name     : $AGENT_DISPLAY_NAME

PROXIMOS PASOS:

1. PROBAR EN GEMINI ENTERPRISE
   Ve a tu app de Gemini Enterprise y selecciona "$AGENT_DISPLAY_NAME".
   Pregunta: "Cuanto gastamos en GCP el mes pasado?"

2. SI ALGO FALLA (alta probabilidad por Pre-GA):
   Revisa los TODO_A2UI en my-a2ui-agent/main.py
   Compara contra el tutorial oficial:
   https://docs.cloud.google.com/gemini/enterprise/docs/a2ui-agents/tutorial-host-agent-cloud-run

   Errores comunes:
   - ImportError: el paquete a2ui-agent-sdk puede tener otro nombre
   - 400 en POST /: el path del endpoint A2A puede ser distinto
   - "schema validation failed": los componentes Card/List/Chart pueden
     tener properties diferentes en v0.8

3. ITERAR
   Para actualizar el agente despues de cambios:
     cd my-a2ui-agent
     gcloud builds submit --tag=gcr.io/${PROJECT_ID}/${AGENT_NAME}:latest
     gcloud run deploy ${AGENT_NAME} --image=gcr.io/${PROJECT_ID}/${AGENT_NAME}:latest --region=${REGION}

4. LOGS PARA DEBUG
   gcloud run services logs tail ${AGENT_NAME} --region=${REGION} --project=${PROJECT_ID}

5. FALLBACK
   Si A2UI v0.8 no funciona como esperas, el v6.6 sigue desplegado
   y registrado como agente separado en Gemini Enterprise.

EOF
