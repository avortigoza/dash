FROM alpine:latest
RUN apk add --no-cache docker-cli msmtp bash jq curl ca-certificates tzdata
ENV TZ=Asia/Manila
COPY docker_status_report.sh /docker_status_report.sh
COPY msmtprc /etc/msmtprc
COPY crontab.txt /etc/crontabs/root
RUN chmod +x /docker_status_report.sh && chmod 600 /etc/msmtprc
CMD ["crond", "-f", "-l", "2"]
