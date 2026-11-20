# AWS observability versus configuration auditing

## 1. Purpose and scope

Cloud operations use different evidence for different questions. **Observability** explains the health and behavior of a workload: what users experienced, which component was slow, and where an error occurred. It is built from operational telemetry such as metrics, logs, and traces. **Configuration auditing** establishes what AWS resources are configured to do, whether that configuration meets a stated control, and how it changed over time.

Amazon CloudWatch and AWS X-Ray are the primary services discussed here for workload observability. AWS Config is the service for resource configuration recording and compliance evaluation. They can be used together, but an alarm, trace, or dashboard is not a substitute for a recorded configuration item or a Config rule result.

The repository provides concrete examples. The X-Ray demo traces `API Gateway -> Lambda A -> Lambda B -> DynamoDB`, using active X-Ray tracing, the AWS-managed ADOT Python Lambda layer, and Terraform-managed infrastructure. The isolated Config PoC records S3 bucket and compliance-resource configuration, delivers history to a dedicated S3 bucket, evaluates versioning with a managed rule, and evaluates encryption and public-read controls in a Conformance Pack.

## 2. Service responsibilities

### Amazon CloudWatch: metrics, logs, alerts, and operational visibility

CloudWatch collects and presents metrics and logs from AWS resources and applications. Engineers use metrics to establish baselines and detect symptoms such as high CPU, elevated error rate, throttling, or increased duration. Logs provide event and exception detail; dashboards correlate signals; alarms turn threshold or anomaly conditions into actionable notifications.

CloudWatch is therefore the normal first tool for infrastructure and application monitoring and for operational troubleshooting. It can display operational telemetry and can be integrated with other observability data, but a CloudWatch alarm does not evaluate a resource against a security or compliance requirement. The X-Ray demo creates CloudWatch log groups for both Lambda functions; it does not deploy dashboards or alarms, so those are optional operational consumers rather than resources configured by this PoC.

### AWS X-Ray: request-level distributed tracing

X-Ray follows an individual request across service boundaries. A trace can show the request path, segment timing, downstream calls, and error or fault information, allowing an engineer to identify a slow dependency or the component that failed. It answers a different question from an aggregate metric: not only “is latency high?” but “which part of this request path consumed the latency?”

In this repository, API Gateway and both Lambda functions use active tracing. Lambda A injects trace context into the synchronous Lambda B event; Lambda B extracts it before its application span, and the DynamoDB `PutItem` call runs under that active context with ADOT AWS SDK instrumentation. This supports end-to-end trace inspection; it does not automatically inspect IAM, encryption, public-access, or other security configuration and does not replace AWS Config.

### AWS Config: configuration recording and compliance evaluation

AWS Config records resource configuration as **Configuration Items (CIs)** and maintains configuration history and relationships for supported resource types. A **Configuration Recorder** determines which resource types are recorded. A delivery channel can deliver history and snapshots to storage, such as the dedicated S3 history bucket in this PoC. This recording function answers “what was configured, and when did it change?” It is separate from compliance evaluation.

**Config Rules** compare recorded resource state with an expected control. Managed rules are AWS-provided checks; custom rules can encode organization-specific requirements. Results such as `COMPLIANT` and `NON_COMPLIANT` are evaluations and should not be confused with the underlying CIs. **Conformance Packs** group Config rules and, where defined, remediation actions into a deployable control set. The Config console’s Resource Timeline and configuration history help investigate the sequence of resource and compliance changes.

The Config PoC uses an S3 Configuration Recorder for `AWS::S3::Bucket` and `AWS::Config::ResourceCompliance`, a dedicated S3 delivery bucket, and the managed rule `S3_BUCKET_VERSIONING_ENABLED`. Its Conformance Pack contains `S3_BUCKET_SERVER_SIDE_ENCRYPTION_ENABLED` and `S3_BUCKET_PUBLIC_READ_PROHIBITED`, scoped to the test bucket. Config is primarily detective: recording and evaluation do not prevent a change from being made, and evaluation is not a synchronous enforcement mechanism.

### Comparison

| Service | Primary purpose | What data is collected | Typical questions answered | Example use cases | What it does **not** replace |
| --- | --- | --- | --- | --- | --- |
| CloudWatch | Operational monitoring and alerting | Metrics, logs, dashboards, alarm state, and related telemetry | Is the workload healthy? Is CPU, duration, error rate, or log volume abnormal? | ECS CPU alarm; Lambda error logs; API latency dashboard | AWS Config compliance evaluation or X-Ray’s request path |
| X-Ray | Distributed request tracing | Trace segments, subsegments, timing, downstream calls, and request errors/faults | Where is this request slow or failing? Which dependency is involved? | API Gateway to Lambda to DynamoDB latency analysis | Security/configuration auditing, resource history, or compliance controls |
| AWS Config | Resource configuration auditing and compliance | Configuration Items, configuration history, relationships, rule evaluations, and Conformance Pack results | What changed? Does this resource meet the required configuration? | S3 versioning, encryption, and public-read controls | Metrics/log monitoring, request tracing, or real-time prevention |

## 3. Practical scenarios

### 1. ECS service CPU utilization is high

Use **CloudWatch**. ECS and its underlying compute resources publish CPU metrics that can be graphed, compared with a baseline, and used to trigger an alarm. CloudWatch Logs and related service metrics can then help determine whether the utilization is caused by traffic, a deployment, retries, or a hot code path.

X-Ray is not the primary tool because the initial symptom is an aggregate resource metric, not a known request path. It may help later if traced requests show that a particular downstream call or handler is consuming time, but it does not replace the CPU metric or alarm. AWS Config is not primary because it can tell whether ECS-related configuration changed or complies with a rule, but it does not measure live CPU utilization or explain current workload pressure.

### 2. API Gateway -> Lambda -> DynamoDB has high request latency

Use **X-Ray** to inspect a representative trace. The trace can show time spent in API Gateway, Lambda A, Lambda B, and the DynamoDB operation, making a service-boundary bottleneck visible. In this repository, the equivalent path is already instrumented with active tracing and the ADOT Python layer; Lambda A propagates context to Lambda B and the DynamoDB SDK call is instrumented under the active context.

CloudWatch remains useful for the aggregate view: API/Lambda duration, errors, logs, and alarms can establish that latency is abnormal and show repeated exceptions. It is not the primary answer to the request-level question because aggregate metrics do not by themselves identify the exact downstream segment. AWS Config is not primary because a compliant configuration can still produce slow requests, and Config does not collect distributed request timing.

### 3. An S3 bucket does not have versioning enabled

Use **AWS Config**. The managed rule `S3_BUCKET_VERSIONING_ENABLED` evaluates the bucket against the required configuration and records the result. In the Config PoC, the test bucket initially produced `NON_COMPLIANT`; after versioning was enabled manually, the rule transitioned to `COMPLIANT`. The configuration history evidence shows the S3 `BucketVersioningConfiguration` changing from `Off` to `Enabled`.

CloudWatch is not primary because a metric, log, dashboard, or alarm does not constitute a versioning compliance evaluation. X-Ray is not relevant because there is no request-latency or service-boundary question. Config detects and records the state; an engineer or an approved remediation workflow must address the change.

### 4. An S3 bucket is public or violates an encryption requirement

Use **AWS Config Rules** and a **Conformance Pack**. Rules such as `S3_BUCKET_PUBLIC_READ_PROHIBITED` and `S3_BUCKET_SERVER_SIDE_ENCRYPTION_ENABLED` can evaluate the resource configuration and report compliance. A Conformance Pack groups such controls so an account or organization can assess a defined baseline consistently. In this repository’s pack, both rules are scoped to the isolated test bucket.

CloudWatch may show access logs or operational symptoms, but those signals do not prove that the bucket satisfies the control. X-Ray traces application requests that use services; they do not automatically detect a public bucket policy or missing encryption configuration. Config evaluation is detective and may be asynchronous; use preventive IAM/SCP controls, service-native blocking settings, or an approved remediation process when prevention is required.

## 4. How the services complement each other

A practical incident and control workflow is:

1. **CloudWatch detects the symptom.** Metrics, logs, dashboards, and alarms indicate elevated error rate, duration, CPU, throttling, or another operational deviation.
2. **X-Ray investigates request behavior.** For a distributed request, inspect the trace tree and downstream segments to locate latency, retries, errors, or faults across service boundaries.
3. **AWS Config checks resource state and compliance.** Review CIs, configuration history, Resource Timeline, rule results, and Conformance Pack results to determine whether a resource changed or violates a required baseline.

The streams can be correlated by time, resource name, deployment, request identifiers, and incident records. They answer related but non-interchangeable questions: telemetry describes workload behavior, tracing explains a request’s journey, and Config establishes resource configuration and compliance history.

## 5. Common mistakes and best practices

- **Mistake: using X-Ray as a security audit.** Traces show instrumented request behavior and metadata, not whether a bucket is encrypted, public, or governed by the correct policy. Use Config Rules and Conformance Packs for those controls.
- **Mistake: treating a CloudWatch alarm as proof of compliance.** An alarm proves that a metric or log condition met its alarm logic. It does not evaluate the desired configuration of an AWS resource. Use Config for the compliance assertion.
- **Mistake: expecting AWS Config to provide distributed tracing.** Configuration history can explain a resource change, but it cannot show the critical path or latency of one API request. Use X-Ray for that.
- **Mistake: relying on a dashboard instead of configuration history.** A dashboard is useful for current operational state; it is not the authoritative timeline of resource configuration changes. Use the Configuration Recorder, CIs, history, and Resource Timeline.
- **Mistake: confusing recording with compliance.** Enable recording for the resource types needed by the audit, then separately configure and scope rules. A CI is evidence of observed configuration; a rule result is an evaluation against a requirement.

Choose CloudWatch for health signals and alerting, X-Ray for request causality and dependency latency, and AWS Config for configuration history and compliance. Define the required control before selecting a rule, account for evaluation delay, and pair detective Config controls with preventive or corrective controls where the risk requires it.

## 6. Conclusion and decision guide

| Decision question | Primary service | Evidence to inspect |
| --- | --- | --- |
| Is the application or infrastructure healthy? | **Amazon CloudWatch** | Metrics, logs, dashboards, and alarms |
| Where is the request slow or failing? | **AWS X-Ray** | Trace map, segments, subsegments, timing, and error/fault details |
| Does the AWS resource configuration comply with requirements? | **AWS Config** | Configuration Items, history, Resource Timeline, Config Rules, and Conformance Pack results |

Use the services together when an incident needs both operational diagnosis and configuration accountability. Do not use one service as a proxy for evidence that only another service collects.

## Official references

- [Amazon CloudWatch User Guide — What is Amazon CloudWatch?](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/WhatIsCloudWatch.html)
- [AWS X-Ray Developer Guide — What is AWS X-Ray?](https://docs.aws.amazon.com/xray/latest/devguide/aws-xray.html)
- [AWS Config Developer Guide — What Is AWS Config?](https://docs.aws.amazon.com/config/latest/developerguide/WhatIsConfig.html)
- [AWS Well-Architected Framework — Implement observability](https://docs.aws.amazon.com/wellarchitected/latest/operational-excellence-pillar/implement-observability.html)
- [AWS Well-Architected Framework — Utilizing workload observability](https://docs.aws.amazon.com/wellarchitected/latest/operational-excellence-pillar/utilizing-workload-observability.html)
- [AWS Config Developer Guide — Evaluating Resources with AWS Config Rules](https://docs.aws.amazon.com/config/latest/developerguide/evaluate-config.html)
- [AWS Config Developer Guide — Conformance Packs](https://docs.aws.amazon.com/config/latest/developerguide/conformance-packs.html)
