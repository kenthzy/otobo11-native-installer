#!/usr/bin/env bash

OTAI_DASHBOARD_DIR="/opt/open-ticket-ai/dashboard"
OTAI_DASHBOARD_FILE="${OTAI_DASHBOARD_DIR}/index.html"

# shellcheck disable=SC2120
collect_model_stats() {
	local model_dir="${1:-/opt/open-ticket-ai/models}"
	local output="${2:-${OTAI_DASHBOARD_DIR}/model_stats.json}"

	mkdir -p "$(dirname "$output")"

	python3 -c "
import json, os, glob

models = []
for d in glob.glob('${model_dir}/*/'):
    name = os.path.basename(os.path.normpath(d))
    size = 0
    for root, dirs, files in os.walk(d):
        for f in files:
            fp = os.path.join(root, f)
            size += os.path.getsize(fp)
    is_fine_tuned = os.path.exists(os.path.join(d, 'label2id.json'))
    models.append({
        'name': name,
        'path': d,
        'size_mb': round(size / (1024*1024), 2),
        'fine_tuned': is_fine_tuned,
        'last_trained': os.path.getmtime(d) if is_fine_tuned else None
    })

with open('$output', 'w') as f:
    json.dump(models, f, indent=2)
" 2>/dev/null || warn "Failed to collect model stats"

	register_result "ModelStats" "OK" "Model statistics collected"
}

# shellcheck disable=SC2120
collect_prediction_stats() {
	local log_file="${1:-/var/log/open-ticket-ai/otai.log}"
	local output="${2:-${OTAI_DASHBOARD_DIR}/prediction_stats.json}"
	local lines="${3:-100}"

	mkdir -p "$(dirname "$output")"

	if [ ! -f "$log_file" ]; then
		echo '{"predictions": [], "total": 0}' >"$output"
		register_result "PredictionStats" "INFO" "No OTAI log file found"
		return
	fi

	python3 -c "
import json, re
from collections import Counter

log_path = '$log_file'
entries = []
with open(log_path) as f:
    for line in f.readlines()[-${lines}:]:
        entries.append(line.strip())

predictions = []
confidences = []
queues = Counter()

for line in entries:
    m = re.search(r'predicted.*?(\w+).*?confidence[=:]?\s*([\d.]+)', line, re.I)
    if m:
        predictions.append({'queue': m.group(1), 'confidence': float(m.group(2))})
        confidences.append(float(m.group(2)))
        queues[m.group(1)] += 1

avg_conf = round(sum(confidences)/len(confidences), 3) if confidences else 0
result = {
    'total_predictions': len(predictions),
    'avg_confidence': avg_conf,
    'queue_distribution': dict(queues),
    'predictions': predictions[-20:]
}

with open('$output', 'w') as f:
    json.dump(result, f, indent=2)
" 2>/dev/null || warn "Failed to parse prediction stats"

	register_result "PredictionStats" "OK" "Prediction statistics collected"
}

# shellcheck disable=SC2120
collect_queue_stats() {
	local otobo_root="${1:-/opt/otobo}"
	local output="${2:-${OTAI_DASHBOARD_DIR}/queue_stats.json}"

	mkdir -p "$(dirname "$output")"

	if [ -f "${otobo_root}/Kernel/Config.pm" ]; then
		python3 -c "
import json, subprocess, re

try:
    result = subprocess.run(
        ['sudo', '-u', 'otobo', 'perl', '-e', '''
            use Kernel::System::ObjectManager;
            local \$Kernel::OM = Kernel::System::ObjectManager->new();
            my \$QueueObject = \$Kernel::OM->Get('Kernel::System::Queue');
            my \$queues = \$QueueObject->QueueList();
            print \"QUEUES:\\n\";
            for my \$q (\@\$queues) {
                print \$q->{Name} . \"\\n\";
            }
        '''],
        capture_output=True, text=True, cwd='$otobo_root', timeout=30
    )
    queues = [l.strip() for l in result.stdout.split('\\n') if l.strip() and not l.startswith('QUEUES')]
except:
    queues = ['Raw', 'PostMaster', 'Internal', 'Junk']

with open('$output', 'w') as f:
    json.dump({'queues': queues, 'source': 'otobo'}, f, indent=2)
" 2>/dev/null || echo '{"queues": ["Raw", "PostMaster"], "source": "fallback"}' >"$output"
	else
		echo '{"queues": ["Raw"], "source": "default"}' >"$output"
	fi

	register_result "QueueStats" "OK" "Queue statistics collected"
}

generate_dashboard_html() {
	info "Generating AI dashboard HTML..."

	mkdir -p "$OTAI_DASHBOARD_DIR"

	local model_stats="${OTAI_DASHBOARD_DIR}/model_stats.json"
	local pred_stats="${OTAI_DASHBOARD_DIR}/prediction_stats.json"
	local queue_stats="${OTAI_DASHBOARD_DIR}/queue_stats.json"

	local models_json="[]"
	local preds_json='{"total_predictions": 0, "avg_confidence": 0}'
	local queues_json='{"queues": []}'

	[ -f "$model_stats" ] && models_json=$(cat "$model_stats")
	[ -f "$pred_stats" ] && preds_json=$(cat "$pred_stats")
	[ -f "$queue_stats" ] && queues_json=$(cat "$queue_stats")

	cat >"$OTAI_DASHBOARD_FILE" <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Open Ticket AI Dashboard</title>
<style>
body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; margin: 0; padding: 20px; background: #f5f5f5; color: #333; }
h1 { color: #1a1a2e; }
h2 { color: #16213e; border-bottom: 2px solid #0f3460; padding-bottom: 5px; }
.card { background: white; border-radius: 8px; padding: 20px; margin: 15px 0; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
.grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 15px; }
.stat { text-align: center; font-size: 2em; font-weight: bold; color: #0f3460; }
.stat-label { font-size: 0.9em; color: #666; }
table { width: 100%; border-collapse: collapse; }
th, td { padding: 10px; text-align: left; border-bottom: 1px solid #ddd; }
th { background: #0f3460; color: white; }
.status-ok { color: green; }
.status-warn { color: orange; }
.status-fail { color: red; }
</style>
</head>
<body>
<h1>Open Ticket AI Dashboard</h1>

<div class="grid">
  <div class="card">
    <div class="stat-label">Models Installed</div>
    <div class="stat" id="model-count">--</div>
  </div>
  <div class="card">
    <div class="stat-label">Total Predictions</div>
    <div class="stat" id="total-preds">--</div>
  </div>
  <div class="card">
    <div class="stat-label">Avg Confidence</div>
    <div class="stat" id="avg-conf">--</div>
  </div>
  <div class="card">
    <div class="stat-label">Service Status</div>
    <div class="stat" id="service-status">--</div>
  </div>
</div>

<div class="card">
  <h2>Installed Models</h2>
  <table id="models-table">
    <thead><tr><th>Name</th><th>Size</th><th>Fine-Tuned</th><th>Last Trained</th></tr></thead>
    <tbody></tbody>
  </table>
</div>

<div class="card">
  <h2>Recent Predictions</h2>
  <table id="preds-table">
    <thead><tr><th>Queue</th><th>Confidence</th></tr></thead>
    <tbody></tbody>
  </table>
</div>

<div class="card">
  <h2>Queue Distribution</h2>
  <table id="queue-table">
    <thead><tr><th>Queue</th><th>Count</th></tr></thead>
    <tbody></tbody>
  </table>
</div>

<script>
const models = $models_json;
const preds = $preds_json;
const queues = $queues_json;

document.getElementById('model-count').textContent = models.length || 0;
document.getElementById('total-preds').textContent = preds.total_predictions || 0;
document.getElementById('avg-conf').textContent = preds.avg_confidence
    ? (preds.avg_confidence * 100).toFixed(1) + '%' : '--';

const serviceStatus = document.getElementById('service-status');
fetch('/health').then(r => {
    serviceStatus.textContent = 'Running';
    serviceStatus.className = 'status-ok';
}).catch(() => {
    serviceStatus.textContent = 'Unknown';
    serviceStatus.className = 'status-warn';
});

const mtbody = document.querySelector('#models-table tbody');
models.forEach(m => {
    const tr = document.createElement('tr');
    tr.innerHTML = '<td>' + m.name + '</td><td>' + m.size_mb + ' MB</td><td>' +
        (m.fine_tuned ? 'Yes' : 'No') + '</td><td>' +
        (m.last_trained ? new Date(m.last_trained * 1000).toLocaleDateString() : '--') + '</td>';
    mtbody.appendChild(tr);
});

const ptbody = document.querySelector('#preds-table tbody');
if (preds.predictions) {
    preds.predictions.slice(-20).forEach(p => {
        const tr = document.createElement('tr');
        tr.innerHTML = '<td>' + p.queue + '</td><td>' + (p.confidence * 100).toFixed(1) + '%</td>';
        ptbody.appendChild(tr);
    });
}

const qtbody = document.querySelector('#queue-table tbody');
if (preds.queue_distribution) {
    Object.entries(preds.queue_distribution).forEach(([q, c]) => {
        const tr = document.createElement('tr');
        tr.innerHTML = '<td>' + q + '</td><td>' + c + '</td>';
        qtbody.appendChild(tr);
    });
}
</script>
</body>
</html>
HTML

	chown -R "${OTAI_USER}:${OTAI_GROUP}" "$OTAI_DASHBOARD_DIR"
	chmod 755 "$OTAI_DASHBOARD_DIR"
	chmod 644 "$OTAI_DASHBOARD_FILE"

	register_result "Dashboard" "OK" "Dashboard generated at $OTAI_DASHBOARD_FILE"
}

generate_dashboard() {
	info "Generating AI dashboard..."

	# shellcheck disable=SC2119
	collect_model_stats
	# shellcheck disable=SC2119
	collect_prediction_stats
	# shellcheck disable=SC2119
	collect_queue_stats
	generate_dashboard_html

	local ip
	ip=$(hostname -I 2>/dev/null | awk '{print $1}')
	echo ""
	echo "========================================"
	echo "  AI Dashboard"
	echo "========================================"
	echo "  File: $OTAI_DASHBOARD_FILE"
	echo "  URL:  http://${ip}:8080/dashboard (if OTAI server is running)"
	echo "========================================"
}
