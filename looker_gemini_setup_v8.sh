#!/bin/bash
# =============================================================================
# setup_looker_gemini_enterprise_v8_redis.sh
# Arquitectura production-ready multi-cliente con cache Redis:
#   1. Memorystore Redis Standard HA (5GB) - cache distribuido
#   2. VPC + VPC Connector (Cloud Run -> Redis privado)
#   3. Cloud Run custom (FastAPI + Looker SDK + Redis client) - reemplaza el binario toolbox
#   4. Cache aislado por cliente con namespace (X-Client-ID header)
#   5. Connection pool a Looker (reduce TLS handshakes)
#   6. Min-instances=2 con CPU always-on (sin cold starts)
#   7. Cloud Trace + Profiler activos (observabilidad real)
#   8. Agente ADK en Agent Engine con SA custom
#   9. Registro en Gemini Enterprise (con link SSO interactivo)
#
# TTLs:
#   - list_dashboards / list_looks : 5 min
#   - get_models / get_explores    : 30 min
#   - run_query results            : 2 min
#   - PNG renders                  : 15 min
#
# Jose Maldonado @joseim 26/Abril/2026 19:55

# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURA ESTAS VARIABLES
# =============================================================================
PROJECT_ID="YOUR_GOOGLE_CLOUD_PROJECT_ID"
PROJECT_NUMBER="YOUR_PROJECT_NUMBER"
REGION="us-central1"
BUCKET_NAME="YOUR_GCS_BUCKET_NAME"
BUCKET_LOCATION="US"

# Cliente (X-Client-ID que enviara el agente, namespace de cache)
CLIENT_ID="acme_corp"

# Looker (compartida por todos los clientes en este v8)
LOOKER_URL="https://your-instance.looker.com"
LOOKER_CLIENT_ID="YOUR_LOOKER_CLIENT_ID"
LOOKER_CLIENT_SECRET="YOUR_LOOKER_CLIENT_SECRET"
LOOKER_EMBED_SECRET="YOUR_LOOKER_EMBED_SECRET"
LOOKER_MODELS='["thelook"]'

# Redis (Memorystore)
REDIS_INSTANCE_ID="looker-cache"
REDIS_TIER="STANDARD_HA"
REDIS_SIZE_GB="5"

# VPC
VPC_NAME="looker-agent-vpc"
VPC_CONNECTOR_NAME="looker-conn"
VPC_CONNECTOR_RANGE="10.8.0.0/28"
REDIS_RESERVED_RANGE="redis-range"
REDIS_RANGE_PREFIX="10.16.0.0"
REDIS_RANGE_LENGTH="20"

# Gemini Enterprise
AS_APP="YOUR_GEMINI_ENTERPRISE_AGENT_ID"
ENGINE_LOCATION="us"
AGENT_DISPLAY_NAME="Looker Agent (Cached)"
AGENT_DESCRIPTION="Looker agent with Redis cache and connection pooling."
TOOL_DESCRIPTION="Query Looker data and dashboards with sub-second latency via Redis cache."
# =============================================================================

unset SA_EMAIL AGENT_SA AGENT_SA_NAME SA_NAME TOOLBOX_SA TOOLBOX_SA_EMAIL
unset CLOUD_RUN_URL MCP_SERVER_URL REASONING_ENGINE REDIS_HOST REDIS_PORT
unset DEPLOY_LOG DEPLOY_PID DEPLOY_EXIT
unset ACCESS_TOKEN API_ENDPOINT AGENT_API_URL REQUEST_BODY
unset HTTP_RESPONSE HTTP_STATUS RESPONSE_BODY
unset ELAPSED MINS SECS LAST_LINE

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
echo " PASO 1: Habilitar APIs (ahora con Redis y VPC)"
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
  cloudresourcemanager.googleapis.com \
  redis.googleapis.com \
  vpcaccess.googleapis.com \
  servicenetworking.googleapis.com \
  compute.googleapis.com \
  cloudtrace.googleapis.com \
  cloudprofiler.googleapis.com \
  --project="$PROJECT_ID"

echo ""
echo "=================================================="
echo " PASO 2: Service accounts"
echo "=================================================="

# SA del Cloud Run toolbox
TOOLBOX_SA="toolbox-cached-sa"
TOOLBOX_SA_EMAIL="${TOOLBOX_SA}@${PROJECT_ID}.iam.gserviceaccount.com"

if ! gcloud iam service-accounts describe "$TOOLBOX_SA_EMAIL" --project="$PROJECT_ID" &>/dev/null; then
  gcloud iam service-accounts create "$TOOLBOX_SA" \
    --project="$PROJECT_ID" \
    --display-name="Toolbox Cached SA"
fi
echo "SA Toolbox: $TOOLBOX_SA_EMAIL"

# SA del Agente
AGENT_SA_NAME="looker-agent-sa"
AGENT_SA="${AGENT_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

if ! gcloud iam service-accounts describe "$AGENT_SA" --project="$PROJECT_ID" &>/dev/null; then
  gcloud iam service-accounts create "$AGENT_SA_NAME" \
    --project="$PROJECT_ID" \
    --display-name="Looker Agent Engine SA"
fi
echo "SA Agente: $AGENT_SA"

# Permisos SA Toolbox
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${TOOLBOX_SA_EMAIL}" \
  --role="roles/redis.editor" \
  --condition=None &>/dev/null
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${TOOLBOX_SA_EMAIL}" \
  --role="roles/cloudtrace.agent" \
  --condition=None &>/dev/null
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${TOOLBOX_SA_EMAIL}" \
  --role="roles/cloudprofiler.agent" \
  --condition=None &>/dev/null
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${TOOLBOX_SA_EMAIL}" \
  --role="roles/logging.logWriter" \
  --condition=None &>/dev/null
echo "Permisos SA toolbox: redis.editor, trace, profiler, logs"

# Permisos SA Agente
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${AGENT_SA}" \
  --role="roles/aiplatform.user" \
  --condition=None &>/dev/null
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${AGENT_SA}" \
  --role="roles/logging.logWriter" \
  --condition=None &>/dev/null
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${AGENT_SA}" \
  --role="roles/storage.objectViewer" \
  --condition=None &>/dev/null
echo "Permisos SA agente: aiplatform, logs, storage viewer"

echo ""
echo "=================================================="
echo " PASO 3: VPC + private services access (para Redis)"
echo "=================================================="

# Crear VPC si no existe
if ! gcloud compute networks describe "$VPC_NAME" --project="$PROJECT_ID" &>/dev/null; then
  gcloud compute networks create "$VPC_NAME" \
    --subnet-mode=custom \
    --project="$PROJECT_ID"
  echo "VPC creada: $VPC_NAME"
else
  echo "VPC ya existe: $VPC_NAME"
fi

# Subnet para VPC Connector
if ! gcloud compute networks subnets describe "${VPC_CONNECTOR_NAME}-subnet" \
     --region="$REGION" --project="$PROJECT_ID" &>/dev/null; then
  gcloud compute networks subnets create "${VPC_CONNECTOR_NAME}-subnet" \
    --network="$VPC_NAME" \
    --region="$REGION" \
    --range="10.9.0.0/28" \
    --project="$PROJECT_ID" || true
fi

# Reservar rango privado para Memorystore
if ! gcloud compute addresses describe "$REDIS_RESERVED_RANGE" \
     --global --project="$PROJECT_ID" &>/dev/null; then
  gcloud compute addresses create "$REDIS_RESERVED_RANGE" \
    --global \
    --purpose=VPC_PEERING \
    --addresses="$REDIS_RANGE_PREFIX" \
    --prefix-length="$REDIS_RANGE_LENGTH" \
    --network="$VPC_NAME" \
    --project="$PROJECT_ID"
  echo "Rango privado reservado para Redis"
fi

# Conectar VPC con servicios privados de Google
gcloud services vpc-peerings connect \
  --service=servicenetworking.googleapis.com \
  --ranges="$REDIS_RESERVED_RANGE" \
  --network="$VPC_NAME" \
  --project="$PROJECT_ID" || echo "VPC peering ya existe (ok)"

echo ""
echo "=================================================="
echo " PASO 4: Memorystore Redis (Standard HA, 5GB)"
echo "=================================================="

if ! gcloud redis instances describe "$REDIS_INSTANCE_ID" \
     --region="$REGION" --project="$PROJECT_ID" &>/dev/null; then
  echo "Creando Redis (toma 5-10 min)..."
  gcloud redis instances create "$REDIS_INSTANCE_ID" \
    --size="$REDIS_SIZE_GB" \
    --region="$REGION" \
    --tier="$REDIS_TIER" \
    --network="$VPC_NAME" \
    --redis-version=redis_7_0 \
    --connect-mode=PRIVATE_SERVICE_ACCESS \
    --project="$PROJECT_ID"
  echo "Redis creado."
else
  echo "Redis ya existe."
fi

REDIS_HOST=$(gcloud redis instances describe "$REDIS_INSTANCE_ID" \
  --region="$REGION" --project="$PROJECT_ID" \
  --format="value(host)")
REDIS_PORT=$(gcloud redis instances describe "$REDIS_INSTANCE_ID" \
  --region="$REGION" --project="$PROJECT_ID" \
  --format="value(port)")

echo "Redis host: $REDIS_HOST"
echo "Redis port: $REDIS_PORT"

echo ""
echo "=================================================="
echo " PASO 5: VPC Connector (Cloud Run -> Redis)"
echo "=================================================="

if ! gcloud compute networks vpc-access connectors describe "$VPC_CONNECTOR_NAME" \
     --region="$REGION" --project="$PROJECT_ID" &>/dev/null; then
  echo "Creando VPC Connector (toma 3-5 min)..."
  gcloud compute networks vpc-access connectors create "$VPC_CONNECTOR_NAME" \
    --region="$REGION" \
    --network="$VPC_NAME" \
    --range="$VPC_CONNECTOR_RANGE" \
    --machine-type=e2-standard-4 \
    --min-instances=2 \
    --max-instances=10 \
    --project="$PROJECT_ID"
  echo "VPC Connector creado."
else
  echo "VPC Connector ya existe."
fi

echo ""
echo "=================================================="
echo " PASO 6: Bucket staging (para deploy del agente)"
echo "=================================================="
if ! gcloud storage buckets describe "gs://${BUCKET_NAME}" &>/dev/null; then
  gcloud storage buckets create "gs://${BUCKET_NAME}" --location="$BUCKET_LOCATION"
fi

echo ""
echo "=================================================="
echo " PASO 7: Crear toolbox custom (FastAPI + Looker + Redis)"
echo "=================================================="
mkdir -p toolbox-cached && cd toolbox-cached

cat > requirements.txt <<'EOF'
fastapi==0.115.0
uvicorn[standard]==0.32.0
looker_sdk==25.0.0
redis==5.2.0
pydantic==2.9.0
google-cloud-trace==1.13.0
google-cloud-profiler==4.1.0
opentelemetry-api==1.27.0
opentelemetry-sdk==1.27.0
opentelemetry-exporter-gcp-trace==1.7.0
EOF

cat > Dockerfile <<'EOF'
FROM python:3.11-slim

WORKDIR /app

# Cache de pip layer
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Codigo
COPY server.py .

ENV PORT=8080
EXPOSE 8080

CMD exec uvicorn server:app --host 0.0.0.0 --port ${PORT} --workers 4 --loop uvloop --http httptools
EOF

cat > server.py <<'PYEOF'
"""
Looker MCP Toolbox con cache Redis y connection pooling.
Implementa el protocolo MCP basico (tools/list, tools/call).
"""
import os
import json
import time
import hashlib
import logging
from typing import Any, Optional
from contextlib import asynccontextmanager

import redis
import looker_sdk
from looker_sdk import models40
from fastapi import FastAPI, Request, HTTPException, Header
from fastapi.responses import JSONResponse
from pydantic import BaseModel

# Cloud Profiler (opcional, ayuda en debug)
try:
    import googlecloudprofiler
    googlecloudprofiler.start(service='toolbox-cached', verbose=2)
except Exception as e:
    logging.warning(f"Profiler no inicio: {e}")

# Cloud Trace
try:
    from opentelemetry import trace
    from opentelemetry.exporter.cloud_trace import CloudTraceSpanExporter
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor
    trace.set_tracer_provider(TracerProvider())
    trace.get_tracer_provider().add_span_processor(
        BatchSpanProcessor(CloudTraceSpanExporter())
    )
    tracer = trace.get_tracer(__name__)
except Exception as e:
    logging.warning(f"Trace no inicio: {e}")
    tracer = None


logging.basicConfig(level=logging.INFO)
log = logging.getLogger("toolbox")

# Config desde env
REDIS_HOST = os.environ["REDIS_HOST"]
REDIS_PORT = int(os.environ.get("REDIS_PORT", "6379"))
LOOKER_URL = os.environ["LOOKERSDK_BASE_URL"]
LOOKER_CLIENT_ID = os.environ["LOOKERSDK_CLIENT_ID"]
LOOKER_CLIENT_SECRET = os.environ["LOOKERSDK_CLIENT_SECRET"]

# TTLs por tipo de operacion (segundos)
TTL = {
    "list_dashboards": 300,
    "list_looks": 300,
    "get_models": 1800,
    "get_explores": 1800,
    "get_dimensions": 1800,
    "run_query": 120,
    "render_png": 900,
}

# Pool de conexiones Redis (compartido entre requests)
redis_pool = redis.ConnectionPool(
    host=REDIS_HOST,
    port=REDIS_PORT,
    decode_responses=True,
    max_connections=50,
    socket_keepalive=True,
    socket_connect_timeout=3,
    socket_timeout=5,
)

# Pool de SDK de Looker (uno por worker, reutiliza session HTTPS)
_LOOKER_SDK = None
def get_looker_sdk():
    global _LOOKER_SDK
    if _LOOKER_SDK is None:
        _LOOKER_SDK = looker_sdk.init40()
    return _LOOKER_SDK


def cache_key(client_id: str, operation: str, **params) -> str:
    """Genera una clave de cache con hash de parametros."""
    params_str = json.dumps(params, sort_keys=True, default=str)
    h = hashlib.sha256(params_str.encode()).hexdigest()[:16]
    return f"{client_id}:{operation}:{h}"


def cache_get(key: str) -> Optional[dict]:
    try:
        r = redis.Redis(connection_pool=redis_pool)
        val = r.get(key)
        if val:
            log.info(f"CACHE HIT: {key}")
            return json.loads(val)
    except Exception as e:
        log.warning(f"Cache get error: {e}")
    return None


def cache_set(key: str, value: dict, ttl: int) -> None:
    try:
        r = redis.Redis(connection_pool=redis_pool)
        r.setex(key, ttl, json.dumps(value, default=str))
        log.info(f"CACHE SET: {key} (ttl={ttl}s)")
    except Exception as e:
        log.warning(f"Cache set error: {e}")


# ----------------------------------------------------------------------------
# Tools (con cache)
# ----------------------------------------------------------------------------
def tool_list_dashboards(client_id: str, search_term: str = "") -> dict:
    key = cache_key(client_id, "list_dashboards", search_term=search_term)
    if cached := cache_get(key):
        return cached

    sdk = get_looker_sdk()
    if search_term:
        dashboards = sdk.search_dashboards(title=f"%{search_term}%", limit=20, fields="id,title,description")
    else:
        dashboards = sdk.search_dashboards(limit=20, fields="id,title,description")

    items = [{"id": str(d.id), "title": d.title, "description": getattr(d, "description", "") or ""}
             for d in dashboards]
    result = {"dashboards": items, "count": len(items)}
    cache_set(key, result, TTL["list_dashboards"])
    return result


def tool_list_looks(client_id: str, search_term: str = "") -> dict:
    key = cache_key(client_id, "list_looks", search_term=search_term)
    if cached := cache_get(key):
        return cached

    sdk = get_looker_sdk()
    if search_term:
        looks = sdk.search_looks(title=f"%{search_term}%", limit=20, fields="id,title,description")
    else:
        looks = sdk.search_looks(limit=20, fields="id,title,description")

    items = [{"id": str(l.id), "title": l.title, "description": getattr(l, "description", "") or ""}
             for l in looks]
    result = {"looks": items, "count": len(items)}
    cache_set(key, result, TTL["list_looks"])
    return result


def tool_get_models(client_id: str) -> dict:
    key = cache_key(client_id, "get_models")
    if cached := cache_get(key):
        return cached

    sdk = get_looker_sdk()
    models = sdk.all_lookml_models(fields="name,label,description")
    items = [{"name": m.name, "label": m.label, "description": getattr(m, "description", "") or ""}
             for m in models]
    result = {"models": items}
    cache_set(key, result, TTL["get_models"])
    return result


def tool_get_explores(client_id: str, model: str) -> dict:
    key = cache_key(client_id, "get_explores", model=model)
    if cached := cache_get(key):
        return cached

    sdk = get_looker_sdk()
    lookml = sdk.lookml_model(model, fields="explores")
    items = [{"name": e.name, "description": getattr(e, "description", "") or ""}
             for e in (lookml.explores or [])]
    result = {"model": model, "explores": items}
    cache_set(key, result, TTL["get_explores"])
    return result


def tool_get_dimensions_and_measures(client_id: str, model: str, explore: str) -> dict:
    key = cache_key(client_id, "get_dimensions", model=model, explore=explore)
    if cached := cache_get(key):
        return cached

    sdk = get_looker_sdk()
    lookml_explore = sdk.lookml_model_explore(model, explore)
    dims = [{"name": d.name, "type": d.type, "label": d.label}
            for d in (lookml_explore.fields.dimensions or [])]
    meas = [{"name": m.name, "type": m.type, "label": m.label}
            for m in (lookml_explore.fields.measures or [])]
    result = {"model": model, "explore": explore, "dimensions": dims, "measures": meas}
    cache_set(key, result, TTL["get_dimensions"])
    return result


def tool_run_query(client_id: str, model: str, explore: str, fields: list,
                   filters: dict = None, limit: int = 500) -> dict:
    key = cache_key(client_id, "run_query", model=model, explore=explore,
                    fields=fields, filters=filters or {}, limit=limit)
    if cached := cache_get(key):
        return cached

    sdk = get_looker_sdk()
    query = sdk.create_query(
        body=models40.WriteQuery(
            model=model, view=explore, fields=fields,
            filters=filters or {}, limit=str(limit),
        )
    )
    rows = sdk.run_query(query_id=str(query.id), result_format="json")
    result = {"model": model, "explore": explore, "fields": fields,
              "rows": json.loads(rows) if isinstance(rows, str) else rows}
    cache_set(key, result, TTL["run_query"])
    return result


# ----------------------------------------------------------------------------
# Registro MCP de tools
# ----------------------------------------------------------------------------
TOOLS_REGISTRY = {
    "list_dashboards": {
        "fn": tool_list_dashboards,
        "schema": {
            "name": "list_dashboards",
            "description": "Lists Looker dashboards. Use search_term to filter by title.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "search_term": {"type": "string", "description": "Optional filter"}
                },
            },
        },
    },
    "list_looks": {
        "fn": tool_list_looks,
        "schema": {
            "name": "list_looks",
            "description": "Lists Looker Looks (saved charts).",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "search_term": {"type": "string"}
                },
            },
        },
    },
    "get_models": {
        "fn": tool_get_models,
        "schema": {
            "name": "get_models",
            "description": "Lists LookML models available.",
            "inputSchema": {"type": "object", "properties": {}},
        },
    },
    "get_explores": {
        "fn": tool_get_explores,
        "schema": {
            "name": "get_explores",
            "description": "Lists explores in a LookML model.",
            "inputSchema": {
                "type": "object",
                "properties": {"model": {"type": "string"}},
                "required": ["model"],
            },
        },
    },
    "get_dimensions_and_measures": {
        "fn": tool_get_dimensions_and_measures,
        "schema": {
            "name": "get_dimensions_and_measures",
            "description": "Lists dimensions and measures of an explore.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "model": {"type": "string"},
                    "explore": {"type": "string"}
                },
                "required": ["model", "explore"],
            },
        },
    },
    "run_query": {
        "fn": tool_run_query,
        "schema": {
            "name": "run_query",
            "description": "Runs a Looker query and returns results.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "model": {"type": "string"},
                    "explore": {"type": "string"},
                    "fields": {"type": "array", "items": {"type": "string"}},
                    "filters": {"type": "object"},
                    "limit": {"type": "integer", "default": 500},
                },
                "required": ["model", "explore", "fields"],
            },
        },
    },
}


# ----------------------------------------------------------------------------
# FastAPI app con endpoint MCP
# ----------------------------------------------------------------------------
@asynccontextmanager
async def lifespan(app: FastAPI):
    log.info("Starting toolbox-cached")
    log.info(f"Redis: {REDIS_HOST}:{REDIS_PORT}")
    log.info(f"Looker: {LOOKER_URL}")
    # Pre-warm Looker SDK
    get_looker_sdk()
    yield
    log.info("Shutting down")


app = FastAPI(lifespan=lifespan)


class MCPRequest(BaseModel):
    jsonrpc: str = "2.0"
    id: Any = None
    method: str
    params: dict = {}


@app.get("/health")
async def health():
    try:
        r = redis.Redis(connection_pool=redis_pool)
        r.ping()
        redis_ok = True
    except Exception:
        redis_ok = False
    return {"status": "ok" if redis_ok else "degraded", "redis": redis_ok}


@app.post("/mcp")
async def mcp_endpoint(
    body: MCPRequest,
    x_client_id: str = Header(default="default"),
):
    """Endpoint principal MCP. Dispatcha tools/list y tools/call."""
    method = body.method
    params = body.params

    if method == "tools/list":
        tools = [t["schema"] for t in TOOLS_REGISTRY.values()]
        return {"jsonrpc": "2.0", "id": body.id, "result": {"tools": tools}}

    if method == "tools/call":
        tool_name = params.get("name")
        tool_args = params.get("arguments", {})

        if tool_name not in TOOLS_REGISTRY:
            raise HTTPException(404, f"Tool not found: {tool_name}")

        try:
            fn = TOOLS_REGISTRY[tool_name]["fn"]
            result = fn(client_id=x_client_id, **tool_args)
            return {
                "jsonrpc": "2.0",
                "id": body.id,
                "result": {
                    "content": [{"type": "text", "text": json.dumps(result, default=str)}]
                },
            }
        except Exception as e:
            log.exception(f"Tool error: {tool_name}")
            return {
                "jsonrpc": "2.0",
                "id": body.id,
                "error": {"code": -32603, "message": str(e)},
            }

    if method == "initialize":
        return {
            "jsonrpc": "2.0",
            "id": body.id,
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "looker-toolbox-cached", "version": "1.0"},
            },
        }

    raise HTTPException(400, f"Unknown method: {method}")


@app.post("/cache/invalidate")
async def cache_invalidate(x_client_id: str = Header(default="default")):
    """Invalida todo el cache de un cliente."""
    r = redis.Redis(connection_pool=redis_pool)
    pattern = f"{x_client_id}:*"
    deleted = 0
    for key in r.scan_iter(pattern, count=1000):
        r.delete(key)
        deleted += 1
    return {"client_id": x_client_id, "keys_deleted": deleted}
PYEOF

echo "Build & deploy del toolbox custom..."

# Build con Cloud Build (mas rapido que docker local en Cloud Shell)
gcloud builds submit \
  --tag="gcr.io/${PROJECT_ID}/toolbox-cached:latest" \
  --project="$PROJECT_ID" \
  --timeout=600s

echo ""
echo "=================================================="
echo " PASO 8: Desplegar Cloud Run con Redis y VPC"
echo "=================================================="

gcloud run deploy toolbox-cached \
  --image="gcr.io/${PROJECT_ID}/toolbox-cached:latest" \
  --service-account="$TOOLBOX_SA_EMAIL" \
  --region="$REGION" \
  --vpc-connector="$VPC_CONNECTOR_NAME" \
  --vpc-egress=all-traffic \
  --set-env-vars="REDIS_HOST=${REDIS_HOST},REDIS_PORT=${REDIS_PORT},LOOKERSDK_BASE_URL=${LOOKER_URL},LOOKERSDK_CLIENT_ID=${LOOKER_CLIENT_ID},LOOKERSDK_CLIENT_SECRET=${LOOKER_CLIENT_SECRET},LOOKERSDK_VERIFY_SSL=true" \
  --cpu=4 \
  --memory=4Gi \
  --min-instances=2 \
  --max-instances=20 \
  --concurrency=80 \
  --no-cpu-throttling \
  --cpu-boost \
  --execution-environment=gen2 \
  --timeout=300s \
  --no-allow-unauthenticated \
  --project="$PROJECT_ID"

CLOUD_RUN_URL=$(gcloud run services describe toolbox-cached \
  --region="$REGION" --project="$PROJECT_ID" --format="value(status.url)")

MCP_SERVER_URL="${CLOUD_RUN_URL}/mcp"
echo "Cloud Run URL: $CLOUD_RUN_URL"
echo "MCP endpoint: $MCP_SERVER_URL"

# SA del agente puede invocar
gcloud run services add-iam-policy-binding toolbox-cached \
  --region="$REGION" \
  --member="serviceAccount:${AGENT_SA}" \
  --role="roles/run.invoker" \
  --project="$PROJECT_ID" &>/dev/null

cd ..

echo ""
echo "=================================================="
echo " PASO 9: Entorno Python del agente"
echo "=================================================="
rm -rf my-agents
mkdir -p my-agents && cd my-agents

python3 -m venv .venv
source .venv/bin/activate
pip install --quiet --upgrade pip
pip install --quiet google-adk toolbox-core looker-sdk
pip install --quiet --upgrade "google-cloud-aiplatform[agent_engines,adk]"

mkdir -p looker_app

cat > looker_app/__init__.py <<'EOF'
from . import agent
EOF

cat > looker_app/.env <<EOF
LOOKERSDK_BASE_URL=${LOOKER_URL}
LOOKERSDK_CLIENT_ID=${LOOKER_CLIENT_ID}
LOOKERSDK_CLIENT_SECRET=${LOOKER_CLIENT_SECRET}
LOOKERSDK_VERIFY_SSL=true
LOOKER_EMBED_SECRET=${LOOKER_EMBED_SECRET}
LOOKER_MODELS=${LOOKER_MODELS}
CLIENT_ID=${CLIENT_ID}
EOF

cat > looker_app/requirements.txt <<EOF
google-adk
toolbox-core
looker_sdk
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
from urllib.parse import quote_plus

import looker_sdk
from looker_sdk import models40

from google.adk.agents import LlmAgent
from google.adk.tools.mcp_tool.mcp_toolset import MCPToolset
from google.adk.tools.mcp_tool.mcp_session_manager import StreamableHTTPConnectionParams
import google.auth.transport.requests
import google.oauth2.id_token

MCP_SERVER_URL = "__MCP_SERVER_URL__"
CLIENT_ID = os.environ.get("CLIENT_ID", "default")
LOOKER_HOST = (
    os.environ.get("LOOKERSDK_BASE_URL", "")
    .replace("https://", "").replace("http://", "").rstrip("/")
)
EMBED_SECRET = os.environ.get("LOOKER_EMBED_SECRET", "")
LOOKER_MODELS_ENV = os.environ.get("LOOKER_MODELS", '["thelook"]')


def get_id_token():
    audience = MCP_SERVER_URL.split('/mcp')[0]
    auth_req = google.auth.transport.requests.Request()
    return google.oauth2.id_token.fetch_id_token(auth_req, audience)


def _generate_signed_embed_url(target_path: str) -> str:
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
    external_user_id = json.dumps(f"{CLIENT_ID}-user")
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


def get_dashboard_link(dashboard_id: str, title: str = "") -> dict:
    """Genera link SSO interactivo a un dashboard de Looker.

    Args:
        dashboard_id: ID numerico.
        title: Titulo opcional.
    """
    url = _generate_signed_embed_url(f"/embed/dashboards/{dashboard_id}")
    label = title if title else f"Dashboard {dashboard_id}"
    return {
        "dashboard_id": dashboard_id,
        "url": url,
        "markdown": f"**[Ver {label} en Looker]({url})**\n\n_Click para abrir el dashboard interactivo._",
    }


def get_look_link(look_id: str, title: str = "") -> dict:
    """Genera link SSO interactivo a un Look.

    Args:
        look_id: ID numerico.
        title: Titulo opcional.
    """
    url = _generate_signed_embed_url(f"/embed/looks/{look_id}")
    label = title if title else f"Look {look_id}"
    return {
        "look_id": look_id,
        "url": url,
        "markdown": f"**[Ver {label} en Looker]({url})**",
    }


root_agent = LlmAgent(
    model='gemini-2.5-flash',
    name='looker_agent',
    description='Looker agent with Redis-cached MCP tools.',
    instruction=(
        'You are a Looker data agent. You answer questions about Looker data using '
        'cached MCP tools (sub-second responses for repeated queries).\n\n'
        'TOOLS available via MCP (cached):\n'
        '- list_dashboards / list_looks: lists with optional search_term\n'
        '- get_models / get_explores / get_dimensions_and_measures: schema info\n'
        '- run_query: executes ad-hoc queries with model, explore, fields\n\n'
        'LOCAL TOOLS:\n'
        '- get_dashboard_link / get_look_link: returns SSO link to Looker UI\n\n'
        'When user asks to SEE/SHOW/VIEW a dashboard: use get_dashboard_link, '
        'return the markdown verbatim.\n'
        'When user asks WHAT dashboards exist: use list_dashboards from MCP.\n'
        'For data questions: use run_query.\n\n'
        'Defaults: model="thelook", explore="order_items".'
    ),
    tools=[
        MCPToolset(
            connection_params=StreamableHTTPConnectionParams(
                url=MCP_SERVER_URL,
                headers={
                    "Authorization": f"Bearer {get_id_token()}",
                    "X-Client-ID": CLIENT_ID,
                },
            ),
            errlog=None,
            tool_filter=None,
        ),
        get_dashboard_link,
        get_look_link,
    ],
)
PYEOF

sed -i "s|__MCP_SERVER_URL__|${MCP_SERVER_URL}|g" looker_app/agent.py
echo "Agente creado."

echo ""
echo "=================================================="
echo " PASO 10: Deploy del agente a Agent Engine"
echo "=================================================="

cat > deploy.py <<'DEPLOYEOF'
import os
import sys
import vertexai
from vertexai.preview import reasoning_engines
from vertexai import agent_engines

from looker_app.agent import root_agent

PROJECT_ID = os.environ["PROJECT_ID"]
REGION = os.environ["REGION"]
STAGING_BUCKET = f"gs://{os.environ['BUCKET_NAME']}"
AGENT_SA = os.environ["AGENT_SA"]
CLIENT_ID = os.environ["CLIENT_ID"]

vertexai.init(project=PROJECT_ID, location=REGION, staging_bucket=STAGING_BUCKET)

print(f"Desplegando agente para CLIENT_ID={CLIENT_ID} con SA: {AGENT_SA}", flush=True)

app = reasoning_engines.AdkApp(agent=root_agent, enable_tracing=True)

env_vars = {
    "LOOKERSDK_BASE_URL": os.environ["LOOKER_URL"],
    "LOOKERSDK_CLIENT_ID": os.environ["LOOKER_CLIENT_ID"],
    "LOOKERSDK_CLIENT_SECRET": os.environ["LOOKER_CLIENT_SECRET"],
    "LOOKERSDK_VERIFY_SSL": "true",
    "LOOKER_EMBED_SECRET": os.environ["LOOKER_EMBED_SECRET"],
    "LOOKER_MODELS": os.environ.get("LOOKER_MODELS", '["thelook"]'),
    "CLIENT_ID": CLIENT_ID,
}

try:
    remote_app = agent_engines.create(
        agent_engine=app,
        display_name=f"looker-agent-{CLIENT_ID}",
        requirements=[
            "google-adk", "toolbox-core", "looker_sdk",
            "google-auth", "google-cloud-aiplatform[agent_engines,adk]", "requests",
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

export PROJECT_ID REGION BUCKET_NAME AGENT_SA CLIENT_ID
export LOOKER_URL LOOKER_CLIENT_ID LOOKER_CLIENT_SECRET
export LOOKER_EMBED_SECRET LOOKER_MODELS

DEPLOY_LOG="/tmp/adk_deploy_$$.log"
> "$DEPLOY_LOG"

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
cat "$DEPLOY_LOG"

if [ $DEPLOY_EXIT -ne 0 ]; then
  echo "ERROR: Deploy fallo"
  exit 1
fi

REASONING_ENGINE=$(grep "AGENT_ENGINE_RESOURCE_NAME=" "$DEPLOY_LOG" | tail -1 | cut -d= -f2- || true)

if [ -z "$REASONING_ENGINE" ]; then
  REASONING_ENGINE=$(grep -oE 'projects/[^/]+/locations/[^/]+/reasoningEngines/[0-9]+' "$DEPLOY_LOG" | head -1 || true)
fi

if [ -z "$REASONING_ENGINE" ]; then
  echo "ERROR: No se obtuvo Reasoning Engine"
  exit 1
fi

echo "Reasoning Engine: $REASONING_ENGINE"

cd ..

echo ""
echo "=================================================="
echo " PASO 11: Registrar en Gemini Enterprise"
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
echo " PASO 12: Crear dashboard de observabilidad"
echo "=================================================="

cat > /tmp/looker-mcp-dashboard.json <<'DASHEOF'
{
  "displayName": "Looker MCP - Operaciones (v8)",
  "mosaicLayout": {
    "tiles": [
      {
        "width": 6, "height": 4,
        "widget": {
          "title": "MCP Request Latency (p50, p95, p99)",
          "xyChart": {
            "dataSets": [
              {
                "timeSeriesQuery": {
                  "timeSeriesFilter": {
                    "filter": "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"toolbox-cached\" AND metric.type=\"run.googleapis.com/request_latencies\"",
                    "aggregation": {
                      "alignmentPeriod": "60s",
                      "perSeriesAligner": "ALIGN_PERCENTILE_50"
                    }
                  }
                },
                "plotType": "LINE",
                "legendTemplate": "p50"
              },
              {
                "timeSeriesQuery": {
                  "timeSeriesFilter": {
                    "filter": "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"toolbox-cached\" AND metric.type=\"run.googleapis.com/request_latencies\"",
                    "aggregation": {
                      "alignmentPeriod": "60s",
                      "perSeriesAligner": "ALIGN_PERCENTILE_95"
                    }
                  }
                },
                "plotType": "LINE",
                "legendTemplate": "p95"
              },
              {
                "timeSeriesQuery": {
                  "timeSeriesFilter": {
                    "filter": "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"toolbox-cached\" AND metric.type=\"run.googleapis.com/request_latencies\"",
                    "aggregation": {
                      "alignmentPeriod": "60s",
                      "perSeriesAligner": "ALIGN_PERCENTILE_99"
                    }
                  }
                },
                "plotType": "LINE",
                "legendTemplate": "p99"
              }
            ],
            "yAxis": {"label": "ms", "scale": "LINEAR"}
          }
        }
      },
      {
        "width": 6, "height": 4, "xPos": 6,
        "widget": {
          "title": "Redis Cache Hit Ratio",
          "xyChart": {
            "dataSets": [{
              "timeSeriesQuery": {
                "timeSeriesFilter": {
                  "filter": "resource.type=\"redis_instance\" AND metric.type=\"redis.googleapis.com/stats/cache_hit_ratio\"",
                  "aggregation": {
                    "alignmentPeriod": "60s",
                    "perSeriesAligner": "ALIGN_MEAN"
                  }
                }
              },
              "plotType": "LINE"
            }],
            "yAxis": {"label": "ratio (0-1)", "scale": "LINEAR"}
          }
        }
      },
      {
        "width": 6, "height": 4, "yPos": 4,
        "widget": {
          "title": "Cloud Run Request Count (req/s)",
          "xyChart": {
            "dataSets": [{
              "timeSeriesQuery": {
                "timeSeriesFilter": {
                  "filter": "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"toolbox-cached\" AND metric.type=\"run.googleapis.com/request_count\"",
                  "aggregation": {
                    "alignmentPeriod": "60s",
                    "perSeriesAligner": "ALIGN_RATE",
                    "crossSeriesReducer": "REDUCE_SUM",
                    "groupByFields": ["metric.label.response_code_class"]
                  }
                }
              },
              "plotType": "STACKED_AREA"
            }]
          }
        }
      },
      {
        "width": 6, "height": 4, "xPos": 6, "yPos": 4,
        "widget": {
          "title": "Cloud Run Container CPU & Memory",
          "xyChart": {
            "dataSets": [
              {
                "timeSeriesQuery": {
                  "timeSeriesFilter": {
                    "filter": "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"toolbox-cached\" AND metric.type=\"run.googleapis.com/container/cpu/utilizations\"",
                    "aggregation": {
                      "alignmentPeriod": "60s",
                      "perSeriesAligner": "ALIGN_MEAN"
                    }
                  }
                },
                "plotType": "LINE",
                "legendTemplate": "CPU"
              },
              {
                "timeSeriesQuery": {
                  "timeSeriesFilter": {
                    "filter": "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"toolbox-cached\" AND metric.type=\"run.googleapis.com/container/memory/utilizations\"",
                    "aggregation": {
                      "alignmentPeriod": "60s",
                      "perSeriesAligner": "ALIGN_MEAN"
                    }
                  }
                },
                "plotType": "LINE",
                "legendTemplate": "Memory"
              }
            ]
          }
        }
      },
      {
        "width": 6, "height": 4, "yPos": 8,
        "widget": {
          "title": "Redis Memory Usage",
          "xyChart": {
            "dataSets": [{
              "timeSeriesQuery": {
                "timeSeriesFilter": {
                  "filter": "resource.type=\"redis_instance\" AND metric.type=\"redis.googleapis.com/stats/memory/usage_ratio\"",
                  "aggregation": {
                    "alignmentPeriod": "60s",
                    "perSeriesAligner": "ALIGN_MEAN"
                  }
                }
              },
              "plotType": "LINE"
            }],
            "yAxis": {"label": "ratio", "scale": "LINEAR"}
          }
        }
      },
      {
        "width": 6, "height": 4, "xPos": 6, "yPos": 8,
        "widget": {
          "title": "Redis Operations/sec",
          "xyChart": {
            "dataSets": [
              {
                "timeSeriesQuery": {
                  "timeSeriesFilter": {
                    "filter": "resource.type=\"redis_instance\" AND metric.type=\"redis.googleapis.com/commands/calls\"",
                    "aggregation": {
                      "alignmentPeriod": "60s",
                      "perSeriesAligner": "ALIGN_RATE",
                      "crossSeriesReducer": "REDUCE_SUM",
                      "groupByFields": ["metric.label.cmd"]
                    }
                  }
                },
                "plotType": "STACKED_AREA"
              }
            ]
          }
        }
      },
      {
        "width": 12, "height": 4, "yPos": 12,
        "widget": {
          "title": "Reasoning Engine - Errors & Latency",
          "xyChart": {
            "dataSets": [
              {
                "timeSeriesQuery": {
                  "timeSeriesFilter": {
                    "filter": "resource.type=\"aiplatform.googleapis.com/ReasoningEngine\" AND severity=\"ERROR\"",
                    "aggregation": {
                      "alignmentPeriod": "300s",
                      "perSeriesAligner": "ALIGN_RATE"
                    }
                  }
                },
                "plotType": "LINE",
                "legendTemplate": "Errors/min"
              }
            ]
          }
        }
      }
    ]
  }
}
DASHEOF

DASHBOARD_RESULT=$(gcloud monitoring dashboards create \
  --config-from-file=/tmp/looker-mcp-dashboard.json \
  --project="$PROJECT_ID" \
  --format="value(name)" 2>&1) || true

if [[ "$DASHBOARD_RESULT" == projects/* ]]; then
  DASHBOARD_ID=$(echo "$DASHBOARD_RESULT" | awk -F/ '{print $NF}')
  DASHBOARD_URL="https://console.cloud.google.com/monitoring/dashboards/builder/${DASHBOARD_ID}?project=${PROJECT_ID}"
  echo "Dashboard creado: $DASHBOARD_URL"
else
  echo "WARN: Dashboard creation message: $DASHBOARD_RESULT"
  DASHBOARD_URL="https://console.cloud.google.com/monitoring/dashboards?project=${PROJECT_ID}"
fi

# Tambien crear log-based metric para cache hits/misses
echo ""
echo "Creando log-based metrics para cache hit/miss tracking..."

gcloud logging metrics create cache_hit_count \
  --description="Count of cache hits in toolbox-cached" \
  --log-filter='resource.type="cloud_run_revision" AND resource.labels.service_name="toolbox-cached" AND textPayload=~"CACHE HIT"' \
  --project="$PROJECT_ID" 2>/dev/null || echo "Metric cache_hit_count ya existe"

gcloud logging metrics create cache_miss_count \
  --description="Count of cache misses (CACHE SET)" \
  --log-filter='resource.type="cloud_run_revision" AND resource.labels.service_name="toolbox-cached" AND textPayload=~"CACHE SET"' \
  --project="$PROJECT_ID" 2>/dev/null || echo "Metric cache_miss_count ya existe"

echo "Log-based metrics creadas (visible en Logs Explorer y Metrics Explorer)"


echo ""
echo "  Cloud Run URL    : $CLOUD_RUN_URL"
echo "  MCP Server URL   : $MCP_SERVER_URL"
echo "  Reasoning Engine : $REASONING_ENGINE"
echo "  Agent SA         : $AGENT_SA"
echo "  Toolbox SA       : $TOOLBOX_SA_EMAIL"
echo "  Redis            : ${REDIS_HOST}:${REDIS_PORT}"
echo "  Client ID        : $CLIENT_ID"
echo ""
echo "Latencia esperada:"
echo "  - Cache HIT  : 50-150ms"
echo "  - Cache MISS : igual que antes (1-5s)"
echo "  - Hit rate post-warmup: 70-90%"
echo ""
echo "Testing del cache:"
echo "  # Limpiar cache de un cliente:"
echo "  curl -X POST -H \"Authorization: Bearer \$(gcloud auth print-identity-token)\" \\"
echo "    -H \"X-Client-ID: $CLIENT_ID\" $CLOUD_RUN_URL/cache/invalidate"
echo ""
echo "  # Health check:"
echo "  curl -H \"Authorization: Bearer \$(gcloud auth print-identity-token)\" $CLOUD_RUN_URL/health"
echo ""
echo "Observabilidad:"
echo "  - Dashboard unificado : $DASHBOARD_URL"
echo "  - Cloud Trace         : https://console.cloud.google.com/traces/list?project=$PROJECT_ID"
echo "  - Cloud Profiler      : https://console.cloud.google.com/profiler?project=$PROJECT_ID"
echo "  - Redis metrics       : https://console.cloud.google.com/memorystore/redis/instances?project=$PROJECT_ID"
echo "  - Logs en vivo        : gcloud run services logs tail toolbox-cached --region=$REGION --project=$PROJECT_ID"
echo ""
echo "Custom log-metrics:"
echo "  - cache_hit_count  (cuenta CACHE HIT en logs)"
echo "  - cache_miss_count (cuenta CACHE SET en logs)"
echo "  Ver en: https://console.cloud.google.com/logs/metrics?project=$PROJECT_ID"
