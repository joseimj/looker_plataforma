Looker Plataforma — Agente Looker para Gemini Enterprise
Scripts de despliegue automatizado para integrar Looker con Gemini Enterprise en Google Cloud. Provisiona toda la infraestructura necesaria (Cloud Run, Memorystore Redis, VPC, Agent Engine) y registra un agente conversacional capaz de consultar dashboards, Looks y datos de Looker con respuestas en sub-segundos.

Autor: Jose Maldonado (@joseimj)


Tabla de contenido

Visión general
Arquitectura (v8)
Requisitos previos
Configuración
Uso
Versiones de los scripts
Capacidades del agente
Cache y TTLs
Costos estimados
Solución de problemas
Licencia


Visión general
Este repositorio contiene una colección de scripts Bash idempotentes que automatizan el despliegue end-to-end de un agente conversacional de Looker sobre Google Cloud y Gemini Enterprise. Cada script ejecuta los pasos en orden: validación de variables, habilitación de APIs, creación de service accounts, networking, build/deploy del toolbox, y registro del agente en Gemini Enterprise.
El objetivo es que un equipo de datos pueda preguntar en lenguaje natural cosas como "muéstrame el dashboard de ventas del Q4" o "cuáles fueron los top 10 productos por revenue la semana pasada" y obtener respuestas (con links interactivos a Looker) en menos de un segundo cuando hay cache hit.
Arquitectura (v8)
La versión más reciente (looker_gemini_setup_v8.sh) implementa una arquitectura production-ready multi-cliente:
┌─────────────────────┐
│ Gemini Enterprise   │
│ (UI conversacional) │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐         ┌──────────────────────┐
│ Agent Engine (ADK)  │────────▶│ Cloud Run (FastAPI)  │
│ - LlmAgent          │   MCP   │ - Looker SDK         │
│ - SSO embed signing │         │ - Redis client       │
└─────────────────────┘         │ - Connection pool    │
                                └──────────┬───────────┘
                                           │ VPC Connector
                                           ▼
                                ┌──────────────────────┐
                                │ Memorystore Redis    │
                                │ Standard HA (5 GB)   │
                                └──────────────────────┘
                                           │
                                           ▼
                                ┌──────────────────────┐
                                │ Looker API           │
                                └──────────────────────┘
Componentes clave:

Memorystore Redis Standard HA (5 GB) — cache distribuido con namespace por cliente (X-Client-ID)
VPC + VPC Connector — egress privado de Cloud Run hacia Redis
Cloud Run custom (FastAPI + Looker SDK + Redis) — implementa el protocolo MCP (tools/list, tools/call) con connection pooling a Looker para reducir TLS handshakes
Min-instances = 2 con CPU always-on (sin cold starts)
Cloud Trace + Cloud Profiler activos para observabilidad
Agente ADK desplegado en Vertex AI Agent Engine con service account dedicado
Registro en Gemini Enterprise con link SSO interactivo

Requisitos previos

Una cuenta de Google Cloud con un proyecto activo y facturación habilitada
gcloud CLI instalada y autenticada (gcloud auth login)
Una instancia de Looker con credenciales API (Client ID, Client Secret y Embed Secret)
Un agente de Gemini Enterprise ya creado (necesitas su AS_APP ID)
Un bucket de GCS para staging del agente
Permisos de Owner o equivalente sobre el proyecto de GCP
bash y python3 (los scripts crean su propio venv)

Configuración
Antes de ejecutar cualquier script, edita las variables al inicio del archivo:
bashPROJECT_ID="tu-proyecto-gcp"
PROJECT_NUMBER="123456789012"
REGION="us-central1"
BUCKET_NAME="tu-bucket-staging"

# Identificador del cliente (namespace de cache)
CLIENT_ID="acme_corp"

# Looker
LOOKER_URL="https://tu-instancia.looker.com"
LOOKER_CLIENT_ID="..."
LOOKER_CLIENT_SECRET="..."
LOOKER_EMBED_SECRET="..."
LOOKER_MODELS='["thelook"]'

# Gemini Enterprise
AS_APP="tu-agent-id"
El script valida automáticamente que ninguna variable empiece con YOUR_ antes de continuar.
Uso
bash# Clona el repo
git clone https://github.com/joseimj/looker_plataforma.git
cd looker_plataforma

# Da permisos de ejecución
chmod +x looker_gemini_setup_v8.sh

# Edita las variables y ejecuta
./looker_gemini_setup_v8.sh
El script ejecuta los siguientes pasos:

Validación de variables
Autenticación
Habilitación de APIs (Cloud Run, Redis, VPC, Vertex AI, Discovery Engine, etc.)
Creación de service accounts (toolbox + agente) y permisos IAM
VPC, subnet y peering de servicios privados
Memorystore Redis (5–10 min)
VPC Connector (3–5 min)
Bucket de staging
Build del toolbox custom con Cloud Build
Deploy a Cloud Run
Setup del entorno Python del agente (ADK)
Deploy del agente a Agent Engine
Registro en Gemini Enterprise

Tiempo total aproximado: 20–30 minutos en el primer despliegue.
Setup de billing export (opcional)
Para tener visibilidad de costos del agente, ejecuta también:
bash./setup_billing_export_v2.sh
Esto configura el export de Cloud Billing a BigQuery para análisis de gasto.
Versiones de los scripts
El repo conserva el historial completo de iteraciones. Usa siempre la más reciente salvo que necesites comparar:
ScriptDescripciónlooker_gemini_setup.shVersión iniciallooker_gemini_setup_v2.sh – v4.shIteraciones tempranas con toolbox binariolooker_gemini_setup_v6.sh – v6_5.shMejoras incrementales en deploy del agentelooker_gemini_v6_6.shRefactor con SA dedicadolooker_gemini_setup_v7.shCloud Run custom (sin binario toolbox)looker_gemini_setup_v8.shVersión actual: cache Redis multi-cliente + VPC + observabilidadsetup_billing_export.sh / _v2.shExport de Cloud Billing a BigQuery
Capacidades del agente
Vía MCP (con cache Redis):

list_dashboards — lista dashboards, filtra por título
list_looks — lista Looks (charts guardados)
get_models — modelos LookML disponibles
get_explores — explores de un modelo
get_dimensions_and_measures — campos de un explore
run_query — ejecuta queries ad-hoc

Tools locales (en el agente):

get_dashboard_link — genera link SSO firmado a un dashboard
get_look_link — genera link SSO firmado a un Look

Cache y TTLs
OperaciónTTLlist_dashboards, list_looks5 minutosget_models, get_explores, get_dimensions_and_measures30 minutosrun_query2 minutosRender PNG15 minutos
El cache está aislado por cliente mediante el header X-Client-ID, lo que permite servir múltiples tenants desde la misma instancia sin cross-contamination.
Para invalidar el cache de un cliente manualmente:
bashcurl -X POST "${CLOUD_RUN_URL}/cache/invalidate" \
  -H "X-Client-ID: acme_corp" \
  -H "Authorization: Bearer $(gcloud auth print-identity-token)"
Costos estimados
Aproximado por mes en us-central1 (puede variar según uso):

Memorystore Redis Standard HA 5 GB: ~$160 USD
VPC Connector (e2-standard-4, min 2): ~$100 USD
Cloud Run min-instances=2 con CPU always-on: ~$80–150 USD
Vertex AI Agent Engine: pay-per-use según invocaciones
Gemini API: según tokens consumidos


Para entornos de desarrollo, considera reducir Redis a BASIC (1 GB) y min-instances=0 para bajar a ~$30 USD/mes.

Solución de problemas
El script falla con VPC peering ya existe — Es normal en redespliegues, el script continúa.
Cloud Build timeout en el build del toolbox — Aumenta --timeout=600s a 900s en la línea correspondiente.
El agente responde lento la primera vez — Es esperado: el primer hit no tiene cache. Las siguientes consultas idénticas serán sub-segundo.
Error 401 desde el agente al Cloud Run — Verifica que el AGENT_SA tenga roles/run.invoker sobre el servicio.
Links SSO de Looker no abren — Confirma que LOOKER_EMBED_SECRET esté correctamente configurado y que el dominio del Cloud Run esté en la whitelist de embed de Looker.
