const express = require("express");
const rateLimit = require("express-rate-limit");
const router = express.Router();
const { signup , login } = require("../controllers/userController");
const config = require("../config");

// Slows down password guessing. The limit is per API pod (in-memory store), so
// with N replicas the effective limit is N times this value.
const authLimiter = rateLimit({
    windowMs: 15 * 60 * 1000,
    limit: config.authRateLimitPerWindow,
    standardHeaders: "draft-8",
    legacyHeaders: false,
    message: { message: "Too many attempts, try again later" },
});

router.post("/signup", authLimiter, signup);
router.post("/login", authLimiter, login);

module.exports = router;
