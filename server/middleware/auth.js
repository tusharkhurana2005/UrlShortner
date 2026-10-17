const jwt = require("jsonwebtoken");
const config = require("../config");

// Requires a valid "Authorization: Bearer <jwt>" header. The user id comes from
// the verified token, never from the request body, so one user cannot act on
// another user's URLs.
const requireAuth = (req, res, next) => {
    const header = req.headers.authorization || "";
    const [scheme, token] = header.split(" ");
    if (scheme !== "Bearer" || !token) {
        return res.status(401).json({ message: "Authentication required" });
    }
    try {
        const payload = jwt.verify(token, config.jwtSecret);
        req.userId = payload.sub;
        next();
    } catch {
        res.status(401).json({ message: "Invalid or expired token" });
    }
};

module.exports = { requireAuth };
