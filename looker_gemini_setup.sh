#!/bin/bash
# =============================================================================
# setup_looker_gemini_enterprise.sh
# Automatiza: MCP Toolbox en Cloud Run + ADK Agent en Agent Engine + Gemini Enterprise
# El agente:
#   1. Renderiza dashboards/looks como PNG via Looker API
#   2. Sube los PNG a un bucket GCS con signed URLs
#   3. Devuelve markdown con imagen inline que Gemini Enterprise renderiza
#   4. Tambien genera links SSO firmados como fallback interactivo
# Originalmente inspirado en: https://medium.com/google-cloud/connect-looker-to-agentspace-in-minutes-with-mcp-toolbox-and-the-adk-8e37ae096f49 de Rob Carr
# Modificado por Jose Maldonado (joseim@google.com) Abril de 2026
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURA ESTAS VARIABLES ANTES DE EJECUTAR
# =============================================================================
PROJECT_ID="YOUR_GOOGLE_CLOUD_PROJECT_ID"
PROJECT_NUMBER="YOUR_PROJECT_NUMBER"           # gcloud projects describe $PROJECT_ID --format='value(projectNumber)'
REGION="us-central1"
BUCKET_NAME="YOUR_GCS_BUCKET_NAME"             # bucket para staging del ADK
BUCKET_LOCATION="US"

# Bucket separado para imagenes PNG de Looker (puede ser el mismo que BUCKET_NAME)
# Se recomienda uno dedicado con ciclo de vida para auto-borrar PNGs viejos
IMAGES_BUCKET="YOUR_LOOKER_IMAGES_BUCKET"

# Credenciales de Looker (obtener en Looker Admin > API Keys)
LOOKER_URL="https://your-instance.looker.com"
LOOKER_CLIENT_ID="YOUR_LOOKER_CLIENT_ID"
LOOKER_CLIENT_SECRET="YOUR_LOOKER_CLIENT_SECRET"

# Embed Secret de Looker (Looker Admin > Embed > Embed Secret)
LOOKER_EMBED_SECRET="YOUR_LOOKER_EMBED_SECRET"

# Modelos LookML permitidos para el embed
LOOKER_MODELS='["thelook"]'

# Gemini Enterprise
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
echo " PASO -1: Validar variables de configuracion"
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
echo " PASO 0: Verificar autenticacion"
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
echo " PASO 2: Crear service accounts y roles"
echo "=================================================="
SA_NAME="toolbox-identity"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

if ! gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID" &>/dev/null; then
  gcloud iam service-accounts create "$SA_NAME" --project="$PROJECT_ID"
fi

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/secretmanager.secretAccessor" \
  --condition=None &>/dev/null

# Service account del Agent Engine necesita acceso a GCS para firmar URLs y subir imagenes
AGENT_ENGINE_SA="service-${PROJECT_NUMBER}@gcp-sa-aiplatform-re.iam.gserviceaccount.com"

echo "SA toolbox: $SA_EMAIL"
echo "SA agent engine: $AGENT_ENGINE_SA"

echo ""
echo "=================================================="
echo " PASO 3: Crear buckets GCS"
echo "=================================================="
# Bucket staging para ADK
if ! gcloud storage buckets describe "gs://${BUCKET_NAME}" &>/dev/null; then
  gcloud storage buckets create "gs://${BUCKET_NAME}" --location="$BUCKET_LOCATION"
  echo "Bucket staging creado: gs://${BUCKET_NAME}"
fi

# Bucket de imagenes (con uniform bucket-level access)
if ! gcloud storage buckets describe "gs://${IMAGES_BUCKET}" &>/dev/null; then
  gcloud storage buckets create "gs://${IMAGES_BUCKET}" \
    --location="$BUCKET_LOCATION" \
    --uniform-bucket-level-access
  echo "Bucket de imagenes creado: gs://${IMAGES_BUCKET}"
fi

# Configurar lifecycle policy: borrar imagenes despues de 1 dia
cat > /tmp/lifecycle.json <<EOF
{
  "lifecycle": {
    "rule": [
      {
        "action": {"type": "Delete"},
        "condition": {"age": 1}
      }
    ]
  }
}
EOF
gcloud storage buckets update "gs://${IMAGES_BUCKET}" --lifecycle-file=/tmp/lifecycle.json
echo "Lifecycle policy: PNGs se borran despues de 1 dia"

# Dar permisos al Agent Engine SA para escribir y firmar URLs en el bucket
# (el SA aun puede no existir si Agent Engine no se ha usado; lo intentamos y si falla, continuamos)
gcloud storage buckets add-iam-policy-binding "gs://${IMAGES_BUCKET}" \
  --member="serviceAccount:${AGENT_ENGINE_SA}" \
  --role="roles/storage.objectAdmin" &>/dev/null || \
  echo "WARN: No se pudo agregar role al Agent Engine SA (se reintentara despues)"

# Permiso para firmar URLs (requerido para signed URLs sin clave privada)
gcloud iam service-accounts add-iam-policy-binding "$AGENT_ENGINE_SA" \
  --member="serviceAccount:${AGENT_ENGINE_SA}" \
  --role="roles/iam.serviceAccountTokenCreator" \
  --project="$PROJECT_ID" &>/dev/null || \
  echo "WARN: No se pudo dar serviceAccountTokenCreator (se reintentara despues)"

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
  --region="$REGION" \
  --project="$PROJECT_ID" \
  --format="value(status.url)")

echo "Cloud Run URL: $CLOUD_RUN_URL"
MCP_SERVER_URL="${CLOUD_RUN_URL}/mcp"
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

# -----------------------------------------------------------------------------
# Configuracion
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
IMAGES_BUCKET = os.environ.get("LOOKER_IMAGES_BUCKET", "")


# -----------------------------------------------------------------------------
# Auth helper para MCP server en Cloud Run
# -----------------------------------------------------------------------------
def get_id_token():
    audience = MCP_SERVER_URL.split('/mcp')[0]
    auth_req = google.auth.transport.requests.Request()
    return google.oauth2.id_token.fetch_id_token(auth_req, audience)


# -----------------------------------------------------------------------------
# Helper: subir PNG a GCS y obtener signed URL
# -----------------------------------------------------------------------------
def _upload_png_to_gcs(png_bytes: bytes, prefix: str = "render") -> str:
    """Sube un PNG al bucket y devuelve una signed URL valida por 1 hora.

    Usa impersonated credentials para firmar URLs sin necesidad de key privada
    (funciona dentro de Agent Engine que usa ADC del service account).
    """
    client = storage.Client()
    bucket = client.bucket(IMAGES_BUCKET)

    blob_name = f"{prefix}/{int(time.time())}-{uuid.uuid4().hex[:8]}.png"
    blob = bucket.blob(blob_name)
    blob.upload_from_string(png_bytes, content_type="image/png")

    # Firmar URL usando la identidad del SA actual (sin private key)
    credentials, project = google.auth.default()
    auth_req = gauth_requests.Request()
    credentials.refresh(auth_req)

    service_account_email = getattr(credentials, "service_account_email", None)

    if service_account_email and service_account_email != "default":
        # Caso normal en Agent Engine: usamos IAM sign blob API
        signing_credentials = impersonated_credentials.Credentials(
            source_credentials=credentials,
            target_principal=service_account_email,
            target_scopes=["https://www.googleapis.com/auth/devstorage.read_only"],
            lifetime=500,
        )
        signed_url = blob.generate_signed_url(
            version="v4",
            expiration=timedelta(hours=1),
            method="GET",
            credentials=signing_credentials,
        )
    else:
        # Fallback: generate_signed_url con credentials default
        signed_url = blob.generate_signed_url(
            version="v4",
            expiration=timedelta(hours=1),
            method="GET",
        )

    return signed_url


# -----------------------------------------------------------------------------
# SSO Embed URL signing
# -----------------------------------------------------------------------------
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
# TOOL: Renderizar dashboard como PNG inline
# -----------------------------------------------------------------------------
def show_dashboard_inline(dashboard_id: str) -> dict:
    """Renderiza un dashboard de Looker como imagen PNG que se muestra INLINE en el chat.

    Usar cuando el usuario quiere VER un dashboard directamente en la conversacion.
    Genera PNG del dashboard, lo sube a GCS, y devuelve markdown con imagen embebida.

    Args:
        dashboard_id: ID numerico del dashboard (ej: "42").
    Returns:
        Dict con URL de imagen publica y markdown para renderizar inline.
    """
    sdk = looker_sdk.init40()

    # Crear render task
    task = sdk.create_dashboard_render_task(
        dashboard_id=dashboard_id,
        result_format="png",
        body=models40.CreateDashboardRenderTask(
            dashboard_style="tiled",
            dashboard_filters=""
        ),
        width=1400,
        height=900,
    )

    # Poll hasta que termine (max 60s)
    max_wait = 60
    waited = 0
    while waited < max_wait:
        status = sdk.render_task(task.id)
        if status.status == "success":
            break
        if status.status == "failure":
            return {
                "error": "Render failed",
                "markdown": f"Error al renderizar el dashboard {dashboard_id}: {status.status_detail}"
            }
        time.sleep(2)
        waited += 2

    if waited >= max_wait:
        return {
            "error": "timeout",
            "markdown": f"Timeout al renderizar dashboard {dashboard_id}. Intenta de nuevo."
        }

    # Descargar PNG
    png_bytes = sdk.render_task_results(task.id)

    # Subir a GCS y obtener signed URL
    try:
        signed_url = _upload_png_to_gcs(png_bytes, prefix=f"dashboard-{dashboard_id}")
    except Exception as e:
        return {
            "error": str(e),
            "markdown": f"Error al subir imagen a GCS: {e}"
        }

    # Link SSO interactivo como backup
    interactive_url = _generate_signed_embed_url(f"/embed/dashboards/{dashboard_id}")

    return {
        "dashboard_id": dashboard_id,
        "image_url": signed_url,
        "interactive_url": interactive_url,
        "markdown": (
            f"![Dashboard {dashboard_id}]({signed_url})\n\n"
            f"[Abrir version interactiva en Looker]({interactive_url})"
        ),
    }


# -----------------------------------------------------------------------------
# TOOL: Renderizar Look como PNG inline
# -----------------------------------------------------------------------------
def show_look_inline(look_id: str) -> dict:
    """Renderiza un Look (grafico) de Looker como imagen PNG inline en el chat.

    Args:
        look_id: ID numerico del Look.
    Returns:
        Dict con URL de imagen y markdown para renderizar inline.
    """
    sdk = looker_sdk.init40()

    try:
        # run_look con result_format=png retorna PNG directamente, sin necesidad de polling
        png_bytes = sdk.run_look(
            look_id=look_id,
            result_format="png",
            image_width=1200,
            image_height=700,
        )
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
        "markdown": (
            f"![Look {look_id}]({signed_url})\n\n"
            f"[Abrir Look interactivo en Looker]({interactive_url})"
        ),
    }


# -----------------------------------------------------------------------------
# TOOL: Ejecutar query y mostrarla como PNG inline
# -----------------------------------------------------------------------------
def show_query_inline(model: str, explore: str, fields: list, vis_type: str = "looker_column") -> dict:
    """Ejecuta una query ad-hoc y muestra el resultado como PNG inline en el chat.

    Usar cuando el usuario quiere visualizar datos especificos sin tener un dashboard.

    Args:
        model: Nombre del modelo LookML (ej: "thelook").
        explore: Nombre del explore (ej: "order_items").
        fields: Lista de campos (ej: ["orders.count", "orders.status"]).
        vis_type: Tipo de visualizacion (looker_column, looker_bar, looker_line,
                  looker_pie, looker_scatter). Default: looker_column.
    Returns:
        Dict con URL de imagen y markdown para renderizar inline.
    """
    sdk = looker_sdk.init40()

    try:
        query = sdk.create_query(
            body=models40.WriteQuery(
                model=model,
                view=explore,
                fields=fields,
                limit="500",
                vis_config={"type": vis_type},
            )
        )

        png_bytes = sdk.run_query(
            query_id=str(query.id),
            result_format="png",
            image_width=1200,
            image_height=700,
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
        "model": model,
        "explore": explore,
        "fields": fields,
        "image_url": signed_url,
        "interactive_url": interactive_url,
        "markdown": (
            f"![{explore} chart]({signed_url})\n\n"
            f"*Datos de {explore} ({model})*\n\n"
            f"[Explorar interactivamente en Looker]({interactive_url})"
        ),
    }


# -----------------------------------------------------------------------------
# TOOL: Listar dashboards disponibles
# -----------------------------------------------------------------------------
def list_available_dashboards(search_term: str = "") -> dict:
    """Lista dashboards disponibles en Looker. Usar cuando el usuario pregunte que hay.

    Args:
        search_term: Filtro opcional por nombre.
    Returns:
        Dict con lista de dashboards.
    """
    sdk = looker_sdk.init40()
    if search_term:
        dashboards = sdk.search_dashboards(title=f"%{search_term}%", limit=20)
    else:
        dashboards = sdk.search_dashboards(limit=20)

    if not dashboards:
        return {"dashboards": [], "markdown": "No encontre dashboards con ese criterio."}

    items = []
    md_lines = ["## Dashboards disponibles:\n"]
    for d in dashboards:
        items.append({"id": str(d.id), "title": d.title})
        md_lines.append(f"- **{d.title}** (ID: {d.id}) — pideme que te lo muestre")

    return {"dashboards": items, "markdown": "\n".join(md_lines)}


# -----------------------------------------------------------------------------
# Agente ADK principal
# -----------------------------------------------------------------------------
root_agent = LlmAgent(
    model='gemini-2.5-flash',
    name='looker_agent',
    description='Looker data agent that renders dashboards/charts as inline images in Gemini Enterprise.',
    instruction=(
        'You are a Looker data agent inside Gemini Enterprise. '
        'Your superpower: you can render Looker dashboards and charts as INLINE IMAGES '
        'directly in the chat, not just as links. '
        '\n\n'
        'CRITICAL RULES: '
        '\n- User asks to SEE/SHOW/VIEW/VISUALIZE/DISPLAY a dashboard: call show_dashboard_inline '
        '  with the dashboard_id and return the "markdown" field verbatim. '
        '\n- User asks about a Look/chart by ID: call show_look_inline. '
        '\n- User wants ad-hoc visualization from data: call show_query_inline '
        '  with model, explore, fields, and vis_type. '
        '\n- User asks "what dashboards exist": call list_available_dashboards. '
        '\n- ALWAYS return the markdown field from these tools verbatim - it contains '
        '  the inline image + interactive link formatted correctly for Gemini Enterprise. '
        '\n\n'
        'For raw numeric questions (totals, counts, trends without visualization): '
        'use MCP tools (get_models, get_explores, run_query, etc). '
        '\n\n'
        'Defaults when uncertain: model="thelook", explore="order_items". '
        '\n\n'
        'For vis_type in show_query_inline, choose based on data: '
        '\n- Categories comparison: looker_column or looker_bar '
        '\n- Time series: looker_line '
        '\n- Parts of whole: looker_pie '
        '\n- Correlation: looker_scatter '
        '\n\n'
        'Rendering takes 5-30 seconds. Dont apologize for the wait - just return the result.'
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
echo " PASO 7: Desplegar agente en Vertex AI Agent Engine"
echo "  (tarda 15-20 min)"
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
echo "Deploy en background (PID: $DEPLOY_PID)"

ELAPSED=0
while kill -0 $DEPLOY_PID 2>/dev/null; do
  sleep 15
  ELAPSED=$((ELAPSED + 15))
  MINS=$((ELAPSED / 60))
  SECS=$((ELAPSED % 60))
  LAST_LINE=$(tail -1 "$DEPLOY_LOG" 2>/dev/null || echo "...")
  echo "[${MINS}m${SECS}s] $LAST_LINE"

  if (( ELAPSED > 0 && ELAPSED % 120 == 0 )); then
    echo "  --- Reasoning Engines ---"
    gcloud ai reasoning-engines list \
      --region="$REGION" --project="$PROJECT_ID" \
      --format="table(name.segment(-1):label=ID,displayName)" 2>/dev/null || true
  fi
done

wait $DEPLOY_PID
DEPLOY_EXIT=$?

echo ""
cat "$DEPLOY_LOG"

if [ $DEPLOY_EXIT -ne 0 ]; then
  echo "ERROR: Deploy fallo"
  exit 1
fi

REASONING_ENGINE=$(grep -oE 'projects/[^/]+/locations/[^/]+/reasoningEngines/[0-9]+' "$DEPLOY_LOG" | head -1 || true)
if [ -z "$REASONING_ENGINE" ]; then
  REASONING_ENGINE=$(gcloud ai reasoning-engines list \
    --region="$REGION" --project="$PROJECT_ID" \
    --filter="displayName=looker-agent1" \
    --sort-by="~createTime" \
    --format="value(name)" --limit=1)
fi

if [ -z "$REASONING_ENGINE" ]; then
  echo "ERROR: No se pudo obtener Reasoning Engine"
  exit 1
fi

echo "Reasoning Engine: $REASONING_ENGINE"

# Permisos post-deploy ahora que el SA ya existe con certeza
echo "Configurando permisos al Agent Engine SA..."

# Cloud Run invoker
gcloud run services add-iam-policy-binding toolbox \
  --region="$REGION" \
  --member="serviceAccount:${AGENT_ENGINE_SA}" \
  --role="roles/run.invoker" \
  --project="$PROJECT_ID" &>/dev/null || true

# Storage admin en el bucket de imagenes
gcloud storage buckets add-iam-policy-binding "gs://${IMAGES_BUCKET}" \
  --member="serviceAccount:${AGENT_ENGINE_SA}" \
  --role="roles/storage.objectAdmin" &>/dev/null || true

# Token creator para firmar URLs
gcloud iam service-accounts add-iam-policy-binding "$AGENT_ENGINE_SA" \
  --member="serviceAccount:${AGENT_ENGINE_SA}" \
  --role="roles/iam.serviceAccountTokenCreator" \
  --project="$PROJECT_ID" &>/dev/null || true

cd ..

echo ""
echo "=================================================="
echo " PASO 8: Registrar agente en Gemini Enterprise"
echo "=================================================="
ACCESS_TOKEN=$(gcloud auth print-access-token)

if [ "$ENGINE_LOCATION" = "global" ]; then
  API_ENDPOINT="discoveryengine.googleapis.com"
else
  API_ENDPOINT="${ENGINE_LOCATION}-discoveryengine.googleapis.com"
fi

AGENT_API_URL="https://${API_ENDPOINT}/v1alpha/projects/${PROJECT_NUMBER}/locations/${ENGINE_LOCATION}/collections/default_collection/engines/${AS_APP}/assistants/default_assistant/agents"

echo "POST a: $AGENT_API_URL"

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

HTTP_RESPONSE=$(curl -sS -w "\n__HTTP_STATUS__:%{http_code}" -X POST \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -H "X-Goog-User-Project: ${PROJECT_NUMBER}" \
  "$AGENT_API_URL" \
  -d "$REQUEST_BODY")

HTTP_STATUS=$(echo "$HTTP_RESPONSE" | grep "__HTTP_STATUS__" | cut -d: -f2)
RESPONSE_BODY=$(echo "$HTTP_RESPONSE" | sed '/__HTTP_STATUS__/d')

echo "HTTP Status: $HTTP_STATUS"
echo "$RESPONSE_BODY" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE_BODY"

if [[ "$HTTP_STATUS" =~ ^2[0-9][0-9]$ ]]; then
  echo "OK: Agente registrado en Gemini Enterprise"
else
  echo "ERROR: Registro fallo con HTTP $HTTP_STATUS"
  exit 1
fi

echo ""
echo "=================================================="
echo " SETUP COMPLETO"
echo "=================================================="
echo ""
echo "  Cloud Run URL       : $CLOUD_RUN_URL"
echo "  MCP Server URL      : $MCP_SERVER_URL"
echo "  Reasoning Engine    : $REASONING_ENGINE"
echo "  Images Bucket       : gs://${IMAGES_BUCKET}"
echo ""
echo "Prueba con:"
echo "  - 'Muestrame el dashboard 1'"
echo "  - 'Ensename el Look 5'"
echo "  - 'Visualiza ordenes por estado como grafico de barras'"
echo ""
echo "IMPORTANTE - Configuracion manual en Looker Admin > Embed:"
echo "  1. ACTIVAR 'Embed SSO Authentication'"
echo "  2. Agregar dominio de Gemini Enterprise al allowlist"
echo "  3. Verificar que el API user tenga permisos 'render' en todos los modelos"
