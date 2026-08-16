#!/bin/bash

LOCKFILE="/tmp/docker_status_report.lock"
if [ -e "$LOCKFILE" ]; then
  echo "$(date): Script already running or ran within lock window, exiting." >> /var/log/cron.log
  exit 1
fi
touch "$LOCKFILE"
trap "rm -f $LOCKFILE" EXIT

TO_RECIPIENTS="jvdumlao@gmanetwork.com avortigoza@gmanetwork.com prramos@gmanetwork.com avvillaceran@gmanetwork.com"
ALL_RECIPIENTS="$TO_RECIPIENTS"
#CC_RECIPIENTS="jidoringo@gmanetwork.com jvdumlao@gmanetwork.com rcmacorol@gmanetwork.com mlnaval@gmanetwork.com prramos@gmanetwork.com fsvalois@gmanetwork.com avvillaceran@gmanetwork.com"
#ALL_RECIPIENTS="$TO_RECIPIENTS $CC_RECIPIENTS"

HOSTNAME="vmmams-core"
REPORT_DATE=$(date +"%A, %B %d, %Y %I:%M %p")

ROWS=""
ATTENTION_ROWS=""

TOTAL=0
HEALTHY_COUNT=0
RUNNING_COUNT=0
STOPPED_COUNT=0
UNHEALTHY_COUNT=0
OTHER_COUNT=0

CONTAINER_IDS=$(docker ps -aq | sort)
CONTAINER_TOTAL=$(echo "$CONTAINER_IDS" | wc -l)
IDX=0

for ID in $CONTAINER_IDS; do
  IDX=$((IDX+1))
  INFO=$(docker inspect "$ID")

  NAME=$(echo "$INFO" | jq -r '.[0].Name' | sed 's|^/||')
  STATUS=$(echo "$INFO" | jq -r '.[0].State.Status')
  HEALTH=$(echo "$INFO" | jq -r '.[0].State.Health.Status // empty')

  if [ "$HEALTH" = "healthy" ]; then
    LABEL="healthy"; COLOR="#22c55e"
    HEALTHY_COUNT=$((HEALTHY_COUNT+1))
  elif [ "$HEALTH" = "unhealthy" ]; then
    LABEL="unhealthy"; COLOR="#ef4444"
    UNHEALTHY_COUNT=$((UNHEALTHY_COUNT+1))
    ATTENTION_ROWS+="<tr><td style=\"padding:0 8px 8px 0;color:#7f1d1d;font-size:14px;vertical-align:top;width:14px;\">&bull;</td><td style=\"padding:0 0 8px 0;color:#7f1d1d;font-size:14px;\"><strong>${NAME}</strong> — unhealthy</td></tr>"
  elif [ "$STATUS" = "running" ]; then
    LABEL="running"; COLOR="#22c55e"
    RUNNING_COUNT=$((RUNNING_COUNT+1))
  elif [ "$STATUS" = "exited" ]; then
    LABEL="stopped"; COLOR="#ef4444"
    STOPPED_COUNT=$((STOPPED_COUNT+1))
    ATTENTION_ROWS+="<tr><td style=\"padding:0 8px 8px 0;color:#7f1d1d;font-size:14px;vertical-align:top;width:14px;\">&bull;</td><td style=\"padding:0 0 8px 0;color:#7f1d1d;font-size:14px;\"><strong>${NAME}</strong> — stopped</td></tr>"
  elif [ "$STATUS" = "created" ]; then
    LABEL="created"; COLOR="#6b7280"
    OTHER_COUNT=$((OTHER_COUNT+1))
    ATTENTION_ROWS+="<tr><td style=\"padding:0 8px 8px 0;color:#7f1d1d;font-size:14px;vertical-align:top;width:14px;\">&bull;</td><td style=\"padding:0 0 8px 0;color:#7f1d1d;font-size:14px;\"><strong>${NAME}</strong> — created</td></tr>"
  else
    LABEL="$STATUS"; COLOR="#6b7280"
    OTHER_COUNT=$((OTHER_COUNT+1))
    ATTENTION_ROWS+="<tr><td style=\"padding:0 8px 8px 0;color:#7f1d1d;font-size:14px;vertical-align:top;width:14px;\">&bull;</td><td style=\"padding:0 0 8px 0;color:#7f1d1d;font-size:14px;\"><strong>${NAME}</strong> — ${STATUS}</td></tr>"
  fi

  TOTAL=$((TOTAL+1))

  if [ "$IDX" -eq "$CONTAINER_TOTAL" ]; then
    ROW_BORDER=""
  else
    ROW_BORDER="border-bottom:1px solid #e5e7eb;"
  fi

  ROWS+="<tr>
    <td style=\"padding:16px 24px;${ROW_BORDER}color:#0ea5e9;font-size:15px;font-weight:500;font-family:Arial,Helvetica,sans-serif;\">${NAME}</td>
    <td style=\"padding:16px 24px;${ROW_BORDER}font-family:Arial,Helvetica,sans-serif;\">
      <table role=\"presentation\" cellpadding=\"0\" cellspacing=\"0\" border=\"0\"><tr>
        <td bgcolor=\"${COLOR}\" style=\"background:${COLOR};color:#ffffff;padding:6px 16px;border-radius:14px;font-size:13px;font-weight:600;font-family:Arial,Helvetica,sans-serif;text-align:center;\">${LABEL}</td>
      </tr></table>
    </td>
  </tr>"
done

ISSUES=$((STOPPED_COUNT + UNHEALTHY_COUNT + OTHER_COUNT))

if [ "$ISSUES" -eq 0 ]; then
  OVERALL_COLOR="#22c55e"
else
  OVERALL_COLOR="#ef4444"
fi

HEALTH_SCORE=$(( (TOTAL - ISSUES) * 100 / TOTAL ))

SUMMARY_TEXT="A total of ${TOTAL} Docker containers were assessed on host ${HOSTNAME}.<br><br>${HEALTHY_COUNT} container(s) reported a healthy state through Docker health checks, while ${RUNNING_COUNT} container(s) were running normally without health check monitoring enabled.<br><br>${STOPPED_COUNT} container(s) were stopped, ${UNHEALTHY_COUNT} container(s) were unhealthy, and ${OTHER_COUNT} container(s) reported an unexpected state.<br><br>The environment health score is ${HEALTH_SCORE}%."

ATTENTION_BLOCK=""
if [ -n "$ATTENTION_ROWS" ]; then
ATTENTION_BLOCK="
<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" border=\"0\" style=\"max-width:900px;margin:0 auto 20px auto;\">
<tr><td style=\"background:#ffffff;border:1px solid #fecaca;border-radius:12px;padding:30px;font-family:Arial,Helvetica,sans-serif;overflow:hidden;\">
  <h2 style=\"margin:0 0 16px 0;color:#b91c1c;font-size:20px;\">Containers Requiring Attention</h2>
  <table role=\"presentation\" cellpadding=\"0\" cellspacing=\"0\" border=\"0\" style=\"width:100%;\">${ATTENTION_ROWS}</table>
</td></tr>
</table>"
fi

HTML=$(cat <<EOF
<html>
<head>
<meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
<!--[if mso]>
<style type="text/css">
table {border-collapse:collapse;}
</style>
<![endif]-->
</head>
<body style="margin:0;padding:0;background:#f3f4f6;font-family:Arial,Helvetica,sans-serif;">

<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#f3f4f6;">
<tr><td align="center" style="padding:30px 20px;">

<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:900px;">

<!-- HEADER -->
<tr><td style="background:#ffffff;border:1px solid #e5e7eb;border-radius:12px;padding:30px;font-family:Arial,Helvetica,sans-serif;overflow:hidden;">
  <div style="font-size:13px;color:#6b7280;text-transform:uppercase;letter-spacing:1px;">Weekly Infrastructure Report — DASH</div>
<h1 style="margin:10px 0 20px 0;font-size:28px;color:#111827;">Docker Automated Status Health (Check)</h1>

  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">
  <tr><td bgcolor="#f9fafb" style="background:#f9fafb;border-left:5px solid ${OVERALL_COLOR};padding:20px;border-radius:10px;">
    <div style="color:#6b7280;font-size:14px;">Host: ${HOSTNAME}</div>
    <div style="margin-top:4px;color:#6b7280;font-size:14px;">Generated: ${REPORT_DATE}</div>
  </td></tr>
  </table>
</td></tr>

<tr><td style="height:20px;line-height:20px;font-size:0;">&nbsp;</td></tr>

<!-- METRICS -->
<tr><td style="background:#ffffff;border:1px solid #e5e7eb;border-radius:12px;padding:30px;font-family:Arial,Helvetica,sans-serif;overflow:hidden;">
  <h2 style="margin:0 0 16px 0;color:#111827;font-size:20px;">Environment Summary</h2>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="font-size:15px;">
    <tr><td style="padding:10px 0;color:#374151;">Health Score</td><td align="right" style="padding:10px 0;font-weight:700;color:#111827;">${HEALTH_SCORE}%</td></tr>
    <tr><td style="padding:10px 0;color:#374151;border-top:1px solid #f0f0f0;">Total Containers</td><td align="right" style="padding:10px 0;font-weight:700;color:#111827;border-top:1px solid #f0f0f0;">${TOTAL}</td></tr>
    <tr><td style="padding:10px 0;color:#374151;border-top:1px solid #f0f0f0;">Healthy</td><td align="right" style="padding:10px 0;font-weight:700;color:#22c55e;border-top:1px solid #f0f0f0;">${HEALTHY_COUNT}</td></tr>
    <tr><td style="padding:10px 0;color:#374151;border-top:1px solid #f0f0f0;">Running</td><td align="right" style="padding:10px 0;font-weight:700;color:#22c55e;border-top:1px solid #f0f0f0;">${RUNNING_COUNT}</td></tr>
    <tr><td style="padding:10px 0;color:#374151;border-top:1px solid #f0f0f0;">Stopped</td><td align="right" style="padding:10px 0;font-weight:700;color:#ef4444;border-top:1px solid #f0f0f0;">${STOPPED_COUNT}</td></tr>
    <tr><td style="padding:10px 0;color:#374151;border-top:1px solid #f0f0f0;">Unhealthy</td><td align="right" style="padding:10px 0;font-weight:700;color:#ef4444;border-top:1px solid #f0f0f0;">${UNHEALTHY_COUNT}</td></tr>
  </table>
</td></tr>

<tr><td style="height:20px;line-height:20px;font-size:0;">&nbsp;</td></tr>

<!-- CONTAINER LIST -->
<tr><td style="background:#ffffff;border:1px solid #e5e7eb;border-radius:12px;font-family:Arial,Helvetica,sans-serif;overflow:hidden;" >
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">
    <tr bgcolor="#f3f4f6">
      <th align="left" style="padding:18px 24px;color:#374151;font-size:14px;font-weight:600;">Name</th>
      <th align="left" style="padding:18px 24px;color:#374151;font-size:14px;font-weight:600;">State</th>
    </tr>
    ${ROWS}
  </table>
</td></tr>

<tr><td style="height:20px;line-height:20px;font-size:0;">&nbsp;</td></tr>

<!-- EXECUTIVE SUMMARY -->
<tr><td style="background:#ffffff;border:1px solid #e5e7eb;border-radius:12px;padding:30px;font-family:Arial,Helvetica,sans-serif;overflow:hidden;">
  <h2 style="margin:0 0 16px 0;color:#111827;font-size:20px;">Executive Summary</h2>
  <p style="color:#374151;font-size:14px;line-height:1.7;margin:0;">${SUMMARY_TEXT}</p>
</td></tr>

<tr><td style="height:20px;line-height:20px;font-size:0;">&nbsp;</td></tr>

</table>
EOF
)

HTML+="${ATTENTION_BLOCK}"

HTML+="
<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" border=\"0\" style=\"max-width:900px;margin:0 auto;\">
<tr><td align=\"center\" style=\"padding:10px 0;color:#9ca3af;font-size:12px;font-family:Arial,Helvetica,sans-serif;\">
	DASH — Docker Automated Status Health (Check) Report
</td></tr>
</table>

</td></tr>
</table>

</body>
</html>
"

SUBJECT="DASH Weekly Report - $(date +"%B %-d, %Y")"

{
  echo "To: $(echo "$TO_RECIPIENTS" | tr ' ' ', ')"
 # echo "Cc: $(echo "$CC_RECIPIENTS" | tr ' ' ', ')"
  echo "From: \"DASH Notifications\" <gma7postmams@gmail.com>"
  echo "Subject: ${SUBJECT}"
  echo "MIME-Version: 1.0"
  echo "Content-Type: text/html; charset=UTF-8"
  echo
  echo "$HTML"
} | msmtp -a gmail $ALL_RECIPIENTS
