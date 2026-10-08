'use strict';

const express = require('express');
const client = require('prom-client');
const otel = require('@opentelemetry/api');

const app = express();
const PORT = process.env.PORT || 3000;

// log estruturado em JSON no stdout; inclui trace_id/span_id do span ativo
// para permitir correlacao logs <-> traces no Grafana (Loki -> Tempo).
function log(level, msg, extra = {}) {
  const span = otel.trace.getActiveSpan();
  const ctx = span ? span.spanContext() : null;
  process.stdout.write(JSON.stringify({
    ts: new Date().toISOString(),
    level,
    msg,
    service: process.env.OTEL_SERVICE_NAME || 'tempconv',
    ...(ctx ? { trace_id: ctx.traceId, span_id: ctx.spanId } : {}),
    ...extra,
  }) + '\n');
}

// ---------------------------------------------------------------------------
// Métricas Prometheus
// ---------------------------------------------------------------------------
const register = new client.Registry();
register.setDefaultLabels({ app: 'tempconv' });
client.collectDefaultMetrics({ register, prefix: 'tempconv_' });

const conversionsTotal = new client.Counter({
  name: 'temp_conversions_total',
  help: 'Total de conversoes de temperatura realizadas, por unidade de origem',
  labelNames: ['conversion'],
  registers: [register],
});

const conversionErrors = new client.Counter({
  name: 'temp_conversion_errors_total',
  help: 'Total de requisicoes de conversao invalidas',
  registers: [register],
});

const lastOutput = new client.Gauge({
  name: 'temp_conversion_last_output',
  help: 'Ultimo valor convertido, por unidade de saida',
  labelNames: ['unit'],
  registers: [register],
});

const httpDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'Duracao das requisicoes HTTP em segundos',
  // synthetic="1" marca checagens de monitoramento (header X-Synthetic), p/ que
  // nao distorçam throughput/erro/Apdex calculados a partir deste histograma
  labelNames: ['method', 'route', 'status', 'synthetic'],
  // buckets sub-ms: as conversoes levam << 1ms; sem eles os quantis so interpolam 0..1ms
  buckets: [0.0001, 0.00025, 0.0005, 0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1],
  registers: [register],
});

// mede a duracao de toda requisicao + loga
app.use((req, res, next) => {
  const end = httpDuration.startTimer();
  const started = Date.now();
  res.on('finish', () => {
    // rota sem match (404) vira um label fixo: req.path criaria uma serie por URL
    const route = req.route ? req.route.path : 'unmatched';
    const synthetic = req.get('X-Synthetic') ? '1' : '0';
    end({ method: req.method, route, status: res.statusCode, synthetic });
    if (route !== '/metrics') {
      const level = res.statusCode >= 400 ? 'error' : 'info';
      log(level, `${req.method} ${req.originalUrl} ${res.statusCode}`, {
        method: req.method,
        route,
        status: res.statusCode,
        duration_ms: Date.now() - started,
      });
    }
  });
  next();
});

// ---------------------------------------------------------------------------
// Logica de conversao
// ---------------------------------------------------------------------------
const round = (n) => Math.round(n * 100) / 100;

function convertFromCelsius(c) {
  return { celsius: round(c), fahrenheit: round(c * 9 / 5 + 32), kelvin: round(c + 273.15) };
}

function run(source, rawValue) {
  const v = parseFloat(rawValue);
  if (Number.isNaN(v)) return null;

  let c;
  if (source === 'celsius') c = v;
  else if (source === 'fahrenheit') c = (v - 32) * 5 / 9;
  else if (source === 'kelvin') c = v - 273.15;
  else return null;

  const out = convertFromCelsius(c);
  conversionsTotal.inc({ conversion: `${source}_to_all` });
  lastOutput.set({ unit: 'celsius' }, out.celsius);
  lastOutput.set({ unit: 'fahrenheit' }, out.fahrenheit);
  lastOutput.set({ unit: 'kelvin' }, out.kelvin);
  return out;
}

// inicializa as series para que Prometheus/Zabbix tenham dados desde o boot
['celsius', 'fahrenheit', 'kelvin'].forEach((s) => run(s, 0));

// ---------------------------------------------------------------------------
// Rotas
// ---------------------------------------------------------------------------
app.get('/convert', (req, res) => {
  const source = ['celsius', 'fahrenheit', 'kelvin'].find((s) => req.query[s] !== undefined);
  if (!source) {
    conversionErrors.inc();
    return res.status(400).json({ error: 'informe ?celsius= , ?fahrenheit= ou ?kelvin=' });
  }

  const span = otel.trace.getActiveSpan();
  if (span) span.setAttribute('tempconv.source_unit', source);

  const out = run(source, req.query[source]);
  if (!out) {
    conversionErrors.inc();
    if (span) span.setAttribute('tempconv.invalid', true);
    log('error', 'valor numerico invalido', { source, raw: String(req.query[source]).slice(0, 32) });
    return res.status(400).json({ error: 'valor numerico invalido' });
  }

  if (span) span.setAttribute('tempconv.celsius_out', out.celsius);
  res.json({ input: { [source]: parseFloat(req.query[source]) }, ...out });
});

app.get('/health', (req, res) => res.json({ status: 'ok', uptime: process.uptime() }));

app.get('/metrics', async (req, res) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});

app.get('/', (req, res) => {
  res.type('html').send(`<!doctype html>
<meta charset="utf-8">
<title>Conversor de Temperatura</title>
<style>
  body{font-family:system-ui,sans-serif;max-width:32rem;margin:3rem auto;padding:0 1rem}
  input,select,button{font-size:1rem;padding:.4rem}
  pre{background:#f4f4f4;padding:1rem;border-radius:.5rem;overflow:auto}
</style>
<h1>Conversor de Temperatura</h1>
<p>
  <input id="v" type="number" value="25" step="0.1">
  <select id="u">
    <option value="celsius">°C</option>
    <option value="fahrenheit">°F</option>
    <option value="kelvin">K</option>
  </select>
  <button onclick="go()">Converter</button>
</p>
<pre id="out">—</pre>
<p><a href="/metrics">/metrics</a> · <a href="/health">/health</a></p>
<script>
async function go(){
  const v=document.getElementById('v').value, u=document.getElementById('u').value;
  const r=await fetch('/convert?'+u+'='+encodeURIComponent(v));
  document.getElementById('out').textContent=JSON.stringify(await r.json(),null,2);
}
go();
</script>`);
});

app.listen(PORT, () => log('info', `tempconv ouvindo na porta ${PORT}`));
