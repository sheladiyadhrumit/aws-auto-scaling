# CloudWatch Alarms — Auto Scaling Project

Complete configuration reference for every CloudWatch alarm in the CloudOps Auto Scaling setup. Each alarm is documented with its purpose, exact settings, AWS Console steps, and the AWS CLI command to create it in one shot.

---

## How CloudWatch Alarms Trigger Scaling

```
EC2 instances publish CPU metrics to CloudWatch every 60 seconds
                          │
                          ▼
         CloudWatch evaluates alarm conditions
                          │
              ┌───────────┴───────────┐
              │                       │
         CPU > 70%               CPU < 30%
         for 2 minutes           for 10 minutes
              │                       │
              ▼                       ▼
       Scale-Out Alarm          Scale-In Alarm
              │                       │
              ▼                       ▼
    ASG launches +1 instance   ASG terminates -1 instance
              │                       │
              ▼                       ▼
       SNS email sent            SNS email sent
```

---

## Alarm Overview

| Alarm Name | Metric | Threshold | Action | Cooldown |
|------------|--------|-----------|--------|----------|
| `cloudops-scale-out` | CPU Utilisation | > 70% for 2 min | Launch +1 instance | 300 s |
| `cloudops-scale-in` | CPU Utilisation | < 30% for 10 min | Terminate -1 instance | 300 s |
| `cloudops-high-cpu-warning` | CPU Utilisation | > 85% for 3 min | SNS alert only | — |
| `cloudops-instance-health` | StatusCheckFailed | >= 1 for 2 min | SNS alert only | — |
| `cloudops-alb-5xx-errors` | HTTPCode_Target_5XX_Count | > 10 in 5 min | SNS alert only | — |
| `cloudops-alb-latency` | TargetResponseTime | > 2 s for 5 min | SNS alert only | — |

---

## Before You Start

You need three values before creating any alarm. Find them first and keep them handy.

**Your Auto Scaling Group name:**
```bash
aws autoscaling describe-auto-scaling-groups \
  --query 'AutoScalingGroups[*].AutoScalingGroupName' \
  --output text
# Expected output: cloudops-asg
```

**Your SNS topic ARN:**
```bash
aws sns list-topics \
  --query 'Topics[*].TopicArn' \
  --output text
# Expected output: arn:aws:sns:us-east-1:123456789012:cloudops-asg-alerts
```

**Your ALB ARN and Target Group ARN** (needed for ALB alarms):
```bash
# Get ALB ARN
aws elbv2 describe-load-balancers \
  --names cloudops-alb \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text

# Get Target Group ARN
aws elbv2 describe-target-groups \
  --names cloudops-target-group \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text
```

---

## Alarm 1 — Scale Out (High CPU)

**What it does:** When average CPU across all instances stays above 70% for 2 consecutive minutes, the ASG launches one new EC2 instance. This is your main defence against traffic spikes.

**Why 70% and not 100%?** At 100% CPU, your site is already degraded. Scaling starts at 70% so the new instance is running and taking traffic before users notice a slowdown. The new instance takes about 60–90 seconds to launch and pass health checks.

**Why 2 minutes?** A single minute of high CPU could be a short-lived spike — a cron job, a deployment, or a burst. Waiting 2 consecutive minutes ensures we only scale for sustained load, not noise.

### Settings

| Field | Value | Why |
|-------|-------|-----|
| Namespace | `AWS/EC2` | Standard EC2 metrics namespace |
| Metric | `CPUUtilization` | Percentage of CPU in use |
| Statistic | `Average` | Average across all instances in ASG |
| Period | `60 seconds` | Evaluate every 1 minute |
| Evaluation periods | `2` | Must breach threshold for 2 periods in a row |
| Datapoints to alarm | `2 out of 2` | Both consecutive periods must be above threshold |
| Threshold | `> 70` | Percent |
| Comparison | `GreaterThanThreshold` | |
| Treat missing data | `missing` | Do nothing if no data (instance might be starting up) |
| Dimension | `AutoScalingGroupName = cloudops-asg` | Only watch your ASG, not all EC2 |
| Action (ALARM state) | Scale Out policy on `cloudops-asg` | |
| Action (ALARM state) | Publish to `cloudops-asg-alerts` SNS topic | |

### AWS Console Steps

1. Go to **CloudWatch → Alarms → Create alarm**
2. Click **Select metric**
3. Choose **EC2 → By Auto Scaling Group**
4. Find `cloudops-asg` in the list and tick **CPUUtilization**
5. Click **Select metric**
6. Configure the metric:
   - Statistic: **Average**
   - Period: **1 minute**
7. Set the condition:
   - Threshold type: **Static**
   - Whenever CPUUtilization is: **Greater than**
   - than: `70`
8. Click **Additional configuration**:
   - Datapoints to alarm: `2 out of 2`
   - Missing data treatment: **Treat missing data as missing**
9. Click **Next**
10. Under **Notification**, select **In alarm** and choose your SNS topic
11. Under **Auto Scaling action**, click **Add Auto Scaling action**:
    - When: **In alarm**
    - Auto Scaling group: `cloudops-asg`
    - Take action: **Add** `1` capacity unit
12. Click **Next**
13. Alarm name: `cloudops-scale-out`
14. Click **Create alarm**

### AWS CLI — One Command

Replace `ACCOUNT_ID`, `REGION`, and `ASG_POLICY_ARN` with your values.

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "cloudops-scale-out" \
  --alarm-description "Scale out: average CPU above 70% for 2 minutes" \
  --namespace "AWS/EC2" \
  --metric-name "CPUUtilization" \
  --dimensions Name=AutoScalingGroupName,Value=cloudops-asg \
  --statistic Average \
  --period 60 \
  --evaluation-periods 2 \
  --datapoints-to-alarm 2 \
  --threshold 70 \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data missing \
  --alarm-actions \
    "arn:aws:autoscaling:REGION:ACCOUNT_ID:scalingPolicy:POLICY_ID:autoScalingGroupName/cloudops-asg:policyName/cloudops-scale-out-policy" \
    "arn:aws:sns:REGION:ACCOUNT_ID:cloudops-asg-alerts" \
  --ok-actions \
    "arn:aws:sns:REGION:ACCOUNT_ID:cloudops-asg-alerts"
```

---

## Alarm 2 — Scale In (Low CPU)

**What it does:** When average CPU stays below 30% for 10 consecutive minutes, the ASG terminates one instance. This saves money by not keeping idle servers running.

**Why 30%?** Keep a comfortable headroom above zero. If you scale in at 10%, any small traffic bump would immediately breach the 70% scale-out threshold on the remaining instances. 30% gives you buffer.

**Why 10 minutes?** Scale-in is much more conservative than scale-out. You never want to aggressively remove instances — if traffic picks back up 3 minutes after a quiet period, you don't want to have already killed a server. 10 minutes confirms the load is genuinely low.

**Important — Scale In protection:** The ASG will never terminate an instance below the minimum capacity (set to 1 in this project). Even if CPU is 0%, it keeps at least 1 instance running.

### Settings

| Field | Value | Why |
|-------|-------|-----|
| Namespace | `AWS/EC2` | |
| Metric | `CPUUtilization` | |
| Statistic | `Average` | Across all instances |
| Period | `60 seconds` | |
| Evaluation periods | `10` | 10 minutes total |
| Datapoints to alarm | `10 out of 10` | All 10 periods must be below threshold |
| Threshold | `< 30` | Percent |
| Comparison | `LessThanThreshold` | |
| Treat missing data | `missing` | |
| Dimension | `AutoScalingGroupName = cloudops-asg` | |
| Action (ALARM state) | Scale In policy on `cloudops-asg` | |
| Action (ALARM state) | Publish to SNS | |

### AWS Console Steps

Follow the same steps as Alarm 1 with these changes:

- Step 7 condition: **Less than** → `30`
- Step 8 datapoints: `10 out of 10`
- Step 11 action: **Remove** `1` capacity unit
- Step 13 name: `cloudops-scale-in`

### AWS CLI — One Command

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "cloudops-scale-in" \
  --alarm-description "Scale in: average CPU below 30% for 10 minutes" \
  --namespace "AWS/EC2" \
  --metric-name "CPUUtilization" \
  --dimensions Name=AutoScalingGroupName,Value=cloudops-asg \
  --statistic Average \
  --period 60 \
  --evaluation-periods 10 \
  --datapoints-to-alarm 10 \
  --threshold 30 \
  --comparison-operator LessThanThreshold \
  --treat-missing-data missing \
  --alarm-actions \
    "arn:aws:autoscaling:REGION:ACCOUNT_ID:scalingPolicy:POLICY_ID:autoScalingGroupName/cloudops-asg:policyName/cloudops-scale-in-policy" \
    "arn:aws:sns:REGION:ACCOUNT_ID:cloudops-asg-alerts" \
  --ok-actions \
    "arn:aws:sns:REGION:ACCOUNT_ID:cloudops-asg-alerts"
```

---

## Alarm 3 — High CPU Warning (No Scaling Action)

**What it does:** Sends you an SNS email when CPU exceeds 85% for 3 minutes — but does NOT trigger any scaling. This is an early warning that your site is under very heavy stress and scaling may not be keeping up.

**Why have this if Alarm 1 already scales at 70%?**
Alarm 1 adds one instance at a time. Under extreme traffic, even the new instance might hit 100% before it's fully warmed up. Alarm 3 catches that scenario and tells you: "something is seriously wrong, go check manually."

### Settings

| Field | Value |
|-------|-------|
| Metric | `CPUUtilization` |
| Statistic | `Average` |
| Period | `60 seconds` |
| Evaluation periods | `3` |
| Datapoints to alarm | `3 out of 3` |
| Threshold | `> 85` |
| Comparison | `GreaterThanThreshold` |
| Action | SNS notification only — no scaling action |
| Alarm name | `cloudops-high-cpu-warning` |

### AWS Console Steps

Same as Alarm 1 with these changes:
- Threshold: `85`
- Datapoints: `3 out of 3`
- **Do NOT add** an Auto Scaling action — SNS notification only
- Name: `cloudops-high-cpu-warning`

### AWS CLI — One Command

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "cloudops-high-cpu-warning" \
  --alarm-description "Warning: CPU critically high above 85% — check scaling" \
  --namespace "AWS/EC2" \
  --metric-name "CPUUtilization" \
  --dimensions Name=AutoScalingGroupName,Value=cloudops-asg \
  --statistic Average \
  --period 60 \
  --evaluation-periods 3 \
  --datapoints-to-alarm 3 \
  --threshold 85 \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data missing \
  --alarm-actions \
    "arn:aws:sns:REGION:ACCOUNT_ID:cloudops-asg-alerts"
```

---

## Alarm 4 — Instance Health Check Failed

**What it does:** Fires when any EC2 instance fails its AWS status check for 2 consecutive minutes. Status checks are AWS's built-in test of whether the underlying hardware and the OS are functioning. A failure usually means the instance is dead and needs replacing.

**How ASG handles it:** The ASG automatically terminates an unhealthy instance and launches a new one. This alarm just makes sure you know it happened via an SNS email.

**Two types of status checks AWS runs:**
- System status check — checks AWS hardware (network, power, host hardware)
- Instance status check — checks your OS (kernel, networking stack)

### Settings

| Field | Value |
|-------|-------|
| Namespace | `AWS/EC2` |
| Metric | `StatusCheckFailed` |
| Statistic | `Maximum` |
| Period | `60 seconds` |
| Evaluation periods | `2` |
| Datapoints to alarm | `2 out of 2` |
| Threshold | `>= 1` |
| Comparison | `GreaterThanOrEqualToThreshold` |
| Treat missing data | `breaching` — if no data arrives, assume the instance is dead |
| Dimension | `AutoScalingGroupName = cloudops-asg` |
| Action | SNS notification only |
| Alarm name | `cloudops-instance-health` |

> Note on `treat-missing-data = breaching` here: for health checks specifically, if an instance stops reporting data entirely (e.g. it crashed), that IS a failure. We want the alarm to fire in that case.

### AWS Console Steps

1. CloudWatch → Alarms → Create alarm → Select metric
2. Choose **EC2 → By Auto Scaling Group**
3. Find `cloudops-asg` → tick **StatusCheckFailed**
4. Statistic: **Maximum** (any single failure counts)
5. Period: **1 minute**
6. Condition: **Greater than or equal to** → `1`
7. Additional config → Missing data: **Treat as bad (breaching)**
8. Add SNS notification, no scaling action
9. Name: `cloudops-instance-health`

### AWS CLI — One Command

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "cloudops-instance-health" \
  --alarm-description "Alert: EC2 instance failed status check" \
  --namespace "AWS/EC2" \
  --metric-name "StatusCheckFailed" \
  --dimensions Name=AutoScalingGroupName,Value=cloudops-asg \
  --statistic Maximum \
  --period 60 \
  --evaluation-periods 2 \
  --datapoints-to-alarm 2 \
  --threshold 1 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --treat-missing-data breaching \
  --alarm-actions \
    "arn:aws:sns:REGION:ACCOUNT_ID:cloudops-asg-alerts"
```

---

## Alarm 5 — ALB 5xx Error Rate

**What it does:** Fires when your instances return more than 10 HTTP 5xx error responses to the ALB within a 5-minute window. A 5xx error means the server crashed or returned an invalid response — as distinct from a 4xx error which is the client's fault.

**Why monitor this separately from CPU?** An instance can be at 20% CPU but still return 500 errors if nginx crashes or the application has a bug. This alarm catches failures that CPU-based alarms would miss entirely.

### Settings

| Field | Value |
|-------|-------|
| Namespace | `AWS/ApplicationELB` |
| Metric | `HTTPCode_Target_5XX_Count` |
| Statistic | `Sum` |
| Period | `300 seconds` (5 minutes) |
| Evaluation periods | `1` |
| Datapoints to alarm | `1 out of 1` |
| Threshold | `> 10` |
| Comparison | `GreaterThanThreshold` |
| Treat missing data | `notBreaching` — no errors = healthy |
| Dimensions | `LoadBalancer = app/cloudops-alb/XXXX` |
| Action | SNS notification only |
| Alarm name | `cloudops-alb-5xx-errors` |

### AWS Console Steps

1. CloudWatch → Alarms → Create alarm → Select metric
2. Choose **ApplicationELB → Per AppELB Metrics**
3. Find your `cloudops-alb` → tick **HTTPCode_Target_5XX_Count**
4. Statistic: **Sum**
5. Period: **5 minutes**
6. Condition: **Greater than** → `10`
7. Missing data: **Treat as not breaching**
8. Add SNS notification
9. Name: `cloudops-alb-5xx-errors`

### AWS CLI — One Command

Replace `ALB_SUFFIX` with the suffix from your ALB ARN (the part after `loadbalancer/`).

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "cloudops-alb-5xx-errors" \
  --alarm-description "Alert: more than 10 server errors in 5 minutes" \
  --namespace "AWS/ApplicationELB" \
  --metric-name "HTTPCode_Target_5XX_Count" \
  --dimensions Name=LoadBalancer,Value=app/cloudops-alb/ALB_SUFFIX \
  --statistic Sum \
  --period 300 \
  --evaluation-periods 1 \
  --datapoints-to-alarm 1 \
  --threshold 10 \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions \
    "arn:aws:sns:REGION:ACCOUNT_ID:cloudops-asg-alerts"
```

---

## Alarm 6 — ALB Response Latency

**What it does:** Fires when the average response time from your instances to the ALB exceeds 2 seconds for 5 consecutive minutes. Slow responses often indicate the instances are overloaded even if CPU looks acceptable — for example, when nginx is queuing connections.

**What is a good target?** For a static website served by nginx, responses should take less than 100 milliseconds. A 2-second threshold gives plenty of headroom while still catching real problems.

### Settings

| Field | Value |
|-------|-------|
| Namespace | `AWS/ApplicationELB` |
| Metric | `TargetResponseTime` |
| Statistic | `Average` |
| Period | `60 seconds` |
| Evaluation periods | `5` |
| Datapoints to alarm | `5 out of 5` |
| Threshold | `> 2` |
| Comparison | `GreaterThanThreshold` |
| Treat missing data | `notBreaching` |
| Dimensions | `LoadBalancer = app/cloudops-alb/XXXX` |
| Action | SNS notification only |
| Alarm name | `cloudops-alb-latency` |

### AWS Console Steps

1. CloudWatch → Alarms → Create alarm → Select metric
2. **ApplicationELB → Per AppELB Metrics**
3. Select `TargetResponseTime` for your ALB
4. Statistic: **Average**, Period: **1 minute**
5. Condition: **Greater than** → `2`
6. Datapoints: `5 out of 5`
7. Missing data: **Treat as not breaching**
8. Add SNS notification
9. Name: `cloudops-alb-latency`

### AWS CLI — One Command

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "cloudops-alb-latency" \
  --alarm-description "Alert: average response time above 2 seconds for 5 minutes" \
  --namespace "AWS/ApplicationELB" \
  --metric-name "TargetResponseTime" \
  --dimensions Name=LoadBalancer,Value=app/cloudops-alb/ALB_SUFFIX \
  --statistic Average \
  --period 60 \
  --evaluation-periods 5 \
  --datapoints-to-alarm 5 \
  --threshold 2 \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions \
    "arn:aws:sns:REGION:ACCOUNT_ID:cloudops-asg-alerts"
```

---

## Create All Alarms at Once

Save time by running this script. Fill in your values at the top and it creates all 6 alarms in one go.

```bash
#!/bin/bash
# create-all-alarms.sh
# Run this after your ASG, ALB, and SNS topic are set up.

# ── FILL THESE IN ──────────────────────────────────
REGION="us-east-1"
ACCOUNT_ID="123456789012"
ASG_NAME="cloudops-asg"
ALB_SUFFIX="app/cloudops-alb/1234567890abcdef"    # from your ALB ARN
SNS_ARN="arn:aws:sns:${REGION}:${ACCOUNT_ID}:cloudops-asg-alerts"
SCALE_OUT_POLICY_ARN="arn:aws:autoscaling:${REGION}:${ACCOUNT_ID}:scalingPolicy:XXXX:autoScalingGroupName/${ASG_NAME}:policyName/cloudops-scale-out-policy"
SCALE_IN_POLICY_ARN="arn:aws:autoscaling:${REGION}:${ACCOUNT_ID}:scalingPolicy:XXXX:autoScalingGroupName/${ASG_NAME}:policyName/cloudops-scale-in-policy"
# ───────────────────────────────────────────────────

echo "Creating 6 CloudWatch alarms..."

# Alarm 1 — Scale Out
aws cloudwatch put-metric-alarm \
  --alarm-name "cloudops-scale-out" \
  --alarm-description "Scale out: CPU above 70% for 2 minutes" \
  --namespace "AWS/EC2" \
  --metric-name "CPUUtilization" \
  --dimensions Name=AutoScalingGroupName,Value=${ASG_NAME} \
  --statistic Average \
  --period 60 \
  --evaluation-periods 2 \
  --datapoints-to-alarm 2 \
  --threshold 70 \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data missing \
  --alarm-actions "${SCALE_OUT_POLICY_ARN}" "${SNS_ARN}" \
  --ok-actions "${SNS_ARN}" \
  --region ${REGION}
echo "  [1/6] cloudops-scale-out created"

# Alarm 2 — Scale In
aws cloudwatch put-metric-alarm \
  --alarm-name "cloudops-scale-in" \
  --alarm-description "Scale in: CPU below 30% for 10 minutes" \
  --namespace "AWS/EC2" \
  --metric-name "CPUUtilization" \
  --dimensions Name=AutoScalingGroupName,Value=${ASG_NAME} \
  --statistic Average \
  --period 60 \
  --evaluation-periods 10 \
  --datapoints-to-alarm 10 \
  --threshold 30 \
  --comparison-operator LessThanThreshold \
  --treat-missing-data missing \
  --alarm-actions "${SCALE_IN_POLICY_ARN}" "${SNS_ARN}" \
  --ok-actions "${SNS_ARN}" \
  --region ${REGION}
echo "  [2/6] cloudops-scale-in created"

# Alarm 3 — High CPU Warning
aws cloudwatch put-metric-alarm \
  --alarm-name "cloudops-high-cpu-warning" \
  --alarm-description "Warning: CPU critically high above 85%" \
  --namespace "AWS/EC2" \
  --metric-name "CPUUtilization" \
  --dimensions Name=AutoScalingGroupName,Value=${ASG_NAME} \
  --statistic Average \
  --period 60 \
  --evaluation-periods 3 \
  --datapoints-to-alarm 3 \
  --threshold 85 \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data missing \
  --alarm-actions "${SNS_ARN}" \
  --region ${REGION}
echo "  [3/6] cloudops-high-cpu-warning created"

# Alarm 4 — Instance Health
aws cloudwatch put-metric-alarm \
  --alarm-name "cloudops-instance-health" \
  --alarm-description "Alert: EC2 instance failed status check" \
  --namespace "AWS/EC2" \
  --metric-name "StatusCheckFailed" \
  --dimensions Name=AutoScalingGroupName,Value=${ASG_NAME} \
  --statistic Maximum \
  --period 60 \
  --evaluation-periods 2 \
  --datapoints-to-alarm 2 \
  --threshold 1 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --treat-missing-data breaching \
  --alarm-actions "${SNS_ARN}" \
  --region ${REGION}
echo "  [4/6] cloudops-instance-health created"

# Alarm 5 — ALB 5xx Errors
aws cloudwatch put-metric-alarm \
  --alarm-name "cloudops-alb-5xx-errors" \
  --alarm-description "Alert: more than 10 server errors in 5 minutes" \
  --namespace "AWS/ApplicationELB" \
  --metric-name "HTTPCode_Target_5XX_Count" \
  --dimensions Name=LoadBalancer,Value=${ALB_SUFFIX} \
  --statistic Sum \
  --period 300 \
  --evaluation-periods 1 \
  --datapoints-to-alarm 1 \
  --threshold 10 \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions "${SNS_ARN}" \
  --region ${REGION}
echo "  [5/6] cloudops-alb-5xx-errors created"

# Alarm 6 — ALB Latency
aws cloudwatch put-metric-alarm \
  --alarm-name "cloudops-alb-latency" \
  --alarm-description "Alert: average response time above 2 seconds" \
  --namespace "AWS/ApplicationELB" \
  --metric-name "TargetResponseTime" \
  --dimensions Name=LoadBalancer,Value=${ALB_SUFFIX} \
  --statistic Average \
  --period 60 \
  --evaluation-periods 5 \
  --datapoints-to-alarm 5 \
  --threshold 2 \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions "${SNS_ARN}" \
  --region ${REGION}
echo "  [6/6] cloudops-alb-latency created"

echo ""
echo "All 6 alarms created. Verify with:"
echo "  aws cloudwatch describe-alarms --alarm-names \\"
echo "    cloudops-scale-out cloudops-scale-in \\"
echo "    cloudops-high-cpu-warning cloudops-instance-health \\"
echo "    cloudops-alb-5xx-errors cloudops-alb-latency \\"
echo "    --query 'MetricAlarms[*].[AlarmName,StateValue]' \\"
echo "    --output table"
```

---

## Verify All Alarms Are Working

```bash
# Check all 6 alarm states at once
aws cloudwatch describe-alarms \
  --alarm-names \
    cloudops-scale-out \
    cloudops-scale-in \
    cloudops-high-cpu-warning \
    cloudops-instance-health \
    cloudops-alb-5xx-errors \
    cloudops-alb-latency \
  --query 'MetricAlarms[*].[AlarmName,StateValue,StateReason]' \
  --output table
```

Expected output when everything is healthy:

```
-----------------------------------------------------------------------
|                        DescribeAlarms                               |
+------------------------------+------------------+-------------------+
|  cloudops-scale-out          |  OK              |  CPU below 70%    |
|  cloudops-scale-in           |  OK              |  CPU above 30%    |
|  cloudops-high-cpu-warning   |  OK              |  CPU below 85%    |
|  cloudops-instance-health    |  OK              |  No failures       |
|  cloudops-alb-5xx-errors     |  OK              |  No 5xx errors     |
|  cloudops-alb-latency        |  OK              |  Latency < 2s      |
+------------------------------+------------------+-------------------+
```

> New alarms may show `INSUFFICIENT_DATA` for the first 2–5 minutes while CloudWatch waits for initial metric data points to arrive.

---

## Test the Scale-Out Alarm Manually

```bash
# SSH into one of your EC2 instances
ssh -i your-key.pem ubuntu@INSTANCE_PUBLIC_IP

# Install the stress tool
sudo apt-get install stress -y

# Max out CPU for 5 minutes
stress --cpu 2 --timeout 300

# In a separate terminal, watch the alarm state change:
watch -n 10 "aws cloudwatch describe-alarms \
  --alarm-names cloudops-scale-out \
  --query 'MetricAlarms[0].[StateValue,StateReason]' \
  --output table"
```

What you will see:
- After 1 minute: alarm state moves to `ALARM`
- After 2 minutes: ASG launches a new instance
- You receive an SNS email
- After `stress` finishes and CPU drops, alarm moves back to `OK`
- After 10 minutes of low CPU: scale-in alarm fires, ASG terminates the extra instance
- You receive another SNS email

---

## Understanding Alarm States

Every CloudWatch alarm is always in one of three states:

| State | Meaning |
|-------|---------|
| `OK` | The metric is within the acceptable range — no action taken |
| `ALARM` | The metric has breached the threshold for the required number of periods — action is being taken |
| `INSUFFICIENT_DATA` | Not enough data points yet to evaluate the condition — usually happens right after creating an alarm or when an instance just started |

---

## Key Terms Explained Simply

**Period** — how often CloudWatch takes a reading of the metric. A period of 60 seconds means one data point per minute. A period of 300 seconds means one data point every 5 minutes.

**Evaluation periods** — how many consecutive periods must breach the threshold before the alarm fires. Scale-out uses 2 periods so the alarm needs 2 minutes of high CPU in a row, not just a single spike.

**Datapoints to alarm** — a sub-setting of evaluation periods. `2 out of 2` means both periods must breach. `3 out of 5` would mean 3 out of any 5 recent periods, which is more forgiving of brief spikes.

**Treat missing data** — what to do when an instance stops reporting metrics:
- `missing` — do nothing, ignore the gap
- `notBreaching` — treat the gap as if the metric is within the safe zone
- `breaching` — treat the gap as if the metric exceeded the threshold (good for health checks — silence usually means something is wrong)
- `ignore` — keep the alarm in its current state

**Cooldown period** — after a scaling action, the ASG waits this many seconds before it will act on the next alarm. Prevents runaway scaling where the system launches 10 instances in a row during a traffic spike. Default is 300 seconds.

---

## Delete All Alarms When Done

```bash
aws cloudwatch delete-alarms \
  --alarm-names \
    cloudops-scale-out \
    cloudops-scale-in \
    cloudops-high-cpu-warning \
    cloudops-instance-health \
    cloudops-alb-5xx-errors \
    cloudops-alb-latency
```
