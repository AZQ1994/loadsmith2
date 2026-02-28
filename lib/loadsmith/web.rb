# frozen_string_literal: true

require "webrick"
require "json"

module Loadsmith
  module Web
    class Server
      def initialize(screens:, scenarios:, config:, on_start_hook: nil, on_stop_hook: nil, port: 8089)
        @screens = screens
        @scenarios = scenarios
        @config = config
        @on_start_hook = on_start_hook
        @on_stop_hook = on_stop_hook
        @port = port
        @runner = nil
        @state = :idle # :idle, :running, :complete
      end

      def start
        @server = WEBrick::HTTPServer.new(
          Port: @port,
          BindAddress: "127.0.0.1",
          Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN),
          AccessLog: []
        )

        mount_routes

        trap("INT") { @server.shutdown }

        puts "Loadsmith Web UI: http://127.0.0.1:#{@port}"
        puts "Press Ctrl+C to stop"
        @server.start
      end

      private

      def mount_routes
        @server.mount_proc("/") { |req, res| handle_dashboard(req, res) }
        @server.mount_proc("/api/status") { |req, res| handle_status(req, res) }
        @server.mount_proc("/api/start") { |req, res| handle_start(req, res) }
        @server.mount_proc("/api/stop") { |req, res| handle_stop(req, res) }
        @server.mount_proc("/api/stream") { |req, res| handle_stream(req, res) }
      end

      def handle_dashboard(_req, res)
        res["Content-Type"] = "text/html; charset=utf-8"
        res.body = dashboard_html
      end

      def handle_status(_req, res)
        json_response(res, {
          state: @state.to_s,
          scenarios: @scenarios.keys.map(&:to_s),
          config: {
            base_url: @config.base_url,
            users: @config.users,
            spawn_rate: @config.spawn_rate,
            workers: @config.workers
          }
        })
      end

      def handle_start(req, res)
        if @state == :running
          json_response(res, { error: "Test already running" }, status: 409)
          return
        end

        body = JSON.parse(req.body || "{}")
        default_scenario = @scenarios.key?(:main) ? :main : @scenarios.keys.first
        scenario_name = (body["scenario"] || default_scenario).to_sym

        unless @scenarios.key?(scenario_name)
          json_response(res, { error: "Unknown scenario: #{scenario_name}" }, status: 400)
          return
        end

        # Apply config overrides from request
        @config.users = body["users"].to_i if body["users"].to_i > 0
        @config.spawn_rate = body["spawn_rate"].to_f if body["spawn_rate"].to_f > 0
        @config.workers = body["workers"].to_i if body["workers"].to_i > 0

        @state = :running
        runner_obj = Runner.new(
          scenario_name: scenario_name,
          screens: @screens,
          scenarios: @scenarios,
          config: @config,
          on_start_hook: @on_start_hook,
          on_stop_hook: @on_stop_hook
        )
        @runner = ThreadRunner.new(runner_obj, web_mode: true)
        @runner.start_async do
          @state = :complete
        end

        json_response(res, { state: "running", scenario: scenario_name.to_s })
      end

      def handle_stop(_req, res)
        if @state != :running || @runner.nil?
          json_response(res, { error: "No test running" }, status: 409)
          return
        end

        @runner.stop
        json_response(res, { state: "stopping" })
      end

      def handle_stream(_req, res)
        res["Content-Type"] = "text/event-stream"
        res["Cache-Control"] = "no-cache"
        res["Connection"] = "keep-alive"
        res["X-Accel-Buffering"] = "no"
        res.chunked = true

        server = self
        res.body = proc do |socket|
          begin
            loop do
              data = server.stream_snapshot
              socket.write("data: #{JSON.generate(data)}\n\n")
              sleep 1
            end
          rescue IOError, Errno::EPIPE, Errno::ECONNRESET
            # Client disconnected
          end
        end
      end

      public

      def stream_snapshot
        if @runner && (@state == :running || @state == :complete)
          data = @runner.stats.snapshot(
            elapsed: @runner.elapsed,
            active_users: @runner.active_count,
            total_users: @config.users
          )
          data[:state] = @state.to_s
          data
        else
          {
            state: @state.to_s,
            elapsed: 0,
            active_users: 0,
            total_users: @config.users,
            finished_users: 0,
            rps: 0,
            error_count: 0,
            total_requests: 0,
            total_errors: 0,
            endpoints: [],
            recent_errors: []
          }
        end
      end

      def json_response(res, data, status: 200)
        res.status = status
        res["Content-Type"] = "application/json"
        res.body = JSON.generate(data)
      end

      private

      def dashboard_html
        <<~'HTML'
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Loadsmith</title>
        <script src="https://cdn.jsdelivr.net/npm/chart.js@4"></script>
        <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #0f1117; color: #e1e4e8; min-height: 100vh; }

        .header { background: #161b22; border-bottom: 1px solid #30363d; padding: 16px 24px; display: flex; align-items: center; justify-content: space-between; }
        .header h1 { font-size: 20px; font-weight: 600; color: #f0f6fc; display: flex; align-items: center; gap: 10px; }
        .logo { width: 32px; height: 32px; }
        .state-badge { padding: 4px 12px; border-radius: 12px; font-size: 12px; font-weight: 600; text-transform: uppercase; }
        .state-idle { background: #30363d; color: #8b949e; }
        .state-running { background: #0d419d; color: #58a6ff; animation: pulse 2s infinite; }
        .state-complete { background: #238636; color: #3fb950; }

        @keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.7; } }

        .container { max-width: 1200px; margin: 0 auto; padding: 24px; }

        .controls { display: flex; gap: 12px; align-items: flex-end; margin-bottom: 24px; flex-wrap: wrap; }
        .controls select, .controls input { background: #21262d; color: #e1e4e8; border: 1px solid #30363d; border-radius: 6px; padding: 8px 12px; font-size: 14px; height: 38px; }
        .controls select { height: 38px; }
        .controls input { width: 80px; text-align: center; }
        .controls input:disabled, .controls select:disabled { opacity: 0.5; cursor: not-allowed; }
        .controls label { font-size: 12px; color: #8b949e; display: flex; flex-direction: column; gap: 4px; }
        .controls button { padding: 8px 20px; border-radius: 6px; font-size: 14px; font-weight: 600; cursor: pointer; border: none; transition: background 0.2s; height: 38px; }
        .btn-group { display: flex; gap: 8px; align-items: flex-end; }
        .btn-start { background: #238636; color: #fff; }
        .btn-start:hover { background: #2ea043; }
        .btn-start:disabled { background: #21262d; color: #484f58; cursor: not-allowed; }
        .btn-stop { background: #da3633; color: #fff; }
        .btn-stop:hover { background: #f85149; }
        .btn-stop:disabled { background: #21262d; color: #484f58; cursor: not-allowed; }

        .cards { display: grid; grid-template-columns: repeat(5, 1fr); gap: 16px; margin-bottom: 24px; }
        .card { background: #161b22; border: 1px solid #30363d; border-radius: 8px; padding: 16px; }
        .card .label { font-size: 12px; color: #8b949e; text-transform: uppercase; margin-bottom: 4px; }
        .card .value { font-size: 28px; font-weight: 700; font-variant-numeric: tabular-nums; }
        .card .value.green { color: #3fb950; }
        .card .value.blue { color: #58a6ff; }
        .card .value.orange { color: #d29922; }
        .card .value.red { color: #f85149; }

        .charts { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; margin-bottom: 24px; }
        .chart-box { background: #161b22; border: 1px solid #30363d; border-radius: 8px; padding: 16px; }
        .chart-box h3 { font-size: 14px; color: #8b949e; margin-bottom: 12px; }

        .table-box { background: #161b22; border: 1px solid #30363d; border-radius: 8px; padding: 16px; margin-bottom: 24px; overflow-x: auto; }
        .table-box h3 { font-size: 14px; color: #8b949e; margin-bottom: 12px; }
        table { width: 100%; border-collapse: collapse; font-size: 13px; font-variant-numeric: tabular-nums; }
        th { text-align: left; padding: 8px; color: #8b949e; border-bottom: 1px solid #30363d; font-weight: 600; }
        td { padding: 8px; border-bottom: 1px solid #21262d; }
        th.num, td.num { text-align: right; }

        .errors-box { background: #161b22; border: 1px solid #30363d; border-radius: 8px; padding: 16px; }
        .errors-box h3 { font-size: 14px; color: #8b949e; margin-bottom: 12px; }
        .error-item { padding: 8px; border-bottom: 1px solid #21262d; font-size: 13px; color: #f85149; }
        .error-item .user { color: #d29922; }
        .no-errors { color: #484f58; font-size: 13px; }

        @media (max-width: 768px) {
          .charts { grid-template-columns: 1fr; }
          .cards { grid-template-columns: repeat(2, 1fr); }
        }
        </style>
        </head>
        <body>

        <div class="header">
          <h1>
            <svg class="logo" viewBox="0 0 512 512" shape-rendering="geometricPrecision">
              <g transform="translate(0,50)">
                <defs>
                  <linearGradient id="anvilGrad" x1="0" y1="0" x2="1" y2="1">
                    <stop offset="0%" stop-color="#8b949e"/>
                    <stop offset="100%" stop-color="#555d66"/>
                  </linearGradient>
                </defs>
                <path d="M24 135L52 201 178 243 178 298 105 322 106 375 194 375 215 340 296 340 318 375 406 375 406 321 333 298 178 117 149 117 149 135Z" fill="url(#anvilGrad)"/>
                <polygon points="345,25 279,117 345,283 411,117" fill="#CC342D"/>
                <polygon points="257,25 345,25 279,117 201,117" fill="#B52A23"/>
                <polygon points="433,25 345,25 411,117 489,117" fill="#B52A23"/>
                <polygon points="201,117 279,117 345,283" fill="#E14A42"/>
                <polygon points="489,117 411,117 345,283" fill="#8F1B16"/>
              </g>
            </svg>
            <span>LOAD<span style="color:#E63946">SMITH</span></span>
          </h1>
          <span id="stateBadge" class="state-badge state-idle">IDLE</span>
        </div>

        <div class="container">
          <div class="controls">
            <label>Scenario<select id="scenarioSelect"></select></label>
            <label>User Pool<input type="number" id="cfgUsers" min="1"></label>
            <label>Spawn/s<input type="number" id="cfgSpawnRate" min="0.1" step="0.1"></label>
            <label>Concurrent<input type="number" id="cfgWorkers" min="1"></label>
            <div class="btn-group">
              <button id="startBtn" class="btn-start" onclick="startTest()">Start</button>
              <button id="stopBtn" class="btn-stop" onclick="stopTest()" disabled>Stop</button>
            </div>
          </div>

          <div class="cards">
            <div class="card"><div class="label">RPS</div><div class="value blue" id="cardRps">0</div></div>
            <div class="card"><div class="label">Active Users</div><div class="value green" id="cardActive">0</div></div>
            <div class="card"><div class="label">Total Requests</div><div class="value" id="cardTotal">0</div></div>
            <div class="card"><div class="label">Error Rate</div><div class="value orange" id="cardErrorRate">0%</div></div>
            <div class="card"><div class="label">Duration</div><div class="value" id="cardDuration">00:00</div></div>
          </div>

          <div class="charts">
            <div class="chart-box">
              <h3>Requests per Second</h3>
              <canvas id="rpsChart"></canvas>
            </div>
            <div class="chart-box">
              <h3>Response Time (ms)</h3>
              <canvas id="latencyChart"></canvas>
            </div>
          </div>

          <div class="table-box">
            <h3>Endpoints (Cumulative)</h3>
            <table>
              <thead>
                <tr>
                  <th>Endpoint</th>
                  <th class="num">Count</th>
                  <th class="num">Avg</th>
                  <th class="num">Min</th>
                  <th class="num">Max</th>
                  <th class="num">P50</th>
                  <th class="num">P95</th>
                  <th class="num">P99</th>
                  <th class="num">Err</th>
                </tr>
              </thead>
              <tbody id="endpointBody"></tbody>
            </table>
          </div>

          <div class="errors-box">
            <h3>Recent Errors</h3>
            <div id="errorsContainer"><span class="no-errors">No errors</span></div>
          </div>
        </div>

        <script>
        const MAX_POINTS = 60;
        let evtSource = null;

        // Chart setup
        const chartDefaults = {
          responsive: true,
          animation: false,
          scales: {
            x: { display: false },
            y: { beginAtZero: true, grid: { color: '#21262d' }, ticks: { color: '#8b949e' } }
          },
          plugins: { legend: { display: false } }
        };

        const rpsChart = new Chart(document.getElementById('rpsChart'), {
          type: 'line',
          data: {
            labels: [],
            datasets: [{
              data: [],
              borderColor: '#58a6ff',
              backgroundColor: 'rgba(88,166,255,0.1)',
              fill: true,
              tension: 0.3,
              pointRadius: 0,
              borderWidth: 2
            }]
          },
          options: { ...chartDefaults }
        });

        const latencyChart = new Chart(document.getElementById('latencyChart'), {
          type: 'line',
          data: {
            labels: [],
            datasets: [{
              label: 'Avg',
              data: [],
              borderColor: '#3fb950',
              tension: 0.3,
              pointRadius: 0,
              borderWidth: 2
            }, {
              label: 'P95',
              data: [],
              borderColor: '#d29922',
              tension: 0.3,
              pointRadius: 0,
              borderWidth: 1,
              borderDash: [4, 2]
            }]
          },
          options: {
            ...chartDefaults,
            plugins: {
              legend: {
                display: true,
                labels: { color: '#8b949e', boxWidth: 12, padding: 8 }
              }
            }
          }
        });

        function pushPoint(chart, label, ...values) {
          chart.data.labels.push(label);
          values.forEach((v, i) => chart.data.datasets[i].data.push(v));
          if (chart.data.labels.length > MAX_POINTS) {
            chart.data.labels.shift();
            chart.data.datasets.forEach(ds => ds.data.shift());
          }
          chart.update('none');
        }

        // Load status and scenarios
        fetch('/api/status').then(r => r.json()).then(data => {
          const sel = document.getElementById('scenarioSelect');
          data.scenarios.forEach(s => {
            const opt = document.createElement('option');
            opt.value = s;
            opt.textContent = ':' + s;
            if (s === 'main') opt.selected = true;
            sel.appendChild(opt);
          });
          document.getElementById('cfgUsers').value = data.config.users;
          document.getElementById('cfgSpawnRate').value = data.config.spawn_rate;
          document.getElementById('cfgWorkers').value = data.config.workers;
          updateState(data.state);
        });

        function updateState(state) {
          const badge = document.getElementById('stateBadge');
          badge.textContent = state.toUpperCase();
          badge.className = 'state-badge state-' + state;
          const isRunning = (state === 'running');
          document.getElementById('startBtn').disabled = isRunning;
          document.getElementById('stopBtn').disabled = !isRunning;
          document.getElementById('scenarioSelect').disabled = isRunning;
          document.getElementById('cfgUsers').disabled = isRunning;
          document.getElementById('cfgSpawnRate').disabled = isRunning;
          document.getElementById('cfgWorkers').disabled = isRunning;
        }

        function startTest() {
          const scenario = document.getElementById('scenarioSelect').value;
          // Reset charts
          rpsChart.data.labels = [];
          rpsChart.data.datasets[0].data = [];
          rpsChart.update('none');
          latencyChart.data.labels = [];
          latencyChart.data.datasets.forEach(ds => { ds.data = []; });
          latencyChart.update('none');

          fetch('/api/start', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              scenario,
              users: parseInt(document.getElementById('cfgUsers').value) || undefined,
              spawn_rate: parseFloat(document.getElementById('cfgSpawnRate').value) || undefined,
              workers: parseInt(document.getElementById('cfgWorkers').value) || undefined
            })
          }).then(r => r.json()).then(data => {
            if (data.state === 'running') {
              updateState('running');
              startSSE();
            }
          });
        }

        function stopTest() {
          fetch('/api/stop', { method: 'POST' }).then(r => r.json());
        }

        function startSSE() {
          if (evtSource) evtSource.close();
          evtSource = new EventSource('/api/stream');
          evtSource.onmessage = (event) => {
            const d = JSON.parse(event.data);
            updateState(d.state);

            // Cards
            document.getElementById('cardRps').textContent = d.rps;
            document.getElementById('cardActive').textContent = d.active_users;
            document.getElementById('cardTotal').textContent = d.total_requests;
            const errRate = d.total_requests > 0
              ? (d.total_errors / d.total_requests * 100).toFixed(1) + '%'
              : '0%';
            document.getElementById('cardErrorRate').textContent = errRate;
            const mm = String(Math.floor(d.elapsed / 60)).padStart(2, '0');
            const ss = String(d.elapsed % 60).padStart(2, '0');
            document.getElementById('cardDuration').textContent = mm + ':' + ss;

            // Charts
            const timeLabel = mm + ':' + ss;
            pushPoint(rpsChart, timeLabel, d.rps);

            // Avg latency across all endpoints
            let avgAll = 0, p95All = 0;
            if (d.endpoints && d.endpoints.length > 0) {
              const totalCount = d.endpoints.reduce((s, e) => s + e.count, 0);
              if (totalCount > 0) {
                avgAll = d.endpoints.reduce((s, e) => s + e.avg * e.count, 0) / totalCount;
                p95All = Math.max(...d.endpoints.map(e => e.p95));
              }
            }
            pushPoint(latencyChart, timeLabel, avgAll.toFixed(1), p95All.toFixed(1));

            // Endpoint table (cumulative)
            const tbody = document.getElementById('endpointBody');
            tbody.innerHTML = '';
            (d.cumulative_endpoints || []).forEach(ep => {
              const tr = document.createElement('tr');
              tr.innerHTML = `<td>${esc(ep.name)}</td><td class="num">${ep.count}</td><td class="num">${ep.avg.toFixed(1)}</td><td class="num">${ep.min.toFixed(1)}</td><td class="num">${ep.max.toFixed(1)}</td><td class="num">${ep.p50.toFixed(1)}</td><td class="num">${ep.p95.toFixed(1)}</td><td class="num">${ep.p99.toFixed(1)}</td><td class="num">${ep.errors}</td>`;
              tbody.appendChild(tr);
            });

            // Errors
            const errDiv = document.getElementById('errorsContainer');
            if (d.recent_errors && d.recent_errors.length > 0) {
              errDiv.innerHTML = d.recent_errors.map(e =>
                `<div class="error-item"><span class="user">User#${e.user_id}</span> in :${esc(e.screen)} &mdash; ${esc(e.message)}</div>`
              ).join('');
            } else {
              errDiv.innerHTML = '<span class="no-errors">No errors</span>';
            }

            // Auto-stop SSE when complete
            if (d.state === 'complete') {
              evtSource.close();
              evtSource = null;
            }
          };
        }

        function esc(s) {
          if (!s) return '';
          const d = document.createElement('div');
          d.textContent = s;
          return d.innerHTML;
        }
        </script>
        </body>
        </html>
        HTML
      end
    end
  end
end
