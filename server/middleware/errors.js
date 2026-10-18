const logger = require("../logger");

const notFound = (req, res) => {
    res.status(404).json({ message: "Not found" });
};

// Express 5 forwards rejected promises from async handlers here, so a bug in a
// controller becomes a logged 500 instead of crashing the whole process.
const errorHandler = (err, req, res, next) => {
    const status = err.status || err.statusCode || 500;
    (req.log || logger).error({ err }, "request failed");
    res.status(status).json({
        message: status >= 500 ? "Internal server error" : err.message,
    });
};

module.exports = { notFound, errorHandler };
