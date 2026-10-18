// Loaded before the app with `node --require ./tracing.js index.js` so the
// instrumentations can patch http/express/mongodb before they are required.
// Tracing is off unless OTEL_EXPORTER_OTLP_ENDPOINT is set (e.g. local dev, tests).

let sdk;

if (process.env.OTEL_EXPORTER_OTLP_ENDPOINT) {
    const { NodeSDK } = require("@opentelemetry/sdk-node");
    const { HttpInstrumentation } = require("@opentelemetry/instrumentation-http");
    const { ExpressInstrumentation } = require("@opentelemetry/instrumentation-express");
    const { MongoDBInstrumentation } = require("@opentelemetry/instrumentation-mongodb");
    const { PinoInstrumentation } = require("@opentelemetry/instrumentation-pino");
    const { OTLPTraceExporter } = require("@opentelemetry/exporter-trace-otlp-http");
    const { resourceFromAttributes } = require("@opentelemetry/resources");

    sdk = new NodeSDK({
        resource: resourceFromAttributes({
            "service.name": process.env.OTEL_SERVICE_NAME || "urlshortener-api",
            "service.version": process.env.APP_VERSION || "dev",
            "deployment.environment.name": process.env.DEPLOY_ENV || "local",
        }),
        traceExporter: new OTLPTraceExporter(),
        // Only the libraries this service uses: inbound/outbound HTTP, Express
        // routes, MongoDB queries (what Mongoose calls underneath), and pino so
        // every log line carries trace_id/span_id.
        instrumentations: [
            new HttpInstrumentation({
                // Probe and scrape traffic would drown out user requests.
                ignoreIncomingRequestHook: (req) =>
                    ["/healthz", "/readyz", "/metrics"].includes(req.url),
            }),
            new ExpressInstrumentation(),
            new MongoDBInstrumentation(),
            new PinoInstrumentation(),
        ],
    });

    sdk.start();
}

// Called from the graceful-shutdown path in index.js so buffered spans are
// flushed after in-flight requests finish, not before.
module.exports.shutdown = () => (sdk ? sdk.shutdown().catch(() => {}) : Promise.resolve());
