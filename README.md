# CloudOps — Auto Scaling Setup on AWS

A production-grade AWS infrastructure project that automatically scales EC2 instances up and down based on CPU load. When traffic increases, new servers spin up by themselves. When traffic drops, they shut down to save cost. No manual intervention needed.

---

## What This Project Does

```
User traffic arrives
        ↓
Application Load Balancer (ALB)
spreads traffic across healthy EC2 instances
        ↓
CloudWatch monitors CPU on every instance
        ↓
CPU > 70% for 2 minutes?
→ Auto Scaling Group launches a new EC2 instance
→ User Data script installs nginx automatically
→ ALB starts sending traffic to the new instance
        ↓
CPU < 30% for 10 minutes?
→ ASG terminates an instance
→ ALB removes it from rotation
→ SNS sends you an email notification
```

Everything in this flow is automatic. You set it up once and AWS handles the rest.

---

## Architecture

```
Internet
    │
    ▼
┌─────────────────────────────────────┐
│   Application Load Balancer (ALB)   │  ← single entry point for all traffic
│   DNS: your-alb-xxxx.amazonaws.com  │
└──────────────┬──────────────────────┘
               │  distributes traffic
       ┌───────┴────────┐
       ▼                ▼
┌─────────────┐  ┌─────────────┐  ← more instances added/removed automatically
│  EC2 :nginx │  │  EC2 :nginx │
│  us-east-1a │  │  us-east-1b │
└─────────────┘  └─────────────┘
       │                │
       └───────┬────────┘
               ▼
┌──────────────────────────────────┐
│   Auto Scaling Group (ASG)       │  min=1  desired=2  max=4
│   Launch Template → user-data.sh │
└───────────┬──────────────────────┘
            │  watches metrics
            ▼
┌──────────────────────────────────┐
│   CloudWatch Alarms              │
│   Scale Out: CPU > 70%  → +1    │
│   Scale In:  CPU < 30%  → -1    │
└───────────┬──────────────────────┘
            │  sends notifications
            ▼
┌──────────────────────────────────┐
│   SNS Topic → your@email.com     │
└──────────────────────────────────┘
```

---

## Tech Stack

| Service | Purpose |
|---------|---------|
| AWS EC2 | Virtual servers that run nginx and serve the website |
| AWS ALB | Application Load Balancer — spreads traffic across instances |
| AWS Auto Scaling Group | Launches and terminates instances based on load |
| AWS Launch Template | Blueprint defining how each new instance is configured |
| AWS CloudWatch | Monitors CPU metrics and triggers scaling alarms |
| AWS SNS | Sends email alerts when scaling events happen |
| AWS IAM | Gives EC2 instances permission to publish to CloudWatch and SNS |
| nginx | Web server installed automatically via the User Data script |
| Ubuntu 22.04 | OS on each EC2 instance |

---

## Project File Structure

```
auto-scaling-aws/
├── user-data.sh          # EC2 startup script — installs nginx + deploys site
├── iam-policy.json       # IAM permissions for EC2 instances
├── cloudwatch-alarms.md  # Step-by-step alarm configuration guide
├── architecture.md       # Detailed architecture explanation
└── README.md             # This file
```

---

## Prerequisites

Before starting, make sure you have:

- An **AWS account** with admin access (free tier works for testing)
- **AWS CLI** installed and configured — `aws configure`
- A **key pair** in your target AWS region (for SSH access)
- Basic familiarity with the AWS Console

---

## Setup Guide

Work through these steps in order. Each step depends on the previous one.

---

### Step 1 — Create an IAM Role for EC2

Every EC2 instance launched by the ASG needs an IAM role so it can publish metrics to CloudWatch and send notifications to SNS — without hardcoding any AWS credentials.

**In AWS Console → IAM → Roles → Create role:**

1. Trusted entity type: **AWS service**
2. Use case: **EC2**
3. Click **Next**
4. Search for and attach these two policies:
   - `CloudWatchAgentServerPolicy`
   - `AmazonSNSFullAccess`
5. Role name: `cloudops-ec2-role`
6. Click **Create role**

You can also use the provided `iam-policy.json` to create a custom least-privilege policy instead of the broad managed policies above.

---

### Step 2 — Create a Security Group

The security group acts as a firewall for your EC2 instances.

**AWS Console → EC2 → Security Groups → Create security group:**

| Field | Value |
|-------|-------|
| Name | `cloudops-asg-sg` |
| Description | Security group for Auto Scaling instances |
| VPC | Your default VPC |

**Inbound rules:**

| Type | Port | Source | Reason |
|------|------|--------|--------|
| HTTP | 80 | Custom: ALB security group ID | Only ALB can send HTTP traffic to instances |
| SSH | 22 | My IP | Only you can SSH in for debugging |

> **Security tip:** Do NOT set HTTP source to `0.0.0.0/0` on the instance security group. Instances should only receive traffic through the ALB, not directly from the internet. You will create the ALB security group in Step 3 and then come back to fill in its ID here.

---

### Step 3 — Create the Application Load Balancer

The ALB is the single entry point for all traffic. It distributes requests to healthy instances.

**AWS Console → EC2 → Load Balancers → Create load balancer → Application Load Balancer:**

**Basic config:**

| Field | Value |
|-------|-------|
| Name | `cloudops-alb` |
| Scheme | Internet-facing |
| IP address type | IPv4 |

**Network mapping:**
- Select your VPC
- Select **at least 2 Availability Zones** (e.g. `us-east-1a` and `us-east-1b`)
- This gives you high availability — if one AZ goes down, traffic routes to the other

**Security group:**
- Create a new security group for the ALB:
  - Name: `cloudops-alb-sg`
  - Inbound: HTTP port 80 from `0.0.0.0/0` (the whole internet can reach the ALB)
  - Outbound: All traffic (so ALB can forward to instances)
- Now go back to `cloudops-asg-sg` from Step 2 and update the HTTP inbound rule source to be the ID of `cloudops-alb-sg`

**Listeners and routing:**
1. Listener: HTTP on port 80
2. Click **Create target group** (opens in a new tab):
   - Target type: **Instances**
   - Name: `cloudops-target-group`
   - Protocol: HTTP, Port: 80
   - Health check path: `/health`
   - Healthy threshold: `2`
   - Unhealthy threshold: `3`
   - Interval: `30` seconds
   - Click **Create target group**
3. Back in the ALB setup, select `cloudops-target-group` as the default action
4. Click **Create load balancer**

Note the **ALB DNS name** from the description tab — this is your public URL (e.g. `cloudops-alb-1234567890.us-east-1.elb.amazonaws.com`).

---

### Step 4 — Create the Launch Template

The Launch Template is the blueprint that tells the ASG exactly how to configure each new EC2 instance it launches.

**AWS Console → EC2 → Launch Templates → Create launch template:**

| Field | Value |
|-------|-------|
| Name | `cloudops-launch-template` |
| Description | CloudOps Auto Scaling — nginx via user data |
| Auto Scaling guidance | Tick the checkbox |

**Launch template contents:**

| Setting | Value |
|---------|-------|
| AMI | Ubuntu Server 22.04 LTS (search: `ubuntu 22.04`) |
| Instance type | `t2.micro` |
| Key pair | Your existing key pair |
| Security groups | `cloudops-asg-sg` |

**Advanced details — IAM instance profile:**
- Select `cloudops-ec2-role` (created in Step 1)

**Advanced details — User data:**
- Paste the **complete contents** of `user-data.sh`
- This script runs automatically on every new instance at first boot
- It installs nginx, writes the website HTML with the instance's own metadata, configures nginx, and verifies everything is working

Click **Create launch template**.

---

### Step 5 — Create the Auto Scaling Group

The ASG uses the Launch Template to create instances, watches CloudWatch for signals to scale, and keeps the right number of instances running at all times.

**AWS Console → EC2 → Auto Scaling Groups → Create Auto Scaling group:**

**Step 1 — Name and template:**

| Field | Value |
|-------|-------|
| Name | `cloudops-asg` |
| Launch template | `cloudops-launch-template` (latest version) |

**Step 2 — Instance launch options:**

| Field | Value |
|-------|-------|
| VPC | Your default VPC |
| Availability Zones | Select `us-east-1a` AND `us-east-1b` (minimum 2) |

**Step 3 — Load balancing:**

| Field | Value |
|-------|-------|
| Attach to existing load balancer | Yes |
| Existing load balancer target groups | `cloudops-target-group` |
| Health checks | Turn on Elastic Load Balancing health checks |
| Health check grace period | `300` seconds (5 minutes for user data to finish running) |

**Step 4 — Group size and scaling:**

| Field | Value |
|-------|-------|
| Desired capacity | `2` |
| Minimum capacity | `1` |
| Maximum capacity | `4` |

**Automatic scaling:**
- Select **Target tracking scaling policy**
- Metric type: `Average CPU Utilization`
- Target value: `50`
- This means: add instances when average CPU across the group exceeds 50%, remove them when it drops below

Click through **Step 5** (notifications — we set these up next) and **Create Auto Scaling group**.

After creating the ASG, wait 3–5 minutes. Two EC2 instances will appear in your EC2 console — launched and configured automatically.

---

### Step 6 — Create SNS Notifications

SNS sends you an email whenever a scaling event happens — instance launched, instance terminated, or a health check failure.

**AWS Console → SNS → Topics → Create topic:**

| Field | Value |
|-------|-------|
| Type | Standard |
| Name | `cloudops-asg-alerts` |

Click **Create topic**, then:

1. Click **Create subscription**
2. Protocol: **Email**
3. Endpoint: your email address
4. Click **Create subscription**
5. Check your email and click the **Confirm subscription** link

**Connect SNS to the ASG:**

1. Go to your Auto Scaling group `cloudops-asg`
2. Click the **Activity** tab → **Activity notifications** → **Create notification**
3. Select your SNS topic: `cloudops-asg-alerts`
4. Select all event types:
   - `EC2_INSTANCE_LAUNCH`
   - `EC2_INSTANCE_TERMINATE`
   - `EC2_INSTANCE_LAUNCH_ERROR`
   - `EC2_INSTANCE_TERMINATE_ERROR`
5. Click **Create**

You will now receive an email for every scaling event.

---

### Step 7 — Create CloudWatch Scaling Alarms

While the Target Tracking policy (Step 5) handles automatic scaling, you can also create manual Step Scaling alarms for more precise control. Here is how to create both Scale Out and Scale In alarms manually.

**Scale Out alarm — launch an instance when CPU is high:**

AWS Console → CloudWatch → Alarms → Create alarm:

1. Click **Select metric** → EC2 → By Auto Scaling Group
2. Find your ASG `cloudops-asg` → select **CPUUtilization**
3. Statistic: **Average**, Period: **1 minute**
4. Condition: **Greater than** `70`
5. Click **Next**
6. In Actions: Select **EC2 Auto Scaling action** → `cloudops-asg` → **Add 1 capacity unit**
7. Also add an SNS notification: select `cloudops-asg-alerts`
8. Alarm name: `cloudops-scale-out`
9. Click **Create alarm**

**Scale In alarm — terminate an instance when CPU is low:**

Repeat the same steps with:
- Condition: **Less than** `30`
- Action: **Remove 1 capacity unit**
- Alarm name: `cloudops-scale-in`

---

## Testing Auto Scaling

This is the most satisfying part — you will watch AWS automatically launch new servers in real time.

### Test 1 — Verify the website is live

Open the ALB DNS name in your browser:

```
http://cloudops-alb-XXXXXXXX.us-east-1.elb.amazonaws.com
```

You should see the CloudOps website showing instance details. Refresh the page several times — the Instance ID and Availability Zone should alternate between your two running instances. This proves the load balancer is working.

### Test 2 — Verify load balancing

```bash
# Use curl in a loop to hit the ALB repeatedly
# Watch the Instance ID change — different instance each time
for i in $(seq 1 10); do
  curl -s http://YOUR_ALB_DNS | grep "Instance ID" | grep -oP 'i-[a-f0-9]+'
  sleep 0.5
done
```

You should see two different instance IDs alternating.

### Test 3 — Trigger a scale-out event

SSH into one of your running instances and simulate high CPU load:

```bash
# SSH into an instance
ssh -i your-key.pem ubuntu@INSTANCE_PUBLIC_IP

# Install the stress tool
sudo apt-get install stress -y

# Simulate 100% CPU load for 5 minutes
# --cpu 2  = stress 2 CPU cores
# --timeout 300  = run for 300 seconds (5 minutes)
stress --cpu 2 --timeout 300
```

Now watch what happens:

```bash
# In a separate terminal, watch the ASG activity
aws autoscaling describe-scaling-activities \
  --auto-scaling-group-name cloudops-asg \
  --query 'Activities[0:3].[StatusCode,Description,StartTime]' \
  --output table
```

Within 2–3 minutes you should see:
1. CloudWatch alarm changes to **In alarm** state
2. ASG launches a new EC2 instance
3. New instance runs the User Data script (installs nginx)
4. ALB adds the new instance to the target group
5. You receive an email from SNS

### Test 4 — Verify the new instance appeared

```bash
# List all running instances in the ASG
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names cloudops-asg \
  --query 'AutoScalingGroups[0].Instances[*].[InstanceId,LifecycleState,AvailabilityZone]' \
  --output table
```

You should now see 3 instances instead of 2.

### Test 5 — Watch scale-in after stress test ends

After the `stress` command finishes (or you kill it with Ctrl+C), wait 10 minutes for CPU to drop below 30%. The ASG will automatically terminate the extra instance it launched. You will get another SNS email.

### Test 6 — Check the User Data log on any instance

```bash
# SSH into an instance and read the startup log
ssh -i your-key.pem ubuntu@INSTANCE_PUBLIC_IP

# See everything user-data.sh printed during startup
sudo cat /var/log/user-data.log

# Check nginx is serving correctly
curl -s http://localhost/health
# Expected output: healthy

# Check nginx access log
sudo tail -f /var/log/nginx/access.log
```

---

## Useful AWS CLI Commands

```bash
# Describe your Auto Scaling group
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names cloudops-asg

# See scaling activity history
aws autoscaling describe-scaling-activities \
  --auto-scaling-group-name cloudops-asg \
  --max-items 10

# Manually set desired capacity (force a scale-out)
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name cloudops-asg \
  --desired-capacity 3

# Check CloudWatch alarm states
aws cloudwatch describe-alarms \
  --alarm-names cloudops-scale-out cloudops-scale-in \
  --query 'MetricAlarms[*].[AlarmName,StateValue,StateReason]' \
  --output table

# List target group health (see which instances are healthy)
aws elbv2 describe-target-health \
  --target-group-arn YOUR_TARGET_GROUP_ARN \
  --query 'TargetHealthDescriptions[*].[Target.Id,TargetHealth.State]' \
  --output table

# Suspend scaling (useful during maintenance)
aws autoscaling suspend-processes \
  --auto-scaling-group-name cloudops-asg \
  --scaling-processes Launch Terminate

# Resume scaling after maintenance
aws autoscaling resume-processes \
  --auto-scaling-group-name cloudops-asg \
  --scaling-processes Launch Terminate
```

---

## Troubleshooting

### Instances launch but fail ALB health checks

```bash
# SSH into the instance and check nginx
sudo systemctl status nginx

# Check the User Data log to see if setup completed
sudo cat /var/log/user-data.log

# Check nginx error log
sudo cat /var/log/nginx/error.log

# Test the health endpoint locally
curl http://localhost/health
# Expected: healthy
```

If nginx is not running, the User Data script probably failed. Check the log for errors. The most common cause is a package install failing — re-run `apt-get update && apt-get install nginx -y` manually to see the error.

### ALB returns 502 Bad Gateway

A 502 means the ALB can reach your instances but they are not returning a valid HTTP response. Check:

```bash
# Is nginx running?
sudo systemctl status nginx

# Is nginx listening on port 80?
sudo ss -tlnp | grep :80

# Can nginx serve a request?
curl -v http://localhost
```

### Instances not registering with the target group

Check the health check grace period. The default is 300 seconds — the instance has 5 minutes to pass health checks before being marked unhealthy. If your User Data script takes longer than that, increase the grace period in the ASG settings.

### CloudWatch alarm stays in INSUFFICIENT_DATA state

This happens when the ASG has not published any metrics yet. Wait 5 minutes after creating instances for the first data points to appear in CloudWatch.

### SNS emails not arriving

- Check your spam folder
- Verify the subscription is confirmed (green tick in SNS console)
- Check the subscription ARN is active
- Test by manually publishing to the topic:

```bash
aws sns publish \
  --topic-arn YOUR_TOPIC_ARN \
  --message "Test alert from CloudOps" \
  --subject "CloudOps SNS Test"
```

---

## Key Concepts Explained Simply

**What is a Launch Template?**
It is a saved configuration that tells AWS: "when you need to launch a new server, set it up exactly like this" — same OS, same instance type, same startup script, same security group every time.

**What is a Target Group?**
It is a list of servers that the load balancer knows about. The ALB sends traffic to servers in this list. When the ASG launches a new instance, it automatically registers the instance with the target group.

**What is a health check grace period?**
After a new instance launches, AWS waits this many seconds before checking if it is healthy. This gives the User Data script time to finish installing nginx. If health checks ran immediately, the instance would fail before nginx was even installed.

**What is the difference between Scale Out and Scale In?**
Scale Out = add more instances (launch new servers). Scale In = remove instances (terminate servers). The Auto Scaling Group does both automatically.

**What does the cooldown period do?**
After a scaling event, the ASG waits the cooldown period (default 300 seconds) before acting on the next alarm. This prevents the ASG from launching 10 instances in a row during a sudden traffic spike — it launches one, waits 5 minutes, checks if CPU is still high, then launches another.

---

## Cost Estimate (us-east-1)

| Resource | Free tier | Estimated cost beyond free tier |
|----------|-----------|--------------------------------|
| EC2 t2.micro | 750 hrs/month free | ~$0.0116 per hour |
| ALB | 750 hrs/month free | ~$0.008 per LCU-hour |
| CloudWatch alarms | 10 alarms free | ~$0.10 per alarm/month |
| SNS emails | 1,000 free | Free for email |
| Data transfer | 1 GB free | ~$0.09 per GB |

For a testing project running a few days: **effectively free** on the AWS free tier. Remember to delete resources when done.

---

## Cleanup — Delete Everything When Done

Delete resources in this order to avoid dependency errors:

```bash
# 1. Delete the Auto Scaling Group (terminates all instances)
aws autoscaling delete-auto-scaling-group \
  --auto-scaling-group-name cloudops-asg \
  --force-delete

# 2. Delete CloudWatch alarms
aws cloudwatch delete-alarms \
  --alarm-names cloudops-scale-out cloudops-scale-in

# 3. Delete the ALB
aws elbv2 delete-load-balancer \
  --load-balancer-arn YOUR_ALB_ARN

# 4. Delete the Target Group (wait ~1 min after deleting ALB)
aws elbv2 delete-target-group \
  --target-group-arn YOUR_TARGET_GROUP_ARN

# 5. Delete the Launch Template
aws ec2 delete-launch-template \
  --launch-template-name cloudops-launch-template

# 6. Delete SNS topic
aws sns delete-topic \
  --topic-arn YOUR_TOPIC_ARN

# 7. Delete IAM role (detach policies first)
aws iam detach-role-policy \
  --role-name cloudops-ec2-role \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy
aws iam detach-role-policy \
  --role-name cloudops-ec2-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonSNSFullAccess
aws iam delete-role \
  --role-name cloudops-ec2-role

# 8. Delete security groups (via AWS Console — easier than CLI for dependencies)
```

Or just go to the AWS Console and delete everything manually. Either way, confirm in the EC2 console that no instances are running.

---

## What You Learned

By completing this project you have hands-on experience with:

- Designing a highly available, multi-AZ AWS architecture
- Configuring an Application Load Balancer with health checks
- Writing a Launch Template with User Data scripts
- Creating and configuring an Auto Scaling Group
- Setting up CloudWatch alarms for CPU-based scaling
- Using SNS for infrastructure event notifications
- Attaching IAM roles to EC2 instances securely
- Load testing with the `stress` tool and watching AWS respond in real time
- Reading CloudWatch metrics and ALB access logs
- Using the AWS CLI to inspect and manage infrastructure

---

## Author

Built as a DevOps learning project — Project 2 of the CloudOps series.
Project 1: Static Website with Docker + Jenkins CI/CD on AWS EC2.
