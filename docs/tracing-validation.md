# Tracing validation report

The report was prepared from the existing Lambda source, Terraform configuration, command-line output, and the ten supplied AWS validation screenshots. 

## 1. Overview

The validated request path is:

`Client -> API Gateway REST API -> Lambda A -> Lambda B -> DynamoDB`

The successful trace contains the complete path in one X-Ray trace. The controlled error trace shows the failure propagating from Lambda B through Lambda A to API Gateway. The deployed trace map also contains the expected API Gateway, Lambda, and DynamoDB relationships.

## 2. Test environment

| Item | Verified value |
|---|---|
| AWS region | `us-east-1` |
| API resource | `POST /dev/events` |
| Lambda runtime | Python 3.12 |
| Lambda functions | `aws-xray-demo-dev-lambda-a`, `aws-xray-demo-dev-lambda-b` |
| DynamoDB table | `aws-xray-demo-dev-records` |
| Tracing backend | AWS X-Ray through the AWS-managed ADOT Python Lambda layer |
| Test date | 2026-11-05 |

The screenshots show the AWS Console in the US East (N. Virginia) region and the deployed `dev` API Gateway stage. The successful request and DynamoDB record were executed with the same correlation ID. The error request used a separate correlation ID.

## 3. Instrumentation configuration

The implementation inspected for this report contains the following tracing configuration:

| Component | Implemented configuration | Evidence status |
|---|---|---|
| API Gateway | Regional REST API stage with `xray_tracing_enabled = true` | Visually supported by the API Gateway node and trace map |
| Lambda A | `tracing_config.mode = "Active"`; ADOT layer; `/opt/otel-instrument` wrapper | Verified in Terraform and trace timeline |
| Lambda B | `tracing_config.mode = "Active"`; ADOT layer; `/opt/otel-instrument` wrapper | Verified in Terraform and trace timeline |
| Lambda A -> Lambda B | Explicit OpenTelemetry context injection into `_trace_context` before `lambda:InvokeFunction` | Implemented in source and supported by the single end-to-end trace |
| Lambda B context handling | Extraction of `_trace_context` before starting `lambda_b.process` | Implemented in source and supported by the trace hierarchy |
| DynamoDB | Boto3 `PutItem` call under the active Lambda B span; ADOT AWS SDK instrumentation | DynamoDB segment is visible in the successful trace |
| Application spans | `lambda_a.request`, `lambda_a.invoke_lambda_b`, and `lambda_b.process` | Visible in the successful trace timeline |

The ADOT Application Signals integration is disabled in Terraform with `OTEL_AWS_APPLICATION_SIGNALS_ENABLED=false`; ADOT tracing and active X-Ray tracing remain enabled.

## 4. Successful request validation

### Test result

| Field | Result |
|---|---|
| HTTP method | `POST` |
| Endpoint | `/dev/events` |
| HTTP response | `200` |
| Correlation ID | `demo-success-20261105042734` |
| X-Ray Trace ID | `1-6aec05b6-724d0df5470e145c567f3665` |
| Trace duration | Approximately `3.618 seconds` (the Console rounds this to `3.6s`) |
| `HasFault` | `false` |
| `HasError` | `false` |
| DynamoDB result | Write completed successfully |

The screenshot shows a `stored` response and the expected correlation ID. The supplied screenshot shows one DynamoDB record with the same correlation ID and a generated record ID.

The successful X-Ray trace is shown in the supplied screenshots.

The trace timeline shows:

- API Gateway response `200`.
- Lambda A response `200`.
- Lambda A application spans `lambda_a.request` and `lambda_a.invoke_lambda_b`.
- Lambda B application span `lambda_b.process`.
- DynamoDB response `200`.
- Successful DynamoDB activity with an approximately 267 ms downstream operation.

The supplied verification result records `HasFault=false` and `HasError=false`. Those boolean field names are not displayed as raw values in the screenshots; the screenshots visually show the corresponding successful/green statuses.

## 5. Error propagation validation

### Test result

| Field | Result |
|---|---|
| HTTP response | `502` |
| Correlation ID | `demo-error-20261105043002` |
| X-Ray Trace ID | `1-6aec064b-596f141d2d2693a228231202` |
| Failure behavior | Lambda B intentionally raises before the DynamoDB write |
| Propagation | Lambda B -> Lambda A -> API Gateway |
| CloudWatch logs | Error and correlation ID are present |

The screenshot shows the expected `downstream_failure` response and correlation ID.

The error trace overview identifies the trace and shows a `502` response. The timeline  shows the API Gateway fault, the Lambda A invocation failure, and the Lambda B error/fault path. No successful DynamoDB write is present in this error trace, which is consistent with the source code raising before `table.put_item()`.

The related logs include the Lambda B failure and the correlation ID `demo-error-20261105043002` in the Lambda A and Lambda B log entries.

## 6. Service Map validation

The supplied screenshot shows the deployed AWS trace map in `us-east-1`.

The map visibly contains the expected flow and AWS-managed context/function nodes:

`Client -> API Gateway stage -> Lambda A -> Lambda B -> DynamoDB`

The successful path is connected to DynamoDB, and both Lambda functions are represented in the map. This verifies service-map visibility for the deployed demo.

## 7. Trace context propagation

Context propagation is implemented in two complementary ways:

1. API Gateway and active Lambda tracing provide the AWS X-Ray context for the request.
2. Lambda A calls `inject({})` while `lambda_a.invoke_lambda_b` is active and places the resulting carrier in the Lambda B event under `_trace_context`. Lambda B calls `extract(...)` and starts `lambda_b.process` with the extracted context.

The successful trace has the single X-Ray Trace ID `1-6aec05b6-724d0df5470e145c567f3665` and contains both Lambda A and Lambda B, followed by DynamoDB. This is evidence that the request was associated end to end across the deployed components.

The screenshots do not display the raw `_trace_context` event payload or the `traceparent` value itself. Therefore the carrier contents are documented as source-level implementation evidence, while the end-to-end parent/child association is verified by the X-Ray trace tree and timeline.

## 8. Annotations and custom spans

### Implemented in source

The shared telemetry helpers set these fields and mark them with the reserved `aws.xray.annotations` attribute:

- `correlation_id`
- `operation`
- `function_name`
- `request_type`

The fields are added to the Lambda A request/invocation spans and the Lambda B processing span. The message payload is not added to trace attributes.

The following custom spans are implemented:

| Span | Function | Purpose |
|---|---|---|
| `lambda_a.request` | Lambda A | API request validation and request-level correlation |
| `lambda_a.invoke_lambda_b` | Lambda A | Downstream Lambda invocation |
| `lambda_b.process` | Lambda B | Context extraction, validation, and DynamoDB write operation |

### Verified in supplied evidence

- The custom span names are visible in the successful X-Ray timeline screenshots.
- The DynamoDB downstream segment is visible and returns `200` in the successful trace.
- The correlation ID is visible in successful and error CloudWatch log entries.
- The error span/status path is visible in the error timeline.

The supplied screenshots do not show a selected trace node's raw attribute/annotation panel or an X-Ray filter query by `correlation_id`. Accordingly, this report does **not** claim visual Console verification that the four fields were rendered as indexed X-Ray annotations. Their implementation is confirmed by source inspection; their appearance in the provided trace screenshots is not independently visible.

## 9. Evidence and screenshots

Ten screenshots were supplied as external validation evidence. They are not stored in the Git repository, are not referenced by file links in this report, and were not renamed or modified.

| Screenshot | Content |
|---|---|
| `01-successful-api-call.png` | Successful API request and `stored` response |
| `02-dynamodb.png` | DynamoDB record containing the successful correlation ID |
| `03-test-err.png` | Controlled error request and `downstream_failure` response |
| `04-xray-successful-trace0-1.png` | Successful X-Ray trace overview and service relationships |
| `05-xray-successful-trace0-2.png` | Successful trace timeline with Lambda and DynamoDB segments |
| `06-xray-successful-trace0-3.png` | Successful trace details and correlated CloudWatch logs |
| `07-xray-service-map.png` | AWS X-Ray Service Map |
| `08-error-trace-overview.png` | Error trace overview with HTTP 502 |
| `09-error-trace-timeline.png` | Error propagation timeline across API Gateway and both Lambdas |
| `10-error-trace-cloudwatch-logs.png` | Error trace timeline and related CloudWatch logs |

The screenshots are available separately in the validation evidence package. They must be attached alongside this report when the EPAM evidence package is submitted; they are intentionally not part of the repository.

## 10. Validation summary

| Capability | Implementation status | AWS evidence status |
|---|---|---|
| API Gateway active X-Ray tracing | Implemented in Terraform | Verified in successful and error traces |
| Lambda A and Lambda B active tracing | Implemented in Terraform | Verified in trace timelines |
| Lambda A -> Lambda B context propagation | Explicit inject/extract implemented | Supported by one end-to-end successful trace; raw carrier not shown |
| DynamoDB tracing | ADOT AWS SDK instrumentation configured | DynamoDB segment and successful `PutItem` path visible |
| Correlation ID | Generated/accepted, forwarded, logged, and added to span annotations | Visible in API response, DynamoDB record, and CloudWatch logs |
| Custom spans | Implemented in both functions | Span names visible in the successful timeline |
| X-Ray annotations | Implemented with `aws.xray.annotations` | Raw indexed-annotation panel not shown in supplied screenshots |
| Controlled error scenario | Lambda B raises before DynamoDB write | Verified as HTTP 502 with error trace and logs |
| Service Map | Produced by deployed X-Ray telemetry | Verified in supplied Service Map screenshot |

The supplied evidence is sufficient to demonstrate the deployed end-to-end path, successful DynamoDB operation, service-map visibility, correlation logging, and controlled error propagation. The only evidence limitations are the absence of a raw annotation-details screenshot, raw `traceparent` payload output, and a separately captured CLI response showing the `HasFault`/`HasError` boolean fields.
