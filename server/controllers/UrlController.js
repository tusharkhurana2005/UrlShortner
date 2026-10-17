const crypto = require("crypto");
const UrlModel = require("../models/url");
const { urlsCreated, redirects } = require("../metrics");

const ALPHABET = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
const SHORT_LENGTH = 7;
const MAX_ATTEMPTS = 5;

// Random base62 id. The baseline hashed the long URL, so the same URL always
// produced the same id and a second request for it crashed the process.
const randomShortId = () => {
    let id = "";
    for (let i = 0; i < SHORT_LENGTH; i++) {
        id += ALPHABET[crypto.randomInt(ALPHABET.length)];
    }
    return id;
};

// Only http(s) targets are allowed so a short link can never become a
// javascript: or data: URL. A missing scheme defaults to https.
const normalizeUrl = (input) => {
    if (typeof input !== "string" || !input.trim()) {
        return null;
    }
    const value = /^[a-z][a-z0-9+.-]*:/i.test(input.trim()) ? input.trim() : `https://${input.trim()}`;
    try {
        const url = new URL(value);
        if (url.protocol !== "http:" && url.protocol !== "https:") {
            return null;
        }
        return url.toString();
    } catch {
        return null;
    }
};

const createShortUrl = async (req, res) => {
    const redirectUrl = normalizeUrl(req.body && req.body.Url);
    if (!redirectUrl) {
        return res.status(400).json({ message: "A valid http(s) URL is required" });
    }

    for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
        try {
            const url = await UrlModel.create({
                userId: req.userId,
                redirectUrl,
                shortUrl: randomShortId(),
            });
            urlsCreated.inc();
            req.log.info({ shortUrl: url.shortUrl }, "short url created");
            return res.status(201).json({
                message: "Url Created Successfully",
                Url: url,
            });
        } catch (error) {
            // 11000 = duplicate key on the unique shortUrl index: retry with a new id.
            if (error.code !== 11000) {
                throw error;
            }
        }
    }
    res.status(503).json({ message: "Could not allocate a short URL, try again" });
}

const getAllUrls = async (req, res) => {
    const urls = await UrlModel.find({ userId: req.userId }).sort({ createdAt: -1 });
    res.status(200).json({ urls : urls });
}

const getUrl = async (req, res) => {
    const shortId = req.query.shortUrl;
    const url = typeof shortId === "string" ? await UrlModel.findOne({ shortUrl: shortId }) : null;
    if (!url) {
        redirects.inc({ result: "not_found" });
        return res.status(404).json({ message: "Url not found" });
    }
    redirects.inc({ result: "found" });
    res.status(200).json({ url: url });
}

// Server-side redirect: GET /r/:id -> 302 to the long URL. Works for anyone with
// the link (no login, no JavaScript), which is how short links are normally shared.
const redirect = async (req, res) => {
    const url = await UrlModel.findOne({ shortUrl: req.params.id });
    if (!url) {
        redirects.inc({ result: "not_found" });
        return res.status(404).json({ message: "Url not found" });
    }
    redirects.inc({ result: "found" });
    res.redirect(302, url.redirectUrl);
}

const deleteUrl = async (req, res) => {
    const url = await UrlModel.findOneAndDelete({
        shortUrl: req.params.id,
        userId: req.userId
    })
    if (!url) {
        return res.status(404).json({ message: "Url not found" });
    }
    res.status(200).json({ message: "Url Deleted Successfully" });
}

module.exports = { createShortUrl , getAllUrls , getUrl , deleteUrl, redirect, normalizeUrl };
