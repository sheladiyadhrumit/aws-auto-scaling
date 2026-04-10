# Architecture Diagram — AWS Auto Scaling Project

A complete reference showing how every AWS service in this project connects, what each one does, and what the data flow looks like when traffic arrives and when scaling events happen.

---

## Full Architecture Overview

```
                           ┌─────────────────────────────────────────────────────────┐
                           │                   AWS Region (us-east-1)                │
                           │                                                         │
         Internet          │  ┌──────────────────────────────────────────────────┐   │
         traffic           │  │         Application Load Balancer (ALB)          │   │
            │              │  │   DNS: cloudops-alb-xxxx.us-east-1.elb.amazonaws  │   │
            └─────────────►│  │   Listener: HTTP :80                             │   │
                           │  │   Target Group: cloudops-target-group            │   │
                           │  │   Health check: GET /health every 30s            │   │
                           │  └───────────────┬──────────────────────────────────┘   │
                           │                  │ distributes traffic                  │
                           │         ┌────────┴─────────┐                            │
                           │         ▼                   ▼                            │
                           │  ┌──────────────────────────────────────────────────┐   │
                           │  │           Auto Scaling Group (ASG)               │   │
                           │  │    Name: cloudops-asg                            │   │
                           │  │    Min: 1  ·  Desired: 2  ·  Max: 4             │   │
                           │  │                                                  │   │
                           │  │  ┌──────────────────┐  ┌──────────────────────┐ │   │
                           │  │  │ EC2 (us-east-1a) │  │  EC2 (us-east-1b)   │ │   │
                           │  │  │  nginx on :80     │  │   nginx on :80       │ │   │
                           │  │  │  t2.micro         │  │   t2.micro           │ │   │
                           │  │  │  Ubuntu 22.04     │  │   Ubuntu 22.04       │ │   │
                           │  │  └──────────────────┘  └──────────────────────┘ │   │
                           │  │                                                  │   │
                           │  │  Launch Template: cloudops-launch-template       │   │
                           │  │  AMI: Ubuntu 22.04  ·  user-data.sh on boot     │   │
                           │  └───────────────────────────┬──────────────────────┘   │
                           │                              │                           │
                           │          ┌───────────────────┤                          │
                           │          ▼                   ▼                           │
                           │  ┌───────────────┐  ┌───────────────────────────────┐   │
                           │  │  CloudWatch   │  │            SNS                │   │
                           │  │               │  │  Topic: cloudops-asg-alerts   │   │
                           │  │  Alarm 1:     │  │  Subscription: your@email.com │   │
                           │  │  CPU > 70%    │  │                               │   │
                           │  │  → scale out  │  │  Notifies on:                 │   │
                           │  │               │  │  · Instance launch            │   │
                           │  │  Alarm 2:     │  │  · Instance terminate         │   │
                           │  │  CPU < 30%    │  │  · Launch error               │   │
                           │  │  → scale in   │  │  · Health check fail          │   │
                           │  └───────────────┘  └───────────────────────────────┘   │
                           │                                                         │
                           │  Supporting resources:                                  │
                           │  · IAM Role: cloudops-ec2-role (CloudWatch + SNS)      │
                           │  · Security Group: cloudops-asg-sg (ports 80, 22)      │
                           │  · VPC: default VPC with public subnets in 2 AZs       │
                           └─────────────────────────────────────────────────────────┘
```

---

## Service Descriptions

### Application Load Balancer (ALB)

The ALB is the single entry point for all user traffic. Users never connect directly to an EC2 instance — they always go through the ALB.

**What it does:**
- Accepts all incoming HTTP traffic on port 80
- Maintains a list of healthy EC2 instances (the Target Group)
- Uses round-robin to spread requests evenly across all healthy instances
- Runs a health check every 30 seconds by sending `GET /health` to each instance
- Removes instances that fail 3 consecutive health checks from the rotation
- Automatically adds newly launched instances once they pass 2 consecutive health checks
- Spans multiple Availability Zones so traffic keeps flowing even if one AZ goes down

**Key settings in this project:**

| Setting | Value |
|---------|-------|
| Scheme | Internet-facing |
| Listener | HTTP port 80 |
| Target type | EC2 instances |
| Health check path | `/health` |
| Healthy threshold | 2 checks |
| Unhealthy threshold | 3 checks |
| Health check interval | 30 seconds |
| Health check grace period | 300 seconds |

The grace period (300 seconds) is critical — it gives the `user-data.sh` script time to finish installing nginx before the ALB starts checking if the instance is healthy. Without it, the ALB would declare a new instance unhealthy before nginx is even installed.

---

### Auto Scaling Group (ASG)

The ASG is the brain of the whole system. It decides how many EC2 instances should be running at any given time and takes action to maintain that number.

**What it does:**
- Always keeps at least 1 instance running (minimum capacity)
- Targets 2 running instances under normal load (desired capacity)
- Can grow up to 4 instances under heavy load (maximum capacity)
- Launches new instances using the Launch Template when CloudWatch says to scale out
- Terminates excess instances when CloudWatch says to scale in
- Automatically replaces any instance that fails an ALB health check
- Distributes instances across multiple Availability Zones for resilience

**Scaling policies in this project:**

| Policy | Trigger | Action | Cooldown |
|--------|---------|--------|----------|
| Scale Out | Average CPU > 70% for 2 min | Launch +1 instance | 300 s |
| Scale In | Average CPU < 30% for 10 min | Terminate -1 instance | 300 s |

The cooldown period (300 seconds) prevents runaway scaling. After launching an instance, the ASG waits 5 minutes before acting on the next alarm — giving the new instance time to take load and CPU to stabilise before deciding whether to launch another one.

---

### Launch Template

The Launch Template is a saved blueprint that defines exactly how every new EC2 instance should be configured. The ASG uses it every time it launches an instance.

**What it specifies:**

| Field | Value |
|-------|-------|
| AMI | Ubuntu Server 22.04 LTS |
| Instance type | t2.micro |
| Key pair | Your SSH key pair |
| Security group | cloudops-asg-sg |
| IAM instance profile | cloudops-ec2-profile |
| User Data | Contents of `user-data.sh` |

The User Data field is where `user-data.sh` lives. When any new EC2 instance boots, AWS runs this script automatically as root. The script installs nginx, writes the website HTML (populated with the instance's own metadata), configures nginx with a `/health` endpoint, sets file permissions, and verifies everything is working — all without any human involvement.

---

### EC2 Instances

Each EC2 instance runs Ubuntu 22.04 with nginx installed by the `user-data.sh` startup script. Instances are distributed across at least two Availability Zones.

**What runs on each instance:**
- nginx serving static HTML on port 80
- The `/health` endpoint returns `200 OK` with body `healthy`
- The website HTML shows the instance's own ID, AZ, private IP, and launch time — so you can verify which instance the ALB is routing you to

**Instance lifecycle inside the ASG:**

```
Launch Template blueprint
         │
         ▼
EC2 instance boots
         │
         ▼
user-data.sh runs (installs nginx, deploys site)
         │
         ▼
ALB runs health checks (GET /health every 30s)
         │
     2 passes
         │
         ▼
Instance added to ALB rotation  ←──── now serving traffic
         │
    (stays healthy)
         │
    3 check failures
         │
         ▼
Instance removed from ALB rotation
         │
         ▼
ASG detects unhealthy instance → terminates it → launches replacement
```

---

### CloudWatch

CloudWatch collects CPU utilisation metrics from every EC2 instance in the ASG and evaluates them against alarm thresholds every 60 seconds.

**Alarms in this project:**

| Alarm | Metric | Condition | Periods | Action |
|-------|--------|-----------|---------|--------|
| `cloudops-scale-out` | CPUUtilization | Average > 70% | 2 of 2 | ASG: +1 instance |
| `cloudops-scale-in` | CPUUtilization | Average < 30% | 10 of 10 | ASG: -1 instance |
| `cloudops-high-cpu-warning` | CPUUtilization | Average > 85% | 3 of 3 | SNS alert only |
| `cloudops-instance-health` | StatusCheckFailed | Maximum >= 1 | 2 of 2 | SNS alert only |
| `cloudops-alb-5xx-errors` | HTTPCode_Target_5XX_Count | Sum > 10 | 1 of 1 | SNS alert only |
| `cloudops-alb-latency` | TargetResponseTime | Average > 2s | 5 of 5 | SNS alert only |

CloudWatch gets CPU data from the EC2 hypervisor automatically — no agent or configuration required on the instances for basic metrics.

---

### SNS (Simple Notification Service)

SNS delivers email notifications whenever a scaling event or alert fires. It connects to the ASG directly as well as receiving publishes from CloudWatch alarms.

**Events that trigger an email in this project:**
- EC2 instance launched by ASG
- EC2 instance terminated by ASG
- EC2 instance launch failed (e.g. capacity unavailable)
- EC2 instance terminate failed
- CloudWatch scale-out alarm fires
- CloudWatch scale-in alarm fires
- CloudWatch high CPU warning fires
- CloudWatch instance health check alarm fires
- CloudWatch 5xx error alarm fires
- CloudWatch latency alarm fires

---

### IAM Role

The IAM role `cloudops-ec2-role` is attached to every EC2 instance via the Launch Template. It grants the permissions the instance needs to interact with other AWS services — without any hardcoded credentials.

**Permissions granted:**

| Permission | Why it's needed |
|-----------|-----------------|
| `cloudwatch:PutMetricData` | Instance publishes custom metrics to CloudWatch |
| `cloudwatch:DescribeAlarms` | Instance can read its own alarm states |
| `logs:PutLogEvents` | Instance writes nginx logs to CloudWatch Logs |
| `sns:Publish` | Instance can send notifications to the SNS topic |
| `ec2:DescribeInstances` | `user-data.sh` reads own instance metadata |
| `autoscaling:Describe*` | Instance can query the ASG it belongs to |
| SSM Session Manager actions | Allows SSH-less console access from AWS Console |

---

### Security Group

The security group `cloudops-asg-sg` controls network access to the EC2 instances.

**Inbound rules:**

| Port | Source | Purpose |
|------|--------|---------|
| 80 | ALB security group ID only | Instances only accept HTTP from the ALB, not the open internet |
| 22 | Your IP only | SSH access for debugging |

**Important:** Port 80 is scoped to the ALB's security group, not `0.0.0.0/0`. This means users cannot bypass the ALB and hit your instances directly. All traffic must go through the load balancer.

---

## Traffic Flow

How a single user request travels from browser to your EC2 instance and back:

```
User's browser
      │
      │  HTTP GET http://cloudops-alb-xxxx.elb.amazonaws.com/
      ▼
Application Load Balancer
      │
      │  Round-robin selection of healthy instance
      │  (checks Target Group for instances with status: healthy)
      ▼
EC2 Instance (e.g. i-0abc123 in us-east-1a)
      │
      │  nginx receives request on port 80
      │  Serves /var/www/html/index.html
      ▼
ALB receives the HTTP 200 response
      │
      │  Forwards response back to user
      ▼
User's browser renders the page
(shows: Instance ID, AZ, IP, launch time)
```

---

## Scale-Out Flow

What happens automatically when traffic increases and CPU rises above 70%:

```
Traffic spike
      │
      │  CPU rises above 70% on existing instances
      ▼
CloudWatch evaluates CPUUtilization metric (every 60 seconds)
      │
      │  Threshold breached for 2 consecutive periods (2 minutes)
      ▼
cloudops-scale-out alarm → state changes to ALARM
      │
      ├─► ASG receives scale-out signal
      │        │
      │        │  Checks: current count (2) < maximum (4)  → OK to scale
      │        ▼
      │   ASG launches new EC2 instance
      │        │  Using Launch Template: cloudops-launch-template
      │        ▼
      │   Instance boots, user-data.sh runs (~60 seconds)
      │        │  installs nginx
      │        │  writes index.html with instance metadata
      │        │  configures /health endpoint
      │        ▼
      │   ALB health checks begin
      │        │  GET /health → 200 OK (×2 checks)
      │        ▼
      │   Instance added to ALB Target Group
      │        │  now receiving live traffic
      │        ▼
      │   CPU load spreads across 3 instances → CPU drops
      │
      └─► SNS publishes notification
               │
               ▼
          Email: "EC2_INSTANCE_LAUNCH: i-0newinstance launched in cloudops-asg"
```

---

## Scale-In Flow

What happens when traffic drops and CPU stays below 30% for 10 minutes:

```
Traffic drops
      │
      │  CPU falls below 30% on all instances
      ▼
CloudWatch evaluates CPUUtilization metric (every 60 seconds)
      │
      │  Threshold met for 10 consecutive periods (10 minutes)
      ▼
cloudops-scale-in alarm → state changes to ALARM
      │
      ├─► ASG receives scale-in signal
      │        │
      │        │  Checks: current count (3) > minimum (1)  → OK to scale in
      │        ▼
      │   ASG selects instance to terminate
      │        │  (picks oldest instance by default)
      │        ▼
      │   ALB connection draining (60 second timeout)
      │        │  in-flight requests finish, no new requests sent
      │        ▼
      │   Instance terminated
      │        │  2 instances remain — still above minimum
      │        ▼
      │   Remaining instances still serving traffic normally
      │
      └─► SNS publishes notification
               │
               ▼
          Email: "EC2_INSTANCE_TERMINATE: i-0oldinstance terminated in cloudops-asg"
```

---

## Instance Failure Recovery Flow

What happens if an EC2 instance crashes or becomes unhealthy:

```
EC2 instance fails (crash, OS hang, nginx dies)
      │
      ▼
ALB health check: GET /health → no response
      │
      │  3 consecutive failures (90 seconds)
      ▼
ALB removes instance from Target Group
      │  (no new requests sent to this instance)
      ▼
ASG detects instance is unhealthy
      │
      ▼
ASG terminates the unhealthy instance
      │
      ▼
ASG launches replacement instance (desired count = 2, actual = 1)
      │  Uses Launch Template: user-data.sh installs nginx automatically
      ▼
New instance passes health checks → added to ALB rotation
      │
      ▼
SNS sends notification of launch and termination
```

This entire recovery happens automatically — no human needs to do anything.

---

## Multi-AZ Resilience

Instances are distributed across two Availability Zones. This means if an entire AZ goes down (data centre power failure, etc.), traffic automatically routes to the instance in the surviving AZ.

```
Normal operation:
  ALB
  ├── us-east-1a: EC2 instance A  ← serving 50% of traffic
  └── us-east-1b: EC2 instance B  ← serving 50% of traffic

AZ failure (us-east-1b goes offline):
  ALB
  ├── us-east-1a: EC2 instance A  ← serving 100% of traffic
  └── us-east-1b: [unavailable]   ← ALB stops routing here

ASG response:
  Launches replacement in us-east-1a
  ALB
  ├── us-east-1a: EC2 instance A  ← serving 50% of traffic
  ├── us-east-1a: EC2 instance C  ← serving 50% of traffic (new)
  └── us-east-1b: [still down]
```

---

## Port Map

```
Internet ──── :80 ───► ALB security group (cloudops-alb-sg)
                              │
                              │ :80
                              ▼
                        EC2 security group (cloudops-asg-sg)
                        Source: cloudops-alb-sg only
                              │
                              │ :80
                              ▼
                        nginx on EC2 instance
                              │
                    ┌─────────┴──────────┐
                    │                    │
                 GET /          GET /health
                    │                    │
               index.html       200 "healthy"
               (website)         (ALB check)

Your IP ──── :22 ───► EC2 security group (cloudops-asg-sg)
                              │
                              │ :22
                              ▼
                        sshd on EC2 (for debugging)
```

---

## File to Service Mapping

Every file in this project maps to a specific AWS service:

| File | AWS Service | What it configures |
|------|-------------|-------------------|
| `user-data.sh` | EC2 Launch Template | Runs at instance boot — installs nginx, deploys site |
| `iam-policy.json` | IAM Role | Permissions for CloudWatch and SNS access |
| `ec2-trust-policy.json` | IAM Role | Allows EC2 to assume the IAM role |
| `cloudwatch-alarms.md` | CloudWatch | Documents all 6 alarm configurations |
| `README.md` | All services | Step-by-step setup guide |
| `architecture-diagram.md` | All services | This file — reference architecture |
