IMAGE_NAME := docker-status-mailer
CONTAINER_NAME := status-mailer
SCRIPT := /docker_status_report.sh

.PHONY: help build run stop restart clean logs test recipients ps crontab-check status all

## Default target: show help when running bare `make`
help:
	@echo ""
	@echo "Docker Status Mailer — available commands:"
	@echo ""
	@echo "  make build            Build the Docker image"
	@echo "  make run              Stop old container and start a fresh one"
	@echo "  make restart          Rebuild + restart in one step (use after editing the script)"
	@echo "  make test             Force-run the report script right now, bypassing cron"
	@echo "  make recipients       Show which recipients are baked into the running script"
	@echo "  make logs             Show the msmtp send log"
	@echo "  make crontab-check    Show the container's active crontab"
	@echo "  make ps               Show running processes inside the container"
	@echo "  make status           Show container status (check for duplicates)"
	@echo "  make all              Rebuild + restart + test, all in one go"
	@echo "  make clean            Stop container and remove the built image"
	@echo ""

build:
	docker build -t $(IMAGE_NAME) .

stop:
	-docker stop $(CONTAINER_NAME)
	-docker rm $(CONTAINER_NAME)

run: stop
	docker run -d --name $(CONTAINER_NAME) \
		--restart unless-stopped \
		-e TZ=Asia/Manila \
		-v /var/run/docker.sock:/var/run/docker.sock:ro \
		$(IMAGE_NAME)

restart: stop build run

test:
	docker exec $(CONTAINER_NAME) $(SCRIPT)

recipients:
	docker exec $(CONTAINER_NAME) grep -E "TO_RECIPIENTS|CC_RECIPIENTS" $(SCRIPT)
logs:
	docker exec $(CONTAINER_NAME) cat /var/log/msmtp.log

crontab-check:
	docker exec $(CONTAINER_NAME) crontab -l

ps:
	docker exec $(CONTAINER_NAME) ps aux

status:
	docker ps -a | grep $(CONTAINER_NAME)

all: restart test

clean: stop
	-docker rmi $(IMAGE_NAME)
