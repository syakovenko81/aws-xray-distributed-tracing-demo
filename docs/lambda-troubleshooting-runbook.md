# Lambda troubleshooting runbook

This runbook extends the existing demo without changing its X-Ray implementation or the previous observability deliverables.

The normal path remains:

`Client -> API Gateway REST API -> Lambda A -> Lambda B -> DynamoDB`

For end-to-end latency and downstream-failure tests, enable `ENABLE_TROUBLESHOOTING_HOOKS=true` in both Lambda A and Lambda B. The deployed environment currently does not set this variable, so both functions use the default `false` value.

## Safety and scope

Troubleshooting hooks are disabled unless the Lambda environment contains:

```text
ENABLE_TROUBLESHOOTING_HOOKS=true
```

The default is `false`. When the flag is disabled, the `troubleshooting` request object is ignored and is not forwarded to Lambda B. Existing success/error requests therefore retain their current behavior.

This repository does not configure the flag in Terraform. Enabling it on AWS requires separate approval because it changes Lambda configuration. No alarms, reserved concurrency, or other AWS resources are created by this runbook.

## Evidence order

For every test:

1. Record region, function names, endpoint, UTC time window, and a unique `correlation_id`.
2. Save the HTTP status and response body.
3. Check API Gateway metrics: `Count`, `Latency`, `IntegrationLatency`, `4XXError`, `5XXError`.
4. Check Lambda metrics: `Invocations`, `Errors`, `Throttles`, `Duration`, and `ConcurrentExecutions`.
5. Search Lambda logs for the correlation ID and platform `REPORT` lines.
6. Locate the X-Ray trace and inspect segment duration, error/fault state, and child calls.
7. For dependency cases, check DynamoDB `SuccessfulRequestLatency`, `SystemErrors`, `UserErrors`, `ThrottledRequests`, and `WriteThrottleEvents`.

## CloudWatch Alarms

The repository does not deploy any `aws_cloudwatch_metric_alarm` resources, notification topic, or alarm actions. The following are recommended educational starting points for a deployed demo; they are not production recommendations and are not currently active.

| Alarm | Namespace | Metric | Dimensions | Statistic | Period | Evaluation periods | Suggested threshold | Meaning and first diagnostic step |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Lambda errors | `AWS/Lambda` | `Errors` | `FunctionName=<lambda-a-or-lambda-b>` | `Sum` | 60 seconds | 1 | `>= 1` | At least one invocation failed. Start with the function's traceback, `REPORT` line, correlation ID, and X-Ray fault segment. |
| Lambda throttles | `AWS/Lambda` | `Throttles` | `FunctionName=<lambda-a-or-lambda-b>` | `Sum` | 60 seconds | 1 | `>= 1` | Lambda rejected an invocation because no concurrency was available. Check `ConcurrentExecutions`, account concurrency, caller response, and whether the request produced no function `REPORT` log. |
| Lambda A duration | `AWS/Lambda` | `Duration` | `FunctionName=<lambda-a>` | `p95` extended statistic | 60 seconds | 2 | `> 12,000 ms` | Approaches the configured Lambda A timeout of 15 seconds. Start with the `lambda_a.invoke_lambda_b` X-Ray span and Lambda B duration. |
| Lambda B duration | `AWS/Lambda` | `Duration` | `FunctionName=<lambda-b>` | `p95` extended statistic | 60 seconds | 2 | `> 8,000 ms` | Approaches the configured Lambda B timeout of 10 seconds. Start with the `lambda_b.process` span, delay hook logs, and DynamoDB subsegment. |
| API server errors | `AWS/ApiGateway` | `5XXError` | `ApiName=<api-name>, Stage=<environment>` | `Sum` | 60 seconds | 1 | `>= 1` | A server-side API response occurred. Correlate the response with Lambda A/B `Errors`, downstream failure logs, and X-Ray. |
| DynamoDB throttled requests | `AWS/DynamoDB` | `ThrottledRequests` | `TableName=<table>, Operation=PutItem` | `Sum` | 60 seconds | 1 | `>= 1` | A DynamoDB request exceeded an applicable throughput limit. Start with the exception's throttling reason and compare `WriteThrottleEvents`. |
| DynamoDB write throttle events | `AWS/DynamoDB` | `WriteThrottleEvents` | `TableName=<table>` for the table; add `GlobalSecondaryIndexName` only for a GSI | `Sum` | 60 seconds | 1 | `>= 1` | A write event was throttled. Inspect table/GSI scope, the exception, and the corresponding X-Ray DynamoDB subsegment. |

Use `ApiName, Stage` for the API-level REST API metrics available in this project. Method/resource dimensions require API Gateway detailed metrics, which this Terraform configuration does not enable. For DynamoDB, `ThrottledRequests` uses `TableName, Operation`; `WriteThrottleEvents` uses table/GSI dimensions. Treat missing data as `notBreaching` for this low-traffic demo and interpret sparse metrics together with the request time window.

The Lambda `Duration` metric covers handler execution and does not include cold-start initialization time. Use the `Init Duration` field in Lambda `REPORT` logs and the X-Ray timeline when diagnosing cold starts.

## Baseline success

```bash
CORRELATION_ID="baseline-$(date -u +%Y%m%d%H%M%S)"
./scripts/test-success.sh "$API_ENDPOINT" "$CORRELATION_ID"
```

Expected evidence:

- HTTP 200;
- Lambda A `accepted request` log;
- Lambda B `stored record` log;
- Lambda `REPORT` entries without errors;
- X-Ray path through DynamoDB;
- no API Gateway `5XXError`.

## Latency and cold starts

```bash
./scripts/test-latency.sh "$API_ENDPOINT" "latency-$(date -u +%Y%m%d%H%M%S)" 2000
```

The script sends a baseline request and a request containing:

```json
{"troubleshooting":{"delay_ms":2000}}
```

The delayed request only has an effect when the safety flag is enabled. Compare Lambda `Duration`, API Gateway `IntegrationLatency`, and the X-Ray Lambda B timeline. A cold start is indicated by `Init Duration` in the Lambda `REPORT` record.

For a timeout-like experiment, use a delay greater than Lambda B's configured timeout. Treat this as an application-controlled timeout demonstration, not as a real network timeout from DynamoDB.

## Timeout diagnosis

The configured Lambda timeouts are:

- Lambda B: 10 seconds — configured in [`terraform/main.tf`](../terraform/main.tf);
- Lambda A: 15 seconds — configured in [`terraform/main.tf`](../terraform/main.tf).

Terraform does not set a separate API Gateway integration timeout in this repository. Do not infer an exact API Gateway timeout value from this runbook; record the actual client response and timestamps from the deployed API.

### Lambda B timeout

Typical evidence is:

- Lambda B `REPORT` containing `Status: timeout`, or a platform message such as `Task timed out`;
- Lambda B `Errors` increment;
- Lambda B `Duration` close to 10,000 ms;
- X-Ray Lambda B segment marked as error/fault or ending at the timeout boundary;
- Lambda A log `Lambda B failed` if Lambda A receives the failed synchronous invocation;
- an extended `lambda_a.invoke_lambda_b` span.

If Lambda A completes before its own 15-second limit, the API may return the application's downstream failure response. Do not assume that every B timeout produces the same HTTP status.

### Lambda A timeout

Typical evidence is:

- Lambda A `REPORT` containing `Status: timeout` or `Task timed out`;
- Lambda A `Errors` increment;
- Lambda A `Duration` close to 15,000 ms;
- API Gateway `5XXError` and latency near the client-visible failure;
- an incomplete or faulted root/API/Lambda A X-Ray path.

Lambda B may have completed, failed, or still been running when Lambda A timed out. Use the B log window and its X-Ray segment to distinguish those cases.

### API Gateway timeout or integration response

API Gateway `Latency` includes gateway overhead, while `IntegrationLatency` covers the backend request/response interval. A gateway-side timeout can occur while Lambda logs later show completion, or while the backend is still running. Check the actual HTTP response, API Gateway `5XXError`, both latency metrics, Lambda `REPORT` timestamps, and X-Ray segments. The HTTP status is not guaranteed to be identical for Lambda B timeout, Lambda A timeout, and an API Gateway-side timeout.

## Errors and exceptions

Existing controlled error:

```bash
./scripts/test-error.sh "$API_ENDPOINT" "error-$(date -u +%Y%m%d%H%M%S)"
```

Expected evidence:

- Lambda B exception and `Errors` increment;
- Lambda A downstream failure log;
- API Gateway HTTP 502 and `5XXError`;
- X-Ray error/fault on Lambda B and its caller;
- no successful DynamoDB write.

Invalid request cases should be checked separately. They return HTTP 400 and are handled application responses, so Lambda `Errors` need not increase.

## Throttling and concurrency

No reserved concurrency is configured by this project. Use existing metrics and do not change concurrency settings:

- Lambda `Throttles`;
- Lambda `ConcurrentExecutions`;
- regional `UnreservedConcurrentExecutions`;
- API Gateway `5XXError` and latency;
- X-Ray traces for requests that did reach the functions.

A throttled invocation may not produce a normal Lambda `REPORT` entry. A repeatable Reserved Concurrency experiment requires a separately approved infrastructure change and is intentionally excluded here.

## Retry behavior

Lambda A invokes Lambda B synchronously with `RequestResponse`. The current application has no retry loop. A synchronous function error is returned to the caller; repeating the request manually is a client retry, not an automatic Lambda retry.

### Asynchronous retries

To demonstrate asynchronous retry behavior without adding an event source:

```bash
./scripts/test-retry.sh "$LAMBDA_B" "async-$(date -u +%Y%m%d%H%M%S)"
```

`scripts/test-retry.sh` directly invokes Lambda B with `InvocationType=Event`. It does not call API Gateway, and it does not exercise retry behavior through Lambda A. The payload uses the existing `simulate_error=true` path, so the function error is generated inside Lambda B.

With the standard asynchronous retry configuration, expect the initial invocation plus up to two retries for function errors. Confirm the attempts using:

- Lambda B `Invocations`, which can reach three for the one queued event;
- Lambda B `Errors`, which can also reach three when every attempt fails;
- repeated Lambda B `START`, traceback, `END`, and `REPORT` log records containing the same `correlation_id`.

The script only queues the event; it does not wait for or query the retry attempts. Allow time for asynchronous processing before searching logs and metrics. X-Ray trace correlation with the original API Gateway request is not guaranteed because this direct invocation is not initiated by the API Gateway → Lambda A path and does not carry the API request's `_trace_context`.

## Downstream DynamoDB failures

```bash
./scripts/test-downstream-failure.sh "$API_ENDPOINT" "ddb-$(date -u +%Y%m%d%H%M%S)"
```

The request contains:

```json
{"troubleshooting":{"dependency_error":true}}
```

When hooks are enabled, Lambda B uses the existing demo table and adds the deliberately contradictory condition `attribute_exists(record_id) AND attribute_not_exists(record_id)` to `PutItem`. The condition is guaranteed to be false and the item is not written. Expected signals are:

- `ConditionalCheckFailedException` in Lambda B logs;
- DynamoDB `UserErrors`;
- Lambda B `Errors`;
- an errored DynamoDB X-Ray subsegment;
- Lambda A downstream failure and API Gateway HTTP 502.

This is a controlled DynamoDB service error, not an infrastructure outage. It differs from `AccessDeniedException`: the latter indicates that the effective IAM policies do not allow `dynamodb:PutItem` for the requested table ARN. The Lambda B policy allows `PutItem` on the existing demo table, so this hook should produce `ConditionalCheckFailedException`, not IAM denial or `ResourceNotFoundException`.

For a real DynamoDB throttling event, use DynamoDB metrics and exception details. Do not change this PAY_PER_REQUEST table or create load without separate approval.

## CloudWatch Logs Insights examples

Duration and cold-start overview:

```text
filter @type = "REPORT"
| stats count() as invocations,
        percentile(@duration, 50) as p50,
        percentile(@duration, 95) as p95,
        percentile(@duration, 99) as p99,
        sum(strcontains(@message, "Init Duration")) as cold_starts
  by bin(5m)
```

Application errors:

```text
fields @timestamp, @requestId, @message
| filter @message like /ERROR|Exception|failed|timeout/
| sort @timestamp desc
| limit 100
```

Correlation search:

```text
fields @timestamp, @requestId, @message
| filter @message like /<correlation-id>/
| sort @timestamp asc
```

Repeated asynchronous attempts for one correlation ID:

```text
fields @timestamp, @requestId, @logStream, @message
| filter @message like /correlation_id=<correlation-id>/
| sort @timestamp asc
```

To group the matching events by Lambda platform request ID:

```text
filter @message like /correlation_id=<correlation-id>/
| stats count(*) as matching_log_events by @requestId, @logStream
| sort @requestId asc
```

The application logs are plain text. The correlation ID is therefore searched in `@message`; `@requestId` is the Lambda platform field used to separate invocation attempts.

Lambda timeout records:

```text
fields @timestamp, @requestId, @message
| filter @message like /Status: timeout|Task timed out|timed out/
| sort @timestamp desc
| limit 100
```

Throttling and `TooManyRequestsException` text:

```text
fields @timestamp, @requestId, @message
| filter @message like /TooManyRequestsException|TooManyRequests|throttl|Throttl|Rate exceeded/
| sort @timestamp desc
| limit 100
```

Platform-level throttled invocations may not create a function log event. Treat the `AWS/Lambda Throttles` metric as the source of truth and use this query for errors that were logged by a caller or function.

Controlled DynamoDB condition failure:

```text
fields @timestamp, @requestId, @message
| filter @message like /ConditionalCheckFailedException|conditional request failed|dependency_error=true/
| sort @timestamp desc
| limit 100
```

IAM authorization failure:

```text
fields @timestamp, @requestId, @message
| filter @message like /AccessDeniedException|AccessDenied|not authorized|Unauthorized/
| sort @timestamp desc
| limit 100
```

These queries use raw `@message` text for application and exception matching because the project does not emit JSON structured application logs.

## References

- [AWS Lambda metrics](https://docs.aws.amazon.com/lambda/latest/dg/monitoring-metrics-types.html)
- [AWS Lambda asynchronous retries](https://docs.aws.amazon.com/lambda/latest/dg/invocation-async-error-handling.html)
- [API Gateway REST API metrics and dimensions](https://docs.aws.amazon.com/apigateway/latest/developerguide/api-gateway-metrics-and-dimensions.html)
- [DynamoDB metrics and dimensions](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/metrics-dimensions.html)
- [CloudWatch Logs Insights query syntax](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/CWL_QuerySyntax.html)

## Completion checklist

- [ ] Correlation ID and UTC window recorded.
- [ ] API Gateway status and latency checked.
- [ ] Lambda `Duration`, `Errors`, `Throttles`, and concurrency checked.
- [ ] `REPORT`, `Init Duration`, timeout and traceback records checked.
- [ ] X-Ray trace and dependency subsegments checked.
- [ ] DynamoDB metrics checked for downstream cases.
- [ ] Retry type identified as client, Lambda async, or SDK-level.
- [ ] No AWS configuration was changed during the diagnostic procedure.
