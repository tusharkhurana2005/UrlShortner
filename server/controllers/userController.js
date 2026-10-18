const userModel = require("../models/user");
const bcrypt = require("bcrypt");
const jwt = require("jsonwebtoken");
const config = require("../config");
const { authAttempts } = require("../metrics");

const signup = async (req, res) => {
    const { name, email, password } = req.body || {};
    if (!name || !email || !password) {
        authAttempts.inc({ action: "signup", result: "invalid" });
        return res.status(400).json({ message: "name, email and password are required" });
    }
    if (String(password).length < 8) {
        authAttempts.inc({ action: "signup", result: "invalid" });
        return res.status(400).json({ message: "Password must be at least 8 characters" });
    }

    try {
        const hashedPass = await bcrypt.hash(String(password), 10);
        const user = await userModel.create({
            name,
            email,
            password: hashedPass
        });
        authAttempts.inc({ action: "signup", result: "success" });
        res.status(201).json(
            {
                message: "User Created Successfully",
                User : user
            }
        );
    } catch (error) {
        if (error.code === 11000) {
            authAttempts.inc({ action: "signup", result: "conflict" });
            return res.status(409).json({ message: "An account with this email already exists" });
        }
        throw error;
    }
};

const login = async (req, res) => {
    const { email, password } = req.body || {};
    if (!email || !password) {
        authAttempts.inc({ action: "login", result: "invalid" });
        return res.status(400).json({ message: "email and password are required" });
    }

    const user = await userModel.findOne({ email: String(email).toLowerCase().trim() });
    // Same response for unknown email and wrong password so the API does not
    // reveal which emails have accounts.
    if (!user || !(await bcrypt.compare(String(password), user.password))) {
        authAttempts.inc({ action: "login", result: "failure" });
        return res.status(401).json({ message: "Invalid credentials" });
    }

    // Only the user id and email go in the token. The baseline embedded the
    // whole user document, including the password hash.
    const token = jwt.sign(
        { sub: user._id.toString(), email: user.email },
        config.jwtSecret,
        { expiresIn: config.jwtExpiresIn }
    );
    authAttempts.inc({ action: "login", result: "success" });
    return res.status(200).json({ result: user, token  , message : "User Logged In Successfully" });
}

module.exports = { signup , login };
