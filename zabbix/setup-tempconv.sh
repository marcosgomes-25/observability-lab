#!/usr/bin/env bash
# Cria no Zabbix o host "tempconv-app" que monitora a aplicacao Node.js
# raspando o mesmo endpoint /metrics (formato Prometheus) via item HTTP agent
# + itens dependentes com pre-processamento "Prometheus pattern".
#
# Requer: bash, curl, jq
set -euo pipefail

ZBX_URL="${ZBX_URL:-http://localhost:8080/api_jsonrpc.php}"
# credenciais: variaveis de ambiente ou o .env da raiz do projeto (ver .env.example)
ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/.env"
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }
ZBX_USER="${ZBX_USER:-${ZABBIX_API_USER:-Admin}}"
ZBX_PASS="${ZBX_PASS:-${ZABBIX_API_PASSWORD:-}}"
[ -n "$ZBX_PASS" ] || { echo "ERRO: defina ZABBIX_API_PASSWORD no .env (veja .env.example) ou exporte ZBX_PASS" >&2; exit 1; }
METRICS_URL="${METRICS_URL:-http://tempconv:3000/metrics}"
HOST_NAME="tempconv-app"
GROUP_NAME="Lab"

TOKEN=""
api() { # $1=method  $2=params(JSON)
  local body resp
  body=$(jq -nc --arg m "$1" --argjson p "$2" '{jsonrpc:"2.0",method:$m,params:$p,id:1}')
  if [ -n "$TOKEN" ]; then
    resp=$(curl -sS --fail -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" -d "$body" "$ZBX_URL") \
      || { echo "ERRO HTTP em $1" >&2; exit 1; }
  else
    resp=$(curl -sS --fail -H "Content-Type: application/json" -d "$body" "$ZBX_URL") \
      || { echo "ERRO HTTP em $1" >&2; exit 1; }
  fi
  # resposta valida sempre tem "result"; senao e erro da API, corpo vazio ou nao-JSON
  if ! echo "$resp" | jq -e 'has("result")' >/dev/null 2>&1; then
    echo "ERRO em $1: $(echo "$resp" | jq -c '.error' 2>/dev/null || echo "${resp:-resposta vazia}")" >&2
    exit 1
  fi
  echo "$resp" | jq '.result'
}

echo ">> login"
TOKEN=$(api user.login "$(jq -nc --arg u "$ZBX_USER" --arg p "$ZBX_PASS" '{username:$u,password:$p}')" | tr -d '"')

echo ">> host group '$GROUP_NAME'"
GID=$(api hostgroup.get "$(jq -nc --arg n "$GROUP_NAME" '{filter:{name:[$n]},output:["groupid"]}')" | jq -r '.[0].groupid // empty')
if [ -z "$GID" ]; then
  GID=$(api hostgroup.create "$(jq -nc --arg n "$GROUP_NAME" '{name:$n}')" | jq -r '.groupids[0]')
fi
echo "   groupid=$GID"

echo ">> remove host anterior (se existir) p/ execucao idempotente"
OLD=$(api host.get "$(jq -nc --arg h "$HOST_NAME" '{filter:{host:[$h]},output:["hostid"]}')" | jq -r '.[0].hostid // empty')
[ -n "$OLD" ] && api host.delete "$(jq -nc --arg id "$OLD" '[$id]')" >/dev/null && echo "   removido hostid=$OLD"

echo ">> cria host $HOST_NAME"
HID=$(api host.create "$(jq -nc --arg h "$HOST_NAME" --arg g "$GID" '{
  host:$h,
  groups:[{groupid:$g}],
  interfaces:[{type:1,main:1,useip:0,ip:"",dns:"tempconv",port:"10050"}],
  tags:[{tag:"app",value:"tempconv"},{tag:"lab",value:"true"}]
}')" | jq -r '.hostids[0]')
echo "   hostid=$HID"

echo ">> item mestre (HTTP agent) tempconv.metrics"
MID=$(api item.create "$(jq -nc --arg h "$HID" --arg u "$METRICS_URL" '{
  hostid:$h, name:"tempconv: Prometheus metrics (raw)", key_:"tempconv.metrics",
  type:19, value_type:4, delay:"30s", url:$u, timeout:"10s", history:"1d", trends:"0"
}')" | jq -r '.itemids[0]')
echo "   master itemid=$MID"

# Pre-processamento "Prometheus pattern" = type 22.
#   params (linhas separadas por \n):
#     linha 1: seletor/pattern    ex: temp_conversions_total  ou  metric{label="x"}
#     linha 2: saida -> "value" | "label" | "function"
#     linha 3: nome do label (se "label")  ou  funcao sum|min|max|avg|count (se "function")
dep() { # $1=key $2=name $3=pattern $4=saida(value|sum|avg|...) $5=units $6=cps(1 p/ add change-per-second)
  local params pp
  case "$4" in
    value|label) params="$3"$'\n'"$4" ;;
    *)           params="$3"$'\n'"function"$'\n'"$4" ;;
  esac
  pp=$(jq -nc --arg p "$params" '[{type:22,params:$p,error_handler:0,error_handler_params:""}]')
  [ "${6:-}" = "1" ] && pp=$(jq -nc --argjson a "$pp" '$a + [{type:10,params:"",error_handler:0,error_handler_params:""}]')
  api item.create "$(jq -nc --arg h "$HID" --arg m "$MID" --arg k "$1" --arg n "$2" --arg u "$5" --argjson pp "$pp" '{
    hostid:$h, name:$n, key_:$k, type:18, master_itemid:$m, value_type:0, units:$u,
    history:"7d", trends:"90d", preprocessing:$pp
  }')" >/dev/null
  echo "   + $1"
}

echo ">> itens dependentes"
dep tempconv.conversions.total "Conversoes - total"           'temp_conversions_total'                         sum   ""
dep tempconv.conversions.cps   "Conversoes por segundo"        'temp_conversions_total'                         sum   ""  1
dep tempconv.errors.total      "Erros de conversao - total"    'temp_conversion_errors_total'                   value ""
dep tempconv.last.celsius      "Ultima leitura (C)"            'temp_conversion_last_output{unit="celsius"}'    value "C"
dep tempconv.last.fahrenheit   "Ultima leitura (F)"            'temp_conversion_last_output{unit="fahrenheit"}' value "F"
dep tempconv.mem.rss           "Memoria RSS do processo Node"  'tempconv_process_resident_memory_bytes'         value "B"
dep tempconv.eventloop.lag     "Event loop lag"                'tempconv_nodejs_eventloop_lag_seconds'          value "s"

# ---------------------------------------------------------------------------
# APM (golden signals) a partir do histograma http_request_duration_seconds
# ---------------------------------------------------------------------------
# Itens "raw" guardam os contadores acumulados (so p/ calculo, sem trends);
# os itens calculados aplicam rate() sobre eles numa janela de APM_WINDOW.
APM_ROUTE="/convert"
APM_WINDOW="5m"
APDEX_T="0.025"     # limiar "satisfeito" em segundos (precisa ser um bucket do histograma)
APDEX_4T="0.1"      # limiar "tolerado" = 4*T (idem)
BUCKETS="0.0001 0.00025 0.0005 0.001 0.005 0.01 0.025 0.05 0.1 0.25 0.5 1 +Inf"   # = buckets do app/server.js
for t in "$APDEX_T" "$APDEX_4T"; do
  [[ " $BUCKETS " == *" $t "* ]] || { echo "ERRO: limiar Apdex $t nao e um bucket ($BUCKETS)" >&2; exit 1; }
done

raw() { # $1=key $2=name $3=pattern(somado c/ function sum) $4=units  -> erro vira 0 (serie ainda inexistente)
  local pp
  pp=$(jq -nc --arg p "$3"$'\n'"function"$'\n'"sum" '[{type:22,params:$p,error_handler:2,error_handler_params:"0"}]')
  api item.create "$(jq -nc --arg h "$HID" --arg m "$MID" --arg k "$1" --arg n "$2" --arg u "$4" --argjson pp "$pp" '{
    hostid:$h, name:$n, key_:$k, type:18, master_itemid:$m, value_type:0, units:$u,
    history:"1d", trends:"0", preprocessing:$pp, tags:[{tag:"component",value:"apm-raw"}]
  }')" | jq -er '.itemids[0]'
}

calc() { # $1=key $2=name $3=formula $4=units [$5=preprocessing JSON]  -> imprime itemid
  api item.create "$(jq -nc --arg h "$HID" --arg k "$1" --arg n "$2" --arg f "$3" --arg u "$4" --argjson pp "${5:-[]}" '{
    hostid:$h, name:$n, key_:$k, type:15, value_type:0, params:$f, units:$u, delay:"1m",
    history:"7d", trends:"90d", preprocessing:$pp, tags:[{tag:"component",value:"apm"}]
  }')" | jq -er '.itemids[0]'
}

echo ">> APM: contadores raw (rota $APM_ROUTE)"
# synthetic="0": ignora as checagens do cenario web (header X-Synthetic) p/ nao distorcer o APM
SEL="route=\"$APM_ROUTE\",synthetic=\"0\""
# buckets so de respostas 2xx/3xx: no Apdex, erros contam como "frustrados" (entram so no total)
OK="status=~\"[23]..\""
raw tempconv.http.requests.total "APM raw: requisicoes (total)"       "http_request_duration_seconds_count{$SEL}"                    ""  >/dev/null
raw tempconv.http.requests.err   "APM raw: requisicoes 4xx+5xx"       "http_request_duration_seconds_count{$SEL,status=~\"[45]..\"}" ""  >/dev/null
raw tempconv.http.requests.5xx   "APM raw: requisicoes 5xx"           "http_request_duration_seconds_count{$SEL,status=~\"5..\"}"    ""  >/dev/null
raw tempconv.http.duration.sum   "APM raw: soma das duracoes"         "http_request_duration_seconds_sum{$SEL}"                      "s" >/dev/null
for le in $BUCKETS; do
  raw "tempconv.http.duration.bucket[$le]" "APM raw: bucket 2xx/3xx le=$le" "http_request_duration_seconds_bucket{$SEL,$OK,le=\"$le\"}" "" >/dev/null
done
echo "   + $((4 + $(wc -w <<<"$BUCKETS"))) itens raw"

echo ">> APM: itens calculados (janela $APM_WINDOW)"
W="$APM_WINDOW"
# (x=0) vale 1 quando x e 0: evita divisao por zero quando nao ha trafego
DEN="(rate(//tempconv.http.requests.total,$W)+(rate(//tempconv.http.requests.total,$W)=0))"
I_TPUT=$(calc tempconv.apm.throughput "APM: Throughput"       "rate(//tempconv.http.requests.total,$W)" "rps")
I_ERR=$(calc tempconv.apm.error_rate  "APM: Taxa de erro (4xx+5xx)" "100*rate(//tempconv.http.requests.err,$W)/$DEN" "%")
I_5XX=$(calc tempconv.apm.error_rate_5xx "APM: Taxa de erro de servidor (5xx)" "100*rate(//tempconv.http.requests.5xx,$W)/$DEN" "%")
# media inclui todas as respostas (2xx-5xx); os quantis abaixo, so 2xx/3xx
I_AVG=$(calc tempconv.apm.latency.avg "APM: Latencia media"   "rate(//tempconv.http.duration.sum,$W)/$DEN" "s")
# quantis das respostas 2xx/3xx; sem trafego OK no periodo histogram_quantile devolve -1,
# descartado pelo pre-processamento "In range" (type 13, min 0) c/ error handler "discard"
NONNEG='[{"type":13,"params":"0\n","error_handler":1,"error_handler_params":""}]'
for q in 50:0.5 95:0.95 99:0.99; do
  id=$(calc "tempconv.apm.latency.p${q%%:*}" "APM: Latencia p${q%%:*}" \
    "histogram_quantile(${q#*:},bucket_rate_foreach(//tempconv.http.duration.bucket[*],$W,1))" "s" "$NONNEG")
  printf -v "I_P${q%%:*}" '%s' "$id"
done
# Apdex = (satisfeitos + tolerados/2) / total = (bucket(T) + bucket(4T)) / 2 / total ; sem trafego -> 1
# (buckets so 2xx/3xx e total com erros => respostas de erro contam como frustradas)
I_APDEX=$(calc tempconv.apm.apdex "APM: Apdex (T=${APDEX_T}s)" \
  "((rate(//tempconv.http.duration.bucket[$APDEX_T],$W)+rate(//tempconv.http.duration.bucket[$APDEX_4T],$W))/2+(rate(//tempconv.http.requests.total,$W)=0))/$DEN" "")
echo "   + throughput, error_rate, error_rate_5xx, latency.avg/p50/p95/p99, apdex"

echo ">> APM: cenario web sintetico (executado pelo zabbix-server)"
APP_BASE="${METRICS_URL%%/metrics*}"
WEB="tempconv synthetic"
api httptest.create "$(jq -nc --arg h "$HID" --arg n "$WEB" --arg b "$APP_BASE" '{
  hostid:$h, name:$n, delay:"1m", retries:1,
  headers:[{name:"X-Synthetic",value:"1"}],
  tags:[{tag:"component",value:"apm-synthetic"}],
  steps:[
    {no:1, name:"health",  url:($b+"/health"),             status_codes:"200", required:"\"status\":\"ok\"", timeout:"10s"},
    {no:2, name:"convert", url:($b+"/convert?celsius=25"), status_codes:"200", required:"\"fahrenheit\":77",  timeout:"10s"}
  ]
}')" >/dev/null && echo "   + web scenario '$WEB' (health, convert)"

echo ">> triggers"
TH="/$HOST_NAME"
trig() { # $1=descricao $2=expressao $3=prioridade [$4=recovery_expression]
  api trigger.create "$(jq -nc --arg d "$1" --arg e "$2" --argjson p "$3" --arg r "${4:-}" '{
    description:$d, expression:$e, priority:$p, tags:[{tag:"component",value:"apm"}]
  } + (if $r == "" then {} else {recovery_mode:1, recovery_expression:$r} end)')" >/dev/null
  echo "   + $1"
}
trig "tempconv APM: taxa de erro 4xx+5xx acima de 20% (5m)" \
     "min($TH/tempconv.apm.error_rate,5m)>20" 2 "max($TH/tempconv.apm.error_rate,5m)<15"
trig "tempconv APM: erros de servidor 5xx acima de 1% (5m)" \
     "min($TH/tempconv.apm.error_rate_5xx,5m)>1" 4 "max($TH/tempconv.apm.error_rate_5xx,5m)<0.5"
trig "tempconv APM: latencia p95 acima de 250ms (5m)" \
     "min($TH/tempconv.apm.latency.p95,5m)>0.25" 3 "max($TH/tempconv.apm.latency.p95,5m)<0.2"
trig "tempconv APM: Apdex abaixo de 0.85 (5m)" \
     "max($TH/tempconv.apm.apdex,5m)<0.85" 2 "min($TH/tempconv.apm.apdex,5m)>0.9"
# app no ar sem trafego real (app fora do ar e coberta pelos triggers nodata/sintetico)
trig "tempconv APM: sem trafego real em $APM_ROUTE ha 5m" \
     "max($TH/tempconv.apm.throughput,5m)=0" 1
trig "tempconv APM: cenario sintetico falhando (2 execucoes)" \
     "min($TH/web.test.fail[$WEB],#2)>0" 4
api trigger.create "$(jq -nc --arg h "$HOST_NAME" '{
  description:"tempconv: sem coleta de metricas ha 2 min",
  expression:("nodata(/"+$h+"/tempconv.metrics,120s)=1"),
  priority:4
}')" >/dev/null && echo "   + trigger nodata"

api trigger.create "$(jq -nc --arg h "$HOST_NAME" '{
  description:"tempconv: muitos erros de conversao (>10 em 10m)",
  expression:("(last(/"+$h+"/tempconv.errors.total)-min(/"+$h+"/tempconv.errors.total,10m))>10"),
  priority:2
}')" >/dev/null && echo "   + trigger erros"

echo ">> dashboard 'tempconv APM'"
DASH="tempconv APM"
# widgets ------------------------------------------------------------------
# item: valor atual + sparkline; thresholds em ordem crescente (cor de fundo)
w_item() { # $1=x $2=y $3=itemid $4=descricao $5=thresholds JSON [[valor,cor],...] $6=decimais
  jq -nc --argjson x "$1" --argjson y "$2" --arg i "$3" --arg d "$4" --argjson th "$5" --argjson dec "${6:-2}" '{
    type:"item", x:$x, y:$y, width:12, height:3,
    fields:([{type:4,name:"itemid.0",value:$i},{type:1,name:"description",value:$d},
             {type:0,name:"decimal_places",value:$dec}]
      + ([$th | to_entries[] | [{type:1,name:"thresholds.\(.key).threshold",value:(.value[0]|tostring)},
                                {type:1,name:"thresholds.\(.key).color",value:.value[1]}]] | add // []))
  }'
}
# svggraph: uma serie por [padrao de nome de item, cor]
w_graph() { # $1=x $2=y $3=titulo $4=series JSON [[padrao,cor],...]
  jq -nc --argjson x "$1" --argjson y "$2" --arg t "$3" --arg h "$HOST_NAME" --argjson s "$4" '{
    type:"svggraph", name:$t, x:$x, y:$y, width:36, height:5,
    fields:([$s | to_entries[] | [{type:1,name:"ds.\(.key).hosts.0",value:$h},
                                  {type:1,name:"ds.\(.key).items.0",value:.value[0]},
                                  {type:1,name:"ds.\(.key).color",value:.value[1]},
                                  {type:0,name:"ds.\(.key).width",value:2},
                                  {type:0,name:"ds.\(.key).fill",value:1}]] | add)
      + [{type:0,name:"legend_statistic",value:1}]
  }'
}
GREEN=0EC9AC; YELLOW=FFD54F; RED=FF465C
W1=$(w_item 0  0 "$I_TPUT"  "Throughput"         '[]' 2)
W2=$(w_item 12 0 "$I_ERR"   "Erro 4xx+5xx"       "[[0,\"$GREEN\"],[10,\"$YELLOW\"],[20,\"$RED\"]]" 1)
W3=$(w_item 24 0 "$I_5XX"   "Erro 5xx"           "[[0,\"$GREEN\"],[0.5,\"$YELLOW\"],[1,\"$RED\"]]" 2)
W4=$(w_item 36 0 "$I_AVG"   "Latencia media"     "[[0,\"$GREEN\"],[0.1,\"$YELLOW\"],[0.25,\"$RED\"]]" 4)
W5=$(w_item 48 0 "$I_P95"   "Latencia p95"       "[[0,\"$GREEN\"],[0.1,\"$YELLOW\"],[0.25,\"$RED\"]]" 4)
W6=$(w_item 60 0 "$I_APDEX" "Apdex (T=${APDEX_T}s)" "[[0,\"$RED\"],[0.85,\"$YELLOW\"],[0.94,\"$GREEN\"]]" 3)
G1=$(w_graph 0  3  "Throughput (req/s)"  '[["APM: Throughput","1E88E5"]]')
G2=$(w_graph 36 3  "Taxa de erro (%)"    '[["APM: Taxa de erro (4xx+5xx)","FFA000"],["APM: Taxa de erro de servidor (5xx)","E53935"]]')
G3=$(w_graph 0  8  "Latencia (s)"        '[["APM: Latencia media","00897B"],["APM: Latencia p50","43A047"],["APM: Latencia p95","FB8C00"],["APM: Latencia p99","E53935"]]')
G4=$(w_graph 36 8  "Apdex"               '[["APM: Apdex*","8E24AA"]]')
G5=$(w_graph 0  13 "Sintetico: tempo de resposta por passo (s)" "[[\"Response time for step \\\"health\\\" of scenario*\",\"1E88E5\"],[\"Response time for step \\\"convert\\\" of scenario*\",\"FB8C00\"]]")
PROB=$(jq -nc --arg h "$HID" '{type:"problems", name:"Problemas tempconv", x:36, y:13, width:36, height:5,
  fields:[{type:3,name:"hostids.0",value:$h},{type:0,name:"show_tags",value:1}]}')

if ! (
  # if ! ( ) desliga o errexit aqui dentro: cada passo checa a falha explicitamente
  WIDGETS=$(jq -sc '.' <<<"$W1 $W2 $W3 $W4 $W5 $W6 $G1 $G2 $G3 $G4 $G5 $PROB") || exit 1
  OLD_D=$(api dashboard.get "$(jq -nc --arg n "$DASH" '{filter:{name:[$n]},output:["dashboardid"]}')" | jq -ec '[.[].dashboardid]') || exit 1
  if [ "$OLD_D" != "[]" ]; then api dashboard.delete "$OLD_D" >/dev/null || exit 1; fi
  DID=$(api dashboard.create "$(jq -nc --arg n "$DASH" --argjson w "$WIDGETS" '{
    name:$n, display_period:30, auto_start:1, pages:[{widgets:$w}]
  }')" | jq -er '.dashboardids[0]') || exit 1
  echo "   + dashboardid=$DID  -> ${ZBX_URL%/api_jsonrpc.php}/zabbix.php?action=dashboard.view&dashboardid=$DID"
); then
  echo "   (aviso: dashboard nao criado; itens, triggers e cenario web continuam ativos)" >&2
fi

echo ">> mapa 'tempconv - arquitetura'"
# So tempconv-app e "Zabbix server" sao hosts (status ao vivo); o resto e icone (elementtype 4).
# Links ficam coloridos quando os triggers associados estao em problema.
MAP="tempconv - arquitetura"
ZBX_HOST_NAME="${ZBX_HOST_NAME:-Zabbix server}"
GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
if ! (
  tid() { # $1=descricao exata do trigger no host tempconv-app -> triggerid
    api trigger.get "$(jq -nc --arg h "$HOST_NAME" --arg d "$1" '{host:$h,filter:{description:[$d]},output:["triggerid"]}')" \
      | jq -er '.[0].triggerid'
  }
  T_SYN=$(tid "tempconv APM: cenario sintetico falhando (2 execucoes)") || exit 1
  T_NODATA=$(tid "tempconv: sem coleta de metricas ha 2 min") || exit 1
  T_ERR=$(tid "tempconv APM: taxa de erro 4xx+5xx acima de 20% (5m)") || exit 1
  T_5XX=$(tid "tempconv APM: erros de servidor 5xx acima de 1% (5m)") || exit 1
  T_P95=$(tid "tempconv APM: latencia p95 acima de 250ms (5m)") || exit 1
  T_APDEX=$(tid "tempconv APM: Apdex abaixo de 0.85 (5m)") || exit 1
  T_TRAF=$(tid "tempconv APM: sem trafego real em $APM_ROUTE ha 5m") || exit 1
  ZID=$(api host.get "$(jq -nc --arg h "$ZBX_HOST_NAME" '{filter:{host:[$h]},output:["hostid"]}')" | jq -er '.[0].hostid') || exit 1

  OLD_M=$(api map.get "$(jq -nc --arg n "$MAP" '{filter:{name:[$n]},output:["sysmapid"]}')" | jq -ec '[.[].sysmapid]') || exit 1
  if [ "$OLD_M" != "[]" ]; then api map.delete "$OLD_M" >/dev/null || exit 1; fi

  H="/$HOST_NAME"
  # rotulo do host da app com os golden signals ao vivo (expression macros)
  APP_LABEL="{HOST.NAME}  (Node.js :3000)
Throughput: {?last($H/tempconv.apm.throughput)}
Erro 4xx+5xx: {?last($H/tempconv.apm.error_rate)}
p95: {?last($H/tempconv.apm.latency.p95)}
Apdex: {{?last($H/tempconv.apm.apdex)}.fmtnum(3)}"

  MAPDEF=$(jq -nc --arg n "$MAP" --arg hid "$HID" --arg zid "$ZID" --arg app "$APP_LABEL" --arg g "$GRAFANA_URL" \
    --arg tsyn "$T_SYN" --arg tnod "$T_NODATA" --arg terr "$T_ERR" --arg t5xx "$T_5XX" \
    --arg tp95 "$T_P95" --arg tapd "$T_APDEX" --arg ttraf "$T_TRAF" '
    # icones 64px padrao do Zabbix
    def img(id; x; y; lbl; url): {selementid:id, elementtype:4, iconid_off:(
        {user:"69",loadgen:"180",prom:"102",tempo:"102",alloy:"59",loki:"135",exp:"96",
         web:"96",agent:"64",pg:"24",grafana:"175"}[id]),
      x:x, y:y, label:lbl, urls:(if url == "" then [] else [{name:"Abrir", url:url}] end)};
    def host(id; hostid; icon; x; y; lbl): {selementid:id, elementtype:0, elements:[{hostid:hostid}],
      iconid_off:icon, x:x, y:y, label:lbl};
    def link(a; b; color; lbl; draw; trig): {selementid1:a, selementid2:b, color:color, label:lbl,
      drawtype:draw, linktriggers:trig, indicator_type:(if (trig|length) > 0 then 1 else 0 end)};  # 1 = cor por trigger
    def lt(t; color): {triggerid:t, color:color, drawtype:2};
    {
      name:$n, width:1400, height:900, label_type:0, label_location:0, highlight:1, expandproblem:1,
      show_unack:0, markelements:1,
      selements:[
        img("user";     110;  70; "Usuario (navegador)"; ""),
        img("loadgen";  330;  70; "tempconv-loadgen\ncurl a cada 3s"; ""),
        host("app"; $hid; "150"; 220; 300; $app),
        img("prom";      70; 580; "Prometheus :9090\nscrape 15s"; "http://localhost:9090"),
        img("tempo";    310; 580; "Grafana Tempo :3200\nOTLP :4318"; ($g+"/explore")),
        img("alloy";    560; 450; "Grafana Alloy\nlogs via docker.sock"; "http://localhost:12345"),
        img("loki";     560; 700; "Loki :3100"; ""),
        img("exp";       70; 790; "node-exporter\ncAdvisor"; ""),
        img("grafana";  660;  70; "Grafana :3000\nPrometheus, Tempo, Loki, Zabbix"; ($g+"/d/tempconv-apm")),
        img("web";     1000;  70; "zabbix-web :8080\nfrontend + API"; ""),
        host("zbx"; $zid; "186"; 1000; 300; "{HOST.NAME}  (Zabbix 8.0)\nHTTP agent + web scenario"),
        img("agent";   1000; 580; "zabbix-agent2 :10050"; ""),
        img("pg";      1240; 300; "PostgreSQL 16"; "")
      ],
      links:[
        # trafego: fica laranja/vermelho com erro, latencia, Apdex ou falta de trafego
        link("user";    "app"; "AAAAAA"; "HTTP";          0; [lt($terr;"FF8000"), lt($t5xx;"DD0000"), lt($tp95;"FF8000"), lt($tapd;"FFC000")]),
        link("loadgen"; "app"; "AAAAAA"; "GET /convert";  0; [lt($ttraf;"FFC000"), lt($terr;"FF8000"), lt($t5xx;"DD0000")]),
        # telemetria
        link("prom";  "app";   "E6522C"; "scrape /metrics";                 0; []),
        link("app";   "tempo"; "E0A54B"; "OTLP/HTTP traces";                0; []),
        link("alloy"; "app";   "9A8FEA"; "le stdout (docker.sock)";         0; []),
        link("alloy"; "loki";  "9A8FEA"; "push";                            0; []),
        link("prom";  "tempo"; "E6522C"; "scrape + remote_write span-metrics"; 4; []),
        link("prom";  "exp";   "E6522C"; "scrape";                          0; []),
        # Zabbix: vermelho se o sintetico falhar ou a coleta parar
        link("zbx"; "app";   "D40000"; "HTTP agent /metrics (30s)\nweb scenario (X-Synthetic)"; 2; [lt($tsyn;"DD0000"), lt($tnod;"DD0000")]),
        link("zbx"; "agent"; "D40000"; "passivo";  0; []),
        link("zbx"; "pg";    "336791"; "SQL";      0; []),
        link("web"; "pg";    "336791"; "SQL";      0; []),
        link("web"; "zbx";   "D40000"; "trapper";  4; []),
        # consultas do Grafana
        link("grafana"; "prom";  "F46800"; "PromQL";  4; []),
        link("grafana"; "tempo"; "F46800"; "TraceQL"; 4; []),
        link("grafana"; "loki";  "F46800"; "LogQL";   4; []),
        link("grafana"; "web";   "F46800"; "API JSON-RPC"; 4; [])
      ]
    }') || exit 1
  MAPID=$(api map.create "$MAPDEF" | jq -er '.sysmapids[0]') || exit 1
  echo "   + sysmapid=$MAPID  -> ${ZBX_URL%/api_jsonrpc.php}/zabbix.php?action=map.view&sysmapid=$MAPID"
); then
  echo "   (aviso: mapa nao criado; itens, triggers e dashboard continuam ativos)" >&2
fi

echo ">> forca coleta imediata do item mestre"
api task.create "$(jq -nc --arg m "$MID" '[{type:6,request:{itemid:$m}}]')" >/dev/null 2>&1 || echo "   (task.create ignorada)"

echo
echo "OK. Host '$HOST_NAME' criado. Veja em Monitoring > Latest data (host $HOST_NAME)."
