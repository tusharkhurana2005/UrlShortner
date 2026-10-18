const pino = require("pino");
const config = require("./config");

// Structured JSON logs to stdout. Kubernetes collects stdout, Alloy ships it to
// Loki, and the OpenTelemetry pino instrumentation adds trace_id/span_id so a
// log line can be joined to its trace in Grafana.
const logger = pino({
    level: config.logLevel,
    base: {
        service: "urlshortener-api",
        version: config.build.version,
    },
    redact: {
        paths: [
            "req.headers.authorization",
            "req.headers.cookie",
            "res.headers[\"set-cookie\"]",
        ],
        censor: "[REDACTED]",
    },
    timestamp: pino.stdTimeFunctions.isoTime,
    // "level":"error" instead of pino's numeric 50: readable, and Loki can
    // use it as a label without a mapping table.
    formatters: {
        level: (label) => ({ level: label }),
    },
});

module.exports = logger;
