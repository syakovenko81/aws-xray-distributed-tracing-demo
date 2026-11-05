# Architecture diagram

```mermaid
flowchart LR
    C[Client] -->|POST /events| G[API Gateway REST API\nactive X-Ray tracing]
    G -->|AWS X-Ray trace context| A[Lambda A\nADOT Python layer]
    A -->|Invoke RequestResponse\nW3C traceparent in event| B[Lambda B\nADOT Python layer]
    B -->|PutItem\nADOT AWS SDK span| D[(DynamoDB\nPAY_PER_REQUEST)]
    G -.-> X[X-Ray trace + service map]
    A -.-> X
    B -.-> X
    D -.-> X
```

Tracing is enabled on API Gateway and both Lambda functions. The ADOT layer exports Lambda and AWS SDK telemetry to X-Ray. Lambda A explicitly injects the active W3C context into the Lambda B event, and Lambda B extracts it before starting its application span.
