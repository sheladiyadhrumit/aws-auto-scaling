#!/bin/bash
# =============================================
#  CloudOps — user-data.sh
#  AWS Launch Template User Data Script
#  Project: auto-scaling-aws (Project 2)
#
#  WHAT IS THIS FILE?
#  ──────────────────
#  When AWS Auto Scaling Group launches a NEW EC2
#  instance, it runs this script automatically
#  at first boot — before the server is added to
#  the load balancer and receives any traffic.
#
#  Think of it as: "instructions for a brand new
#  server to set itself up without any human help."
#
#  HOW TO USE:
#  ──────────────────
#  1. Go to AWS Console → EC2 → Launch Templates
#  2. Click Create Launch Template
#  3. Scroll down to "Advanced details"
#  4. Paste this ENTIRE script into "User data"
#  5. Save the template — done!
#
#  Every new instance the ASG launches will run
#  this script automatically at startup.
# =============================================

# ── SHELL OPTIONS ──────────────────────────────────────
# Exit immediately if any command fails
# This prevents the script running further if something
# goes wrong early — e.g. if apt-get fails, stop there
set -e

# Print each command to the system log before running it
# You can see these logs later with: sudo cat /var/log/user-data.log
set -x

# ── LOG EVERYTHING ─────────────────────────────────────
# Redirect ALL output (stdout + stderr) to a log file
# This is critical for debugging — if something goes wrong
# you can SSH in and read exactly what happened
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

echo "============================================="
echo "  CloudOps Auto Scaling — EC2 User Data"
echo "  Starting at: $(date)"
echo "  Instance ID: $(curl -s http://169.254.169.254/latest/meta-data/instance-id)"
echo "  Region:      $(curl -s http://169.254.169.254/latest/meta-data/placement/region)"
echo "============================================="


# ─────────────────────────────────────────────
# SECTION 1: SYSTEM UPDATE
#
# Always update first on a fresh instance.
# AWS AMIs are periodically updated but may be
# a few days/weeks old when you use them.
# -y = answer yes to all prompts automatically
# DEBIAN_FRONTEND=noninteractive = don't show
#   interactive configuration dialogs
# ─────────────────────────────────────────────
echo ""
echo ">>> [1/6] Updating system packages..."

export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get upgrade -y -o Dpkg::Options::="--force-confold"

echo ">>> System updated."


# ─────────────────────────────────────────────
# SECTION 2: INSTALL nginx
#
# nginx is a fast, lightweight web server.
# We use it to serve our static HTML/CSS/JS files.
#
# Why nginx instead of Apache?
# - Smaller memory footprint (important for t2.micro)
# - Faster at serving static files
# - Used widely in production
# ─────────────────────────────────────────────
echo ""
echo ">>> [2/6] Installing nginx..."

apt-get install -y nginx

# Start nginx right now
# systemctl start = turn it on immediately
systemctl start nginx

# Enable nginx to start automatically on every reboot
# Without this: nginx would not start after instance restart
systemctl enable nginx

echo ">>> nginx installed and running."


# ─────────────────────────────────────────────
# SECTION 3: DEPLOY THE WEBSITE
#
# /var/www/html is the default folder nginx
# looks for files to serve. This is where we
# put our index.html, style.css, script.js.
#
# In a real production setup you would pull
# from S3, CodeDeploy, or a git repo.
# Here we create the files directly in the
# script so the instance is fully self-contained.
# ─────────────────────────────────────────────
echo ""
echo ">>> [3/6] Deploying website files..."

# Get instance metadata — used in the HTML page so
# you can see WHICH instance is serving the request
# This is extremely useful for verifying load balancer
# is spreading traffic across multiple instances
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
INSTANCE_AZ=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)
INSTANCE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
INSTANCE_TYPE=$(curl -s http://169.254.169.254/latest/meta-data/instance-type)
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
LAUNCH_TIME=$(date '+%Y-%m-%d %H:%M:%S UTC')

# Remove the default nginx welcome page
rm -rf /var/www/html/*

# Write the website index.html
# The heredoc (cat << 'EOF') writes everything
# between EOF markers into the file.
# Variables like $INSTANCE_ID are expanded BEFORE
# writing — so each instance gets its own unique HTML.
cat > /var/www/html/index.html << HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
  <title>CloudOps — Auto Scaling on AWS</title>
  <link href="https://fonts.googleapis.com/css2?family=Syne:wght@400;700;800&family=DM+Mono:wght@300;400&family=Instrument+Sans:wght@400;500&display=swap" rel="stylesheet">
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    html { scroll-behavior: smooth; }
    :root {
      --bg:      #080b12;
      --bg2:     #0d1117;
      --bg3:     #131820;
      --border:  rgba(255,255,255,0.07);
      --border2: rgba(255,255,255,0.13);
      --text:    #e2e8f5;
      --text2:   #7e8fa8;
      --text3:   #3d4e63;
      --accent:  #3b7ef8;
      --accent2: #6ea3ff;
      --green:   #22d474;
      --amber:   #f0a429;
      --font-d: 'Syne', sans-serif;
      --font-b: 'Instrument Sans', sans-serif;
      --font-m: 'DM Mono', monospace;
    }
    body {
      background: var(--bg); color: var(--text);
      font-family: var(--font-b); font-size: 16px;
      line-height: 1.7; overflow-x: hidden;
    }
    body::before {
      content: ''; position: fixed; inset: 0;
      background-image:
        linear-gradient(rgba(59,126,248,0.03) 1px, transparent 1px),
        linear-gradient(90deg, rgba(59,126,248,0.03) 1px, transparent 1px);
      background-size: 48px 48px; pointer-events: none; z-index: 0;
    }
    ::-webkit-scrollbar { width: 5px; }
    ::-webkit-scrollbar-track { background: var(--bg); }
    ::-webkit-scrollbar-thumb { background: var(--bg3); border-radius: 99px; }

    /* NAV */
    nav {
      position: fixed; top: 0; left: 0; right: 0; z-index: 100;
      height: 60px; display: flex; align-items: center; padding: 0 2rem;
      background: rgba(8,11,18,0.85); backdrop-filter: blur(12px);
      border-bottom: 1px solid var(--border);
    }
    .nav-inner {
      width: 100%; max-width: 1180px; margin: 0 auto;
      display: flex; align-items: center; gap: 2rem;
    }
    .logo {
      display: flex; align-items: center; gap: 9px;
      font-family: var(--font-d); font-weight: 800; font-size: 17px;
      letter-spacing: -.02em;
    }
    .logo-hex {
      width: 28px; height: 28px; background: var(--accent);
      clip-path: polygon(50% 0%,100% 25%,100% 75%,50% 100%,0% 75%,0% 25%);
      display: flex; align-items: center; justify-content: center;
      font-size: 10px; font-weight: 700; color: #fff; font-family: var(--font-m);
    }
    .nav-right {
      margin-left: auto; display: flex; align-items: center; gap: 12px;
    }
    .badge {
      display: flex; align-items: center; gap: 7px;
      font-family: var(--font-m); font-size: 11px;
      padding: 5px 12px; border-radius: 99px; letter-spacing: .02em;
    }
    .badge-green { color: var(--green); background: rgba(34,212,116,0.1); border: 1px solid rgba(34,212,116,0.22); }
    .badge-blue  { color: var(--accent2); background: rgba(59,126,248,0.1); border: 1px solid rgba(59,126,248,0.22); }
    .pulse {
      width: 7px; height: 7px; border-radius: 50%; background: var(--green); flex-shrink: 0;
      animation: pulse 2.2s ease-in-out infinite;
    }
    @keyframes pulse {
      0%,100% { opacity:1; box-shadow: 0 0 0 0 rgba(34,212,116,.5); }
      50%      { opacity:.8; box-shadow: 0 0 0 5px rgba(34,212,116,0); }
    }

    /* HERO */
    .hero {
      min-height: 100vh; display: flex; flex-direction: column;
      justify-content: center; align-items: center; text-align: center;
      padding: 110px 2rem 80px; position: relative; z-index: 1;
    }
    .hero-eyebrow {
      display: inline-flex; align-items: center; gap: 8px;
      font-family: var(--font-m); font-size: 11px; color: var(--accent2);
      background: rgba(59,126,248,0.12); border: 1px solid rgba(59,126,248,0.25);
      padding: 5px 14px; border-radius: 99px; margin-bottom: 1.75rem; letter-spacing: .03em;
    }
    .hero-title {
      font-family: var(--font-d); font-size: clamp(2.8rem,6vw,5rem);
      font-weight: 800; line-height: 1.05; letter-spacing: -.045em; margin-bottom: 1.25rem;
    }
    .hero-title em { font-style: normal; color: var(--accent); }
    .hero-sub {
      font-size: 1rem; color: var(--text2); line-height: 1.75;
      max-width: 560px; margin: 0 auto 2.5rem;
    }

    /* INSTANCE CARD — the star of the show */
    .instance-card {
      background: var(--bg2); border: 1px solid var(--border);
      border-radius: 16px; padding: 0; overflow: hidden;
      width: 100%; max-width: 560px; margin: 0 auto 2.5rem;
      box-shadow: 0 0 60px rgba(59,126,248,0.1), 0 20px 60px rgba(0,0,0,0.4);
      animation: cardIn 0.6s ease both 0.2s;
    }
    @keyframes cardIn {
      from { opacity:0; transform: translateY(20px); }
      to   { opacity:1; transform: translateY(0); }
    }
    .card-header {
      background: var(--bg3); border-bottom: 1px solid var(--border);
      padding: 14px 20px; display: flex; align-items: center; justify-content: space-between;
    }
    .card-header-title {
      font-family: var(--font-m); font-size: 12px; color: var(--text2); letter-spacing: .03em;
    }
    .card-header-id {
      font-family: var(--font-m); font-size: 12px; color: var(--accent2); letter-spacing: .02em;
    }
    .card-body { padding: 6px 0; }
    .card-row {
      display: flex; justify-content: space-between; align-items: center;
      padding: 11px 20px; border-bottom: 1px solid var(--border);
    }
    .card-row:last-child { border-bottom: none; }
    .card-key  { font-family: var(--font-m); font-size: 11px; color: var(--text3); letter-spacing: .04em; }
    .card-val  { font-family: var(--font-m); font-size: 12px; color: var(--text); font-weight: 400; }
    .card-val.green { color: var(--green); }
    .card-val.blue  { color: var(--accent2); }
    .card-val.amber { color: var(--amber); }

    /* REFRESH HINT */
    .refresh-hint {
      font-family: var(--font-m); font-size: 12px; color: var(--text3);
      margin-bottom: 2.5rem; letter-spacing: .02em;
    }
    .refresh-hint span { color: var(--accent2); }

    /* METRICS */
    .metrics-row {
      display: flex; align-items: center; gap: 2.5rem; justify-content: center;
      flex-wrap: wrap;
    }
    .metric { text-align: center; }
    .metric-val {
      font-family: var(--font-d); font-size: 2rem; font-weight: 800;
      color: var(--text); line-height: 1; letter-spacing: -.04em;
    }
    .metric-val em { font-style: normal; color: var(--accent); font-size: 1.2rem; }
    .metric-label { font-family: var(--font-m); font-size: 10px; color: var(--text3); letter-spacing: .08em; text-transform: uppercase; margin-top: 4px; }
    .metric-sep   { width: 1px; height: 40px; background: var(--border2); }

    /* SECTIONS */
    section { padding: 88px 0; position: relative; z-index: 1; }
    .section-dark { background: var(--bg2); border-top: 1px solid var(--border); border-bottom: 1px solid var(--border); }
    .container { max-width: 1180px; margin: 0 auto; padding: 0 2rem; }
    .eyebrow { font-family: var(--font-m); font-size: 11px; color: var(--accent); letter-spacing: .08em; margin-bottom: .6rem; display: block; }
    .section-title {
      font-family: var(--font-d); font-size: clamp(1.75rem,3vw,2.5rem);
      font-weight: 800; letter-spacing: -.035em; margin-bottom: 2.5rem;
    }

    /* ARCHITECTURE */
    .arch-grid { display: grid; grid-template-columns: repeat(3,1fr); gap: 14px; }
    .arch-card {
      background: var(--bg); border: 1px solid var(--border); border-radius: 12px; padding: 22px;
      display: flex; flex-direction: column; gap: 10px;
      opacity: 0; transform: translateY(16px);
      transition: border-color .2s, box-shadow .2s;
    }
    .arch-card.visible { animation: rise .5s ease forwards; }
    @keyframes rise { to { opacity:1; transform: translateY(0); } }
    .arch-card:hover { border-color: rgba(59,126,248,.35); box-shadow: 0 0 28px rgba(59,126,248,.08); }
    .ac-icon { font-size: 28px; }
    .ac-label {
      font-family: var(--font-m); font-size: 10.5px; color: var(--accent2);
      background: rgba(59,126,248,0.12); border: 1px solid rgba(59,126,248,0.2);
      padding: 2px 8px; border-radius: 4px; width: fit-content; letter-spacing: .02em;
    }
    .ac-name { font-family: var(--font-d); font-size: 16px; font-weight: 700; color: var(--text); letter-spacing: -.02em; }
    .ac-desc { font-size: 13px; color: var(--text2); line-height: 1.65; flex: 1; }
    .ac-tag {
      font-family: var(--font-m); font-size: 10.5px; color: var(--green);
      background: rgba(34,212,116,0.1); border: 1px solid rgba(34,212,116,0.2);
      padding: 2px 9px; border-radius: 99px; width: fit-content; letter-spacing: .03em;
    }

    /* FLOW */
    .flow-grid { display: grid; grid-template-columns: repeat(4,1fr); gap: 0; position: relative; }
    .flow-grid::before {
      content: ''; position: absolute; top: 38px; left: 12%; right: 12%; height: 2px;
      background: linear-gradient(90deg, transparent, var(--border2) 20%, var(--accent) 80%, transparent);
    }
    .flow-step {
      padding: 0 .75rem; display: flex; flex-direction: column; align-items: center; text-align: center;
      opacity: 0; transform: translateY(14px); transition: opacity .4s, transform .4s;
    }
    .flow-step.visible { opacity:1; transform: translateY(0); }
    .flow-icon {
      width: 48px; height: 48px; border-radius: 50%; background: var(--bg3);
      border: 1px solid var(--border2); display: flex; align-items: center; justify-content: center;
      font-size: 20px; margin-bottom: 14px; position: relative; z-index: 1;
      transition: border-color .2s, background .2s;
    }
    .flow-step:hover .flow-icon { border-color: var(--accent); background: rgba(59,126,248,0.12); }
    .flow-num { font-family: var(--font-m); font-size: 10px; color: var(--text3); letter-spacing: .05em; margin-bottom: 8px; }
    .flow-title { font-family: var(--font-d); font-size: 14px; font-weight: 700; color: var(--text); margin-bottom: 6px; letter-spacing: -.02em; }
    .flow-desc { font-size: 12px; color: var(--text2); line-height: 1.6; }

    /* FOOTER */
    footer { background: var(--bg2); border-top: 1px solid var(--border); padding: 48px 0; position: relative; z-index: 1; }
    .footer-inner {
      display: flex; justify-content: space-between; align-items: center;
      flex-wrap: wrap; gap: 1rem;
    }
    .footer-copy { font-family: var(--font-m); font-size: 12px; color: var(--text3); }
    .chip-row { display: flex; flex-wrap: wrap; gap: 7px; }
    .chip {
      font-family: var(--font-m); font-size: 11px; color: var(--text2);
      background: var(--bg3); border: 1px solid var(--border2);
      padding: 4px 10px; border-radius: 5px; letter-spacing: .03em;
    }

    @media (max-width: 700px) {
      .arch-grid { grid-template-columns: 1fr; }
      .flow-grid { grid-template-columns: 1fr 1fr; }
      .flow-grid::before { display: none; }
      .metrics-row { gap: 1.5rem; }
    }
  </style>
</head>
<body>

  <nav>
    <div class="nav-inner">
      <div class="logo">
        <div class="logo-hex">CO</div>
        CloudOps
      </div>
      <div class="nav-right">
        <span class="badge badge-blue">Auto Scaling Group</span>
        <span class="badge badge-green"><span class="pulse"></span>Instance Healthy</span>
      </div>
    </div>
  </nav>

  <div class="hero">
    <div class="hero-eyebrow">
      <span class="pulse"></span>
      AWS Auto Scaling — This instance launched automatically
    </div>
    <h1 class="hero-title">
      One of <em>many.</em><br>
      Scaled by AWS.
    </h1>
    <p class="hero-sub">
      You are looking at a server that was launched automatically by an
      AWS Auto Scaling Group. No human clicked "launch" — the ASG did it
      based on CPU load, then the Load Balancer routed you here.
    </p>

    <!-- THE INSTANCE INFO CARD — shows unique details per server -->
    <div class="instance-card">
      <div class="card-header">
        <span class="card-header-title">// serving this request</span>
        <span class="card-header-id">${INSTANCE_ID}</span>
      </div>
      <div class="card-body">
        <div class="card-row">
          <span class="card-key">Instance ID</span>
          <span class="card-val blue">${INSTANCE_ID}</span>
        </div>
        <div class="card-row">
          <span class="card-key">Instance type</span>
          <span class="card-val">${INSTANCE_TYPE}</span>
        </div>
        <div class="card-row">
          <span class="card-key">Availability zone</span>
          <span class="card-val amber">${INSTANCE_AZ}</span>
        </div>
        <div class="card-row">
          <span class="card-key">Private IP</span>
          <span class="card-val">${INSTANCE_IP}</span>
        </div>
        <div class="card-row">
          <span class="card-key">Region</span>
          <span class="card-val">${REGION}</span>
        </div>
        <div class="card-row">
          <span class="card-key">Web server</span>
          <span class="card-val">nginx (installed via User Data)</span>
        </div>
        <div class="card-row">
          <span class="card-key">Instance launched</span>
          <span class="card-val">${LAUNCH_TIME}</span>
        </div>
        <div class="card-row">
          <span class="card-key">Health status</span>
          <span class="card-val green">Healthy — serving traffic</span>
        </div>
      </div>
    </div>

    <p class="refresh-hint">
      Refresh the page multiple times &mdash; the <span>Instance ID</span> and
      <span>Availability Zone</span> will change as the Load Balancer routes you
      to different instances.
    </p>

    <div class="metrics-row">
      <div class="metric">
        <div class="metric-val">99<em>.9%</em></div>
        <div class="metric-label">Uptime SLA</div>
      </div>
      <div class="metric-sep"></div>
      <div class="metric">
        <div class="metric-val">2<em>–4</em></div>
        <div class="metric-label">Active Instances</div>
      </div>
      <div class="metric-sep"></div>
      <div class="metric">
        <div class="metric-val">0<em>s</em></div>
        <div class="metric-label">Manual work</div>
      </div>
      <div class="metric-sep"></div>
      <div class="metric">
        <div class="metric-val">&lt;60<em>s</em></div>
        <div class="metric-label">Scale-out time</div>
      </div>
    </div>
  </div>

  <section class="section-dark" id="architecture">
    <div class="container">
      <span class="eyebrow">// aws architecture</span>
      <h2 class="section-title">How Auto Scaling Works</h2>
      <div class="arch-grid">

        <div class="arch-card" data-delay="0">
          <div class="ac-icon">⚖️</div>
          <div class="ac-label">Application Load Balancer</div>
          <div class="ac-name">ALB</div>
          <div class="ac-desc">Receives all incoming traffic and distributes it across healthy EC2 instances. If an instance fails its health check, ALB stops sending traffic to it automatically.</div>
          <div class="ac-tag">Entry point</div>
        </div>

        <div class="arch-card" data-delay="80">
          <div class="ac-icon">📋</div>
          <div class="ac-label">Launch Template</div>
          <div class="ac-name">Launch Template</div>
          <div class="ac-desc">The blueprint for new instances. Defines the AMI, instance type, security groups, IAM role, and this very User Data script that installs nginx at startup.</div>
          <div class="ac-tag">Instance blueprint</div>
        </div>

        <div class="arch-card" data-delay="160">
          <div class="ac-icon">🔁</div>
          <div class="ac-label">Auto Scaling Group</div>
          <div class="ac-name">ASG</div>
          <div class="ac-desc">Watches CloudWatch metrics (CPU, network). When CPU exceeds 70%, it launches new instances using the Launch Template. When it drops below 30%, it terminates extras.</div>
          <div class="ac-tag">Scaling brain</div>
        </div>

        <div class="arch-card" data-delay="240">
          <div class="ac-icon">📊</div>
          <div class="ac-label">CloudWatch</div>
          <div class="ac-name">CloudWatch</div>
          <div class="ac-desc">Monitors your EC2 fleet in real time. Collects CPU utilisation, network I/O, and custom metrics. Triggers scaling alarms that tell the ASG to scale out or in.</div>
          <div class="ac-tag">Monitoring</div>
        </div>

        <div class="arch-card" data-delay="320">
          <div class="ac-icon">🔔</div>
          <div class="ac-label">SNS</div>
          <div class="ac-name">SNS Notifications</div>
          <div class="ac-desc">Simple Notification Service sends you an email every time a scaling event happens — instance launched, terminated, or a health check fails. Full visibility into your fleet.</div>
          <div class="ac-tag">Alerts</div>
        </div>

        <div class="arch-card" data-delay="400">
          <div class="ac-icon">🛡️</div>
          <div class="ac-label">IAM</div>
          <div class="ac-name">IAM Role</div>
          <div class="ac-desc">Each EC2 instance has an IAM role attached via the Launch Template. This grants the instance permission to publish CloudWatch metrics and interact with SNS — no hardcoded keys.</div>
          <div class="ac-tag">Security</div>
        </div>

      </div>
    </div>
  </section>

  <section id="flow">
    <div class="container">
      <span class="eyebrow">// scaling flow</span>
      <h2 class="section-title">What Happens During a Scale-Out</h2>
      <div class="flow-grid">
        <div class="flow-step" data-step="1">
          <div class="flow-num">01</div>
          <div class="flow-icon">📈</div>
          <div class="flow-title">CPU Spikes</div>
          <div class="flow-desc">Traffic increases. CPU on existing instances rises above 70% for 2 consecutive minutes.</div>
        </div>
        <div class="flow-step" data-step="2">
          <div class="flow-num">02</div>
          <div class="flow-icon">🚨</div>
          <div class="flow-title">Alarm Fires</div>
          <div class="flow-desc">CloudWatch alarm triggers. ASG receives the scale-out signal and checks its max capacity.</div>
        </div>
        <div class="flow-step" data-step="3">
          <div class="flow-num">03</div>
          <div class="flow-icon">🚀</div>
          <div class="flow-title">Instance Launches</div>
          <div class="flow-desc">ASG uses the Launch Template to start a new EC2 instance. This User Data script runs automatically.</div>
        </div>
        <div class="flow-step" data-step="4">
          <div class="flow-num">04</div>
          <div class="flow-icon">✅</div>
          <div class="flow-title">Traffic Distributed</div>
          <div class="flow-desc">Once healthy, ALB adds the new instance and routes traffic to it. Load drops across the fleet.</div>
        </div>
      </div>
    </div>
  </section>

  <footer>
    <div class="container">
      <div class="footer-inner">
        <span class="footer-copy">&copy; 2025 CloudOps &mdash; Auto Scaling Project &mdash; Instance: ${INSTANCE_ID}</span>
        <div class="chip-row">
          <span class="chip">AWS EC2</span>
          <span class="chip">Auto Scaling</span>
          <span class="chip">ALB</span>
          <span class="chip">CloudWatch</span>
          <span class="chip">SNS</span>
          <span class="chip">IAM</span>
        </div>
      </div>
    </div>
  </footer>

  <script>
    // Card reveal on scroll
    const cardObs = new IntersectionObserver(entries => {
      entries.forEach(e => {
        if (e.isIntersecting) {
          setTimeout(() => e.target.classList.add('visible'), parseInt(e.target.dataset.delay || 0));
          cardObs.unobserve(e.target);
        }
      });
    }, { threshold: 0.1 });
    document.querySelectorAll('.arch-card').forEach(c => cardObs.observe(c));

    // Flow step reveal
    const flowObs = new IntersectionObserver(entries => {
      entries.forEach(e => {
        if (e.isIntersecting) {
          const step = parseInt(e.target.dataset.step || 1);
          setTimeout(() => e.target.classList.add('visible'), (step - 1) * 130);
          flowObs.unobserve(e.target);
        }
      });
    }, { threshold: 0.2 });
    document.querySelectorAll('.flow-step').forEach(s => flowObs.observe(s));
  </script>
</body>
</html>
HTMLEOF

echo ">>> Website HTML written to /var/www/html/index.html"


# ─────────────────────────────────────────────
# SECTION 4: CONFIGURE nginx
#
# The default nginx config works fine for our
# use case, but we add a few tweaks:
# - Set server_tokens off (hide nginx version)
# - Add security headers (good practice)
# - Add gzip compression (faster page loads)
# - Set correct file permissions
# ─────────────────────────────────────────────
echo ""
echo ">>> [4/6] Configuring nginx..."

# Write a clean nginx site config
# This replaces the default site config
cat > /etc/nginx/sites-available/cloudops << 'NGINXEOF'
server {
    # Listen on port 80 (standard HTTP)
    listen 80 default_server;
    listen [::]:80 default_server;

    # The folder where your website files live
    root /var/www/html;

    # The default file to serve when someone visits /
    index index.html;

    # Server name — underscore means "catch all" (any hostname)
    server_name _;

    # Hide nginx version number from response headers
    # Security best practice: don't reveal server software version
    server_tokens off;

    # Main location block — how to handle all requests
    location / {
        # Try to serve the exact file, then directory, then 404
        try_files $uri $uri/ =404;
    }

    # Security headers — good practice for any web server
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;

    # Health check endpoint for ALB
    # ALB pings /health every 30 seconds to check if this
    # instance is alive. We return 200 OK with a simple message.
    location /health {
        access_log off;           # Don't log health check hits (saves disk)
        add_header Content-Type text/plain;
        return 200 "healthy\n";
    }

    # Gzip compression — makes files smaller = faster page loads
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css text/javascript application/javascript;

    # Cache static assets for 1 hour in the browser
    location ~* \.(css|js|png|jpg|gif|ico|woff2)$ {
        expires 1h;
        add_header Cache-Control "public, immutable";
    }
}
NGINXEOF

# Enable our config by linking it to sites-enabled
# (sites-enabled is what nginx actually reads)
ln -sf /etc/nginx/sites-available/cloudops /etc/nginx/sites-enabled/cloudops

# Remove the default nginx site so ours is the only one
rm -f /etc/nginx/sites-enabled/default

# Test the nginx configuration for syntax errors
# -t = test, -q = quiet (only show errors)
nginx -t -q

# Reload nginx to pick up the new config
# reload = apply config without dropping connections
# (better than restart for production servers)
systemctl reload nginx

echo ">>> nginx configured and reloaded."


# ─────────────────────────────────────────────
# SECTION 5: SET FILE PERMISSIONS
#
# nginx runs as the www-data user.
# The files in /var/www/html need to be readable
# by that user, otherwise nginx returns 403 Forbidden.
# ─────────────────────────────────────────────
echo ""
echo ">>> [5/6] Setting file permissions..."

# chown  = change owner
# www-data:www-data = nginx's user and group
# -R = apply recursively to all files in the folder
chown -R www-data:www-data /var/www/html

# chmod 755 = owner can read/write/execute, everyone else read/execute
# This is the standard permission for web-served directories
chmod -R 755 /var/www/html

echo ">>> Permissions set."


# ─────────────────────────────────────────────
# SECTION 6: VERIFY AND SIGNAL READY
#
# Do a final health check to make sure everything
# is working before we mark the instance as ready.
# The ALB will NOT send traffic until the instance
# passes its health check — but this local test
# helps catch errors early and log them.
# ─────────────────────────────────────────────
echo ""
echo ">>> [6/6] Running final verification..."

# Wait a moment for nginx to fully start
sleep 3

# Test that nginx is serving on port 80
# curl localhost = make HTTP request to this machine itself
# --fail   = exit with error code if response is not 200
# --silent = no progress output
# --max-time 10 = give up after 10 seconds
if curl --fail --silent --max-time 10 http://localhost > /dev/null 2>&1; then
    echo ">>> SUCCESS: nginx is serving on port 80"
else
    echo ">>> WARNING: nginx health check failed — check /var/log/nginx/error.log"
    # Don't exit here — let the instance continue starting up.
    # The ALB will detect the failure via its own health check.
fi

# Also verify the /health endpoint works
if curl --fail --silent --max-time 10 http://localhost/health > /dev/null 2>&1; then
    echo ">>> SUCCESS: /health endpoint is responding"
else
    echo ">>> WARNING: /health endpoint not responding"
fi

# Print final instance info summary to the log
echo ""
echo "============================================="
echo "  SETUP COMPLETE"
echo "============================================="
echo "  Instance ID:  $(curl -s http://169.254.169.254/latest/meta-data/instance-id)"
echo "  Private IP:   $(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)"
echo "  Public IP:    $(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo 'N/A (private only)')"
echo "  AZ:           $(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)"
echo "  nginx status: $(systemctl is-active nginx)"
echo "  Finished at:  $(date)"
echo "  Log file:     /var/log/user-data.log"
echo "============================================="
echo ""
echo "  This instance is ready to receive traffic"
echo "  from the Application Load Balancer."
echo "============================================="
