# The Ultimate Guide to Managing Application Traffic Using Traefik Middlewares

[Rate limiting](https://traefik.io/glossary/rate-limiting-what-it-is-and-why-it-matters/), maximum concurrent connections, retries, and circuit breakers are all techniques used to manage the flow of traffic to a server or service and improve its stability and performance.

And these techniques come with a bunch of benefits, including:

- **Protection against malicious traffic:** You can use rate limiting, maximum concurrent connections, and circuit breakers to protect against [Denial of Service (DoS)](https://www.cloudflare.com/learning/ddos/glossary/denial-of-service/) attacks and other forms of malicious traffic. These solutions limit the rate at which requests are accepted and impose limits on the number of open connections or failed requests.
- **Improved system reliability and user experience:** By limiting the processing rate of requests and implementing retries and circuit breakers, it's possible to mitigate the impact of temporary issues — such as server overloads — and ensure that the system remains available and responsive to clients. This can help to ensure that the system remains secure and able to withstand attacks.
- **Efficient resource usage:** By limiting the rate at which requests are processed and the number of concurrent connections, it's possible to ensure that the server's resources are used efficiently and prevent them from being wasted on unnecessary or redundant requests.
- **Easy to put in place:** Implementing all these techniques may sound difficult, but it’s really not as bad as it sounds — when you have the right tools, of course! Traefik's rate limiting and traffic management [middlewares](https://doc.traefik.io/traefik/middlewares/overview/) make it easy to use these techniques in a variety of environments and systems.
- **Customization and flexibility:** Traefik middlewares can be customized and tailored to the specific needs and requirements of a particular system, allowing administrators to fine-tune their settings and adjust them as needed.

In this detailed tutorial, I will show you how to manage traffic and limit requests accessing web servers using Traefik Proxy and its middlewares. I will also provide you with several hands-on examples of how to use the RateLimit, InFlightReq, Retry, and CircuitBreaker middlewares.

You can find all the examples used in the article in [this repository](https://github.com/traefik-tech-blog/traefik-traffic-middlewares).

## Setting everything up

To follow this tutorial, you will need to have a Kubernetes cluster ready.
The following is a quick start on how to have a simple Kubernetes cluster ([Rancher's K3s](https://k3s.io)) running with Traefik, as well as a demo web service.

To start a [K3s cluster](https://traefik.io/glossary/k3s-explained/), this command spins up a Kubernetes cluster running in a Docker container:

```bash
k3d cluster create traefik-cluster-blog \
	--api-port 6550 \
	-p 80:80@loadbalancer \
	--k3s-arg '--disable=traefik@server:0' \ # We want to handle Traefik on our side
	-i rancher/k3s:v1.21.4-k3s1
```

### Implementing role-based access control and resources definition

As Traefik Proxy uses the Kubernetes API to [discover running services](https://doc.traefik.io/traefik/providers/kubernetes-crd/), we have to allow Traefik to access the resources it needs.

For this, we can install RBAC for Traefik:

```bash
kubectl apply -f https://raw.githubusercontent.com/traefik/traefik/v2.9/docs/content/reference/dynamic-configuration/kubernetes-crd-rbac.yml
```

And for the sake of this tutorial, we will be using Traefik's [Custom Resource Definition](https://doc.traefik.io/traefik/providers/kubernetes-crd/#configuration-requirements):

```bash
kubectl apply -f https://raw.githubusercontent.com/traefik/traefik/v2.9/docs/content/reference/dynamic-configuration/kubernetes-crd-definition-v1.yml
```

### Installing Traefik Proxy

Once all resources are set up, we can install Traefik Proxy in the cluster using a deployment, a service account, and a load balancer:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: traefik-ingress-controller

---
kind: Deployment
apiVersion: apps/v1
metadata:
  name: traefik
  labels:
    app: traefik

spec:
  replicas: 1
  selector:
    matchLabels:
      app: traefik
  template:
    metadata:
      labels:
        app: traefik
    spec:
      serviceAccountName: traefik-ingress-controller
      containers:
        - name: traefik
          image: traefik:v2.9
            - --providers.kubernetescrd
          ports:
            - name: web
              containerPort: 80

---
apiVersion: v1
kind: Service
metadata:
  name: traefik
spec:
  type: LoadBalancer
  selector:
    app: traefik
  ports:
    - protocol: TCP
      port: 80
      name: web
      targetPort: 80
```

### Deploying the sample application whoami

To test our middlewares, we will use the simple `traefik/whoami` Docker image as a web service.

Let's deploy it using a deployment and a service.

```yaml
kind: Deployment
apiVersion: apps/v1
metadata:
  name: whoami
  namespace: default
  labels:
    app: traefiklabs
    name: whoami

spec:
  replicas: 2
  selector:
    matchLabels:
      app: traefiklabs
      task: whoami
  template:
    metadata:
      labels:
        app: traefiklabs
        task: whoami
    spec:
      containers:
        - name: whoami
          image: traefik/whoami
          ports:
            - containerPort: 80

---
apiVersion: v1
kind: Service
metadata:
  name: whoami
  namespace: default

spec:
  ports:
    - name: http
      port: 80
  selector:
    app: traefiklabs
    task: whoami
```

And finally, let's create an [IngressRoute](https://doc.traefik.io/traefik/routing/providers/kubernetes-crd/#kind-ingressroute) to expose the service through Traefik Proxy:

```yaml
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: myingressroute
  namespace: default

spec:
  entryPoints:
    - web

  routes:
    - match: PathPrefix(`/ratelimit`)
      kind: Rule
      services:
        - name: whoami
          port: 80
```

You should be able to access the `whoami` service via Traefik Proxy using curl:

```
> curl http://localhost/whoami
Hostname: whoami-844bdd7c79-d76w5
IP: 127.0.0.1
IP: ::1
IP: 10.42.0.8
RemoteAddr: 10.42.0.6:45902
GET /whoami HTTP/1.1
Host: localhost
User-Agent: curl/7.79.0-DEV
Accept: application/json, application/xml, text/plain, */*
Accept-Encoding: gzip
X-Forwarded-For: 10.42.0.1
X-Forwarded-Host: localhost
X-Forwarded-Port: 80
X-Forwarded-Proto: http
X-Forwarded-Server: traefik-6877b6fd5f-w5vvn
X-Real-Ip: 10.42.0.1
```

Now that we have the easy part done, let's get into the interesting part!

## Implementing rate limiting

If you [observe](https://traefik.io/blog/capture-traefik-metrics-for-apps-on-kubernetes-with-prometheus/) spikes in your requests count, you might be experiencing a strain on your web servers induced by malicious bot activity. This is where rate limiting could be helpful.

Rate limiting is a technique used to control the amount of incoming traffic to a server or service. It helps to prevent an overwhelmed server from too many requests in a short period of time, which can cause it to become unresponsive or crash.

Rate limiting on Traefik allows a [fixed number of requests](https://doc.traefik.io/traefik/middlewares/http/ratelimit/#average) per [period](https://doc.traefik.io/traefik/middlewares/http/ratelimit/#period) from a particular [client](https://doc.traefik.io/traefik/middlewares/http/ratelimit/#sourcecriterionrequesthost) or [IP address](https://doc.traefik.io/traefik/middlewares/http/ratelimit/#sourcecriterionipstrategy). If a client exceeds this limit, Traefik will respond with an HTTP error [`429 Too Many Requests`](https://www.rfc-editor.org/rfc/rfc6585.html#section-4), and the client will have to wait until the next period before it can make more requests.

As seen earlier, rate limiting can be used to protect against a variety of threats, such as DoS attacks and scraping. It can also be used to share a server's resources equally among all its clients.

If you are not yet intimately familiar with the concept of rate limiting. the [leaky bucket analogy](https://en.wikipedia.org/wiki/Leaky_bucket) is often used to better understand how rate limiting works. In this analogy, drops of water represent incoming requests, and the bucket represents the server's capacity to handle requests. Imagine that the bucket has a small hole in the bottom, and water is slowly dripping out of it. As long as the rate at which water is dripping out of the hole is equal to or greater than the rate at which water is being added to the bucket (i.e., the [average](https://doc.traefik.io/traefik/middlewares/http/ratelimit/#average) at which requests are being made to the server), the bucket will never overflow. Yet, if the rate of incoming requests exceeds the rate at which the bucket is leaking, the bucket will eventually overflow and the excess water (requests) will be lost.

In this analogy, the size of the hole represents the rate limit: the smaller the hole, the fewer requests the server will be able to handle per period. By adjusting the size of the hole, the server can control the rate at which it processes incoming requests and prevent itself from becoming overwhelmed.

### Defining the average number of requests per period

Traefik counts an [average](https://doc.traefik.io/traefik/middlewares/http/ratelimit/#average) of requests during a [period](https://doc.traefik.io/traefik/middlewares/http/ratelimit/#period), so the calculated rate will be: 

rate = \frac{average}{period}

Let’s say you only want to allow each user to send 10 requests every second, and to discard requests that do not follow this pattern.

You need to create a [RateLimit middleware](https://doc.traefik.io/traefik/middlewares/http/ratelimit) and [attach](https://doc.traefik.io/traefik/routing/providers/kubernetes-crd/#kind-middleware) it to your ingress route.

For this, we are going to create the following middleware:

```yaml
apiVersion: traefik.containo.us/v1alpha1
kind: Middleware
metadata:
  name: test-ratelimit
spec:
  rateLimit:
    average: 10
    period: 1s
```

And another ingress route to go with it:

```yaml
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: myingressroute-ratelimit
  namespace: default

spec:
  entryPoints:
    - web

  routes:
    - match: PathPrefix(`/ratelimit`)
      kind: Rule
      services:
        - name: whoami
          port: 80
      middlewares:
        - name: test-ratelimit
          namespace: default
```

Now, this route will only allow 10 requests per second (RPS). If you send 20 RPS, 10 will be forwarded to the service, and the other 10 will receive a `429` error.

We can confirm that by using an [HTTP load testing tool](https://github.com/tsenart/vegeta). When sending requests for 200 second, I get:

```
> echo "GET http://localhost/ratelimit" \
    | vegeta attack -duration=200s \
    | vegeta report
Requests      [total, rate]            10000, 50.00
...
Success       [ratio]                  2.00%
Status Codes  [code:count]             200:2000  429:8000
Error Set:
429 Too Many Requests
```

We can see that during the 200-second test, `vegeta` sent 10000 requests, 2000 requests had a `200` status code and the rest of the requests got a `429`. In the end, 10 request per second were accepted!

### What about bursts?

Another configuration available for this RateLimit middleware is the [`burst`](https://doc.traefik.io/traefik/middlewares/http/ratelimit/#burst) option. In the context of rate limiting, a burst is a temporary increase in the rate at which requests are sent to a server. Bursts can occur for a variety of reasons, for example, when a popular website or service experiences a sudden surge in traffic, or when many clients try to access the server at the same time.

To handle bursts, Traefik's rate limiting algorithm allow a certain number of requests "above" the normal rate limit within a specified period. 

For example, a rate limit of 10 RPS with a burst of 50 might allow a client to make 60 requests in a single second, as long as it doesn't make any more requests in the following second. This can help to smooth out short term spikes in traffic and prevent the server from being overwhelmed.

**Note:** Bursts are not meant to allow a client to make more requests than the normal rate limit. If a client tries to make too many requests in a burst, it may still receive a 429 HTTP error code.

To enable this feature, we must change the middleware definition to the following:

```yaml
apiVersion: traefik.containo.us/v1alpha1
kind: Middleware
metadata:
  name: test-ratelimit
spec:
  rateLimit:
    average: 10
    period: 1s
    burst: 50 # <-- Here is the configuration change
```

There is no need to re-create or update the existing ingress route because Traefik will automatically update the middleware behavior.

When doing the same `vegeta` test, I get the following:

```
> echo "GET http://localhost/ratelimit" \
    | vegeta attack -duration=200s \
    | vegeta report
Requests      [total, rate]            10000, 50.00
...
Success       [ratio]                  2.00%
Status Codes  [code:count]             200:2050  429:7950
Error Set:
429 Too Many Requests
```

There are now 2050 requests with a `200` code which means that on top of the 2000 request accepted by the middleware, an addition of 50 more was allowed to go through.

### Filtering requests on a source

Grouping requests by source with rate limiting is a technique used to prevent a few clients from overwhelming a system with too many requests. By grouping requests by source, a rate limit can be applied to each individual source, rather than to the system as a whole.

For example, requests from individual IP addresses can be grouped and rate limited. This prevents a single IP address from making an excessive number of requests, which could lead to overloading and degradation of the system's performance.

By grouping requests by source, you can achieve a more fine-grained control over the rate of requests. This helps to prevent a single source from monopolizing resources, while still allowing other sources to make requests at a normal rate.

In short, grouping requests by source with rate limiting is a way of ensuring that a system remains stable and responsive, even in the face of high volumes of requests, and provides a better user experience.

The RateLimit middleware can group requests by source using the following criteria:

- `IP`: The IP address of the client
- `Host`: The hostname of the client
- `Header`: The value of a specific header

**Note:** For the `IP` criterion, the middleware uses the `X-Forwarded-For` header value to determine the client's IP address. There are two options on how to configure this criterion:
 - Using the `depth` option to specify the `depth`nth IP address to use from the `X-Forwarded-For` header
 - Using the `excludedIPs` option to specify a list of IP addresses to exclude from `X-Forwarded-For` header value lookup

For example, if the `X-Forwarded-For` header contains the value `10.0.0.1,11.0.0.1,12.0.0.1,13.0.0.1`, a depth of 3 will use `11.0.0.1` as the client's IP address, and a depth of 3 with an excluded IP of `12.0.0.1` will use `10.0.0.1`.
For this example, the middleware could be configured like:

```yaml
apiVersion: traefik.containo.us/v1alpha1
kind: Middleware
metadata:
  name: test-ratelimit-with-ip-strategy
spec:
  rateLimit:
    sourceCriterion:
      ipStrategy:
        depth: 3 # <- depth is defined here.
```

## Implementing max connections

![InFlightReq middleware flow schema](https://i.imgur.com/A14z3LH.png)

A web service handles HTTP requests from a client. When a client makes an HTTP request to a web server, it establishes a connection with that server. Once the request has been fulfilled and the server has sent back its response, the connection is usually closed.

Yet, it's possible for a client to keep the connection open and make many requests over the same connection, a process known as ["persistent"](https://wikipedia.org/wiki/HTTP_persistent_connection) connections. This can be more efficient than establishing a new connection for every request, but it also means that the server needs to keep track of each open connection and allocate resources to handle them.

To prevent the server from running out of resources, we can use the [InFlightReq middleware](https://doc.traefik.io/traefik/middlewares/http/inflightreq) to set limits on the number of concurrent connections the server will accept. This helps to ensure that the server can continue to function effectively even under heavy load. There are various strategies for determining the optimal number of concurrent connections for a particular server, and this can depend on factors such as the hardware configuration of the server and the expected workload.

As for the [RateLimit middleware](#rate-limiting), Traefik uses the request [IP address](https://en.wikipedia.org/wiki/IP_address) to [group requests](https://doc.traefik.io/traefik/middlewares/http/inflightreq/#sourcecriterion) coming from a common source to restrain the request count.

For this, we are going to create the following middleware:

```yaml
apiVersion: traefik.containo.us/v1alpha1
kind: Middleware
metadata:
  name: test-inflightreq
spec:
  inFlightReq:
    amount: 10
```

And another ingress route to go with it:

```yaml
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: myingressroute-inflightreq
  namespace: default

spec:
  entryPoints:
    - web

  routes:
    - match: PathPrefix(`/inflightreq`)
      kind: Rule
      services:
        - name: whoami
          port: 80
      middlewares:
        - name: test-inflightreq
          namespace: default
```

By doing so, we can see the following in the [Traefik metrics](https://doc.traefik.io/traefik/observability/metrics/overview/) where before 11:50 requests were made on a rule where the previous middleware was used, and after 11:50, no middleware was used.

![Grafana dashboard that shows the number of open connections on a service](https://i.imgur.com/pdsr1Re.png)

We can see a general trend that before, the number of connections per service does not go higher than 10, whereas after, the limit is not present anymore.

## Implementing retries

The [Retry middleware](https://doc.traefik.io/traefik/middlewares/http/retry/) uses the process of re-sending a failed request to the upstream server with an [exponential backoff](https://en.wikipedia.org/wiki/Exponential_backoff)^[[https://pkg.go.dev/github.com/cenkalti/backoff/v4](https://pkg.go.dev/github.com/cenkalti/backoff/v4)] in an attempt to complete it.

When a client makes a request to a route with the middleware attached, the proxy will forward the request to the backend servers and return the response to the client. If the backend server failed to establish a connection, the middleware will retry the request in an attempt to establish it.

This can be useful in situations where the upstream server is experiencing temporary issues, such as a network outage or server overload. Paired with [services health checks](https://doc.traefik.io/traefik/routing/services/#health-check) or [circuit breakers](https://doc.traefik.io/traefik/middlewares/http/circuitbreaker/), retries can help improve the reliability and availability of the system by mitigating the impact of these types of issues.

For this, we are going to create the following middleware:

```yaml
apiVersion: traefik.containo.us/v1alpha1
kind: Middleware
metadata:
  name: test-retry
spec:
  retry:
    attempts: 4
    initialInterval: 10ms
```

And another ingress route to go with it:

```yaml
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: myingressroute-retry
  namespace: default

spec:
  entryPoints:
    - web

  routes:
    - match: PathPrefix(`/retry`)
      kind: Rule
      services:
        - name: whoami
          port: 81
      middlewares:
        - name: test-retry
          namespace: default
```

When accessing the rule — as the rule points to a port that is not listened on by any service — Traefik retries four times before forwarding a [`502 Bad Gateway`](https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/502) to the user:

```
> kubectl logs deployment.apps/traefik
...
DBG > Service selected by WRR: 265d14423adb2c79
DBG > 502 Bad Gateway error="dial tcp 10.42.0.11:81: connect: connection refused"
DBG > New attempt 2 for request: /retry middlewareName=default-test-retry@kubernetescrd middlewareType=Retry
DBG > Service selected by WRR: 66f2e65a52593a36
DBG > 502 Bad Gateway error="dial tcp 10.42.0.12:81: connect: connection refused"
DBG > New attempt 3 for request: /retry middlewareName=default-test-retry@kubernetescrd middlewareType=Retry
DBG > Service selected by WRR: 265d14423adb2c79
DBG > 502 Bad Gateway error="dial tcp 10.42.0.11:81: connect: connection refused"
DBG > New attempt 4 for request: /retry middlewareName=default-test-retry@kubernetescrd middlewareType=Retry
DBG > Service selected by WRR: 66f2e65a52593a36
DBG > 502 Bad Gateway error="dial tcp 10.42.0.12:81: connect: connection refused"
10.42.0.1 - - [] "GET /retry HTTP/1.1" 502 11 "-" "-" 200 "default-myingressroute-retry-7cdc091e15f006bacd1d@kubernetescrd" "http://10.42.0.12:81" 312ms
10.42.0.1 - - [] "GET /whoami HTTP/1.1" 200 454 "-" "-" 680 "default-myingressroute-default-9ab4060701404e59ffcd@kubernetescrd" "http://10.42.0.12:80" 0ms
```

## Implementing circuit breakers

![circuit breaker flow schema](https://i.imgur.com/qj00wET.png)

A circuit breaker can help prevent the reverse proxy from getting stuck in a loop of retrying failed requests, or where a failure in one part of an infrastructure can have cascading effects on other parts of the system. This can waste resources and degrade the performance of the service as a whole. By "breaking the circuit" and temporarily halting requests to the backend server, the circuit breaker allows the server to recover and prevents further failures from occurring.

A circuit breaker can be used to protect Traefik from excessive or infinite retries when one or more of the backend servers is failing. A circuit breaker is a pattern that works by "tripping" or "opening" a circuit after a certain [trigger](https://doc.traefik.io/traefik/middlewares/http/circuitbreaker/#configuring-the-trigger) is tripped and prevents further requests from being sent to the backend server until it has had a chance to recover.

**Note:** A circuit breaker middleware usage should be implemented with care, as it can have unintended consequences if it trips too frequently or for the wrong reasons.

The circuit breaker can have one of three statuses: closed, open, and recovering.

- When the number of requests is within the acceptable limit,
  the circuit breaker remains **closed** and Traefik routes the requests to the backend server.
- When the backend server is facing an issue, Traefik starts receiving a high number of requests (see [triggers](#triggers)), which **opens** the circuit breaker to prevent overloading and further damage to the system. At specified intervals ([`checkPeriod`](https://doc.traefik.io/traefik/middlewares/http/circuitbreaker/#checkperiod)), the CircuitBreaker middleware will check the expression to decide if the state should change.
- After a certain period of time ([`FallbackDuration`](https://doc.traefik.io/traefik/middlewares/http/circuitbreaker/#fallbackduration)), Traefik starts to send a few requests to the backend server to test its availability for [`RecoveryDuration`](https://doc.traefik.io/traefik/middlewares/http/circuitbreaker/#recoveryduration) — this is the **recovery step**. If the backend server responds properly, the circuit breaker changes its state to **closed** and starts allowing the normal flow of requests.

**Note:** The time and conditions for tripping, opening, and recovering are configurable.

### Triggers

Triggers are expressions that are evaluated for each request, and try to detect abnormal user behavior.

Once an evaluation is matched, and the circuit breaker is opened, the fallback mechanism is used instead of calling the backend service. The fallback mechanism is a handler that returns a `HTTP 503 Service Unavailable` and is **not** configurable.

A trigger evaluation can contain many metrics joined with the two common Boolean operators AND (`&&`) or OR (`||`).

#### Network Error Ratio

The Network Error Ratio is a metric used by the circuit breaker to determine when to trip the middleware. The Network Error Ratio is calculated as the ratio of failed requests to total requests. The circuit breaker is triggered and opens when the Network Error Ratio exceeds a certain threshold.

For example, if the threshold is set to 50%, and the circuit breaker calculates that 50% or more of the requests sent to the backend server have failed at the last minute, it will get triggered and open.

This is done by creating an expression that is:

```
NetworkErrorRatio() > 0.50

```

The Network Error Ratio is an important factor in the design of a circuit breaker and is used to determine when to trip and when to recover. A well-tuned circuit breaker can prevent a system from overloading and provide a more stable and reliable service to its users.

#### Response Code Ratio

Response Code Ratio is a metric used by the circuit breaker to determine when to trip the middleware. The Response Code Ratio is calculated as the ratio of failed requests (based on specific response codes, such as 4XX or 5XX) to the total requests sent. The circuit breaker is triggered and opens when the Response Code Ratio exceeds a certain threshold.

For example, if the threshold is set to 50%, and the circuit breaker calculates that 50% or more of the requests sent to the backend server have received a 4XX or 5XX response code, it will get triggered and open.

The expression would be:

```
ResponseCodeRatio(400, 600, 0, 600) > 0.5
```

This expression can be explained as “look at the ratio of requests that got a status code between 400 and 600 over the number of requests that got a status code between 0 and 600.” Or:

\frac{\sum_{request} 400 \le status code < 600}{\sum_{request} 0 \le status code < 600}

#### Latency

Latency at quantile is a metric used by the circuit breaker to determine when to trip the middleware. It measures the amount of time taken for a backend server to respond to a request and calculates the time taken for a certain percentage (quantile) of requests. The circuit breaker is triggered and opens when the latency at the quantile exceeds a certain threshold.

For example, if the threshold is set to 500ms and the circuit breaker calculates that 50% or more of the requests sent to the backend server have taken more than 500ms to respond at the last minute, it will get triggered and open.

This is done by creating an expression that is:

```
LatencyAtQuantileMS(50.0) > 500

```

### Circuit breaker in action

Now that we know how to configure the circuit breaker middleware, let's see how to use it in a real-world scenario.

We will use the following configuration:

```yaml
apiVersion: traefik.containo.us/v1alpha1
kind: Middleware
metadata:
  name: test-circuit-breaker
spec:
  circuitBreaker:
    expression: LatencyAtQuantileMS(50.0) > 500 || ResponseCodeRatio(400, 600, 0, 600) > 0.5 || NetworkErrorRatio() > 0.50
    checkPeriod: 10s
    fallbackDuration: 30s
    recoveryDuration: 1m
```

This configuration will open the circuit breaker if:

- 50% or more of the requests sent to the backend server have taken more than 500ms to respond in the 10s period
- 50% or more of the requests sent to the backend server have received a 4XX or 5XX response code in the 10s period
- 50% or more of the requests sent to the backend server have failed in the 10s period

Once the circuit breaker is opened, Traefik will use the fallback mechanism for 30s. After 30s, Traefik will start to send some requests to the backend server to test its availability for 1m. If the backend server responds, the circuit breaker will change its state to **closed** and start allowing the normal flow of requests.

Let's see how this configuration works. We will use the following backend server:

```go
package main

import (
    "fmt"
    "math/rand"
    "net/http"
    "time"
)

func main() {
    http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
        // Simulate a random latency between 0 and 1s.
        time.Sleep(time.Duration(rand.Intn(1000)) * time.Millisecond)

        // Simulate a random error.
        if rand.Intn(100) < 10 {
            w.WriteHeader(http.StatusInternalServerError)
            fmt.Fprintln(w, "Internal Server Error")
            return
        }

        // Simulate a random 4XX error.
        if rand.Intn(100) < 10 {
            w.WriteHeader(http.StatusNotFound)
            fmt.Fprintln(w, "Not Found")
            return
        }

        fmt.Fprintln(w, "Hello, World!")
    })

    http.ListenAndServe(":8080", nil)
}
```

This server will simulate a random latency between 0 and 1s, and a random error or 4XX error.

Now, let's compare the behavior of the circuit breaker with and without the middleware, using `vegeta`:

```bash
> # Without the circuit breaker middleware.
> echo "GET http://localhost/backend" \
	| vegeta attack -duration=200s \
	| vegeta report
…
Success       [ratio]                           80.44%
Status Codes  [code:count]                      200:8044  404:935  500:1021
Error Set:
500 Internal Server Error
404 Not Found

> # With the circuit breaker middleware.
> echo "GET http://localhost/circuit-breaker" \
    | vegeta attack -duration=200s \
    | vegeta report
…
Success       [ratio]                           28.75%
Status Codes  [code:count]                      200:2875  404:325  500:362  503:6438
Error Set:
404 Not Found
500 Internal Server Error
503 Service Unavailable

```

As you can see, the CircuitBreaker middleware has a significant impact on the number of requests sent to the backend server. A lot of `404` and `500` errors were avoided by using the CircuitBreaker middleware. However, using the most basic configuration, it is inevitable that the middleware will catch a few `200` legitimate requests as well. Some additional fine-tuning to meet your specific requirements and specific use cases is always a good idea. 

## Conclusion

Rate limiting, max connections, retries, and circuit breakers are essential tools for managing and protecting a system from overload, becoming unavailable, and a bunch of other issues.

Rate limiting restricts the request's rate made to a system, ensuring that it does not get overwhelmed by too many requests. Max connections limit the number of concurrent connections that a system can handle, preventing it from getting bogged down by too many connections. Retries provide a mechanism for a system to automatically retry failed requests, increasing the chances of success and providing a better user experience.

Circuit breakers, on the other hand, provide a protection mechanism by interrupting the flow of requests when the system is under stress. They can be triggered by a variety of metrics — such as Network Error Ratio, Response Code Ratio, and latency at quantile — to prevent further damage to the system and provide a more stable and reliable service to its users.

All these techniques can work together to provide a robust and scalable system that can handle a high volume of requests while providing a stable and reliable service to its users. And you can do all that using a single tool, Traefik Proxy! If you haven’t already tried Traefik, can learn more about its capabilities here, or dig through our Documentation to explore the technical details of its features and functions. 

