const client = require("prom-client");
const config = require("./config");

const register = new client.Registry();
client.collectDefaultMetrics({ register });

// RED metrics for every request. `route` is the Express route template
// (e.g. /api/url/delete/:id), never the raw path, to keep label cardinality bounded.
const httpRequestDuration = new client.Histogram({
    name: "http_request_duration_seconds",
    help: "HTTP request latency in seconds",
    labelNames: ["method", "route", "status_code"],
    buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
    registers: [register],
});

const urlsCreated = new client.Counter({
    name: "urlshortener_urls_created_total",
    help: "Short URLs successfully created",
    registers: [register],
});

const redirects = new client.Counter({
    name: "urlshortener_redirects_total",
    help: "Short URL lookups by result",
    labelNames: ["result"],
    registers: [register],
});

const authAttempts = new client.Counter({
    name: "urlshortener_auth_attempts_total",
    help: "Signup and login attempts by result",
    labelNames: ["action", "result"],
    registers: [register],
});

const mongoUp = new client.Gauge({
    name: "urlshortener_mongo_up",
    help: "1 if the API currently has a MongoDB connection",
    registers: [register],
});

// Constant 1 with the build identity as labels. Lets dashboards and alerts show
// exactly which commit is serving traffic.
const buildInfo = new client.Gauge({
    name: "urlshortener_build_info",
    help: "Build information for the running API",
    labelNames: ["version", "commit"],
    registers: [register],
});
buildInfo.set({ version: config.build.version, commit: config.build.commit }, 1);

function httpMetricsMiddleware(req, res, next) {
    const end = httpRequestDuration.startTimer();
    res.on("finish", () => {
        const route = req.route ? `${req.baseUrl}${req.route.path}` : "unmatched";
        end({ method: req.method, route, status_code: res.statusCode });
    });
    next();
}

module.exports = {
    register,
    httpMetricsMiddleware,
    urlsCreated,
    redirects,
    authAttempts,
    mongoUp,
};
