# Lambda troubleshooting evidence report

This report documents the AWS validation evidence collected for the Development Plan task **Deepen Lambda troubleshooting beyond CloudWatch Logs**.

The task objective was to practice diagnosing unexpected Lambda behavior by combining CloudWatch Logs, CloudWatch Metrics, CloudWatch Alarms, and AWS X-Ray traces across the existing path:

`Client -> API Gateway REST API -> Lambda A -> Lambda B -> DynamoDB`

The evidence was collected manually in AWS. Screenshots are maintained in the external evidence package and are not stored in this repository.

## 1. Evidence scope and preservation

The validation used the existing deployed demo in `us-east-1`:

| Item | Value |
|---|---|
| API endpoint | `https://pfk89hj0jg.execute-api.us-east-1.amazonaws.com/dev/events` |
| API resource | `POST /dev/events` |
| Lambda A | `aws-xray-demo-dev-lambda-a` |
| Lambda B | `aws-xray-demo-dev-lambda-b` |
| DynamoDB table | `aws-xray-demo-dev-records` |
| Lambda A timeout | 15 seconds |
| Lambda B timeout | 10 seconds |
| Validation date | 2026-11-13 |

The troubleshooting hooks were enabled manually in both Lambda functions with:

```text
ENABLE_TROUBLESHOOTING_HOOKS=true
```

This variable is not configured by Terraform and defaults to `false` in the application. It must be enabled in both Lambda functions for the latency and downstream scenarios to take effect.

The following previous deliverables remained available and demonstrable:

- API Gateway and Lambda active X-Ray tracing;
- ADOT instrumentation and trace-context propagation;
- existing success and controlled-error scenarios;
- `docs/observability-runbook.md`;
- `docs/tracing-validation.md`;
- `scripts/test-success.sh`;
- `scripts/test-error.sh`;
- `tests/test_handlers.py`;
- Lambda telemetry helpers.

No CloudWatch alarms, Reserved Concurrency settings, or other additional AWS resources were created for this validation.

## 2. Validation summary

| Requirement | Status | Evidence summary | Limitation |
|---|---|---|---|
| Lambda latency and Duration | Completed | Artificial 2-second delay was observed in Lambda B Logs, Lambda Duration, API Gateway latency, and X-Ray timeline | API Gateway metrics aggregate requests by period; exact request attribution is taken from Logs/X-Ray |
| Cold starts | Completed as diagnostic signal | `REPORT` records included cold-start indicators such as `Init Duration`/slow cold start | Cold start was observed, not artificially forced |
| Lambda errors and exceptions | Completed | Controlled failure produced Lambda error logs, HTTP 502, X-Ray faults, and DynamoDB conditional failure signals | The DynamoDB failure is intentionally controlled |
| Lambda retries | Completed | Direct asynchronous invocation returned 202 and produced three Lambda B error events over time | This is direct Lambda B asynchronous retry behavior, not API Gateway end-to-end retry |
| Throttling and concurrency | Partially completed | `Throttles` and `ConcurrentExecutions` were inspected during the validation window | No controlled throttling was generated because Reserved Concurrency was not configured |
| Downstream DynamoDB failure | Completed | `ConditionalCheckFailedException`, DynamoDB conditional-failure metric, HTTP 502, X-Ray DynamoDB error, and zero matching items | This is not a DynamoDB infrastructure outage |
| CloudWatch Alarms | Not deployed | CloudWatch showed `Alarms (0)` | Alarm creation was intentionally excluded from this deployment |
| Repeatable diagnostic checklist | Completed | The checklist and queries are documented in `docs/lambda-troubleshooting-runbook.md` | Live alarm state is documented as a limitation |

## 3. Baseline successful request

### Test input

The existing success script was used without modification:

```bash
./scripts/test-success.sh \
  "$API_ENDPOINT" \
  "ep04-baseline-20261113094514"
```

The request returned:

```json
{
  "status": "stored",
  "record_id": "ep04-baseline-20261113094514-43749cc8bbf9",
  "correlation_id": "ep04-baseline-20261113094514"
}
```

### CloudWatch Logs evidence

Lambda A logs contained the accepted request with the baseline correlation ID. Lambda B logs contained the stored-record message with the same correlation ID. Both functions emitted normal `REPORT` records.

The baseline logs also showed a slow-cold-start indicator. This is useful diagnostic evidence because Lambda `Duration` and the `REPORT` record should be interpreted together when separating initialization overhead from application work.

### CloudWatch Metrics evidence

The following metrics were inspected in the baseline time window:

- Lambda `Duration`;
- Lambda `Errors`;
- Lambda `Throttles`;
- Lambda `ConcurrentExecutions`;
- API Gateway `Count`;
- API Gateway `Latency`;
- API Gateway `IntegrationLatency`;
- API Gateway `4XXError` and `5XXError`.

The baseline showed successful traffic, no Lambda errors, no throttles, low concurrency, and no API Gateway 4XX/5XX signal for the successful request.

### X-Ray evidence

The baseline trace showed the expected successful path:

`API Gateway -> Lambda A -> Lambda B -> DynamoDB`

The trace tree and timeline showed successful segment statuses and a successful DynamoDB operation.

## 4. Artificial latency validation

### Test input

The latency script sent a baseline request followed by a request with a 2-second delay:

```bash
./scripts/test-latency.sh \
  "$API_ENDPOINT" \
  "ep04-latency-20261113100833" \
  2000
```

The delayed request used:

```json
{
  "troubleshooting": {
    "delay_ms": 2000
  }
}
```

Both requests returned `status: stored`.

### CloudWatch Logs evidence

Lambda B emitted:

```text
troubleshooting delay_ms=2000 correlation_id=ep04-latency-20261113100833-delayed
```

The corresponding `REPORT` record showed approximately 2 seconds of Lambda B execution time for the delayed request.

### CloudWatch Metrics evidence

The Lambda Duration graph was inspected for the 10:05–10:12 UTC window. Lambda B showed the increased execution time associated with the delayed request. Because the baseline and delayed requests occurred within the same one-minute metric period, CloudWatch aggregated their values. The exact request-level values were therefore taken from Logs and X-Ray.

API Gateway `Latency` and `IntegrationLatency` were also inspected. The API Gateway metrics were interpreted together with the Lambda Duration graph and the X-Ray trace rather than as an isolated request-level measurement.

### X-Ray evidence

The delayed trace showed:

| Segment/span | Observed duration or signal |
|---|---|
| API Gateway | Approximately 2.13 seconds |
| Lambda A | Approximately 2.10 seconds |
| `lambda_b.process` | Approximately 2.01 seconds |
| DynamoDB | Approximately 14 ms |
| Status | HTTP 200 / OK |

This identifies Lambda B application delay as the source of latency. DynamoDB did not account for the observed delay.

The validation did not claim a Lambda A timeout. With the current timeouts, Lambda B reaches its 10-second timeout before Lambda A can reach its 15-second timeout when the delay is implemented inside Lambda B.

## 5. Controlled DynamoDB downstream failure

### Test input

The downstream failure script was run with:

```bash
./scripts/test-downstream-failure.sh \
  "$API_ENDPOINT" \
  "ep04-dynamodb-20261113103712"
```

The request used `dependency_error=true`. Lambda B used the existing demo table and a deliberately false condition:

```text
attribute_exists(record_id) AND attribute_not_exists(record_id)
```

The condition cannot be true for any item. The generated item was not written.

### HTTP and Logs evidence

The API response was:

```json
{
  "error": "downstream_failure",
  "correlation_id": "ep04-dynamodb-20261113103712"
}
```

The explicit HTTP check returned:

```text
HTTP_STATUS=502
```

Lambda B logs contained:

```text
ConditionalCheckFailedException
dependency_error=true
Lambda B failed
```

Lambda A logs contained the corresponding `Lambda B failed` downstream error for the same correlation ID.

The request was executed twice while collecting evidence, so two related traces and two groups of Lambda error logs were expected. These were separate synchronous requests, not automatic retries.

### DynamoDB evidence

The DynamoDB table metric `ConditionalCheckFailedRequests` showed events in the failure window. This is a more specific signal for this controlled scenario than a generic infrastructure error metric.

The table was scanned read-only with a filter on:

```text
correlation_id = ep04-dynamodb-20261113103712
```

The result was:

```text
Items returned: 0
Items scanned: 3
```

This confirms that no item with the failure correlation ID was created.

The expected error is `ConditionalCheckFailedException`, not `AccessDeniedException` or `ResourceNotFoundException`. Lambda B has `dynamodb:PutItem` permission on the existing table ARN; DynamoDB rejects the operation because the condition evaluates to false.

### X-Ray evidence

The downstream trace showed:

`API Gateway -> Lambda A -> Lambda B -> DynamoDB`

with:

- API Gateway response code `502`;
- Lambda A fault on the downstream invocation path;
- Lambda B error/fault status;
- DynamoDB response code `400` for the failed conditional operation;
- no successful DynamoDB write.

This demonstrates a controlled downstream operation failure, not a DynamoDB outage or IAM failure.

## 6. Asynchronous Lambda retry validation

### Test input

The retry script directly invoked Lambda B asynchronously:

```bash
./scripts/test-retry.sh \
  "$LAMBDA_B" \
  "ep04-retry-20261113105140"
```

The script uses:

```text
InvocationType=Event
simulate_error=true
```

The initial invocation returned:

```json
{
  "StatusCode": 202
}
```

### CloudWatch Logs evidence

Lambda B produced three error events with the same correlation ID at approximately:

```text
10:51:48 UTC
10:52:46 UTC
10:54:36 UTC
```

This is consistent with the initial asynchronous attempt plus two retries under the standard Lambda asynchronous retry behavior.

The retry was not initiated through API Gateway or Lambda A. X-Ray correlation with the original API request was therefore not required for this scenario.

### CloudWatch Metrics evidence

For Lambda B in the retry window, the following were inspected with one-minute periods and `Sum`:

- `Invocations`;
- `Errors`.

The metrics showed approximately three invocations and three errors, matching the three failed asynchronous attempts.

## 7. Throttling and concurrency validation

Lambda A and Lambda B metrics were inspected for:

- `Throttles` with `Sum`;
- `ConcurrentExecutions` with `Maximum`.

No throttles were observed in the validation window. Concurrent executions remained low.

This is diagnostic evidence for the observed window only. It is not a controlled throttling experiment.

The repository does not configure Reserved Concurrency, Provisioned Concurrency, or a load generator. A deterministic throttling demonstration would require a separately approved infrastructure or load-generation change and was intentionally excluded.

## 8. CloudWatch Alarms

CloudWatch showed:

```text
Alarms (0)
No alarms
```

No alarms were created for this validation. The recommended educational alarm configurations remain documented in `docs/lambda-troubleshooting-runbook.md`.

Recommended future alarm categories are:

- Lambda `Errors`;
- Lambda `Throttles`;
- Lambda `Duration`;
- API Gateway `5XXError`;
- DynamoDB write throttling metrics.

These are recommendations only and are not claims about deployed resources.

## 9. Screenshot evidence manifest

The following names refer to the external screenshot package collected during validation. The package may contain duplicate or exploratory screenshots; the entries below identify the evidence categories.

### Configuration and baseline

- `01-lambda-a-hooks-enabled.png`
- `02-lambda-a-hooks-enabled-2.png`
- `03-lambda-b-hooks-enabled.png`
- `04-lambda-b-hooks-enabled-2.png`
- `03-baseline-success-response.png`
- `05-baseline-lambda-a-logs.png`
- `06-baseline-lambda-b-logs.png`
- `07-baseline-lambda-duration.png`
- `08-baseline-errors-throttles-concurrency.png`
- `09-baseline-api-gateway-metrics.png`
- `10-baseline-xray-trace-details.png`

### Latency

- `11-latency-responses.png`
- `12a-latency-cloudwatch-logs.png`
- `12b-latency-delay-detail.png`
- `13-latency-lambda-duration.png`
- `14-latency-api-gateway-metrics.png`
- `15-latency-xray-overview.png`
- `16-latency-xray-timeline-logs-1.png`
- `16-latency-xray-timeline-logs-2.png`

### Downstream DynamoDB failure

- `17-downstream-failure-response.png`
- `17b-downstream-http-status.png`
- `18-downstream-lambda-b-logs.png`
- `19-downstream-lambda-a-logs.png`
- `20a-dynamodb-conditional-check-failed.png`
- `20b-dynamodb-conditional-check-failed-clean.png`
- `21-dynamodb-no-item.png`
- `22-downstream-xray-overview.png`
- `23-downstream-xray-timeline.png`
- `24-downstream-xray-timeline-2.png`
- `25-downstream-xray-timeline-3.png`

### Asynchronous retries, throttling, and alarms

- `24-retry-invocation.png`
- `25-retry-cloudwatch-logs-clean.png`
- `26-retry-lambda-metrics.png`
- `27-throttling-concurrency-metrics.png`
- `28-cloudwatch-alarms-not-deployed.png`

## 10. Repeatable diagnostic checklist

- [x] Record region, function names, endpoint, UTC window, and correlation ID.
- [x] Confirm that troubleshooting hooks are enabled in both Lambda functions for latency and downstream tests.
- [x] Capture the HTTP response before opening CloudWatch.
- [x] Search Lambda A and Lambda B logs using the correlation ID.
- [x] Inspect `REPORT`, `Duration`, and `Init Duration` for cold starts and execution time.
- [x] Check Lambda `Errors`, `Throttles`, and `ConcurrentExecutions`.
- [x] Check API Gateway `Latency`, `IntegrationLatency`, and `5XXError`.
- [x] Check DynamoDB conditional-failure and throttling-related metrics for dependency scenarios.
- [x] Locate the corresponding X-Ray trace and inspect the segment timeline.
- [x] For retry scenarios, identify whether the retry is client-side, synchronous caller behavior, or Lambda asynchronous retry.
- [x] For downstream failures, distinguish `ConditionalCheckFailedException` from `AccessDeniedException`, throttling, and system errors.
- [x] Verify that the controlled DynamoDB failure created no item.
- [x] Record missing alarms or missing controlled throttling experiments as explicit limitations.

## 11. Final assessment

The evidence demonstrates a repeatable troubleshooting workflow that combines:

```text
CloudWatch Logs
    + CloudWatch Metrics
    + X-Ray traces
    + documented alarm recommendations
```

The live validation successfully demonstrated latency diagnosis, application/downstream errors, asynchronous Lambda retries, correlation IDs, DynamoDB conditional failure behavior, and the relationship between Lambda, API Gateway, and DynamoDB timing.

The two remaining infrastructure-level limitations are intentional:

1. CloudWatch Alarms were not deployed.
2. Lambda throttling was not deliberately generated.

Both limitations are documented rather than presented as completed live experiments.
