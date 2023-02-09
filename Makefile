all: stop start sleep deploy

.PHONY: stop
stop:
	k3d cluster delete mycluster

.PHONY: start
start:
	k3d cluster create mycluster \
		--api-port 6550 \
		--timestamps \
		-p 80:80@loadbalancer \
		-p 8080:8080@loadbalancer \
		--k3s-arg '--disable=traefik@server:0' \
		-i rancher/k3s:v1.25.4-k3s1
	k3d image import traefik:v3.0 -c mycluster
	k3d image import traefik/whoami:latest -c mycluster

.PHONY: sleep
sleep:
	sleep 5s

.PHONY: deploy
deploy:
	kubectl apply -f 01-start/
	kubectl apply -f 02-RateLimit/
	kubectl apply -f 03-InFlightReq/
	kubectl apply -f 04-Retry/
	$(MAKE) -C ./05-circuit-breaker/ build
	k3d image import circuit-breaker-test -c mycluster
	kubectl apply -f 05-circuit-breaker/

.PHONY: test-ratelimit
test-ratelimit:
	echo "GET http://localhost/ratelimit" \
		| vegeta attack -duration=200s \
		| vegeta report

.PHONY: test-infligthreq
test-infligthreq:
	hey -z 20s http://localhost/inflightreq
	hey -z 20s http://localhost/whoami
	
.PHONY: test-retry
test-retry:
	curl http://localhost/retry
	curl http://localhost/whoami

.PHONY: test-circuit-breaker
test-circuit-breaker:
	echo "GET http://localhost/circuit-breaker" \
		| vegeta attack -duration=200s \
		| vegeta report

.PHONY: test-circuit-breaker-backend
test-circuit-breaker-backend:
	echo "GET http://localhost/backend" \
		| vegeta attack -duration=200s \
		| vegeta report
