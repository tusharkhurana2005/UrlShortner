const mongoose = require('mongoose');
const config = require("./config");
const logger = require("./logger");
const tracing = require("./tracing");
const { app, state } = require("./app");

mongoose.connection.on("connected", () => logger.info("MongoDB connected"));
mongoose.connection.on("disconnected", () => logger.warn("MongoDB disconnected"));
mongoose.connection.on("error", (err) => logger.error({ err }, "MongoDB error"));

// The baseline tried once and gave up. Keep retrying so the API recovers on
// its own when Mongo starts after it (or comes back after an outage);
// readiness stays false until this succeeds.
const connectWithRetry = async (attempt = 1) => {
    try {
        await mongoose.connect(config.mongoUri, { serverSelectionTimeoutMS: 5000 });
    } catch (err) {
        const delay = Math.min(30000, 1000 * 2 ** Math.min(attempt, 5));
        logger.error({ err: err.message, attempt, retryInMs: delay }, "MongoDB connection failed");
        setTimeout(() => connectWithRetry(attempt + 1), delay);
    }
};

const server = app.listen(config.port, () => {
    logger.info({ port: config.port, ...config.build }, "Server is running");
});
connectWithRetry();

// Graceful shutdown on SIGTERM (rollouts, evictions, liveness restarts):
// 1. fail readiness and keep serving for drainSeconds. When only the container
//    restarts, the pod is NOT removed from the Service until readiness fails,
//    and the proxy keeps reusing its keep-alive connections; closing the
//    listener immediately turned those requests into 502s.
// 2. stop accepting, close idle keep-alive connections, finish in-flight
//    requests, close Mongo, flush traces, exit.
const shutdown = (signal) => {
    if (state.shuttingDown) return;
    state.shuttingDown = true;
    logger.info({ signal, drainSeconds: config.drainSeconds }, "Shutting down: draining");
    const force = setTimeout(() => {
        logger.error("Forced exit after grace period");
        process.exit(1);
    }, (config.drainSeconds + config.shutdownGraceSeconds) * 1000);
    force.unref();
    setTimeout(() => {
        logger.info("Drain period over, closing server");
        server.close(async () => {
            await mongoose.disconnect().catch(() => {});
            await tracing.shutdown();
            logger.info("Shutdown complete");
            process.exit(0);
        });
        server.closeIdleConnections();
    }, config.drainSeconds * 1000);
};

process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));
process.on("unhandledRejection", (err) => {
    logger.error({ err }, "Unhandled promise rejection");
});
