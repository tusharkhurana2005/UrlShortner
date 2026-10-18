// All runtime configuration comes from environment variables so the same image
// runs unchanged in local dev, CI and Kubernetes (12-factor style).

const env = process.env;

const config = {
    env: env.NODE_ENV || "development",
    port: parseInt(env.PORT || "8000", 10),
    mongoUri: env.MONGODB_URI || "mongodb://127.0.0.1:27017/Urls",
    jwtSecret: env.JWT_SECRET,
    jwtExpiresIn: env.JWT_EXPIRES_IN || "1h",
    corsOrigins: (env.CORS_ORIGINS || "http://localhost:3000")
        .split(",")
        .map((o) => o.trim())
        .filter(Boolean),
    logLevel: env.LOG_LEVEL || "info",
    // After SIGTERM: keep serving (with readiness failing) for drainSeconds so
    // the pod leaves the load balancer first, then allow shutdownGraceSeconds
    // for in-flight requests before forcing exit.
    drainSeconds: parseInt(env.DRAIN_SECONDS || "10", 10),
    shutdownGraceSeconds: parseInt(env.SHUTDOWN_GRACE_SECONDS || "10", 10),
    authRateLimitPerWindow: parseInt(env.AUTH_RATE_LIMIT || "20", 10),
    build: {
        version: env.APP_VERSION || "dev",
        commit: env.GIT_COMMIT || "unknown",
        buildTime: env.BUILD_TIME || "unknown",
    },
};

if (!config.jwtSecret) {
    if (config.env === "production") {
        // Fail fast: never run production with a guessable signing key.
        throw new Error("JWT_SECRET must be set when NODE_ENV=production");
    }
    config.jwtSecret = "dev-only-insecure-secret";
}

module.exports = config;
