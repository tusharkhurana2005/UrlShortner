const express = require("express");
const cors = require('cors');
const helmet = require("helmet");
const mongoose = require('mongoose');
const pinoHttp = require("pino-http");
const crypto = require("crypto");
const config = require("./config");
const logger = require("./logger");
const { register, httpMetricsMiddleware, mongoUp } = require("./metrics");
const UserRoute = require("./Routes/UserRoute");
const UrlRoute = require("./Routes/UrlRoute");
const { redirect } = require("./controllers/UrlController");
const { notFound, errorHandler } = require("./middleware/errors");

const state = { shuttingDown: false };

const app = express();
// One proxy hop (the ingress controller) so req.ip is the real client for rate limiting.
app.set("trust proxy", 1);
app.disable("x-powered-by");

// Probes and scrapes are registered before logging/metrics so they do not flood
// the logs or skew the latency histogram.
app.get("/healthz", (req, res) => {
    // Liveness: the event loop is responsive. Deliberately does NOT check Mongo,
    // otherwise a database outage would make Kubernetes restart healthy API pods.
    res.status(200).json({ status: "ok" });
});

app.get("/readyz", (req, res) => {
    // Readiness: only receive traffic when Mongo is connected and we are not draining.
    const dbReady = mongoose.connection.readyState === 1;
    mongoUp.set(dbReady ? 1 : 0);
    if (state.shuttingDown || !dbReady) {
        return res.status(503).json({ status: "not ready", db: dbReady, shuttingDown: state.shuttingDown });
    }
    res.status(200).json({ status: "ready" });
});

app.get("/metrics", async (req, res) => {
    mongoUp.set(mongoose.connection.readyState === 1 ? 1 : 0);
    res.set("Content-Type", register.contentType);
    res.send(await register.metrics());
});

app.use(pinoHttp({
    logger,
    customLogLevel: (req, res, err) => {
        if (err || res.statusCode >= 500) return "error";
        if (res.statusCode >= 400) return "warn";
        return "info";
    },
    // Lean request logs: id, method, route, status and timing are enough to
    // investigate (the trace has the rest). Logging every header made each
    // line several KB, drove the log shipper's CPU under load and kept
    // user agents/IPs we do not need.
    serializers: {
        req: (req) => ({ id: req.id, method: req.method, url: req.url }),
        res: (res) => ({ statusCode: res.statusCode }),
    },
    genReqId: (req, res) => {
        const id = req.headers["x-request-id"] || crypto.randomUUID();
        res.setHeader("X-Request-Id", id);
        return id;
    },
}));
app.use(httpMetricsMiddleware);
app.use(helmet());
app.use(express.json({ limit: "10kb" }));

app.use(cors({
    origin: config.corsOrigins,
    methods: ["GET", "POST", "PUT", "DELETE"],
    credentials: true,
}));

app.use("/api/user", UserRoute);
app.use("/api/url", UrlRoute);
app.get("/r/:id", redirect);

app.get("/api/version", (req, res) => {
    res.json(config.build);
});

app.get("/", (req, res) => {
    res.send("Hello World!");
});

app.use(notFound);
app.use(errorHandler);

module.exports = { app, state };
