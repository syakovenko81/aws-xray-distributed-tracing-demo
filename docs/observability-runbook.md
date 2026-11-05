# Observability runbook: tracing a serverless request

This runbook is for the deployed demo in this repository. It traces one request through:

`Client -> API Gateway REST API -> Lambda A -> Lambda B -> DynamoDB`

Use it after a deployment, without changing Lambda code or Terraform. The architecture and implementation details are in [`architecture.md`](architecture.md); the supplied deployment evidence is in [`tracing-validation.md`](tracing-validation.md).

## Scope and evidence boundaries

The demo has these deployed resources, with names derived from the Terraform variables `project_name` and `environment`:

| Resource | Default/example value |
| --- | --- |
| Region | `us-east-1` |
| API | `POST /dev/events` |
| Lambda A | `aws-xray-demo-dev-lambda-a` |
| Lambda B | `aws-xray-demo-dev-lambda-b` |
| DynamoDB table | `aws-xray-demo-dev-records` |
| Lambda log groups | `/aws/lambda/aws-xray-demo-dev-lambda-a` and `/aws/lambda/aws-xray-demo-dev-lambda-b` |

The names above are the values recorded by the validation report. For another deployment, use the Terraform outputs rather than assuming the defaults.

The validation report verified a complete successful trace and a controlled error trace in `us-east-1` on 2026-11-05:

| Scenario | Correlation ID | X-Ray Trace ID | Expected result |
| --- | --- | --- | --- |
| Success | `demo-success-20261105042734` | `1-6aec05b6-724d0df5470e145c567f3665` | HTTP 200, DynamoDB write, approximately 3.618 seconds, `HasFault=false`, `HasError=false` |
| Controlled error | `demo-error-20261105043002` | `1-6aec064b-596f141d2d2693a228231202` | HTTP 502; Lambda B raises before the DynamoDB write |

These are historical evidence examples, not IDs to reuse for a new test. The validation evidence verified the trace tree, timeline, service map, logs, and DynamoDB result. It did not include the raw `_trace_context`/`traceparent` payload or a raw annotation-details panel, so those details are source-verified but not independently evidence-verified.

## Prerequisites and access

### AWS access

Use credentials authorized for the deployment account and the deployment region. An observer role should have, at minimum:

- `xray:GetTraceSummaries`
- `xray:BatchGetTraces`
- `xray:GetServiceGraph`
- `xray:GetSamplingRules` if sampling rules must be inspected
- `logs:DescribeLogGroups`
- `logs:DescribeLogStreams`
- `logs:FilterLogEvents` and/or `logs:GetLogEvents`
- `logs:StartQuery` and `logs:GetQueryResults` only if CloudWatch Logs Insights is used
- `dynamodb:Scan` only if the optional DynamoDB record check below is used

The runbook does not require the observer to have permission to deploy, invoke, or modify resources. The Lambda execution roles in this repository separately require permission to publish X-Ray segments/telemetry and write their own logs; those are deployment prerequisites, not permissions for the engineer reading telemetry.

### Confirm the deployment context

Run these commands from the repository root after Terraform has been initialized and applied:

```bash
REGION="$(terraform -chdir=terraform output -raw deployment_region)"
API_ENDPOINT="$(terraform -chdir=terraform output -raw api_endpoint)"
LAMBDA_A="$(terraform -chdir=terraform output -raw lambda_a_name)"
LAMBDA_B="$(terraform -chdir=terraform output -raw lambda_b_name)"
TABLE_NAME="$(terraform -chdir=terraform output -raw dynamodb_table_name)"
echo "region=$REGION api=$API_ENDPOINT lambda_a=$LAMBDA_A lambda_b=$LAMBDA_B table=$TABLE_NAME"
```

The demo defaults to `us-east-1`, `project_name=aws-xray-demo`, and `environment=dev`. These commands remain correct when those variables were overridden.

### Tracing configuration to verify

The implementation relies on all of the following:

- API Gateway is a regional REST API with stage-level `xray_tracing_enabled = true`.
- Both Lambda functions use `tracing_config.mode = "Active"`.
- Both functions attach the AWS-managed ADOT Python Lambda layer and set `AWS_LAMBDA_EXEC_WRAPPER=/opt/otel-instrument`.
- `OTEL_PROPAGATORS` is `tracecontext,baggage,xray-lambda`.
- Lambda A injects the current OpenTelemetry context into the event field `_trace_context` before its synchronous `RequestResponse` invoke of Lambda B. Lambda B extracts that field before starting `lambda_b.process`.
- ADOT instruments the Boto3 DynamoDB `PutItem` call under Lambda B's active context.
- Application Signals, ADOT metrics, and ADOT logs are disabled in Terraform; tracing remains enabled.

The ADOT layer ARN is a Terraform variable and must be published in the selected region. If a trace is missing after a layer change, verify the deployed layer ARN and wrapper configuration before investigating application behavior.

## Procedure: trace one successful request

### 1. Generate a request with a known Correlation ID

Use a unique, short ID and keep it for the entire investigation. The handler accepts a caller-provided ID of 1–64 characters and returns it in the response.

```bash
CORRELATION_ID="runbook-success-$(date -u +%Y%m%d%H%M%S)"
./scripts/test-success.sh "$API_ENDPOINT" "$CORRELATION_ID"
```

Expected application response shape:

```json
{"status":"stored","record_id":"<generated-id>","correlation_id":"runbook-success-<timestamp>"}
```

The exact `record_id` is generated by Lambda B and is not predictable. If the caller does not provide `correlation_id`, Lambda A generates a `demo-...` ID; an explicit ID is easier to search for in X-Ray and CloudWatch Logs.

For the controlled error path, use the repository helper instead:

```bash
CORRELATION_ID="runbook-error-$(date -u +%Y%m%d%H%M%S)"
./scripts/test-error.sh "$API_ENDPOINT" "$CORRELATION_ID"
```

That request should return an HTTP 502 body containing `downstream_failure` and the same correlation ID. Lambda B raises before `PutItem`, and Lambda A converts the downstream function error to the 502 response.

### 2. Allow for X-Ray ingestion

Wait briefly after the request, then search a UTC window covering the request. X-Ray is not a synchronous response channel; a successful API response does not guarantee that the trace is already searchable.

```bash
START_EPOCH="$(date -u -d '15 minutes ago' +%s)"
END_EPOCH="$(date -u +%s)"
```

If the request was made earlier, set explicit Unix-second values that cover its timestamp. Use the same region as the deployment on every AWS CLI command.

### 3. Locate the trace by Correlation ID

The telemetry helper sets `correlation_id` as one of the fields configured for X-Ray annotations. Start with an annotation filter:

```bash
aws xray get-trace-summaries --region "$REGION" --start-time "$START_EPOCH" --end-time "$END_EPOCH" --no-sampling --filter-expression "annotation.correlation_id = \"$CORRELATION_ID\"" --query 'TraceSummaries[].{TraceId:Id,Duration:Duration,Fault:HasFault,Error:HasError}' --output table
```

The `TraceId` column in this query is the X-Ray `Id` field. Copy the returned value into `TRACE_ID`; it has the X-Ray form `1-<8 hex digits>-<24 hex digits>`.

If this returns no row, do not conclude immediately that the request was untraced. Annotation indexing may not be available for the deployed layer representation, the trace may be unsampled, or ingestion may still be in progress. Use the fallback below to list recent summaries, then correlate the timestamp, API response, and service names:

```bash
aws xray get-trace-summaries --region "$REGION" --start-time "$START_EPOCH" --end-time "$END_EPOCH" --no-sampling --query 'TraceSummaries[].{TraceId:Id,Start:StartTime,Duration:Duration,Fault:HasFault,Error:HasError,Services:ServiceIds}' --output table
```

The validation evidence recorded this known mapping: `demo-success-20261105042734` -> `1-6aec05b6-724d0df5470e145c567f3665`; `demo-error-20261105043002` -> `1-6aec064b-596f141d2d2693a228231202`.

CloudWatch Logs in step 6 are the fallback when the X-Ray summary does not contain an annotation match: Lambda A logs the accepted correlation ID, and Lambda B logs the same ID on success or failure.

### 4. Retrieve the trace details

Set the trace ID returned by X-Ray (or one of the historical evidence IDs when reviewing that evidence):

```bash
TRACE_ID="<trace-id-from-the-TraceId-column>"
aws xray batch-get-traces --region "$REGION" --trace-ids "$TRACE_ID" --output json
```

`BatchGetTraces` returns trace segments as serialized segment documents. In the console, the same response is easier to read by opening **X-Ray -> Traces**, selecting the trace, and expanding the trace tree. In either view, record the segment names, parent/child relationships, response status, duration, annotations, and downstream calls. Do not treat an empty response as proof of a bad request until the region, trace ID, permissions, and ingestion delay have been checked.

### 5. Inspect segments, subsegments, and context propagation

For a successful request, the expected trace hierarchy is:

1. API Gateway request segment for the deployed `dev` stage and `POST /events`.
2. Lambda A segment, containing the application spans `lambda_a.request` and `lambda_a.invoke_lambda_b`.
3. Lambda B segment, containing `lambda_b.process`.
4. A DynamoDB downstream segment/subsegment for the `PutItem` operation under Lambda B's active context.

The exact nesting and display labels can vary by X-Ray/ADOT layer version, but the validated successful trace showed the API Gateway, both Lambdas, the application spans, and a successful DynamoDB operation in one end-to-end X-Ray trace.

Verify propagation using these checks:

- The successful path uses one X-Ray Trace ID from API Gateway through Lambda A, Lambda B, and DynamoDB.
- Lambda A's `lambda_a.invoke_lambda_b` span is the parent context used to inject `_trace_context`.
- Lambda B extracts `_trace_context` before creating `lambda_b.process`.
- The Lambda A and Lambda B logs contain the same Correlation ID. The source logs also emit the current trace/span IDs when a valid ADOT context is present.

The raw `_trace_context` event and `traceparent` value are not logged by this demo. Their presence is therefore verified from source and inferred from the single end-to-end trace association, not from a captured event payload.

### 6. Verify DynamoDB visibility and logs

In the successful trace, select the DynamoDB child operation and confirm that it is a successful `PutItem`-related operation. The validation evidence recorded an approximately 267 ms downstream DynamoDB operation with response `200`.

Search both Lambda log groups using the same Correlation ID:

```bash
START_MS="$((START_EPOCH * 1000))"
END_MS="$((END_EPOCH * 1000))"
aws logs filter-log-events --region "$REGION" --log-group-name "/aws/lambda/$LAMBDA_A" --start-time "$START_MS" --end-time "$END_MS" --filter-pattern "\"$CORRELATION_ID\"" --output json
aws logs filter-log-events --region "$REGION" --log-group-name "/aws/lambda/$LAMBDA_B" --start-time "$START_MS" --end-time "$END_MS" --filter-pattern "\"$CORRELATION_ID\"" --output json
```

For a successful request, expect an accepted-request entry from Lambda A and a stored-record entry from Lambda B. The DynamoDB record itself contains `record_id`, `correlation_id`, and `message`. The validated success record for `demo-success-20261105042734` contained these fields and record ID `demo-success-20261105042734-bfe17039241a`.

If you also need to verify the stored record outside the trace, use this optional read-only command:

```bash
aws dynamodb scan --table-name "$TABLE_NAME" --region "$REGION" --output json
```

This requires `dynamodb:Scan`, which is not part of the minimum X-Ray and CloudWatch read permissions.

## Interpreting the X-Ray views

### Service Map

The Service Map is an aggregate over the selected time range, not a visualization of one request. For this demo, a matching window should show the flow:

`Client -> API Gateway stage -> Lambda A -> Lambda B -> DynamoDB`

Use it to answer operational questions such as:

- Is the API Gateway stage sending traffic to Lambda A?
- Is Lambda A reaching Lambda B?
- Is Lambda B reaching DynamoDB on successful requests?
- Which node or edge is showing errors, faults, latency, or no traffic in the selected time range?

Select the same region and time range used for the trace search. A node can be absent because there was no sampled traffic for it in the window, because the window is too narrow, or because the request took the controlled error path before DynamoDB. The validation evidence verified the expected API Gateway, Lambda, and DynamoDB nodes and relationships for the deployed demo.

The X-Ray Service Map also displays separate `Lambda Context` and `Lambda Function` nodes for the two functions. Treat these as X-Ray's representation of the Lambda invocation/context and function layers, not as additional application components.

### Segments Timeline and trace tree

The Segments Timeline is request-specific. Read it from the outer request inward:

- The API Gateway segment establishes the request and HTTP result.
- Lambda A shows the handler work and its `lambda_a.request` / `lambda_a.invoke_lambda_b` application spans.
- Lambda B shows `lambda_b.process` and, on success, the DynamoDB operation.
- Horizontal length represents elapsed duration; parent/child nesting shows propagation and downstream work.
- An error or fault marker identifies the part of the path that reported a problem; use the segment details and CloudWatch Logs to determine the exception.

Lambda cold-start rows such as `Init` and `Overhead` may also appear; they are runtime detail, not additional business steps. In the validated success, the timeline showed the DynamoDB operation as `200` with a 267 ms duration. In the validated error, the timeline showed API Gateway `502`/`Fault`, Lambda A's downstream invocation fault, and Lambda B `Error`/`Fault`; no DynamoDB operation was displayed for that request.

For the validated success, the timeline showed API Gateway 200, Lambda A 200, Lambda B processing, DynamoDB 200, and no error/fault indicators. For the validated error, Lambda B failed, Lambda A returned the dependency failure, API Gateway returned 502, and no successful DynamoDB write was present.

## Sampling and trace availability

X-Ray sampling determines which requests receive a complete trace. It is normal for a request to succeed while no corresponding full trace is available: the request may not have won the sampling decision, or telemetry may not yet have been ingested. Sampling affects trace visibility, not the application response or the Lambda log entries.

This repository does not define an X-Ray sampling rule in Terraform. The effective account/service sampling configuration therefore comes from AWS defaults or rules configured outside this repository. Do not assume that sending many test requests will produce one trace per request.

When a trace is missing, check in this order:

1. Confirm the CLI region matches `deployment_region` and widen the UTC time range.
2. Wait for ingestion and query summaries without an annotation filter.
3. Confirm the request response and search both Lambda log groups by Correlation ID.
4. Check the effective X-Ray sampling rules if access is available:

   ```bash
   aws xray get-sampling-rules --region "$REGION" --output json
   ```

5. Verify API Gateway active tracing, both Lambda `Active` tracing configurations, the ADOT layer/wrapper, and the Lambda execution-role permissions to publish X-Ray segments and telemetry.

`get-trace-summaries --sampling` can return sampling statistics with the summaries, but it does not force an unsampled request to become traceable. The `--no-sampling` commands in this runbook are used to avoid requesting sampling statistics; they do not disable AWS sampling.

## Troubleshooting

### No trace found

- Confirm `REGION` and the UTC start/end values. X-Ray traces are regional.
- Search without the annotation filter, because the request may be sampled but the annotation may not be indexed or may be represented differently by the deployed ADOT layer.
- Wait for ingestion and use a wider window.
- Check the response and Lambda logs by Correlation ID. Logs can confirm that the request reached the functions even when a sampled trace is unavailable.
- Check sampling rules and the active-tracing configuration. A successful HTTP response alone does not prove that a full X-Ray trace was sampled.

### Incomplete trace

- If the API Gateway segment exists but a child is absent, inspect the trace time range and the function invocation logs.
- Confirm that both Lambda functions are deployed with `tracing_config.mode = "Active"`, the ADOT layer, and `/opt/otel-instrument`.
- Check the Lambda execution role for `xray:PutTraceSegments` and `xray:PutTelemetryRecords`.
- Compare the trace tree with the request path. The error test intentionally stops before DynamoDB, so an error trace is expected to be shorter than a success trace.

### Missing Lambda segments

- Verify the function names from Terraform outputs and search the correct region.
- Check whether Lambda A or B was invoked in CloudWatch Logs.
- Verify active tracing, the deployed ADOT layer ARN, and `AWS_LAMBDA_EXEC_WRAPPER`.
- Confirm that the execution role can publish X-Ray telemetry. A function can execute and log normally while its X-Ray segment is unavailable.

### Missing DynamoDB subsegments

- Confirm that the request used the success path. `simulate_error=true` raises in Lambda B before `table.put_item()` and should not produce a successful DynamoDB write.
- On the success path, inspect the Lambda B portion of the trace for the Boto3 `PutItem` call and confirm the table name from `TABLE_NAME`.
- Verify Lambda B's `dynamodb:PutItem` permission and the table's region.
- Verify that the ADOT layer is present and that the call runs under Lambda B's active context. The repository relies on ADOT AWS SDK instrumentation; it does not create a separate manual DynamoDB span.

### Broken trace context propagation

- A successful end-to-end request should keep one X-Ray Trace ID across API Gateway, Lambda A, Lambda B, and the DynamoDB downstream operation.
- Inspect source/deployed configuration for `OTEL_PROPAGATORS=tracecontext,baggage,xray-lambda`.
- Verify that Lambda A injects the carrier into `_trace_context` and that Lambda B extracts it before `lambda_b.process`.
- Verify that Lambda A invokes Lambda B with `RequestResponse` and that the event has not been altered by an intermediary. This demo does not log the raw carrier, so do not claim payload-level verification from the supplied evidence.
- If the functions have separate traces, use the Correlation ID and logs to determine whether the break is at the Lambda invocation or at ADOT context extraction.

### Missing annotations

- The source configures `correlation_id`, `operation`, `function_name`, and `request_type` through the reserved `aws.xray.annotations` attribute on the application spans.
- First use CloudWatch Logs and the trace time window to locate the request; then inspect the selected span's attributes in the X-Ray console or returned segment documents.
- If an annotation filter returns no result, retry without the filter. The validation evidence did not include a raw indexed-annotation panel, so indexed rendering is not independently verified.
- Do not add the message payload to searches expecting an annotation: the implementation intentionally does not put `message` into trace attributes.

### Error and fault indicators

- Inspect `HasError` and `HasFault` in `get-trace-summaries`, then open the trace to identify the segment that reported the status.
- On the controlled error path, Lambda B raises `controlled DynamoDB failure for tracing demo` before the write; Lambda A records the downstream failure and returns 502.
- The application spans call `record_exception` and set an OpenTelemetry error status when the handler catches an error. Use CloudWatch Logs to confirm the exception and Correlation ID.
- Do not interpret every latency increase as a fault. Use the timeline duration, segment status, and logs together. The validated success had `HasFault=false` and `HasError=false`; the validated error showed the expected propagation to HTTP 502.

## Command reference

The following commands are the minimal CLI set used by this runbook. They return live AWS data; no output is reproduced here.

```bash
# Recent trace summaries
aws xray get-trace-summaries --region "$REGION" --start-time "$START_EPOCH" --end-time "$END_EPOCH" --no-sampling --output json

# Details for one X-Ray trace
aws xray batch-get-traces --region "$REGION" --trace-ids "$TRACE_ID" --output json

# Aggregate service graph for the same time window
aws xray get-service-graph --region "$REGION" --start-time "$START_EPOCH" --end-time "$END_EPOCH" --output json

# Recent Lambda log streams
aws logs describe-log-streams --region "$REGION" --log-group-name "/aws/lambda/$LAMBDA_A" --order-by LastEventTime --descending --max-items 5 --output json

# Correlation-ID log search; repeat for Lambda B as shown above
aws logs filter-log-events --region "$REGION" --log-group-name "/aws/lambda/$LAMBDA_A" --start-time "$START_MS" --end-time "$END_MS" --filter-pattern "\"$CORRELATION_ID\"" --output json
```

The X-Ray commands require trace-read access; the log commands require CloudWatch Logs read access. These commands do not deploy, mutate, or delete resources.
